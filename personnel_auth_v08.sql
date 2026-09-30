-- 현장 업무 통합 로그인 v0.8 · 개인 PIN 로그인 기반
-- SQL 버전: personnel_auth v0.8 / 전환 단계: S0-2 / 작성 2026-09-30
-- 적용 대상: Supabase work-status-test · personnel_pilot_v1 시험 스키마
-- 적용 방법: Supabase SQL Editor에서 전체 실행 → personnel_auth_v08_check.sql로 확인
-- 추가형 변경만 포함한다. (기존 테이블 구조·행, 기존 pilot 함수 변경 없음)
--
-- 원칙
--   * 기존 테이블 구조·행과 기존 함수(pilot_roster 등)는 변경하지 않는다.
--   * 새 테이블은 API 비노출 스키마 personnel_pilot_v1에만 만들고 직접 접근을 막는다.
--   * PIN은 bcrypt 해시로만 저장한다. 전화번호는 사용하지 않는다.
--   * 로그인 검증·계정 연결 함수는 service_role(Edge Function)만 실행한다.
--   * 역할은 서버 정보로만 판단한다.
--       업무계정: login_profiles
--       개인 로그인: account_links → people → memberships / role_assignments
--   * 개인 PIN 로그인에는 소장·관리자 권한을 주지 않는다. (허용 역할: MEMBER, TEAM_LEADER)
--   * PIN은 발급된 사람 중 퇴사(inactive)가 아닌 사람만 사용할 수 있다. (unknown 허용, 일괄 active 처리 없음)
--   * 로그인 실패: 같은 이름 연속 5회 실패 시 30분 잠금, IP별·전체 실패 한도 별도 적용
--   * 내부 기록은 people.id(UUID) 기준, legacy_user_id는 표시용이다.
-- 롤백: personnel_auth_v08_rollback.sql
begin;

-- 0. 사전 확인 (다르면 전체 중단)
do $pre$
begin
  if to_regclass('personnel_pilot_v1.people') is null
     or to_regclass('personnel_pilot_v1.login_profiles') is null
     or to_regclass('personnel_pilot_v1.account_links') is null
     or to_regclass('personnel_pilot_v1.memberships') is null
     or to_regclass('personnel_pilot_v1.role_assignments') is null
     or to_regclass('personnel_pilot_v1.teams') is null
     or to_regclass('personnel_pilot_v1.sites') is null then
    raise exception 'PRECHECK: personnel_pilot_v1 기존 구조가 예상과 다름';
  end if;
  if not exists (
    select 1 from pg_extension
    where extname = 'pgcrypto' and extnamespace = 'extensions'::regnamespace
  ) then
    raise exception 'PRECHECK: extensions 스키마의 pgcrypto 필요';
  end if;
  if to_regclass('auth.sessions') is null or to_regprocedure('auth.jwt()') is null then
    raise exception 'PRECHECK: auth.sessions / auth.jwt() 필요';
  end if;
  if to_regclass('personnel_pilot_v1.member_pins') is not null then
    raise exception 'PRECHECK: v0.8 객체가 이미 있음. 중복 적용 중단';
  end if;
end $pre$;

-- 1. 개인 PIN (bcrypt 해시만 저장)
create table personnel_pilot_v1.member_pins (
  person_id uuid primary key references personnel_pilot_v1.people(id),
  pin_hash text not null check (pin_hash like '$2_$%'),
  pin_kind text not null check (pin_kind in ('TEMP', 'PERSONAL')),
  must_change boolean not null,
  enabled boolean not null default true,
  issued_at timestamptz not null default clock_timestamp(),
  changed_at timestamptz,
  check (pin_kind <> 'TEMP' or must_change)
);

-- 2. 로그인 시도 기록 (실패 제한·감사)
create table personnel_pilot_v1.member_login_attempts (
  id bigint generated always as identity primary key,
  attempted_at timestamptz not null default clock_timestamp(),
  name_key text not null,
  person_id uuid references personnel_pilot_v1.people(id),
  client_ip inet,
  outcome text not null check (outcome in (
    'OK', 'NO_MATCH', 'AMBIGUOUS', 'INACTIVE', 'DISABLED',
    'LOCKED', 'RATE_LIMITED', 'INVALID_INPUT', 'ADMIN_UNLOCK'))
);
create index member_login_attempts_name_idx
  on personnel_pilot_v1.member_login_attempts (name_key, attempted_at desc);
create index member_login_attempts_ip_idx
  on personnel_pilot_v1.member_login_attempts (client_ip, attempted_at desc)
  where client_ip is not null;
create index member_login_attempts_time_idx
  on personnel_pilot_v1.member_login_attempts (attempted_at desc);

-- 3. PIN·개인 계정 관리 이력
create table personnel_pilot_v1.member_pin_events (
  id bigint generated always as identity primary key,
  person_id uuid not null references personnel_pilot_v1.people(id),
  event text not null check (event in (
    'ISSUE_TEMP', 'CHANGE', 'CHANGE_FAIL', 'DISABLE', 'ENABLE', 'UNLOCK', 'LINK_ACCOUNT')),
  actor text not null,
  reason text,
  created_at timestamptz not null default clock_timestamp()
);
create index member_pin_events_person_idx
  on personnel_pilot_v1.member_pin_events (person_id, created_at desc);

alter table personnel_pilot_v1.member_pins enable row level security;
alter table personnel_pilot_v1.member_login_attempts enable row level security;
alter table personnel_pilot_v1.member_pin_events enable row level security;
revoke all on table
  personnel_pilot_v1.member_pins,
  personnel_pilot_v1.member_login_attempts,
  personnel_pilot_v1.member_pin_events
from public, anon, authenticated, service_role;

-- 4. 내부 함수 (API 비노출, 다른 함수에서만 사용)

-- 이름 비교용 정규화: NFC, 공백 제거, 소문자
create function personnel_pilot_v1.name_key(p_name text) returns text
language sql immutable set search_path = ''
as $fn$
  select nullif(lower(regexp_replace(normalize(coalesce(p_name, ''), nfc), '\s+', '', 'g')), '')
$fn$;

-- 사용할 수 없는 PIN: 6자리 숫자가 아님, 같은 숫자 반복, 연속 숫자, 12/123 반복
create function personnel_pilot_v1.pin_is_weak(p_pin text) returns boolean
language sql immutable set search_path = ''
as $fn$
  select p_pin is null
      or p_pin !~ '^[0-9]{6}$'
      or p_pin ~ '^([0-9])\1{5}$'
      or '01234567890' like '%' || p_pin || '%'
      or '09876543210' like '%' || p_pin || '%'
      or p_pin ~ '^([0-9]{2})\1\1$'
      or p_pin ~ '^([0-9]{3})\1$'
$fn$;

-- 같은 이름의 다른 인원이 이미 같은 PIN을 쓰는지 (동명이인 충돌 방지)
create function personnel_pilot_v1.pin_collides(p_person_id uuid, p_pin text) returns boolean
language sql stable set search_path = ''
as $fn$
  select exists (
    select 1
    from personnel_pilot_v1.people me
    join personnel_pilot_v1.people other
      on personnel_pilot_v1.name_key(other.display_name) = personnel_pilot_v1.name_key(me.display_name)
     and other.id <> me.id
    join personnel_pilot_v1.member_pins c on c.person_id = other.id
    where me.id = p_person_id
      and c.pin_hash = extensions.crypt(p_pin, c.pin_hash)
  )
$fn$;

-- 현재 로그인 사용자의 서버 기준 신원·역할 (모든 업무 RPC의 공통 기준)
create function personnel_pilot_v1.current_actor() returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare
  c_pin_roles constant text[] := array['TEAM_LEADER'];
  c_member_session_max constant interval := interval '16 hours';
  v_uid uuid := auth.uid();
  v_claims jsonb := auth.jwt();
  v_session_created timestamptz;
  lp personnel_pilot_v1.login_profiles%rowtype;
  al personnel_pilot_v1.account_links%rowtype;
  p personnel_pilot_v1.people%rowtype;
  pin personnel_pilot_v1.member_pins%rowtype;
  v_roles text[];
  v_site_codes jsonb;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(s.code order by s.code), '[]'::jsonb) into v_site_codes
  from personnel_pilot_v1.sites s where s.is_active;

  -- 업무계정 (관리자·소장·팀 공용 계정): 기존 방식 유지
  select * into lp
  from personnel_pilot_v1.login_profiles
  where auth_user_id = v_uid and enabled;
  if found then
    return jsonb_build_object(
      'kind', 'WORK_ACCOUNT',
      'auth_source', 'supabase-v2',
      'auth_user_id', v_uid,
      'person_id', null,
      'user_id', 'SUPA-' || lp.app_role,
      'name', lp.login_name,
      'app_role', lp.app_role,
      'roles', case lp.app_role
                 when 'ADMIN' then '["ADMIN"]'
                 when 'MANAGER' then '["SITE_MANAGER"]'
                 when 'LEADER' then '["TEAM_LEADER"]'
                 when 'MATERIAL' then '["MATERIAL_STAFF"]'
                 else '[]' end::jsonb,
      'role_label', case lp.app_role
                      when 'ADMIN' then '관리자' when 'MANAGER' then '소장'
                      when 'LEADER' then '팀장' when 'MATERIAL' then '자재' end,
      'team', coalesce(lp.team_scope, '현장소장'),
      'team_scopes', case when lp.team_scope is null then '[]'::jsonb
                          else jsonb_build_array(jsonb_build_object(
                            'team_name', lp.team_scope,
                            'team_id', (select t.id from personnel_pilot_v1.teams t
                                        where t.name = lp.team_scope order by t.id limit 1))) end,
      'site_codes', v_site_codes,
      'personal', false,
      'must_change_pin', false
    );
  end if;

  -- 개인 로그인: 계정 연결 → 인원 → 소속·역할
  select * into al from personnel_pilot_v1.account_links where auth_user_id = v_uid;
  if not found or not al.enabled then
    raise exception 'ACCOUNT_NOT_LINKED' using errcode = '42501';
  end if;

  select * into p from personnel_pilot_v1.people where id = al.person_id;
  if not found or p.employment_status = 'inactive' then
    raise exception 'ACCOUNT_INACTIVE' using errcode = '42501';
  end if;

  select * into pin from personnel_pilot_v1.member_pins where person_id = p.id;
  if not found or not pin.enabled then
    raise exception 'ACCOUNT_DISABLED' using errcode = '42501';
  end if;

  -- 개인 PIN 세션은 로그인 후 최대 16시간, 로그아웃·폐기된 세션은 즉시 거부
  select s.created_at into v_session_created
  from auth.sessions s
  where s.id = nullif(v_claims ->> 'session_id', '')::uuid
    and s.user_id = v_uid;
  if v_session_created is null or v_session_created < now() - c_member_session_max then
    raise exception 'SESSION_EXPIRED' using errcode = '42501';
  end if;

  select array['MEMBER'] || coalesce(array_agg(distinct r.role_code order by r.role_code), array[]::text[])
  into v_roles
  from personnel_pilot_v1.memberships m
  join personnel_pilot_v1.role_assignments r
    on r.membership_id = m.id and r.revoked_at is null
  where m.person_id = p.id and m.valid_to is null
    and r.role_code = any (c_pin_roles);

  return jsonb_build_object(
    'kind', 'MEMBER_PIN',
    'auth_source', 'supabase-pin',
    'auth_user_id', v_uid,
    'person_id', p.id,
    'user_id', p.legacy_user_id,
    'name', p.display_name,
    'rank', p.rank_title,
    'job', p.job_title,
    'team', p.team_name,
    'attendance_grade', p.attendance_grade,
    'app_role', case when 'TEAM_LEADER' = any (v_roles) then 'LEADER' else 'MEMBER' end,
    'roles', to_jsonb(v_roles),
    'role_label', case when 'TEAM_LEADER' = any (v_roles) then '팀장' else '팀원' end,
    'team_scopes', (
      select coalesce(jsonb_agg(distinct jsonb_build_object('team_id', t.id, 'team_name', t.name, 'site_code', s.code)), '[]'::jsonb)
      from personnel_pilot_v1.memberships m
      join personnel_pilot_v1.role_assignments r
        on r.membership_id = m.id and r.revoked_at is null and r.role_code = 'TEAM_LEADER'
      join personnel_pilot_v1.teams t on t.id = m.team_id
      join personnel_pilot_v1.sites s on s.id = m.site_id
      where m.person_id = p.id and m.valid_to is null
        and 'TEAM_LEADER' = any (c_pin_roles)),
    'memberships', (
      select coalesce(jsonb_agg(jsonb_build_object('site_code', s.code, 'team_id', t.id, 'team_name', t.name)), '[]'::jsonb)
      from personnel_pilot_v1.memberships m
      join personnel_pilot_v1.sites s on s.id = m.site_id
      left join personnel_pilot_v1.teams t on t.id = m.team_id
      where m.person_id = p.id and m.valid_to is null),
    'site_codes', (
      select coalesce(jsonb_agg(distinct s.code), '[]'::jsonb)
      from personnel_pilot_v1.memberships m
      join personnel_pilot_v1.sites s on s.id = m.site_id
      where m.person_id = p.id and m.valid_to is null),
    'personal', true,
    'must_change_pin', pin.must_change,
    'session_expires_at', v_session_created + c_member_session_max
  );
end $fn$;

-- 업무 RPC용 공통 검사: PIN 변경 필요 시 차단, 필요한 역할 확인
create function personnel_pilot_v1.require_actor(p_roles text[] default null) returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare a jsonb := personnel_pilot_v1.current_actor();
begin
  if coalesce((a ->> 'must_change_pin')::boolean, false) then
    raise exception 'PIN_CHANGE_REQUIRED' using errcode = '42501';
  end if;
  if p_roles is not null and not ((a -> 'roles') ?| p_roles) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return a;
end $fn$;

-- 5. 공개 RPC

-- 5-1. 이름 + PIN 검증 (Edge Function 전용, service_role만 실행)
--      실패도 기록해야 하므로 예외 대신 결과 코드를 반환한다.
create function public.pilot_member_login_verify(p_name text, p_pin text, p_client_ip text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  c_name_fail_limit constant int := 5;           -- 같은 이름 연속 실패 한도
  c_name_lock constant interval := interval '30 minutes';  -- 연속 실패 후 잠금 시간
  c_ip_fail_short constant int := 20;            -- IP별 15분 실패 한도
  c_global_fail_hour constant int := 100;        -- 전체 1시간 실패 한도
  v_key text := personnel_pilot_v1.name_key(p_name);
  v_log_key text;
  v_ip inet;
  v_since timestamptz;
  v_fail_count int;
  v_last_fail timestamptz;
  v_candidates int;
  v_matches uuid[];
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

  if v_key is null or length(p_name) > 100 or p_pin is null or p_pin !~ '^[0-9]{6}$' then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_log_key, v_ip, 'INVALID_INPUT');
    return jsonb_build_object('ok', false, 'code', 'INVALID_INPUT');
  end if;

  -- 같은 이름 동시 시도 직렬화
  perform pg_advisory_xact_lock(hashtextextended('member_login:' || v_key, 0));

  -- 전체 실패 급증 (여러 이름에 흩뿌리는 대입 공격)
  if (select count(*) from personnel_pilot_v1.member_login_attempts
      where outcome = 'NO_MATCH' and attempted_at > clock_timestamp() - interval '1 hour') >= c_global_fail_hour then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_log_key, v_ip, 'RATE_LIMITED');
    return jsonb_build_object('ok', false, 'code', 'RATE_LIMITED');
  end if;

  -- IP별 실패 한도
  if v_ip is not null and (
      select count(*) from personnel_pilot_v1.member_login_attempts
      where client_ip = v_ip
        and outcome in ('NO_MATCH', 'INVALID_INPUT', 'LOCKED', 'RATE_LIMITED')
        and attempted_at > clock_timestamp() - interval '15 minutes') >= c_ip_fail_short then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_log_key, v_ip, 'RATE_LIMITED');
    return jsonb_build_object('ok', false, 'code', 'RATE_LIMITED');
  end if;

  -- 이름별 잠금: 마지막 성공·관리자 해제 이후 연속 실패가 5회 이상이고
  --             마지막 실패 후 30분이 지나지 않았으면 잠금
  select coalesce(max(attempted_at), '-infinity'::timestamptz) into v_since
  from personnel_pilot_v1.member_login_attempts
  where name_key = v_key and outcome in ('OK', 'ADMIN_UNLOCK');

  select count(*), max(attempted_at)
  into v_fail_count, v_last_fail
  from personnel_pilot_v1.member_login_attempts
  where name_key = v_key and outcome = 'NO_MATCH' and attempted_at > v_since;

  if v_fail_count >= c_name_fail_limit and v_last_fail > clock_timestamp() - c_name_lock then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_key, v_ip, 'LOCKED');
    return jsonb_build_object('ok', false, 'code', 'LOCKED');
  end if;

  -- 이름이 같은 인원 중 PIN이 맞는 사람
  select count(*),
         array_agg(p2.id) filter (where c.pin_hash = extensions.crypt(p_pin, c.pin_hash))
  into v_candidates, v_matches
  from personnel_pilot_v1.people p2
  join personnel_pilot_v1.member_pins c on c.person_id = p2.id
  where personnel_pilot_v1.name_key(p2.display_name) = v_key;

  if v_candidates = 0 then
    -- 이름 존재 여부가 응답 시간으로 드러나지 않도록 같은 비용의 계산 수행
    perform extensions.crypt(p_pin, extensions.gen_salt('bf', 10));
  end if;

  if coalesce(array_length(v_matches, 1), 0) = 0 then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_key, v_ip, 'NO_MATCH');
    return jsonb_build_object('ok', false, 'code', 'INVALID_CREDENTIALS');
  end if;

  if array_length(v_matches, 1) > 1 then
    insert into personnel_pilot_v1.member_login_attempts(name_key, client_ip, outcome)
    values (v_key, v_ip, 'AMBIGUOUS');
    return jsonb_build_object('ok', false, 'code', 'AMBIGUOUS');
  end if;

  select * into p from personnel_pilot_v1.people where id = v_matches[1];
  select * into pin from personnel_pilot_v1.member_pins where person_id = p.id;

  if p.employment_status = 'inactive' then
    insert into personnel_pilot_v1.member_login_attempts(name_key, person_id, client_ip, outcome)
    values (v_key, p.id, v_ip, 'INACTIVE');
    return jsonb_build_object('ok', false, 'code', 'INVALID_CREDENTIALS');
  end if;

  select * into al from personnel_pilot_v1.account_links where person_id = p.id;
  if not pin.enabled or (found and not al.enabled) then
    insert into personnel_pilot_v1.member_login_attempts(name_key, person_id, client_ip, outcome)
    values (v_key, p.id, v_ip, 'DISABLED');
    return jsonb_build_object('ok', false, 'code', 'ACCOUNT_DISABLED');
  end if;

  insert into personnel_pilot_v1.member_login_attempts(name_key, person_id, client_ip, outcome)
  values (v_key, p.id, v_ip, 'OK');

  return jsonb_build_object(
    'ok', true,
    'code', 'OK',
    'person_id', p.id,
    'auth_user_id', al.auth_user_id,
    'must_change_pin', pin.must_change
  );
end $fn$;

-- 5-2. 개인 Auth 사용자 ↔ 인원 연결 (Edge Function 전용, 기존 account_links 재사용)
create function public.pilot_member_link_account(p_person_id uuid, p_auth_user_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  u auth.users%rowtype;
  v_linked uuid;
begin
  select * into u from auth.users where id = p_auth_user_id;
  if not found
     or u.email is distinct from format('member-%s@example.com', p_person_id)
     or u.raw_app_meta_data ->> 'attendance_pilot' is distinct from 'v1'
     or u.raw_app_meta_data ->> 'kind' is distinct from 'member_pin'
     or u.raw_app_meta_data ->> 'person_id' is distinct from p_person_id::text then
    raise exception 'ACCOUNT_IDENTITY_MISMATCH' using errcode = '42501';
  end if;
  if exists (select 1 from personnel_pilot_v1.login_profiles where auth_user_id = p_auth_user_id) then
    raise exception 'WORK_ACCOUNT_NOT_ALLOWED' using errcode = '42501';
  end if;
  if not exists (
    select 1 from personnel_pilot_v1.people p
    join personnel_pilot_v1.member_pins c on c.person_id = p.id and c.enabled
    where p.id = p_person_id and p.employment_status <> 'inactive'
  ) then
    raise exception 'PERSON_NOT_ELIGIBLE' using errcode = '42501';
  end if;

  insert into personnel_pilot_v1.account_links(auth_user_id, person_id, enabled)
  values (p_auth_user_id, p_person_id, true)
  on conflict do nothing;

  select auth_user_id into v_linked from personnel_pilot_v1.account_links where person_id = p_person_id;
  if v_linked is distinct from p_auth_user_id then
    raise exception 'LINK_CONFLICT' using errcode = '23505';
  end if;

  insert into personnel_pilot_v1.member_pin_events(person_id, event, actor)
  select p_person_id, 'LINK_ACCOUNT', 'edge:member-login'
  where not exists (
    select 1 from personnel_pilot_v1.member_pin_events
    where person_id = p_person_id and event = 'LINK_ACCOUNT');

  return jsonb_build_object('person_id', p_person_id, 'auth_user_id', p_auth_user_id);
end $fn$;

-- 5-3. 내 신원·역할 조회 (로그인 사용자 공통, 화면 이동·표시용)
create function public.pilot_whoami() returns jsonb
language sql stable security definer set search_path = ''
as $fn$
  select personnel_pilot_v1.current_actor()
$fn$;

-- 5-4. 개인 PIN 변경 (임시 PIN → 개인 PIN, 또는 개인 PIN 교체)
create function public.pilot_member_change_pin(p_current_pin text, p_new_pin text)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.current_actor();
  v_person uuid;
  pin personnel_pilot_v1.member_pins%rowtype;
begin
  if a ->> 'kind' <> 'MEMBER_PIN' then
    return jsonb_build_object('ok', false, 'code', 'NOT_MEMBER_SESSION');
  end if;
  v_person := (a ->> 'person_id')::uuid;

  select * into pin from personnel_pilot_v1.member_pins where person_id = v_person for update;

  if (select count(*) from personnel_pilot_v1.member_pin_events
      where person_id = v_person and event = 'CHANGE_FAIL'
        and created_at > clock_timestamp() - interval '15 minutes') >= 5 then
    return jsonb_build_object('ok', false, 'code', 'LOCKED');
  end if;

  if p_current_pin is null or pin.pin_hash <> extensions.crypt(p_current_pin, pin.pin_hash) then
    insert into personnel_pilot_v1.member_pin_events(person_id, event, actor)
    values (v_person, 'CHANGE_FAIL', 'self');
    return jsonb_build_object('ok', false, 'code', 'INVALID_CREDENTIALS');
  end if;

  if personnel_pilot_v1.pin_is_weak(p_new_pin) or p_new_pin = p_current_pin
     or personnel_pilot_v1.pin_collides(v_person, p_new_pin) then
    return jsonb_build_object('ok', false, 'code', 'PIN_NOT_ALLOWED');
  end if;

  update personnel_pilot_v1.member_pins
  set pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf', 10)),
      pin_kind = 'PERSONAL',
      must_change = false,
      changed_at = clock_timestamp()
  where person_id = v_person;

  insert into personnel_pilot_v1.member_pin_events(person_id, event, actor)
  values (v_person, 'CHANGE', 'self');

  return jsonb_build_object('ok', true, 'code', 'OK');
end $fn$;

-- 6. 관리 함수 (SQL Editor 전용, API 역할 실행 불가)

-- 6-1. 임시 PIN 발급·재발급 (퇴사 inactive 제외, 첫 로그인 시 변경 강제)
--      결과의 temp_pin은 이 실행 결과에서만 볼 수 있다. 본인에게 직접 전달한다.
create function personnel_pilot_v1.admin_issue_temp_pins(p_person_ids uuid[], p_reason text)
returns table(person_id uuid, legacy_user_id text, display_name text, team_name text, temp_pin text)
language plpgsql security definer set search_path = ''
as $fn$
declare
  v_id uuid;
  v_pin text;
  v_bytes bytea;
  p personnel_pilot_v1.people%rowtype;
begin
  if p_reason is null or length(trim(p_reason)) < 2 then
    raise exception 'REASON_REQUIRED';
  end if;
  if p_person_ids is null or cardinality(p_person_ids) = 0 then
    raise exception 'NO_TARGET';
  end if;

  foreach v_id in array p_person_ids loop
    select * into p from personnel_pilot_v1.people where id = v_id;
    if not found then
      raise exception 'PERSON_NOT_FOUND: %', v_id;
    end if;
    if p.employment_status = 'inactive' then
      raise exception 'INACTIVE_PERSON: % (퇴사 인원에게는 발급하지 않음)', p.legacy_user_id;
    end if;

    loop
      v_bytes := extensions.gen_random_bytes(4);
      v_pin := lpad((((get_byte(v_bytes, 0)::bigint << 24) | (get_byte(v_bytes, 1)::bigint << 16)
                     | (get_byte(v_bytes, 2)::bigint << 8) | get_byte(v_bytes, 3)::bigint) % 1000000)::text, 6, '0');
      exit when not personnel_pilot_v1.pin_is_weak(v_pin)
            and not personnel_pilot_v1.pin_collides(v_id, v_pin);
    end loop;

    insert into personnel_pilot_v1.member_pins as mp (person_id, pin_hash, pin_kind, must_change, enabled, issued_at, changed_at)
    values (v_id, extensions.crypt(v_pin, extensions.gen_salt('bf', 10)), 'TEMP', true, true, clock_timestamp(), null)
    on conflict on constraint member_pins_pkey do update
      set pin_hash = excluded.pin_hash, pin_kind = 'TEMP', must_change = true,
          enabled = true, issued_at = excluded.issued_at, changed_at = null;

    insert into personnel_pilot_v1.member_pin_events(person_id, event, actor, reason)
    values (v_id, 'ISSUE_TEMP', session_user, trim(p_reason));
    insert into personnel_pilot_v1.member_login_attempts(name_key, person_id, outcome)
    values (coalesce(personnel_pilot_v1.name_key(p.display_name), '(invalid)'), v_id, 'ADMIN_UNLOCK');

    person_id := v_id;
    legacy_user_id := p.legacy_user_id;
    display_name := p.display_name;
    team_name := nullif(p.team_name, '');
    temp_pin := v_pin;
    return next;
  end loop;
end $fn$;

-- 6-2. 로그인 잠금 해제
create function personnel_pilot_v1.admin_unlock_member(p_person_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $fn$
declare p personnel_pilot_v1.people%rowtype;
begin
  if p_reason is null or length(trim(p_reason)) < 2 then raise exception 'REASON_REQUIRED'; end if;
  select * into p from personnel_pilot_v1.people where id = p_person_id;
  if not found then raise exception 'PERSON_NOT_FOUND'; end if;
  insert into personnel_pilot_v1.member_login_attempts(name_key, person_id, outcome)
  values (coalesce(personnel_pilot_v1.name_key(p.display_name), '(invalid)'), p.id, 'ADMIN_UNLOCK');
  insert into personnel_pilot_v1.member_pin_events(person_id, event, actor, reason)
  values (p.id, 'UNLOCK', session_user, trim(p_reason));
end $fn$;

-- 6-3. 개인 로그인 사용 중지·재개 (PIN과 계정 연결 모두 적용, 기존 세션도 즉시 차단)
create function personnel_pilot_v1.admin_set_member_login(p_person_id uuid, p_enabled boolean, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $fn$
begin
  if p_reason is null or length(trim(p_reason)) < 2 then raise exception 'REASON_REQUIRED'; end if;
  if p_enabled is null then raise exception 'INVALID_INPUT'; end if;
  update personnel_pilot_v1.member_pins set enabled = p_enabled where person_id = p_person_id;
  if not found then raise exception 'PIN_NOT_ISSUED'; end if;
  update personnel_pilot_v1.account_links set enabled = p_enabled where person_id = p_person_id;
  insert into personnel_pilot_v1.member_pin_events(person_id, event, actor, reason)
  values (p_person_id, case when p_enabled then 'ENABLE' else 'DISABLE' end, session_user, trim(p_reason));
end $fn$;

-- 7. 실행 권한 (Supabase 기본값은 public 스키마 함수를 anon에게 자동 허용하므로 모두 명시적으로 회수)
revoke all on function personnel_pilot_v1.name_key(text) from public, anon, authenticated, service_role;
revoke all on function personnel_pilot_v1.pin_is_weak(text) from public, anon, authenticated, service_role;
revoke all on function personnel_pilot_v1.pin_collides(uuid, text) from public, anon, authenticated, service_role;
revoke all on function personnel_pilot_v1.current_actor() from public, anon, authenticated, service_role;
revoke all on function personnel_pilot_v1.require_actor(text[]) from public, anon, authenticated, service_role;
revoke all on function personnel_pilot_v1.admin_issue_temp_pins(uuid[], text) from public, anon, authenticated, service_role;
revoke all on function personnel_pilot_v1.admin_unlock_member(uuid, text) from public, anon, authenticated, service_role;
revoke all on function personnel_pilot_v1.admin_set_member_login(uuid, boolean, text) from public, anon, authenticated, service_role;

revoke all on function public.pilot_member_login_verify(text, text, text) from public, anon, authenticated;
revoke all on function public.pilot_member_link_account(uuid, uuid) from public, anon, authenticated;
revoke all on function public.pilot_whoami() from public, anon;
revoke all on function public.pilot_member_change_pin(text, text) from public, anon;
grant execute on function public.pilot_member_login_verify(text, text, text) to service_role;
grant execute on function public.pilot_member_link_account(uuid, uuid) to service_role;
grant execute on function public.pilot_whoami() to authenticated;
grant execute on function public.pilot_member_change_pin(text, text) to authenticated;

commit;
