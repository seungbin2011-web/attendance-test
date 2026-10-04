-- v0.11 롤백 시험: 새 함수만 사라지고 명부 함수는 v0.10으로, 행·해시 칸은 그대로
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse
select test_util.expect('v11 functions removed', (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where p.proname in ('pilot_member_login4', 'pilot_admin_save_person', 'pilot_org_chart', 'set_login4', 'assign_current', 'end_current')), '0');
select test_util.expect('roster back to v10', (select (prosrc like '%can_edit'',a.app_role in (''ADMIN'',''MANAGER'')%')::text from pg_proc where proname = 'pilot_roster'), 'true');
select test_util.expect('update_person back to v10', (select (prosrc like '%a.app_role not in (''ADMIN'',''MANAGER'')%')::text from pg_proc where proname = 'pilot_update_person'), 'true');
select test_util.expect('rows kept', (select (count(*) > 0)::text from personnel_pilot_v1.people where legacy_user_id is null), 'true');
select test_util.expect('legacy stays optional while rows without id exist', (select is_nullable from information_schema.columns
  where table_schema = 'personnel_pilot_v1' and table_name = 'people' and column_name = 'legacy_user_id'), 'YES');
select 'personnel_auth v0.11 rollback tests passed';
