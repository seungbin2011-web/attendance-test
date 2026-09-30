-- 현장 업무 통합 로그인 v0.8 · 적용 후 확인 (읽기 전용)
-- SQL 버전: personnel_auth v0.8 / 전환 단계: S0-2
-- SELECT 한 문장. 이름·PIN·이메일은 출력하지 않는다.
select jsonb_pretty(jsonb_build_object(
  'v08_tables', (select jsonb_agg(jsonb_build_object(
       'table', c.relname, 'rls', c.relrowsecurity,
       'anon_select', has_table_privilege('anon', c.oid, 'SELECT'),
       'authenticated_select', has_table_privilege('authenticated', c.oid, 'SELECT'),
       'service_role_select', has_table_privilege('service_role', c.oid, 'SELECT')) order by c.relname)
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'personnel_pilot_v1'
       and c.relname in ('member_pins', 'member_login_attempts', 'member_pin_events')),
  'function_exec', (select jsonb_agg(jsonb_build_object(
       'fn', f,
       'anon', has_function_privilege('anon', f, 'EXECUTE'),
       'authenticated', has_function_privilege('authenticated', f, 'EXECUTE'),
       'service_role', has_function_privilege('service_role', f, 'EXECUTE')) order by f)
     from unnest(array[
       'public.pilot_member_login_verify(text,text,text)',
       'public.pilot_member_link_account(uuid,uuid)',
       'public.pilot_whoami()',
       'public.pilot_member_change_pin(text,text)',
       'personnel_pilot_v1.current_actor()',
       'personnel_pilot_v1.require_actor(text[])',
       'personnel_pilot_v1.admin_issue_temp_pins(uuid[],text)',
       'personnel_pilot_v1.admin_unlock_member(uuid,text)',
       'personnel_pilot_v1.admin_set_member_login(uuid,boolean,text)']) f),
  'expected', jsonb_build_object(
       'anon', 'false for all',
       'authenticated', 'true only for pilot_whoami, pilot_member_change_pin',
       'service_role', 'true for pilot_member_login_verify, pilot_member_link_account (+whoami/change_pin harmless)'),
  'existing_pilot_functions_unchanged', (select jsonb_object_agg(p.proname, md5(p.prosrc))
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('pilot_roster', 'pilot_set_attendance_grade', 'pilot_update_person', 'pilot_bind_account')),
  'counts', jsonb_build_object(
       'people', (select count(*) from personnel_pilot_v1.people),
       'login_profiles', (select count(*) from personnel_pilot_v1.login_profiles),
       'account_links', (select count(*) from personnel_pilot_v1.account_links),
       'member_pins', (select count(*) from personnel_pilot_v1.member_pins),
       'member_pins_temp', (select count(*) from personnel_pilot_v1.member_pins where pin_kind = 'TEMP'),
       'login_attempts_24h', (select count(*) from personnel_pilot_v1.member_login_attempts where attempted_at > now() - interval '24 hours'))
)) as check_v08;
