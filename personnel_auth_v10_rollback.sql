-- personnel_auth v0.10 롤백 · 개인 로그인 역할 판정을 v0.8로 되돌린다 (소장 개인 로그인 → 팀원)
-- 적용 방법: Supabase SQL Editor에서 이 파일만 단독 실행
-- 표·행은 바꾸지 않는다. current_actor() 본문만 v0.8과 똑같이 되돌린다.
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

commit;
