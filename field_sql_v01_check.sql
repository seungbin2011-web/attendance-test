-- 현장 TBM·현장보고 1단계 · field v0.1 적용 후 확인 (읽기 전용)
-- SQL 버전: field v0.1 / 전환 단계: S1-1
select jsonb_pretty(jsonb_build_object(
  'schema_exists', exists (select 1 from pg_namespace where nspname = 'field_pilot_v1'),
  'schema_usage', jsonb_build_object(
     'anon', has_schema_privilege('anon', 'field_pilot_v1', 'USAGE'),
     'authenticated', has_schema_privilege('authenticated', 'field_pilot_v1', 'USAGE')),
  'tables', (select jsonb_agg(jsonb_build_object('table', c.relname, 'rls', c.relrowsecurity,
       'anon_select', has_table_privilege('anon', c.oid, 'SELECT'),
       'authenticated_select', has_table_privilege('authenticated', c.oid, 'SELECT'),
       'rows', (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from field_pilot_v1.%I', c.relname), false, true, '')))[1]::text::int)
     order by c.relname)
     from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'field_pilot_v1' and c.relkind = 'r'),
  'rpc_exec', (select jsonb_agg(jsonb_build_object('fn', p.oid::regprocedure::text,
       'anon', has_function_privilege('anon', p.oid, 'EXECUTE'),
       'authenticated', has_function_privilege('authenticated', p.oid, 'EXECUTE'),
       'security_definer', p.prosecdef) order by 1)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'tbm\_%'),
  'internal_exec_open', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'field_pilot_v1' and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
       and p.proname not in ('storage_can_upload', 'storage_can_read')),
  'expected', 'anon=false everywhere, authenticated=true only for public.tbm_*, internal_exec_open=0, tables rls=true'
)) as check_field_v01;
