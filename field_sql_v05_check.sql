-- field v0.5 사전 CHECK (읽기 전용). ready=true일 때만 field_sql_v05.sql을 실행한다.
-- 두 번째 결과 data_fingerprint를 보관해 두고 VERIFY의 두 번째 결과와 같아야 한다 (적용 중 다른 저장이 없을 때).
with checks as (
  select 'v04_applied' as name, to_regprocedure('public.tbm_task_stop(uuid,text,text,text,text)') is not null as ok
  union all select 'v05_not_applied', to_regprocedure('public.tbm_carry_cancel(uuid,text,text)') is null
  union all select 'carry_status_values', not exists (select 1 from field_pilot_v1.report_tasks where carry_status is not null and carry_status not in ('PENDING', 'CONTINUED', 'DROPPED'))
  union all select 'one_open_per_team_date', not exists (select 1 from field_pilot_v1.daily_reports where evening_at is null group by site_id, team_id, work_date having count(*) > 1)
  union all select 'rls_enabled', not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'field_pilot_v1' and c.relkind = 'r' and not c.relrowsecurity)
)
select bool_and(ok) as ready, jsonb_object_agg(name, ok) as checks from checks;

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
  (select count(*) from field_pilot_v1.attendance_records) as attendance_records,
  (select count(*) from personnel_pilot_v1.people where employment_status <> 'inactive') as active_people;
