-- 적용 전 기존 구조 지문 저장 (v0.8·field 적용 후 불변 확인용)
create table test_util.snapshot (key text primary key, value text);
insert into test_util.snapshot values
  ('pilot_functions', (select md5(string_agg(p.proname || md5(p.prosrc), ',' order by p.proname)) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('pilot_roster', 'pilot_set_attendance_grade', 'pilot_update_person', 'pilot_bind_account'))),
  ('people_count', (select count(*)::text from personnel_pilot_v1.people)),
  ('people_hash', (select md5(string_agg(t::text, '' order by t.id)) from personnel_pilot_v1.people t)),
  ('works_policies', (select string_agg(policyname, ',' order by policyname) from pg_policies where tablename = 'works'));
grant select on test_util.snapshot to anon, authenticated, service_role;
