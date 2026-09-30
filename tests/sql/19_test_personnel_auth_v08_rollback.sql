-- v0.8 롤백 시험: v0.8 객체만 사라지고 기존 구조·행은 남아야 한다.
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
select test_util.expect('v0.8 functions removed', (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where (n.nspname = 'personnel_pilot_v1' and p.proname in ('name_key','pin_is_weak','pin_collides','current_actor','require_actor','admin_issue_temp_pins','admin_unlock_member','admin_set_member_login'))
     or (n.nspname = 'public' and p.proname in ('pilot_member_login_verify','pilot_member_link_account','pilot_whoami','pilot_member_change_pin'))), '0');
select test_util.expect('v0.8 tables removed', (select count(*)::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'personnel_pilot_v1' and c.relname in ('member_pins','member_login_attempts','member_pin_events')), '0');
select test_util.expect('account_links rows kept', (select count(*)::text from personnel_pilot_v1.account_links), (select value from test_util.snapshot where key = 'account_links_before_rollback'));
select test_util.expect('pilot functions unchanged',
  (select md5(string_agg(p.proname || md5(p.prosrc), ',' order by p.proname)) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('pilot_roster', 'pilot_set_attendance_grade', 'pilot_update_person', 'pilot_bind_account')),
  (select value from test_util.snapshot where key = 'pilot_functions'));
select test_util.expect('field rollback: tbm photo policies removed', (select count(*)::text from pg_policies where schemaname = 'storage' and policyname like 'tbm\_photos\_%'), '0');
select test_util.expect('field rollback: schema and tbm rpc removed', (select (count(*) filter (where nspname = 'field_pilot_v1'))::text from pg_namespace)
  || '/' || (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'tbm\_%'), '0/0');
select 'personnel_auth v0.8 rollback tests passed';
