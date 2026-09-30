-- 현장 TBM·현장보고 1단계 · field v0.2 적용 후 확인 (읽기 전용)
-- SQL 버전: field v0.2 / 전환 단계: S1-5
select jsonb_pretty(jsonb_build_object(
  'bucket', (select jsonb_build_object('id', id, 'public', public, 'file_size_limit', file_size_limit, 'allowed_mime_types', allowed_mime_types)
             from storage.buckets where id = 'tbm-photos'),
  'policies', (select jsonb_agg(jsonb_build_object('name', policyname, 'cmd', cmd, 'roles', roles, 'using', qual, 'check', with_check) order by policyname)
               from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'tbm\_photos\_%'),
  'update_or_delete_policies_on_tbm_photos', (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
               and policyname like 'tbm\_photos\_%' and cmd in ('UPDATE', 'DELETE', 'ALL')),
  'functions', (select jsonb_agg(jsonb_build_object('fn', p.oid::regprocedure::text, 'security_definer', p.prosecdef,
                  'search_path', p.proconfig, 'anon', has_function_privilege('anon', p.oid, 'EXECUTE'),
                  'authenticated', has_function_privilege('authenticated', p.oid, 'EXECUTE')) order by 1)
                from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'field_pilot_v1' and p.proname in ('storage_can_upload', 'storage_can_read')),
  'schema_usage', jsonb_build_object('anon', has_schema_privilege('anon', 'field_pilot_v1', 'USAGE'),
                                     'authenticated', has_schema_privilege('authenticated', 'field_pilot_v1', 'USAGE')),
  'tables_open_to_authenticated', (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
               where n.nspname = 'field_pilot_v1' and c.relkind = 'r'
                 and (has_table_privilege('authenticated', c.oid, 'SELECT') or has_table_privilege('authenticated', c.oid, 'INSERT'))),
  'objects_in_bucket', (select count(*) from storage.objects where bucket_id = 'tbm-photos'),
  'expected', 'bucket public=false 2097152 [image/jpeg], policies 2 (INSERT, SELECT) to authenticated, update_or_delete=0, functions anon=false authenticated=true, schema_usage anon=false authenticated=true, tables_open_to_authenticated=0'
)) as check_field_v02;
