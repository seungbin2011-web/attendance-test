-- 현장 업무 통합 로그인 v0.10 · 역할 판정 정리 (개인 로그인: 팀원·팀장·현장관리·관리자) + 내 팀 조회
-- SQL 버전: personnel_auth v0.10 / Season 2 현장 사용 준비 / 작성 2026-10-03 (53명 확정 명단 반영)
-- 선행 조건: personnel_auth_v02.sql, personnel_auth_v08.sql, personnel_auth_v09.sql 적용
-- 적용 방법: Supabase SQL Editor에서 이 파일만 단독 실행 → personnel_auth_v10_check.sql을 별도 탭에서 실행
--
-- 역할은 서버 표(현재 memberships · role_assignments)만 본다. 직급·직책 글자, 이름, 화면 값으로 정하지 않는다.
--   ADMIN_DEPT(기존 역할 코드) → ADMIN(관리자) / SITE_MANAGER → MANAGER(현장관리) / TEAM_LEADER → LEADER(팀장) / 그 외 MEMBER(팀원)
--   현장관리·관리자 개인 로그인은 본인 현재 소속 현장만 본다. (업무계정은 기존처럼 전체)
--
-- 바뀌는 것 (표 구조·행 변경 없음, 권한 GRANT는 새 함수만)
--   1) personnel_pilot_v1.current_actor(): 위 역할 판정, 표시 팀은 현재 소속 팀
--   2) personnel_pilot_v1.roster_actor() 추가: 업무계정 또는 개인 로그인 관리자(ADMIN)를 명부 함수의 사용자로 돌려줌
--   3) pilot_roster / pilot_update_person / pilot_set_attendance_grade: 사용자 확인만 roster_actor()로 바꿈 (나머지 같음)
--      → 개인 로그인 관리자도 기존 관리자와 같은 명부 조회·편집·등급 변경. 현장관리(SITE_MANAGER) 개인 로그인은 편집 불가
--      pilot_update_person: 팀 이름은 기존 목록 또는 teams 표의 현재 팀 이름 허용
--   4) public.pilot_my_team() 추가: 팀원 화면의 "우리 팀장·팀원"을 현재 소속 기준으로 조회
-- 롤백: personnel_auth_v10_rollback.sql
begin;

do $pre$
begin
  if to_regprocedure('personnel_pilot_v1.current_actor()') is null
     or to_regprocedure('public.pilot_member_roster_login(text,text,boolean,text)') is null
     or to_regprocedure('public.pilot_roster()') is null
     or to_regprocedure('public.pilot_update_person(uuid,integer,text,text,text,text,text,text)') is null
     or to_regprocedure('public.pilot_set_attendance_grade(uuid,integer,text,text)') is null then
    raise exception 'PRECHECK: personnel_auth_v02·v08·v09가 먼저 적용돼 있어야 함';
  end if;
  -- 롤백이 원래 함수를 그대로 되돌릴 수 있도록, 바꾸기 전 함수가 저장소 사본과 같은지 확인 (재실행이면 통과)
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('pilot_roster', 'pilot_update_person', 'pilot_set_attendance_grade')
      and md5(p.prosrc) not in ('f209c18fb12b4f1691626541a9545ffb', '22a7ae3c8749ad75b3144ecfc321c7b8', 'fbf8dc9df6eb4d68cbc5a3145326422d')
      and p.prosrc not like '%roster_actor()%') then
    raise exception 'PRECHECK: 명부 함수가 저장소 사본과 다름. 적용 중단 (현재 함수 내용 확인 필요)';
  end if;
end $pre$;

-- 1) 현재 로그인 사용자의 서버 기준 신원·역할 (모든 업무 RPC의 공통 기준)
create or replace function personnel_pilot_v1.current_actor() returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare
  c_pin_roles constant text[] := array['TEAM_LEADER', 'SITE_MANAGER', 'ADMIN_DEPT'];
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

  -- 관리부서(ADMIN_DEPT) 역할 = 관리자(ADMIN) 권한
  select array['MEMBER'] || coalesce(array_agg(distinct case r.role_code when 'ADMIN_DEPT' then 'ADMIN' else r.role_code end
                                              order by case r.role_code when 'ADMIN_DEPT' then 'ADMIN' else r.role_code end), array[]::text[])
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
    'team', coalesce((select t.name from personnel_pilot_v1.memberships m
                      join personnel_pilot_v1.teams t on t.id = m.team_id
                      where m.person_id = p.id and m.valid_to is null order by t.name limit 1), p.team_name),
    'attendance_grade', p.attendance_grade,
    'app_role', case when 'ADMIN' = any (v_roles) then 'ADMIN'
                      when 'SITE_MANAGER' = any (v_roles) then 'MANAGER'
                      when 'TEAM_LEADER' = any (v_roles) then 'LEADER' else 'MEMBER' end,
    'roles', to_jsonb(v_roles),
    'role_label', case when 'ADMIN' = any (v_roles) then '관리자'
                        when 'SITE_MANAGER' = any (v_roles) then '현장관리'
                        when 'TEAM_LEADER' = any (v_roles) then '팀장' else '팀원' end,
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

-- 2) 명부 함수용 사용자: 업무계정(기존) 또는 개인 로그인 관리자
create or replace function personnel_pilot_v1.roster_actor() returns personnel_pilot_v1.login_profiles
language plpgsql stable security definer set search_path = ''
as $fn$
declare
  lp personnel_pilot_v1.login_profiles%rowtype;
  a jsonb;
begin
  select * into lp from personnel_pilot_v1.login_profiles where auth_user_id = auth.uid() and enabled;
  if found then return lp; end if;
  begin
    a := personnel_pilot_v1.current_actor();
  exception when others then
    return null;
  end;
  if a ->> 'kind' = 'MEMBER_PIN' and a ->> 'app_role' = 'ADMIN' and not coalesce((a ->> 'must_change_pin')::boolean, false) then
    lp.auth_user_id := auth.uid();
    lp.login_name := a ->> 'name';
    lp.app_role := 'ADMIN';
    lp.team_scope := null;
    lp.enabled := true;
    return lp;
  end if;
  return null;
end $fn$;

-- 3) 명부 함수: 사용자 확인만 roster_actor()로
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
    'id_conflict',exists(
      select 1 from personnel_pilot_v1.people d
      where d.legacy_user_id=p.legacy_user_id and d.id<>p.id
    )
  ) order by p.source_row),'[]'::jsonb) into result
  from personnel_pilot_v1.people p
  where a.app_role in ('ADMIN','MANAGER')
     or (a.app_role='LEADER' and p.team_name=a.team_scope);

  return jsonb_build_object(
    'login_name',a.login_name,
    'app_role',a.app_role,
    'role_label',case a.app_role when 'ADMIN' then '관리자' when 'MANAGER' then '소장' else '팀장' end,
    'can_edit',a.app_role in ('ADMIN','MANAGER'),
    'can_change_grade',a.app_role in ('ADMIN','MANAGER'),
    'team_scope',a.team_scope,
    'people',result
  );
end $fn$;

create or replace function public.pilot_set_attendance_grade(
  p_id uuid,
  p_version integer,
  p_grade text,
  p_reason text
) returns jsonb
language plpgsql security definer set search_path=''
as $fn$
declare
  a personnel_pilot_v1.login_profiles%rowtype;
  before_row personnel_pilot_v1.people%rowtype;
  after_row personnel_pilot_v1.people%rowtype;
begin
  a := personnel_pilot_v1.roster_actor();
  if a.auth_user_id is null or a.app_role not in ('ADMIN','MANAGER') then
    raise exception 'EDIT_FORBIDDEN' using errcode='42501';
  end if;
  if p_grade is null or p_grade not in ('A','B','C')
     or p_reason is null or length(trim(p_reason)) not between 2 and 500 then
    raise exception 'INVALID_INPUT' using errcode='22023';
  end if;

  select * into before_row
  from personnel_pilot_v1.people
  where id=p_id for update;
  if not found then raise exception 'PERSON_NOT_FOUND' using errcode='P0002'; end if;
  if p_version is distinct from before_row.version then
    raise exception 'VERSION_CONFLICT' using errcode='40001';
  end if;

  update personnel_pilot_v1.people
  set attendance_grade=p_grade,
      version=version+1,
      updated_at=clock_timestamp()
  where id=p_id
  returning * into after_row;

  insert into personnel_pilot_v1.attendance_grade_edits(
    person_id,actor_id,actor_login,before_grade,after_grade,reason
  ) values (
    p_id,a.auth_user_id,a.login_name,before_row.attendance_grade,after_row.attendance_grade,trim(p_reason)
  );

  return jsonb_build_object('id',after_row.id,'version',after_row.version,'attendance_grade',after_row.attendance_grade);
end $fn$;

create or replace function public.pilot_update_person(p_id uuid, p_version integer, p_name text, p_team text, p_rank text, p_job text, p_status text, p_note text)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare a personnel_pilot_v1.login_profiles%rowtype; before_row personnel_pilot_v1.people%rowtype; after_row personnel_pilot_v1.people%rowtype;
begin
 a := personnel_pilot_v1.roster_actor();
 if a.auth_user_id is null or a.app_role not in ('ADMIN','MANAGER') then
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

-- 4) 팀원 화면: 내 현재 소속 팀의 팀장·팀원 (휴대폰 번호 없음)
create or replace function public.pilot_my_team() returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(null);
  v_person uuid := (a ->> 'person_id')::uuid;
  v_team uuid;
  v_team_name text;
begin
  if v_person is not null then
    select t.id, t.name into v_team, v_team_name
    from personnel_pilot_v1.memberships m join personnel_pilot_v1.teams t on t.id = m.team_id
    where m.person_id = v_person and m.valid_to is null
    order by t.name limit 1;
  end if;
  if v_team is null then
    return jsonb_build_object('ok', true, 'team', null, 'leaders', '[]'::jsonb, 'members', '[]'::jsonb);
  end if;
  return jsonb_build_object('ok', true, 'team', v_team_name,
    'leaders', (select coalesce(jsonb_agg(x.j order by x.name), '[]'::jsonb) from (
        select p.display_name as name, jsonb_build_object('personId', p.id, 'userId', p.legacy_user_id, 'name', p.display_name,
                 'rank', p.rank_title, 'job', p.job_title) as j
        from personnel_pilot_v1.memberships m join personnel_pilot_v1.people p on p.id = m.person_id
        where m.team_id = v_team and m.valid_to is null and p.employment_status <> 'inactive'
          and exists (select 1 from personnel_pilot_v1.role_assignments r
                      where r.membership_id = m.id and r.revoked_at is null and r.role_code = 'TEAM_LEADER')) x),
    'members', (select coalesce(jsonb_agg(x.j order by x.name), '[]'::jsonb) from (
        select p.display_name as name, jsonb_build_object('personId', p.id, 'userId', p.legacy_user_id, 'name', p.display_name,
                 'rank', p.rank_title, 'job', p.job_title) as j
        from personnel_pilot_v1.memberships m join personnel_pilot_v1.people p on p.id = m.person_id
        where m.team_id = v_team and m.valid_to is null and p.employment_status <> 'inactive'
          and not exists (select 1 from personnel_pilot_v1.role_assignments r
                          where r.membership_id = m.id and r.revoked_at is null and r.role_code = 'TEAM_LEADER')) x));
end $fn$;

revoke all on function personnel_pilot_v1.roster_actor() from public, anon, authenticated, service_role;
revoke all on function public.pilot_my_team() from public, anon;
grant execute on function public.pilot_my_team() to authenticated;

commit;
