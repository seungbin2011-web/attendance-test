-- 현장 업무 통합 로그인 v0.11 · Supabase 단독 개인 로그인(이름 + 휴대폰 뒤 4자리) + 관리자 인원 관리 + 조직도 권한
-- SQL 버전: personnel_auth v0.11 / Season 2 / 작성 2026-10-03
-- 선행 조건: personnel_auth_v08·v09·v10 적용
-- 적용 방법: Supabase SQL Editor에서 이 파일만 단독 실행 → personnel_auth_v11_check.sql을 별도 탭에서 실행
--
-- 바뀌는 것
--   1) people.legacy_user_id(기존 사용자ID)는 참고용: 없어도 됨 (NOT NULL 해제, 기존 값 그대로)
--   2) 로그인 번호(휴대폰 뒤 4자리)는 개인 로그인 표 member_pins.login4_hash에 bcrypt 해시로만 저장 (평문·전체 번호 저장 없음)
--   3) pilot_member_login4: 이름 + 4자리를 Supabase 안에서만 확인 (Apps Script 호출 없음)
--      실패 한도·잠금은 v0.8과 같은 기록 표·기준 (이름 연속 5회 → 30분, IP 15분 20회, 전체 1시간 100회)
--      같은 이름 중 번호까지 맞는 사람을 찾고, 같은 이름 + 같은 번호가 둘 이상이면 AMBIGUOUS로 막는다
--   4) pilot_admin_save_person: 관리자(ADMIN)만. 인원 추가·이름·직급·직무·팀 이동·권한·로그인 번호·비활성·재투입을 한 번에
--   5) pilot_org_chart: 현장관리(SITE_MANAGER)·관리자(ADMIN)만. 휴대폰 번호·로그인 번호는 돌려주지 않는다
--   6) pilot_roster: 편집 가능(can_edit)은 관리자만, 사람마다 현재 팀·권한·로그인 번호 등록 여부(값 아님), 팀 목록
--      pilot_update_person: 관리자만 (현장관리 업무계정 편집 권한 제거, 출결등급 변경은 그대로)
-- 롤백: personnel_auth_v11_rollback.sql
begin;

do $pre$
begin
  if to_regprocedure('personnel_pilot_v1.roster_actor()') is null or to_regprocedure('public.pilot_my_team()') is null then
    raise exception 'PRECHECK: personnel_auth_v10.sql을 먼저 적용해야 함';
  end if;
end $pre$;

-- 1) 기존 사용자ID는 참고용
alter table personnel_pilot_v1.people alter column legacy_user_id drop not null;

-- 2) 로그인 번호 해시
alter table personnel_pilot_v1.member_pins add column if not exists login4_hash text;
alter table personnel_pilot_v1.member_pins add column if not exists login4_set_at timestamptz;
do $chk$
begin
  if not exists (select 1 from pg_constraint where conname = 'member_pins_login4_hash_check') then
    alter table personnel_pilot_v1.member_pins
      add constraint member_pins_login4_hash_check check (login4_hash is null or login4_hash like '$2_$%');
  end if;
end $chk$;

-- 3) 내부 도우미 (직접 실행 권한 없음, 아래 함수와 SQL Editor에서만)
-- 로그인 번호 설정: 같은 이름의 다른 현재 인원이 같은 번호를 쓰면 거절 (로그인 때 한 사람으로 정할 수 없으므로)
create or replace function personnel_pilot_v1.set_login4(p_person_id uuid, p_code text, p_actor text default null)
returns void
language plpgsql security definer set search_path = ''
as $fn$
declare p personnel_pilot_v1.people%rowtype;
begin
  if p_code is null or p_code !~ '^[0-9]{4}$' then
    raise exception 'INVALID_LOGIN_CODE' using errcode = '22023';
  end if;
  select * into p from personnel_pilot_v1.people where id = p_person_id for update;
  if not found then raise exception 'PERSON_NOT_FOUND' using errcode = 'P0002'; end if;
  perform pg_advisory_xact_lock(hashtextextended('member_login:' || personnel_pilot_v1.name_key(p.display_name), 0));
  if exists (
    select 1 from personnel_pilot_v1.people q join personnel_pilot_v1.member_pins c on c.person_id = q.id
    where q.id <> p.id and q.employment_status <> 'inactive'
      and personnel_pilot_v1.name_key(q.display_name) = personnel_pilot_v1.name_key(p.display_name)
      and c.login4_hash is not null and c.login4_hash = extensions.crypt(p_code, c.login4_hash)) then
    raise exception 'LOGIN_DUPLICATE' using errcode = '23505';
  end if;
  insert into personnel_pilot_v1.member_pins (person_id, pin_hash, pin_kind, must_change, enabled, login4_hash, login4_set_at)
  values (p.id, extensions.crypt(encode(extensions.gen_random_bytes(24), 'hex'), extensions.gen_salt('bf', 6)), 'PERSONAL', false, true,
          extensions.crypt(p_code, extensions.gen_salt('bf', 10)), clock_timestamp())
  on conflict (person_id) do update set login4_hash = excluded.login4_hash, login4_set_at = excluded.login4_set_at;
  insert into personnel_pilot_v1.member_pin_events (person_id, event, actor, reason)
  values (p.id, 'CHANGE', left(coalesce(p_actor, session_user), 100), 'LOGIN4 로그인 번호 설정');
end $fn$;

-- 현재 소속·역할을 하나로: 지정한 팀 소속 하나만 남기고(다른 현재 소속·역할은 종료), 역할은 지정한 것만 (팀원은 없음)
create or replace function personnel_pilot_v1.assign_current(p_person_id uuid, p_team_id uuid, p_role_code text)
returns void
language plpgsql security definer set search_path = ''
as $fn$
declare
  v_site uuid;
  v_keep uuid;
  v_now timestamptz := clock_timestamp();
  m record;
begin
  select site_id into v_site from personnel_pilot_v1.teams where id = p_team_id;
  if v_site is null then raise exception 'TEAM_NOT_FOUND' using errcode = 'P0002'; end if;
  for m in select * from personnel_pilot_v1.memberships where person_id = p_person_id and valid_to is null order by valid_from loop
    if v_keep is null and m.team_id = p_team_id then
      v_keep := m.id;
    else
      update personnel_pilot_v1.role_assignments set revoked_at = v_now where membership_id = m.id and revoked_at is null;
      update personnel_pilot_v1.memberships set valid_to = v_now where id = m.id;
    end if;
  end loop;
  if v_keep is null then
    insert into personnel_pilot_v1.memberships (person_id, site_id, team_id) values (p_person_id, v_site, p_team_id)
    returning id into v_keep;
  end if;
  update personnel_pilot_v1.role_assignments set revoked_at = v_now
  where membership_id = v_keep and revoked_at is null and role_code is distinct from p_role_code;
  if p_role_code is not null and not exists (select 1 from personnel_pilot_v1.role_assignments
                                             where membership_id = v_keep and role_code = p_role_code and revoked_at is null) then
    insert into personnel_pilot_v1.role_assignments (membership_id, role_code) values (v_keep, p_role_code);
  end if;
end $fn$;

-- 비활성: 현재 소속·역할 종료 (행·지난 기록 유지)
create or replace function personnel_pilot_v1.end_current(p_person_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $fn$
declare v_now timestamptz := clock_timestamp();
begin
  update personnel_pilot_v1.role_assignments r set revoked_at = v_now
  from personnel_pilot_v1.memberships m
  where m.id = r.membership_id and m.person_id = p_person_id and m.valid_to is null and r.revoked_at is null;
  update personnel_pilot_v1.memberships set valid_to = v_now where person_id = p_person_id and valid_to is null;
end $fn$;

-- 4) 개인 로그인: 이름 + 휴대폰 뒤 4자리 (Edge Function 전용, service_role만 실행)
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

-- 5) 관리자 인원 관리: 추가·수정·팀 이동·권한·로그인 번호·비활성·재투입 (관리자만, 한 트랜잭션)
create or replace function public.pilot_admin_save_person(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a personnel_pilot_v1.login_profiles%rowtype := personnel_pilot_v1.roster_actor();
  v_id uuid := nullif(p_payload ->> 'id', '')::uuid;
  v_name text := trim(coalesce(p_payload ->> 'name', ''));
  v_rank text := trim(coalesce(p_payload ->> 'rank', ''));
  v_job text := trim(coalesce(p_payload ->> 'job', ''));
  v_note text := coalesce(p_payload ->> 'note', '');
  v_status text := coalesce(nullif(p_payload ->> 'status', ''), 'active');
  v_team uuid := nullif(p_payload ->> 'team_id', '')::uuid;
  v_role text := coalesce(nullif(p_payload ->> 'role', ''), 'MEMBER');
  v_code text := nullif(p_payload ->> 'login_code', '');
  v_role_code text;
  v_team_name text;
  before_row personnel_pilot_v1.people%rowtype;
  after_row personnel_pilot_v1.people%rowtype;
begin
  if a.auth_user_id is null or a.app_role <> 'ADMIN' then
    raise exception 'EDIT_FORBIDDEN' using errcode = '42501';
  end if;
  if length(v_name) not between 1 and 80 or length(v_rank) > 40 or length(v_job) > 80 or length(v_note) > 1000
     or v_status not in ('unknown', 'active', 'inactive')
     or v_role not in ('MEMBER', 'TEAM_LEADER', 'SITE_MANAGER', 'ADMIN')
     or (v_code is not null and v_code !~ '^[0-9]{4}$') then
    raise exception 'INVALID_INPUT' using errcode = '22023';
  end if;
  if v_status <> 'inactive' then
    if v_team is null then raise exception 'TEAM_REQUIRED' using errcode = '22023'; end if;
    select name into v_team_name from personnel_pilot_v1.teams where id = v_team;
    if v_team_name is null then raise exception 'TEAM_NOT_FOUND' using errcode = 'P0002'; end if;
  end if;
  v_role_code := case v_role when 'TEAM_LEADER' then 'TEAM_LEADER' when 'SITE_MANAGER' then 'SITE_MANAGER' when 'ADMIN' then 'ADMIN_DEPT' end;

  if v_id is null then
    if v_status = 'inactive' then raise exception 'INVALID_INPUT' using errcode = '22023'; end if;
    if v_code is null then raise exception 'LOGIN_CODE_REQUIRED' using errcode = '22023'; end if;
    insert into personnel_pilot_v1.people (legacy_user_id, display_name, rank_title, job_title, team_name, employment_status, note, source_system)
    values (null, v_name, v_rank, v_job, v_team_name, v_status, v_note, 'admin_screen')
    returning * into after_row;
    insert into personnel_pilot_v1.person_edits (person_id, actor_id, actor_login, before_data, after_data)
    values (after_row.id, a.auth_user_id, a.login_name, '{}'::jsonb, to_jsonb(after_row));
  else
    select * into before_row from personnel_pilot_v1.people where id = v_id for update;
    if not found then raise exception 'PERSON_NOT_FOUND' using errcode = 'P0002'; end if;
    if (p_payload ->> 'version') is null or (p_payload ->> 'version')::int <> before_row.version then
      raise exception 'VERSION_CONFLICT' using errcode = '40001';
    end if;
    update personnel_pilot_v1.people
    set display_name = v_name, rank_title = v_rank, job_title = v_job, note = v_note, employment_status = v_status,
        team_name = coalesce(v_team_name, team_name), version = version + 1, updated_at = clock_timestamp()
    where id = v_id
    returning * into after_row;
    insert into personnel_pilot_v1.person_edits (person_id, actor_id, actor_login, before_data, after_data)
    values (v_id, a.auth_user_id, a.login_name, to_jsonb(before_row), to_jsonb(after_row));
  end if;

  if v_status = 'inactive' then
    perform personnel_pilot_v1.end_current(after_row.id);
  else
    perform personnel_pilot_v1.assign_current(after_row.id, v_team, v_role_code);
  end if;
  if v_code is not null then
    perform personnel_pilot_v1.set_login4(after_row.id, v_code, a.login_name);
  end if;
  return jsonb_build_object('ok', true, 'id', after_row.id, 'version', after_row.version);
end $fn$;

-- 6) 조직도: 현장관리·관리자만 (휴대폰 번호·로그인 번호 없음)
create or replace function public.pilot_org_chart()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare a jsonb := personnel_pilot_v1.require_actor(array['SITE_MANAGER', 'ADMIN']);
begin
  return jsonb_build_object('ok', true,
    'viewer', jsonb_build_object('name', a ->> 'name', 'role_label', a ->> 'role_label'),
    'people', (select coalesce(jsonb_agg(jsonb_build_object(
        'person_id', p.id, 'name', p.display_name, 'rank', p.rank_title, 'job', p.job_title,
        'team', t.name, 'legacy_user_id', p.legacy_user_id,
        'role', case when exists (select 1 from personnel_pilot_v1.role_assignments r where r.membership_id = m.id and r.revoked_at is null and r.role_code = 'ADMIN_DEPT') then 'ADMIN'
                     when exists (select 1 from personnel_pilot_v1.role_assignments r where r.membership_id = m.id and r.revoked_at is null and r.role_code = 'SITE_MANAGER') then 'SITE_MANAGER'
                     when exists (select 1 from personnel_pilot_v1.role_assignments r where r.membership_id = m.id and r.revoked_at is null and r.role_code = 'TEAM_LEADER') then 'TEAM_LEADER'
                     else 'MEMBER' end)
        order by t.name, p.display_name), '[]'::jsonb)
      from personnel_pilot_v1.people p
      join personnel_pilot_v1.memberships m on m.person_id = p.id and m.valid_to is null
      join personnel_pilot_v1.teams t on t.id = m.team_id
      join personnel_pilot_v1.sites s on s.id = m.site_id
      where p.employment_status <> 'inactive'
        and s.code in (select jsonb_array_elements_text(coalesce(a -> 'site_codes', '[]'::jsonb)))));
end $fn$;

-- 7) 명부 함수: 편집은 관리자만, 현재 팀·권한·로그인 번호 등록 여부
create or replace function public.pilot_roster() returns jsonb
language plpgsql security definer set search_path=''
as $fn$
declare a personnel_pilot_v1.login_profiles%rowtype; result jsonb;
begin
  a := personnel_pilot_v1.roster_actor();
  if a.auth_user_id is null or a.app_role not in ('ADMIN','MANAGER','LEADER') then
    raise exception 'PILOT_ACCESS_DENIED' using errcode='42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'legacy_user_id',p.legacy_user_id,'display_name',p.display_name,
    'rank_title',p.rank_title,'job_title',p.job_title,'team_name',p.team_name,
    'source_site',p.source_site,'employment_status',p.employment_status,
    'attendance_grade',p.attendance_grade,
    'note',case when a.app_role in ('ADMIN','MANAGER') then p.note else '' end,
    'version',p.version,'updated_at',p.updated_at,
    'team_id',cm.team_id,'team',ct.name,
    'role',case when exists(select 1 from personnel_pilot_v1.role_assignments r where r.membership_id=cm.id and r.revoked_at is null and r.role_code='ADMIN_DEPT') then 'ADMIN'
                when exists(select 1 from personnel_pilot_v1.role_assignments r where r.membership_id=cm.id and r.revoked_at is null and r.role_code='SITE_MANAGER') then 'SITE_MANAGER'
                when exists(select 1 from personnel_pilot_v1.role_assignments r where r.membership_id=cm.id and r.revoked_at is null and r.role_code='TEAM_LEADER') then 'TEAM_LEADER'
                else 'MEMBER' end,
    'has_login',exists(select 1 from personnel_pilot_v1.member_pins c where c.person_id=p.id and c.login4_hash is not null),
    'id_conflict',exists(
      select 1 from personnel_pilot_v1.people d
      where d.legacy_user_id=p.legacy_user_id and d.id<>p.id
    )
  ) order by p.source_row),'[]'::jsonb) into result
  from personnel_pilot_v1.people p
  left join lateral (select m.id, m.team_id from personnel_pilot_v1.memberships m
                     where m.person_id=p.id and m.valid_to is null order by m.valid_from limit 1) cm on true
  left join personnel_pilot_v1.teams ct on ct.id=cm.team_id
  where a.app_role in ('ADMIN','MANAGER')
     or (a.app_role='LEADER' and p.team_name=a.team_scope);

  return jsonb_build_object(
    'login_name',a.login_name,
    'app_role',a.app_role,
    'role_label',case a.app_role when 'ADMIN' then '관리자' when 'MANAGER' then '소장' else '팀장' end,
    'can_edit',a.app_role='ADMIN',
    'can_change_grade',a.app_role in ('ADMIN','MANAGER'),
    'team_scope',a.team_scope,
    'teams',(select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'name',t.name) order by t.name),'[]'::jsonb)
             from personnel_pilot_v1.teams t join personnel_pilot_v1.sites s on s.id=t.site_id and s.is_active),
    'people',result
  );
end $fn$;

create or replace function public.pilot_update_person(p_id uuid, p_version integer, p_name text, p_team text, p_rank text, p_job text, p_status text, p_note text)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare a personnel_pilot_v1.login_profiles%rowtype; before_row personnel_pilot_v1.people%rowtype; after_row personnel_pilot_v1.people%rowtype;
begin
 a := personnel_pilot_v1.roster_actor();
 if a.auth_user_id is null or a.app_role <> 'ADMIN' then
  raise exception 'EDIT_FORBIDDEN' using errcode='42501';
 end if;
 if p_name is null or length(trim(p_name)) not between 1 and 80
 or p_team is null or (p_team not in ('','용인사무실','현장소장','자재팀','공사1팀','공사2팀','공사3팀','공사4팀')
                       and not exists (select 1 from personnel_pilot_v1.teams t where t.name = p_team))
 or p_rank is null or length(p_rank)>40 or p_job is null or length(p_job)>80
 or p_status is null or p_status not in ('unknown','active','inactive')
 or p_note is null or length(p_note)>1000 then
  raise exception 'INVALID_INPUT' using errcode='22023';
 end if;
 select * into before_row from personnel_pilot_v1.people where id=p_id for update;
 if not found then raise exception 'PERSON_NOT_FOUND' using errcode='P0002'; end if;
 if p_version is distinct from before_row.version then raise exception 'VERSION_CONFLICT' using errcode='40001'; end if;
 update personnel_pilot_v1.people set display_name=trim(p_name),team_name=p_team,
 rank_title=trim(p_rank),job_title=trim(p_job),employment_status=p_status,note=p_note,
 version=version+1,updated_at=clock_timestamp()
 where id=p_id returning * into after_row;
 insert into personnel_pilot_v1.person_edits(person_id,actor_id,actor_login,before_data,after_data)
 values(p_id,a.auth_user_id,a.login_name,to_jsonb(before_row),to_jsonb(after_row));
 return jsonb_build_object('id',after_row.id,'version',after_row.version);
end $function$;

-- 8) 실행 권한
revoke all on function personnel_pilot_v1.set_login4(uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function personnel_pilot_v1.assign_current(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function personnel_pilot_v1.end_current(uuid) from public, anon, authenticated, service_role;
revoke all on function public.pilot_member_login4(text, text, text) from public, anon, authenticated;
grant execute on function public.pilot_member_login4(text, text, text) to service_role;
revoke all on function public.pilot_admin_save_person(jsonb) from public, anon;
grant execute on function public.pilot_admin_save_person(jsonb) to authenticated;
revoke all on function public.pilot_org_chart() from public, anon;
grant execute on function public.pilot_org_chart() to authenticated;

commit;
