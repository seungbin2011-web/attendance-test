-- 현장 업무 통합 로그인 v0.9 · 적용 후 확인 (읽기 전용: SELECT만, 별도 탭에서 실행)
-- SQL 버전: personnel_auth v0.9
select jsonb_pretty(jsonb_build_object(
  'roster_login_exists', to_regprocedure('public.pilot_member_roster_login(text,text,boolean,text)') is not null,
  'exec', case when to_regprocedure('public.pilot_member_roster_login(text,text,boolean,text)') is null then null else jsonb_build_object(
      'anon', has_function_privilege('anon', 'public.pilot_member_roster_login(text,text,boolean,text)', 'EXECUTE'),
      'authenticated', has_function_privilege('authenticated', 'public.pilot_member_roster_login(text,text,boolean,text)', 'EXECUTE'),
      'service_role', has_function_privilege('service_role', 'public.pilot_member_roster_login(text,text,boolean,text)', 'EXECUTE')) end,
  'v08_functions_present', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname in ('pilot_member_login_verify', 'pilot_member_link_account', 'pilot_whoami', 'pilot_member_change_pin')),
  'counts', jsonb_build_object(
      'people', (select count(*) from personnel_pilot_v1.people),
      'account_links', (select count(*) from personnel_pilot_v1.account_links),
      'member_pins', (select count(*) from personnel_pilot_v1.member_pins)),
  'expected', 'roster_login_exists=true, exec anon=false authenticated=false service_role=true, v08_functions_present=4'
)) as check_v09;
