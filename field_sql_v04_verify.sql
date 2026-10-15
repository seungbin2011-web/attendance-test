-- field v0.4 VERIFY (읽기 전용). field_sql_v04.sql 실행 직후 실행한다.
-- ok=true 이고, 두 번째 결과 data_fingerprint가 CHECK(field_sql_v04_check.sql) 때와 같아야 다음 단계로 간다.
with expected(name, hash) as (values
  ('field_pilot_v1.check_members', '1139425eabb85ef9f4f85ef0f6e6c9a5'),
  ('field_pilot_v1.replace_assignments', 'd8607d050cdf47194bc365e3cb60027f'),
  ('field_pilot_v1.report_json', '455b825ccc9deb1aab5cd15be87f9df6'),
  ('field_pilot_v1.attendance_team_json', 'df61457f912cd82faf71c5e57e6c9655'),
  ('public.tbm_task_stop', '7abe058bd84f46061636f2d79c4c230b'),
  ('public.tbm_task_result', 'e50c82826506ce52a96cda0f7b6555bb'),
  ('public.tbm_site_overview', 'e383bcce4c0a984e830d4d3be53a3447'),
  ('public.tbm_my_today', '4c1098beb0fd1711c0aab7c82fa03785'),
  ('public.tbm_site_people', 'f806b4b915b26fbaf5f3b6587bceb934'),
  ('public.tbm_attendance_today', '7982fc60cfb570822af954122473a912'),
  ('public.tbm_attendance_save', '467b36ea22015223e8ae96edf8e43ab6'),
  ('public.tbm_attendance_overview', 'cae449b69c9ab2759d63cb427bf025f6'),
  -- v03에서 바뀌지 않아야 하는 함수
  ('field_pilot_v1.lock_editable_report', 'da099c369391c2032b8db821513c332f'),
  ('public.tbm_today', 'c7fb06abc78c95f118fd716e80d252f9'),
  ('public.tbm_report_detail', '4d7438a52c7ac78e3c00e900211cc012')
), rpcs(sig) as (values
  ('public.tbm_task_stop(uuid,text,text,text,text)'), ('public.tbm_site_people(uuid)'),
  ('public.tbm_attendance_today(uuid)'), ('public.tbm_attendance_save(jsonb)'), ('public.tbm_attendance_overview(date)')
), checks as (
  select 'functions_match' as name, not exists (select 1 from expected e where not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname || '.' || p.proname = e.name and md5(replace(p.prosrc, chr(13), '')) = e.hash)) as ok
  union all select 'stopped_constraints', (select count(*) from pg_constraint where conrelid = 'field_pilot_v1.report_tasks'::regclass and contype = 'c'
    and conname in ('report_tasks_alert_check', 'report_tasks_result_check', 'report_tasks_carry_result_check', 'report_tasks_stopped_check')
    and (conname = 'report_tasks_carry_result_check' or pg_get_constraintdef(oid) like '%STOPPED%')) = 4
  union all select 'old_carry_constraint_removed', not exists (select 1 from pg_constraint where conrelid = 'field_pilot_v1.report_tasks'::regclass and contype = 'c'
    and pg_get_constraintdef(oid) like '%carry_over%' and pg_get_constraintdef(oid) not like '%STOPPED%' and pg_get_constraintdef(oid) like '%NOT_DONE%')
  union all select 'home_team_column', exists (select 1 from information_schema.columns where table_schema = 'field_pilot_v1' and table_name = 'task_assignments' and column_name = 'home_team_id')
  union all select 'attendance_tables', to_regclass('field_pilot_v1.attendance_records') is not null and to_regclass('field_pilot_v1.attendance_history') is not null
  union all select 'one_open_per_team_date', not exists (select 1 from field_pilot_v1.daily_reports where evening_at is null group by site_id, team_id, work_date having count(*) > 1)
  union all select 'stopped_rows_consistent', not exists (select 1 from field_pilot_v1.report_tasks where (alert = 'STOPPED') <> (coalesce(result, '') = 'STOPPED'))
  union all select 'rpc_permissions', not exists (select 1 from rpcs where not has_function_privilege('authenticated', sig, 'execute')
      or has_function_privilege('anon', sig, 'execute') or has_function_privilege('service_role', sig, 'execute'))
    and not has_function_privilege('authenticated', 'field_pilot_v1.attendance_team_json(uuid,uuid,date)', 'execute')
    and not has_function_privilege('anon', 'field_pilot_v1.attendance_team_json(uuid,uuid,date)', 'execute')
  union all select 'field_tables_private', not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'field_pilot_v1' and c.relkind = 'r' and (not c.relrowsecurity
      or has_table_privilege('anon', c.oid, 'select') or has_table_privilege('authenticated', c.oid, 'select')
      or has_table_privilege('anon', c.oid, 'insert') or has_table_privilege('authenticated', c.oid, 'insert')
      or has_table_privilege('authenticated', c.oid, 'update') or has_table_privilege('authenticated', c.oid, 'delete')))
)
select bool_and(ok) as ok, jsonb_object_agg(name, ok) as checks from checks;

select jsonb_build_object(
  'reports', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text, '[]')) from field_pilot_v1.daily_reports t),
  'tasks', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text, '[]')) from field_pilot_v1.report_tasks t),
  'assignments', (select md5(coalesce(jsonb_agg(to_jsonb(t) - 'home_team_id' order by task_id, person_id)::text, '[]')) from field_pilot_v1.task_assignments t),
  'attachments', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text, '[]')) from field_pilot_v1.attachments t),
  'history', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text, '[]')) from field_pilot_v1.workflow_history t),
  'people', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text, '[]')) from personnel_pilot_v1.people t),
  'memberships', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text, '[]')) from personnel_pilot_v1.memberships t),
  'roles', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text, '[]')) from personnel_pilot_v1.role_assignments t),
  'credentials', (select md5(coalesce(jsonb_agg(to_jsonb(t) order by person_id)::text, '[]')) from personnel_pilot_v1.member_pins t)
) as data_fingerprint;

select (select count(*) from field_pilot_v1.daily_reports) as reports, (select count(*) from field_pilot_v1.report_tasks) as tasks,
  (select count(*) from field_pilot_v1.task_assignments) as assignments, (select count(*) from field_pilot_v1.attachments) as photos,
  (select count(*) from field_pilot_v1.workflow_history) as history,
  (select count(*) from field_pilot_v1.attendance_records) as attendance_records,
  (select count(*) from personnel_pilot_v1.people where employment_status <> 'inactive') as active_people;
