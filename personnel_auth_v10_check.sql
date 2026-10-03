-- 현장 업무 통합 로그인 v0.10 · 적용 후 확인 (읽기 전용: SELECT만, 별도 탭에서 실행)
-- SQL 버전: personnel_auth v0.10
select jsonb_pretty(jsonb_build_object(
  'v10_personal_roles', pg_get_functiondef('personnel_pilot_v1.current_actor()'::regprocedure)
      like '%array[''TEAM_LEADER'', ''SITE_MANAGER'']%',
  'current_actor_exec', jsonb_build_object(
      'anon', has_function_privilege('anon', 'personnel_pilot_v1.current_actor()', 'EXECUTE'),
      'authenticated', has_function_privilege('authenticated', 'personnel_pilot_v1.current_actor()', 'EXECUTE')),
  'whoami_exec', jsonb_build_object(
      'anon', has_function_privilege('anon', 'public.pilot_whoami()', 'EXECUTE'),
      'authenticated', has_function_privilege('authenticated', 'public.pilot_whoami()', 'EXECUTE')),
  'roster_login_exists', to_regprocedure('public.pilot_member_roster_login(text,text,boolean,text)') is not null,
  'active_roles', jsonb_build_object(
      'TEAM_LEADER', (select count(*) from personnel_pilot_v1.role_assignments r
                      join personnel_pilot_v1.memberships m on m.id = r.membership_id and m.valid_to is null
                      where r.role_code = 'TEAM_LEADER' and r.revoked_at is null),
      'SITE_MANAGER', (select count(*) from personnel_pilot_v1.role_assignments r
                       join personnel_pilot_v1.memberships m on m.id = r.membership_id and m.valid_to is null
                       where r.role_code = 'SITE_MANAGER' and r.revoked_at is null)),
  'expected', 'v10_personal_roles=true, current_actor_exec anon=false authenticated=false, whoami_exec anon=false authenticated=true, roster_login_exists=true'
)) as check_v10;
