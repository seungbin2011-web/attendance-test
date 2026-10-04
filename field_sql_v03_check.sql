-- Read only. ready=true is required. Keep data_fingerprint for comparison after APPLY.
with expected(name,hash) as(values ('field_pilot_v1.lock_editable_report','ea35fef8dac02c34bcba1d5c87bbe728'),
('field_pilot_v1.check_members','228ddad81caa39c09073b7295403ef93'),
('field_pilot_v1.report_json','2c008ad3ca14f6a3ff524da45c698a63'),
('field_pilot_v1.storage_can_upload','edddf79284e904a3bda027c2736ffc52'),
('public.tbm_today','1b1046351f53727e1b7ece43ab2e9bcc'),
('public.tbm_save_plan','b662fcd8afcea6183d21628cd3dd7dc5'),
('public.tbm_site_overview','e33f8de25d1c3dc85af961984d17c7a5')), checks as (
 select 'v03_not_applied' as name, not exists(select 1 from information_schema.columns where table_schema='field_pilot_v1' and table_name='daily_reports' and column_name='session_no') as ok
 union all select 'old_unique',exists(select 1 from pg_constraint where conrelid='field_pilot_v1.daily_reports'::regclass and conname='daily_reports_site_id_team_id_work_date_key')
 union all select 'original_functions',not exists(select 1 from expected e where not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname||'.'||p.proname=e.name and md5(replace(p.prosrc,chr(13),''))=e.hash))
 union all select 'one_report_per_team_date',not exists(select 1 from field_pilot_v1.daily_reports group by site_id,team_id,work_date having count(*)>1)
 union all select 'rls_enabled',not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='field_pilot_v1' and c.relkind='r' and not c.relrowsecurity)
) select bool_and(ok) as ready,jsonb_object_agg(name,ok) as checks from checks;
select jsonb_build_object(
  'reports',(select md5(coalesce(jsonb_agg(to_jsonb(t)-'session_no' order by id)::text,'[]')) from field_pilot_v1.daily_reports t),
  'tasks',(select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text,'[]')) from field_pilot_v1.report_tasks t),
  'assignments',(select md5(coalesce(jsonb_agg(to_jsonb(t) order by task_id,person_id)::text,'[]')) from field_pilot_v1.task_assignments t),
  'attachments',(select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text,'[]')) from field_pilot_v1.attachments t),
  'history',(select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text,'[]')) from field_pilot_v1.workflow_history t),
  'people',(select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text,'[]')) from personnel_pilot_v1.people t),
  'memberships',(select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text,'[]')) from personnel_pilot_v1.memberships t),
  'roles',(select md5(coalesce(jsonb_agg(to_jsonb(t) order by id)::text,'[]')) from personnel_pilot_v1.role_assignments t),
  'credentials',(select md5(coalesce(jsonb_agg(to_jsonb(t) order by person_id)::text,'[]')) from personnel_pilot_v1.member_pins t)
) as data_fingerprint;
