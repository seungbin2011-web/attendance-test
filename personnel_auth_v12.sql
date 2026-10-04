-- 현장 업무 통합 로그인 v0.12 · 기존 인원 최초 로그인 때 로그인 번호 자동 이관
-- SQL 버전: personnel_auth v0.12 / Season 2 / 작성 2026-10-03
-- 선행 조건: personnel_auth_v08 ~ v11 적용
-- 적용 방법: Supabase SQL Editor에서 이 파일만 단독 실행 → personnel_auth_v12_check.sql을 별도 탭에서 실행
--
-- 바뀌는 것 (표·행 변경 없음)
--   1) pilot_member_login4: 번호가 맞는 사람이 없고, 같은 이름의 현재 인원 중 아직 로그인 번호가 없는 사람이 있으면
--      FIRST_LOGIN_REQUIRED를 돌려준다. 번호가 맞더라도 같은 이름의 번호 없는 현재 인원이 있으면 AMBIGUOUS
--      (같은 번호일 수 있어 한 사람으로 확정하지 않음). 나머지는 v0.11과 같음
--   2) pilot_member_login4_migrate 추가 (Edge Function 전용, service_role만): 정식 인원DB(Apps Script) 확인 결과를 받아
--      - 재직(active) + 현재 소속 + 로그인 번호 없음 + 사용 중지 아님인 같은 이름 1명에게만 번호를 bcrypt 해시로 저장
--      - 같은 이름이 여럿이면 정식 인원DB 사용자ID로만 구분, 안 되면 AMBIGUOUS
--      - 기존 사용자ID가 있는 사람은 정식 인원DB 사용자ID와 같아야 함 (다른 동명이인 연결 방지)
--      - 명단에 없는 사람은 NOT_IN_PILOT, 비활성은 ACCOUNT_DISABLED, 확인 실패는 기존 실패 한도에 기록
--   이관이 끝난 사람은 다음 로그인부터 Apps Script를 부르지 않는다.
--   최초 이관 끄기: Edge Function Secrets에 MEMBER_LOGIN_FIRST_LOGIN_FALLBACK=off (또는 이 함수 롤백)
-- 롤백: personnel_auth_v12_rollback.sql
begin;

do $pre$
begin
  if to_regprocedure('public.pilot_member_login4(text,text,text)') is null
     or to_regprocedure('personnel_pilot_v1.set_login4(uuid,text,text)') is null then
    raise exception 'PRECHECK: personnel_auth_v11.sql을 먼저 적용해야 함';
  end if;
end $pre$;

-- 1) 로그인: 아직 번호가 없는 현재 인원은 최초 이관 대상으로 알려 줌
create or replace function public.pilot_member_login4(p_name text, p_code text, p_client_ip text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  c_name_fail_limit constant int := 5;
  c_name_lock constant interval := interval '30 minutes';
  c_ip_fail_short constant int := 20;
  c_global_fail_hour constant int := 100;
  v_key text := personnel_pilot_v1.name_key(p_name);
  v_log_key text;
  v_ip inet;
  v_since timestamptz;
  v_fail_count int;
  v_last_fail timestamptz;
  v_any uuid[];
  v_ok uuid[];
  p personnel_pilot_v1.people%rowtype;
  pin personnel_pilot_v1.member_pins%rowtype;
  al personnel_pilot_v1.account_links%rowtype;
begin
  begin
    v_ip := nullif(trim(p_client_ip), '')::inet;
  exception when others then
    v_ip := null;
  end;
  v_log_key := coalesce(left(v_key, 60), '(invalid)');

  if v_key is null or length(p_name) > 100 or p_code is null or p_code !~ '^[0-9]{4}$' then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_log_key, v_ip, 'INVALID_INPUT');
    return jsonb_build_object('ok', false, 'code', 'INVALID_INPUT');
  end if;

  perform pg_advisory_xact_lock(hashtextextended('member_login:' || v_key, 0));

  -- 실패 한도 (v0.8 PIN 로그인과 같은 기준, 같은 기록 표)
  if (select count(*) from personnel_pilot_v1.member_login_attempts
      where outcome = 'NO_MATCH' and attempted_at > clock_timestamp() - interval '1 hour') >= c_global_fail_hour then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_log_key, v_ip, 'RATE_LIMITED');
    return jsonb_build_object('ok', false, 'code', 'RATE_LIMITED');
  end if;
  if v_ip is not null and (
      select count(*) from personnel_pilot_v1.member_login_attempts
      where client_ip = v_ip
        and outcome in ('NO_MATCH', 'INVALID_INPUT', 'LOCKED', 'RATE_LIMITED')
        and attempted_at > clock_timestamp() - interval '15 minutes') >= c_ip_fail_short then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_log_key, v_ip, 'RATE_LIMITED');
    return jsonb_build_object('ok', false, 'code', 'RATE_LIMITED');
  end if;
  select coalesce(max(attempted_at), '-infinity'::timestamptz) into v_since
  from personnel_pilot_v1.member_login_attempts
  where name_key = v_key and outcome in ('OK', 'ADMIN_UNLOCK');
  select count(*), max(attempted_at) into v_fail_count, v_last_fail
  from personnel_pilot_v1.member_login_attempts
  where name_key = v_key and outcome = 'NO_MATCH' and attempted_at > v_since;
  if v_fail_count >= c_name_fail_limit and v_last_fail > clock_timestamp() - c_name_lock then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_key, v_ip, 'LOCKED');
    return jsonb_build_object('ok', false, 'code', 'LOCKED');
  end if;

  -- 같은 이름 중 번호까지 맞는 사람
  select coalesce(array_agg(q.id), '{}') into v_any
  from personnel_pilot_v1.people q join personnel_pilot_v1.member_pins c on c.person_id = q.id
  where personnel_pilot_v1.name_key(q.display_name) = v_key
    and c.login4_hash is not null and c.login4_hash = extensions.crypt(p_code, c.login4_hash);
  if cardinality(v_any) = 0 then
    perform extensions.crypt(p_code, extensions.gen_salt('bf', 10));  -- 이름이 없을 때도 비슷한 시간
    -- v0.12: 같은 이름의 현재 인원 중 아직 로그인 번호가 없는 사람이 있으면 최초 1회 이관 대상
    --        (실패 기록은 이관 함수가 정식 인원DB 확인 결과로 남긴다)
    if exists (select 1 from personnel_pilot_v1.people q
               where personnel_pilot_v1.name_key(q.display_name) = v_key and q.employment_status = 'active'
                 and exists (select 1 from personnel_pilot_v1.memberships m where m.person_id = q.id and m.valid_to is null)
                 and not exists (select 1 from personnel_pilot_v1.member_pins c where c.person_id = q.id and c.login4_hash is not null)) then
      return jsonb_build_object('ok', false, 'code', 'FIRST_LOGIN_REQUIRED');
    end if;
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_key, v_ip, 'NO_MATCH');
    return jsonb_build_object('ok', false, 'code', 'INVALID_CREDENTIALS');
  end if;
  select coalesce(array_agg(q.id), '{}') into v_ok
  from personnel_pilot_v1.people q join personnel_pilot_v1.member_pins c on c.person_id = q.id
  where q.id = any (v_any) and q.employment_status <> 'inactive' and c.enabled;
  if cardinality(v_ok) > 1 then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_key, v_ip, 'AMBIGUOUS');
    return jsonb_build_object('ok', false, 'code', 'AMBIGUOUS');
  end if;
  if cardinality(v_ok) = 0 then
    insert into personnel_pilot_v1.member_login_attempts(name_key, person_id, client_ip, outcome)
    values (v_key, v_any[1], v_ip, 'INACTIVE');
    return jsonb_build_object('ok', false, 'code', 'ACCOUNT_DISABLED');
  end if;
  -- v0.12: 같은 이름의 현재 인원 중 아직 번호가 없는 사람이 있으면 같은 번호일 수 있어 한 사람으로 확정하지 않는다
  --        (관리자 화면에서 그 사람 번호를 등록하면 풀린다. 새 인원은 등록할 때 번호가 함께 들어가므로 생기지 않음)
  if exists (select 1 from personnel_pilot_v1.people q
             where personnel_pilot_v1.name_key(q.display_name) = v_key and q.employment_status = 'active' and q.id <> v_ok[1]
               and exists (select 1 from personnel_pilot_v1.memberships m where m.person_id = q.id and m.valid_to is null)
               and not exists (select 1 from personnel_pilot_v1.member_pins c where c.person_id = q.id and c.login4_hash is not null)) then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_key, v_ip, 'AMBIGUOUS');
    return jsonb_build_object('ok', false, 'code', 'AMBIGUOUS');
  end if;

  select * into p from personnel_pilot_v1.people where id = v_ok[1];
  select * into pin from personnel_pilot_v1.member_pins where person_id = p.id;
  select * into al from personnel_pilot_v1.account_links where person_id = p.id;
  if al.auth_user_id is not null and not al.enabled then
    insert into personnel_pilot_v1.member_login_attempts(name_key, person_id, client_ip, outcome)
    values (v_key, p.id, v_ip, 'DISABLED');
    return jsonb_build_object('ok', false, 'code', 'ACCOUNT_DISABLED');
  end if;

  insert into personnel_pilot_v1.member_login_attempts(name_key, person_id, client_ip, outcome)
  values (v_key, p.id, v_ip, 'OK');
  return jsonb_build_object('ok', true, 'code', 'OK', 'person_id', p.id, 'auth_user_id', al.auth_user_id,
    'must_change_pin', coalesce(pin.must_change, false));
end $fn$;

-- 2) 최초 로그인 이관 (정식 인원DB 확인 결과 → 로그인 번호 해시 저장)
create or replace function public.pilot_member_login4_migrate(p_name text, p_code text, p_verified boolean, p_user_id text default null, p_client_ip text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  c_name_fail_limit constant int := 5;
  c_name_lock constant interval := interval '30 minutes';
  c_ip_fail_short constant int := 20;
  c_global_fail_hour constant int := 100;
  v_key text := personnel_pilot_v1.name_key(p_name);
  v_log_key text;
  v_ip inet;
  v_since timestamptz;
  v_fail_count int;
  v_last_fail timestamptz;
  v_ids uuid[];
  p personnel_pilot_v1.people%rowtype;
  pin personnel_pilot_v1.member_pins%rowtype;
  al personnel_pilot_v1.account_links%rowtype;
begin
  begin
    v_ip := nullif(trim(p_client_ip), '')::inet;
  exception when others then
    v_ip := null;
  end;
  v_log_key := coalesce(left(v_key, 60), '(invalid)');

  if v_key is null or length(p_name) > 100 or p_code is null or p_code !~ '^[0-9]{4}$' or p_verified is null then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_log_key, v_ip, 'INVALID_INPUT');
    return jsonb_build_object('ok', false, 'code', 'INVALID_INPUT');
  end if;

  perform pg_advisory_xact_lock(hashtextextended('member_login:' || v_key, 0));

  -- 실패 한도 (v0.8과 같은 기준, 같은 기록 표)
  if (select count(*) from personnel_pilot_v1.member_login_attempts
      where outcome = 'NO_MATCH' and attempted_at > clock_timestamp() - interval '1 hour') >= c_global_fail_hour then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_log_key, v_ip, 'RATE_LIMITED');
    return jsonb_build_object('ok', false, 'code', 'RATE_LIMITED');
  end if;
  if v_ip is not null and (
      select count(*) from personnel_pilot_v1.member_login_attempts
      where client_ip = v_ip
        and outcome in ('NO_MATCH', 'INVALID_INPUT', 'LOCKED', 'RATE_LIMITED')
        and attempted_at > clock_timestamp() - interval '15 minutes') >= c_ip_fail_short then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_log_key, v_ip, 'RATE_LIMITED');
    return jsonb_build_object('ok', false, 'code', 'RATE_LIMITED');
  end if;
  select coalesce(max(attempted_at), '-infinity'::timestamptz) into v_since
  from personnel_pilot_v1.member_login_attempts
  where name_key = v_key and outcome in ('OK', 'ADMIN_UNLOCK');
  select count(*), max(attempted_at) into v_fail_count, v_last_fail
  from personnel_pilot_v1.member_login_attempts
  where name_key = v_key and outcome = 'NO_MATCH' and attempted_at > v_since;
  if v_fail_count >= c_name_fail_limit and v_last_fail > clock_timestamp() - c_name_lock then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_key, v_ip, 'LOCKED');
    return jsonb_build_object('ok', false, 'code', 'LOCKED');
  end if;

  -- 정식 인원DB에서 이름 + 뒤 4자리가 확인되지 않으면 실패 기록만
  if not p_verified then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_key, v_ip, 'NO_MATCH');
    return jsonb_build_object('ok', false, 'code', 'INVALID_CREDENTIALS');
  end if;

  -- 이관 대상: 같은 이름의 재직(active) + 현재 소속 있음 + 아직 로그인 번호 없음 + 로그인 사용 중지 아님
  select coalesce(array_agg(q.id), '{}') into v_ids
  from personnel_pilot_v1.people q
  where personnel_pilot_v1.name_key(q.display_name) = v_key and q.employment_status = 'active'
    and exists (select 1 from personnel_pilot_v1.memberships m where m.person_id = q.id and m.valid_to is null)
    and not exists (select 1 from personnel_pilot_v1.member_pins c where c.person_id = q.id and (c.login4_hash is not null or not c.enabled))
    and not exists (select 1 from personnel_pilot_v1.account_links l where l.person_id = q.id and not l.enabled);
  if cardinality(v_ids) > 1 then
    -- 같은 이름이 여럿이면 정식 인원DB 사용자ID로만 구분
    select coalesce(array_agg(q.id), '{}') into v_ids
    from personnel_pilot_v1.people q where q.id = any (v_ids) and q.legacy_user_id = nullif(trim(p_user_id), '');
    if cardinality(v_ids) <> 1 then
      insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
      values (v_key, v_ip, 'AMBIGUOUS');
      return jsonb_build_object('ok', false, 'code', 'AMBIGUOUS');
    end if;
  end if;
  if cardinality(v_ids) = 0 then
    if exists (select 1 from personnel_pilot_v1.people q where personnel_pilot_v1.name_key(q.display_name) = v_key
               and (q.employment_status = 'inactive'
                    or exists (select 1 from personnel_pilot_v1.member_pins c where c.person_id = q.id and not c.enabled))) then
      insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
      values (v_key, v_ip, 'INACTIVE');
      return jsonb_build_object('ok', false, 'code', 'ACCOUNT_DISABLED');
    end if;
    return jsonb_build_object('ok', false, 'code', 'NOT_IN_PILOT');
  end if;

  select * into p from personnel_pilot_v1.people where id = v_ids[1];
  -- 기존 사용자ID가 있는 사람은 정식 인원DB가 돌려준 사용자ID와 같아야 한다 (다른 동명이인 연결 방지)
  if p.legacy_user_id is not null and nullif(trim(p_user_id), '') is not null and p.legacy_user_id <> trim(p_user_id) then
    insert into personnel_pilot_v1.member_login_attempts(name_key, person_id, client_ip, outcome)
    values (v_key, p.id, v_ip, 'AMBIGUOUS');
    return jsonb_build_object('ok', false, 'code', 'AMBIGUOUS');
  end if;

  begin
    perform personnel_pilot_v1.set_login4(p.id, p_code, 'first_login');
  exception when sqlstate '23505' then
    insert into personnel_pilot_v1.member_login_attempts(name_key, person_id, client_ip, outcome)
    values (v_key, p.id, v_ip, 'AMBIGUOUS');
    return jsonb_build_object('ok', false, 'code', 'AMBIGUOUS');
  end;

  select * into pin from personnel_pilot_v1.member_pins where person_id = p.id;
  select * into al from personnel_pilot_v1.account_links where person_id = p.id;
  insert into personnel_pilot_v1.member_login_attempts(name_key, person_id, client_ip, outcome)
  values (v_key, p.id, v_ip, 'OK');
  return jsonb_build_object('ok', true, 'code', 'OK', 'person_id', p.id, 'auth_user_id', al.auth_user_id,
    'must_change_pin', coalesce(pin.must_change, false), 'migrated', true);
end $fn$;

revoke all on function public.pilot_member_login4_migrate(text, text, boolean, text, text) from public, anon, authenticated;
grant execute on function public.pilot_member_login4_migrate(text, text, boolean, text, text) to service_role;

commit;
