-- field v0.4 사전 CHECK (읽기 전용). ready=true일 때만 field_sql_v04.sql을 실행한다.
-- 두 번째 결과 data_fingerprint를 보관해 두고 VERIFY의 두 번째 결과와 같아야 한다 (적용 중 다른 저장이 없을 때).
with expected(name, hash) as (values
  ('field_pilot_v1.check_members', 'a5ef2c740dda8257b1f6e5430408e951'),
  ('field_pilot_v1.report_json', '3d28bb61a481ec9ec7e53e4179e17345'),
  ('field_pilot_v1.replace_assignments', 'c74f67c1ece84a11e19652cf747d123c'),
  ('public.tbm_site_overview', 'fc9bb669bfd952fd85df09dc054f83d5'),
  ('public.tbm_my_today', '377b06000f65ff5cd49a0e9be01eab8e'),
  ('public.tbm_task_result', 'b6b7a28ab2ef8f33da672199de6dc074')
), checks as (
  select 'v03_applied' as name, exists (select 1 from information_schema.columns where table_schema = 'field_pilot_v1' and table_name = 'daily_reports' and column_name = 'session_no') as ok
  union all select 'v04_not_applied', to_regprocedure('public.tbm_task_stop(uuid,text,text,text,text)') is null
    and not exists (select 1 from pg_constraint where conrelid = 'field_pilot_v1.report_tasks'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%STOPPED%')
  union all select 'original_functions', not exists (select 1 from expected e where not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname || '.' || p.proname = e.name and md5(replace(p.prosrc, chr(13), '')) = e.hash))
  union all select 'task_constraints_found', (select count(*) from pg_constraint where conrelid = 'field_pilot_v1.report_tasks'::regclass and contype = 'c'
    and (pg_get_constraintdef(oid) like '%alert = ANY%' or pg_get_constraintdef(oid) like '%result = ANY%')) = 3
  union all select 'one_open_per_team_date', not exists (select 1 from field_pilot_v1.daily_reports where evening_at is null group by site_id, team_id, work_date having count(*) > 1)
  union all select 'rls_enabled', not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'field_pilot_v1' and c.relkind = 'r' and not c.relrowsecurity)
)
select bool_and(ok) as ready, jsonb_object_agg(name, ok) as checks from checks;

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
  (select count(*) from personnel_pilot_v1.people where employment_status <> 'inactive') as active_people;
