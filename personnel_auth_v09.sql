-- 현장 업무 통합 로그인 v0.9 · 휴대폰 번호 뒤 4자리 로그인 (기존 정식 인원DB 확인 결과 연결)
-- SQL 버전: personnel_auth v0.9 / Season 2 현장 시연 준비 / 작성 2026-10-01
-- 선행 조건: personnel_auth_v08.sql 적용
-- 적용 방법: Supabase SQL Editor에서 이 파일만 단독 실행 → personnel_auth_v09_check.sql을 별도 탭에서 실행
-- 추가형 변경만 포함한다. (새 함수 1개. 기존 표 구조·기존 함수 변경 없음)
--
-- 동작
--   * 휴대폰 번호는 Supabase에 저장하지 않는다. 이름 + 뒤 4자리 확인은 Edge Function이 기존 정식 인원DB(Apps Script)에 묻는다.
--   * 이 함수는 그 확인 결과(p_verified, 정식 인원DB의 사용자ID)를 받아
--     실패 한도·잠금을 적용하고, 인원(people.id)을 찾아 개인 세션 발급에 필요한 정보를 돌려준다.
--   * v0.8의 실패 기록 표와 한도를 그대로 쓴다: 같은 이름 연속 5회 실패 시 30분 잠금, IP별 15분 20회, 전체 1시간 100회.
--   * 개인 PIN 행이 없으면 "로그인 허용 표시" 행을 만든다. (무작위 값의 해시라 PIN으로는 로그인할 수 없음)
--     기존 v0.8 함수(current_actor, 계정 연결)가 이 행으로 로그인 허용·사용 중지를 판단하기 때문이다.
--   * 역할은 v0.8과 같다: 팀장(TEAM_LEADER)만 개인 로그인에 부여, 소장·관리자는 업무계정만.
-- 롤백: personnel_auth_v09_rollback.sql
begin;

do $pre$
begin
  if to_regclass('personnel_pilot_v1.member_pins') is null
     or to_regprocedure('public.pilot_member_link_account(uuid,uuid)') is null then
    raise exception 'PRECHECK: personnel_auth_v08.sql을 먼저 적용해야 함';
  end if;
  if to_regprocedure('public.pilot_member_roster_login(text,text,boolean,text)') is not null then
    raise exception 'PRECHECK: v0.9 함수가 이미 있음. 중복 적용 중단';
  end if;
end $pre$;

-- 이름 + 휴대폰 뒤 4자리 로그인 (Edge Function 전용, service_role만 실행)
-- p_verified: 정식 인원DB가 이름·뒤 4자리를 확인했는지, p_user_id: 정식 인원DB가 돌려준 사용자ID
create function public.pilot_member_roster_login(p_name text, p_user_id text, p_verified boolean, p_client_ip text default null)
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

  if v_key is null or length(p_name) > 100 or p_verified is null
     or (p_verified and (p_user_id is null or length(trim(p_user_id)) not between 1 and 40)) then
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

  if not p_verified then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_key, v_ip, 'NO_MATCH');
    return jsonb_build_object('ok', false, 'code', 'INVALID_CREDENTIALS');
  end if;

  -- 정식 인원DB 사용자ID로 인원 찾기. 같은 ID가 여러 행이면(기존 ID 중복) 이름으로 구분한다.
  select array_agg(id) into v_ids from personnel_pilot_v1.people where legacy_user_id = trim(p_user_id);
  if coalesce(array_length(v_ids, 1), 0) > 1 then
    select array_agg(id) into v_ids from personnel_pilot_v1.people
    where legacy_user_id = trim(p_user_id) and personnel_pilot_v1.name_key(display_name) = v_key;
  end if;
  if coalesce(array_length(v_ids, 1), 0) = 0 then
    if exists (select 1 from personnel_pilot_v1.people where legacy_user_id = trim(p_user_id)) then
      insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
      values (v_key, v_ip, 'AMBIGUOUS');
      return jsonb_build_object('ok', false, 'code', 'AMBIGUOUS');
    end if;
    return jsonb_build_object('ok', false, 'code', 'NOT_IN_PILOT');
  end if;
  if array_length(v_ids, 1) > 1 then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_key, v_ip, 'AMBIGUOUS');
    return jsonb_build_object('ok', false, 'code', 'AMBIGUOUS');
  end if;

  select * into p from personnel_pilot_v1.people where id = v_ids[1];
  if p.employment_status = 'inactive' then
    insert into personnel_pilot_v1.member_login_attempts(name_key, person_id, client_ip, outcome)
    values (v_key, p.id, v_ip, 'INACTIVE');
    return jsonb_build_object('ok', false, 'code', 'ACCOUNT_DISABLED');
  end if;

  select * into pin from personnel_pilot_v1.member_pins where person_id = p.id;
  select * into al from personnel_pilot_v1.account_links where person_id = p.id;
  if (pin.person_id is not null and not pin.enabled) or (al.auth_user_id is not null and not al.enabled) then
    insert into personnel_pilot_v1.member_login_attempts(name_key, person_id, client_ip, outcome)
    values (v_key, p.id, v_ip, 'DISABLED');
    return jsonb_build_object('ok', false, 'code', 'ACCOUNT_DISABLED');
  end if;

  -- 로그인 허용 표시 행 (PIN으로는 쓸 수 없는 무작위 값의 해시)
  if pin.person_id is null then
    insert into personnel_pilot_v1.member_pins(person_id, pin_hash, pin_kind, must_change, enabled)
    values (p.id, extensions.crypt(encode(extensions.gen_random_bytes(24), 'hex'), extensions.gen_salt('bf', 6)), 'PERSONAL', false, true)
    on conflict do nothing;
    select * into pin from personnel_pilot_v1.member_pins where person_id = p.id;
  end if;

  insert into personnel_pilot_v1.member_login_attempts(name_key, person_id, client_ip, outcome)
  values (v_key, p.id, v_ip, 'OK');

  return jsonb_build_object(
    'ok', true,
    'code', 'OK',
    'person_id', p.id,
    'auth_user_id', al.auth_user_id,
    'must_change_pin', coalesce(pin.must_change, false)
  );
end $fn$;

revoke all on function public.pilot_member_roster_login(text, text, boolean, text) from public, anon, authenticated;
grant execute on function public.pilot_member_roster_login(text, text, boolean, text) to service_role;

commit;
