-- personnel_auth v0.12 롤백 · 최초 로그인 이관을 끄고 v0.11 로그인으로 되돌린다
-- 적용 방법: Edge Function을 MEMBER_LOGIN_FIRST_LOGIN_FALLBACK=off로 두거나 v0.3으로 되돌린 뒤 이 파일만 단독 실행
-- 이미 이관된 로그인 번호 해시는 그대로 둔다 (지우지 않음)
begin;

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

drop function if exists public.pilot_member_login4_migrate(text, text, boolean, text, text);

commit;
