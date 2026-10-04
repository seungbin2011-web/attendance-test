-- Read only after APPLY. ok=true AND unchanged pre-APPLY data_fingerprint required before merge.
with expected(name,hash) as(values ('field_pilot_v1.lock_editable_report','da099c369391c2032b8db821513c332f'),
('field_pilot_v1.check_members','a5ef2c740dda8257b1f6e5430408e951'),
('field_pilot_v1.report_json','3d28bb61a481ec9ec7e53e4179e17345'),
('field_pilot_v1.storage_can_upload','6a8d580b8d72009ad6a8f2f02f411370'),
('public.tbm_today','c7fb06abc78c95f118fd716e80d252f9'),
('public.tbm_save_plan','061d0c3dabb835fea6cebd3a739b8b05'),
('public.tbm_site_overview','fc9bb669bfd952fd85df09dc054f83d5'),
('public.tbm_open_next','9f890e073e02eca106b6f91ba8a1dc2a'),
('public.tbm_my_today','377b06000f65ff5cd49a0e9be01eab8e')), checks as (
 select 'functions_match' as name,not exists(select 1 from expected e where not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname||'.'||p.proname=e.name and md5(replace(p.prosrc,chr(13),''))=e.hash)) as ok
 union all select 'session_unique',exists(select 1 from pg_constraint where conrelid='field_pilot_v1.daily_reports'::regclass and conname='daily_reports_session_key')
 union all select 'single_open_index',exists(select 1 from pg_indexes where schemaname='field_pilot_v1' and indexname='daily_reports_one_open_session')
 union all select 'one_open_per_team_date',not exists(select 1 from field_pilot_v1.daily_reports where evening_at is null group by site_id,team_id,work_date having count(*)>1)
 union all select 'session_numbers_valid',not exists(select 1 from field_pilot_v1.daily_reports where session_no is null or session_no<1)
 union all select 'rpc_permissions',has_function_privilege('authenticated','public.tbm_open_next(uuid)','execute') and has_function_privilege('authenticated','public.tbm_my_today()','execute') and not has_function_privilege('anon','public.tbm_open_next(uuid)','execute') and not has_function_privilege('anon','public.tbm_my_today()','execute') and not has_function_privilege('service_role','public.tbm_open_next(uuid)','execute') and not has_function_privilege('service_role','public.tbm_my_today()','execute')
 union all select 'field_tables_private',not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='field_pilot_v1' and c.relkind='r' and (not c.relrowsecurity or has_table_privilege('anon',c.oid,'select') or has_table_privilege('authenticated',c.oid,'select')))
) select bool_and(ok) as ok,jsonb_object_agg(name,ok) as checks from checks;
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

select session_no,count(*) as reports from field_pilot_v1.daily_reports group by session_no order by session_no;
