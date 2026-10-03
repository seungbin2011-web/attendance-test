-- personnel_auth v0.10 롤백 · v0.8 역할 판정과 v0.2 명부 함수로 되돌린다
-- 적용 방법: Supabase SQL Editor에서 이 파일만 단독 실행 (인원 명단 동기화를 했다면 personnel_roster_v10_rollback.sql을 먼저)
-- 표·행은 바꾸지 않는다. 함수 본문만 v0.10 이전과 똑같이 되돌리고, v0.10에서 추가한 함수 2개를 지운다.
begin;

create or replace function personnel_pilot_v1.current_actor() returns jsonb
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

create or replace function public.pilot_roster() returns jsonb
language plpgsql security definer set search_path=''
as $fn$
declare a personnel_pilot_v1.login_profiles%rowtype; result jsonb;
begin
  select * into a
  from personnel_pilot_v1.login_profiles
  where auth_user_id = auth.uid()
    and enabled
    and app_role in ('ADMIN','MANAGER','LEADER');
  if not found then raise exception 'PILOT_ACCESS_DENIED' using errcode='42501'; end if;

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
  select * into a
  from personnel_pilot_v1.login_profiles
  where auth_user_id=auth.uid() and enabled;
  if not found or a.app_role not in ('ADMIN','MANAGER') then
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
 select * into a from personnel_pilot_v1.login_profiles where auth_user_id=auth.uid() and enabled;
 if not found or a.app_role not in ('ADMIN','MANAGER') then
  raise exception 'EDIT_FORBIDDEN' using errcode='42501';
 end if;
 if p_name is null or length(trim(p_name)) not between 1 and 80
 or p_team is null or p_team not in ('','용인사무실','현장소장','자재팀','공사1팀','공사2팀','공사3팀','공사4팀')
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

drop function if exists public.pilot_my_team();
drop function if exists personnel_pilot_v1.roster_actor();

commit;
