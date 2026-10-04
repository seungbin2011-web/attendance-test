-- v0.10 롤백 시험: 개인 로그인 역할 판정이 v0.8로 돌아가고 표·행은 그대로
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse
select test_util.expect('v08 roles restored', (pg_get_functiondef('personnel_pilot_v1.current_actor()'::regprocedure)
  like '%array[''TEAM_LEADER''];%')::text, 'true');
select test_util.expect('anon still closed', has_function_privilege('anon', 'personnel_pilot_v1.current_actor()', 'EXECUTE')::text, 'false');
select test_util.claims('f0000000-0000-0000-0000-000000000003', '90000000-0000-0000-0000-000000000003');
set role authenticated;
select test_util.expect('manager via personal login is member again', public.pilot_whoami() ->> 'roles', '["MEMBER"]');
select test_util.expect_error('no overview after rollback', $$select public.tbm_site_overview()$$, 'FORBIDDEN');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000026', '90000000-0000-0000-0000-000000000026');
set role authenticated;
select test_util.expect('leader unaffected', public.pilot_whoami() ->> 'app_role', 'LEADER');
reset role;
select test_util.expect('role rows kept', (select count(*)::text from personnel_pilot_v1.role_assignments r
  where r.role_code = 'SITE_MANAGER' and r.revoked_at is null), '1');
select test_util.expect('roster functions restored exactly',
  (select md5(string_agg(p.proname || md5(p.prosrc), ',' order by p.proname)) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('pilot_roster', 'pilot_set_attendance_grade', 'pilot_update_person', 'pilot_bind_account')),
  (select value from test_util.snapshot where key = 'pilot_functions'));
select test_util.expect('v10 added functions removed', (to_regprocedure('public.pilot_my_team()') is null
  and to_regprocedure('personnel_pilot_v1.roster_actor()') is null)::text, 'true');
select test_util.expect('roster grants kept', has_function_privilege('authenticated', 'public.pilot_roster()', 'EXECUTE')::text, 'true');
select 'personnel_auth v0.10 rollback tests passed';
