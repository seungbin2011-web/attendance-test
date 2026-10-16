-- field v0.5 VERIFY (읽기 전용). field_sql_v05.sql 실행 직후 실행한다.
-- ok=true 이고, 두 번째 결과 data_fingerprint가 CHECK(field_sql_v05_check.sql) 때와 같아야 다음 단계로 간다.
with expected(name, hash) as (values
  ('public.tbm_carry_cancel', '3e1b2ad3d5936f8ca5d7f31325fa4506'),
  -- v04에서 바뀌지 않아야 하는 함수
  ('public.tbm_task_stop', '7abe058bd84f46061636f2d79c4c230b'),
  ('public.tbm_today', 'c7fb06abc78c95f118fd716e80d252f9'),
  ('public.tbm_save_plan', '061d0c3dabb835fea6cebd3a739b8b05'),
  ('field_pilot_v1.lock_editable_report', 'da099c369391c2032b8db821513c332f'),
  ('field_pilot_v1.report_json', '455b825ccc9deb1aab5cd15be87f9df6')
), checks as (
  select 'functions_match' as name, not exists (select 1 from expected e where not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname || '.' || p.proname = e.name and md5(replace(p.prosrc, chr(13), '')) = e.hash)) as ok
  union all select 'rpc_permissions', has_function_privilege('authenticated', 'public.tbm_carry_cancel(uuid,text,text)', 'execute')
    and not has_function_privilege('anon', 'public.tbm_carry_cancel(uuid,text,text)', 'execute')
    and not has_function_privilege('service_role', 'public.tbm_carry_cancel(uuid,text,text)', 'execute')
  union all select 'one_open_per_team_date', not exists (select 1 from field_pilot_v1.daily_reports where evening_at is null group by site_id, team_id, work_date having count(*) > 1)
  union all select 'field_tables_private', not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'field_pilot_v1' and c.relkind = 'r' and (not c.relrowsecurity
      or has_table_privilege('anon', c.oid, 'select') or has_table_privilege('authenticated', c.oid, 'select')
      or has_table_privilege('authenticated', c.oid, 'insert') or has_table_privilege('authenticated', c.oid, 'update')))
)
select bool_and(ok) as ok, jsonb_object_agg(name, ok) as checks from checks;

select jsonb_build_object(
  'reports', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text, '[]')) from field_pilot_v1.daily_reports t),
  'tasks', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text, '[]')) from field_pilot_v1.report_tasks t),
  'assignments', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by task_id, person_id)::text, '[]')) from field_pilot_v1.task_assignments t),
  'attachments', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text, '[]')) from field_pilot_v1.attachments t),
  'history', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text, '[]')) from field_pilot_v1.workflow_history t),
  'attendance', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text, '[]')) from field_pilot_v1.attendance_records t),
  'people', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text, '[]')) from personnel_pilot_v1.people t),
  'memberships', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text, '[]')) from personnel_pilot_v1.memberships t),
  'roles', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text, '[]')) from personnel_pilot_v1.role_assignments t),
  'credentials', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by person_id)::text, '[]')) from personnel_pilot_v1.member_pins t)
) as data_fingerprint;

select (select count(*) from field_pilot_v1.daily_reports) as reports, (select count(*) from field_pilot_v1.report_tasks) as tasks,
  (select count(*) from field_pilot_v1.report_tasks where carry_status = 'PENDING') as carry_pending,
  (select count(*) from field_pilot_v1.attachments) as photos, (select count(*) from field_pilot_v1.workflow_history) as history,
  (select count(*) from field_pilot_v1.workflow_history where action = 'CARRY_CANCELLED') as carry_cancelled_history,
  (select count(*) from field_pilot_v1.attendance_records) as attendance_records,
  (select count(*) from personnel_pilot_v1.people where employment_status <> 'inactive') as active_people;
