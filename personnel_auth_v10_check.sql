-- 현장 업무 통합 로그인 v0.10 · 적용 후 확인 (읽기 전용: SELECT만, 별도 탭에서 실행)
-- SQL 버전: personnel_auth v0.10
select jsonb_pretty(jsonb_build_object(
  'v10_personal_roles', pg_get_functiondef('personnel_pilot_v1.current_actor()'::regprocedure)
      like '%array[''TEAM_LEADER'', ''SITE_MANAGER'', ''ADMIN_DEPT'']%',
  'roster_functions_use_roster_actor', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname in ('pilot_roster', 'pilot_update_person', 'pilot_set_attendance_grade')
        and p.prosrc like '%roster_actor()%'),
  'exec', jsonb_build_object(
      'current_actor_anon', has_function_privilege('anon', 'personnel_pilot_v1.current_actor()', 'EXECUTE'),
      'current_actor_authenticated', has_function_privilege('authenticated', 'personnel_pilot_v1.current_actor()', 'EXECUTE'),
      'roster_actor_anon', has_function_privilege('anon', 'personnel_pilot_v1.roster_actor()', 'EXECUTE'),
      'roster_actor_authenticated', has_function_privilege('authenticated', 'personnel_pilot_v1.roster_actor()', 'EXECUTE'),
      'my_team_anon', has_function_privilege('anon', 'public.pilot_my_team()', 'EXECUTE'),
      'my_team_authenticated', has_function_privilege('authenticated', 'public.pilot_my_team()', 'EXECUTE'),
      'roster_anon', has_function_privilege('anon', 'public.pilot_roster()', 'EXECUTE'),
      'whoami_anon', has_function_privilege('anon', 'public.pilot_whoami()', 'EXECUTE')),
  'roster_login_exists', to_regprocedure('public.pilot_member_roster_login(text,text,boolean,text)') is not null,
  'expected', 'v10_personal_roles=true, roster_functions_use_roster_actor=3, exec: my_team_authenticated=true, 나머지 모두 false, roster_login_exists=true'
)) as check_v10;
