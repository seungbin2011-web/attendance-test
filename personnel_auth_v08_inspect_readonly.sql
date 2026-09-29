-- 현장 업무 통합 로그인 v0.8 · Supabase 현황 조회 (읽기 전용)
-- 적용 버전: v0.8 사전 조사 / 작성 2026-09-29
-- 실행 위치: Supabase Dashboard → SQL Editor (work-status-test 프로젝트)
--
-- 이 파일은 SELECT 한 문장만 실행한다.
--   * 테이블·정책·함수·권한·행을 만들거나 바꾸지 않는다.
--   * 이름·전화번호·이메일 원문은 출력하지 않는다. 구조, 권한, 건수만 출력한다.
--   * SQL Editor는 마지막 결과만 보여주므로 결과를 JSON 한 칸으로 묶었다.
-- 사용법: 전체 실행 → 결과 칸(inspect_v08)의 JSON 전체를 복사해 전달.

with
rel as (
  select c.oid, n.nspname as schema_name, c.relname as rel_name, c.relkind,
         c.relrowsecurity as rls, c.relforcerowsecurity as rls_forced,
         c.reltuples::bigint as est_rows
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'personnel_pilot_v1')
    and c.relkind in ('r', 'p', 'v', 'm')
),
fn as (
  select p.oid, n.nspname as schema_name, p.proname
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'personnel_pilot_v1')
    and p.prokind = 'f'
    and not exists (
      select 1 from pg_depend d
      where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e'
    )
)
select jsonb_pretty(jsonb_build_object(
  'generated_at', now(),
  'server_version', current_setting('server_version'),
  'current_user', current_user,

  'schemas', (
    select jsonb_agg(jsonb_build_object(
      'schema', n.nspname,
      'anon_usage', has_schema_privilege('anon', n.oid, 'USAGE'),
      'authenticated_usage', has_schema_privilege('authenticated', n.oid, 'USAGE')
    ) order by n.nspname)
    from pg_namespace n
    where n.nspname not like 'pg\_%' and n.nspname <> 'information_schema'
  ),

  'extensions', (
    select jsonb_agg(jsonb_build_object('name', e.extname, 'version', e.extversion, 'schema', e.extnamespace::regnamespace::text) order by e.extname)
    from pg_extension e
  ),

  'tables', (
    select jsonb_agg(jsonb_build_object(
      'table', schema_name || '.' || rel_name,
      'kind', relkind,
      'rls', rls,
      'rls_forced', rls_forced,
      'est_rows', est_rows,
      'anon', array_remove(array[
        case when has_table_privilege('anon', oid, 'SELECT') then 'SELECT' end,
        case when has_table_privilege('anon', oid, 'INSERT') then 'INSERT' end,
        case when has_table_privilege('anon', oid, 'UPDATE') then 'UPDATE' end,
        case when has_table_privilege('anon', oid, 'DELETE') then 'DELETE' end,
        case when has_table_privilege('anon', oid, 'TRUNCATE') then 'TRUNCATE' end], null),
      'authenticated', array_remove(array[
        case when has_table_privilege('authenticated', oid, 'SELECT') then 'SELECT' end,
        case when has_table_privilege('authenticated', oid, 'INSERT') then 'INSERT' end,
        case when has_table_privilege('authenticated', oid, 'UPDATE') then 'UPDATE' end,
        case when has_table_privilege('authenticated', oid, 'DELETE') then 'DELETE' end,
        case when has_table_privilege('authenticated', oid, 'TRUNCATE') then 'TRUNCATE' end], null)
    ) order by schema_name, rel_name)
    from rel
  ),

  'columns', (
    select jsonb_object_agg(tbl, cols)
    from (
      select c.table_schema || '.' || c.table_name as tbl,
             jsonb_agg(jsonb_build_object(
               'col', c.column_name, 'type', c.data_type,
               'nullable', c.is_nullable, 'default', c.column_default
             ) order by c.ordinal_position) as cols
      from information_schema.columns c
      where c.table_schema in ('public', 'personnel_pilot_v1')
      group by 1
    ) x
  ),

  -- 전화번호·PIN·비밀번호로 보이는 열 이름만 찾는다 (값은 읽지 않음)
  'sensitive_like_columns', (
    select coalesce(jsonb_agg(c.table_schema || '.' || c.table_name || '.' || c.column_name order by 1), '[]'::jsonb)
    from information_schema.columns c
    where c.table_schema not in ('pg_catalog', 'information_schema', 'auth', 'storage', 'extensions',
                                 'graphql', 'graphql_public', 'realtime', 'supabase_functions',
                                 'supabase_migrations', 'vault', 'pgsodium', 'net', 'cron', 'pgbouncer')
      and c.column_name ~* '(phone|mobile|tel|pin|password|passwd|secret|token|birth|resident|jumin|휴대|전화|연락)'
  ),

  'constraints', (
    select jsonb_agg(jsonb_build_object(
      'table', con.conrelid::regclass::text, 'name', con.conname,
      'type', con.contype, 'def', pg_get_constraintdef(con.oid)
    ) order by 1, 2)
    from pg_constraint con
    join rel on rel.oid = con.conrelid
  ),

  'indexes', (
    select jsonb_agg(jsonb_build_object('table', i.schemaname || '.' || i.tablename, 'index', i.indexname, 'def', i.indexdef) order by 1, 2)
    from pg_indexes i
    where i.schemaname in ('public', 'personnel_pilot_v1')
  ),

  'triggers', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'table', t.tgrelid::regclass::text, 'trigger', t.tgname,
      'function', t.tgfoid::regproc::text, 'enabled', t.tgenabled
    ) order by 1, 2), '[]'::jsonb)
    from pg_trigger t
    join rel on rel.oid = t.tgrelid
    where not t.tgisinternal
  ),

  'policies', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'table', p.schemaname || '.' || p.tablename, 'policy', p.policyname,
      'cmd', p.cmd, 'roles', p.roles, 'permissive', p.permissive,
      'using', p.qual, 'with_check', p.with_check
    ) order by p.schemaname, p.tablename, p.policyname), '[]'::jsonb)
    from pg_policies p
    where p.schemaname in ('public', 'personnel_pilot_v1', 'storage')
  ),

  'functions', (
    select jsonb_agg(jsonb_build_object(
      'fn', fn.schema_name || '.' || fn.proname || '(' || pg_get_function_identity_arguments(fn.oid) || ')',
      'returns', pg_get_function_result(fn.oid),
      'security_definer', p.prosecdef,
      'config', p.proconfig,
      'owner', pg_get_userbyid(p.proowner),
      'public_exec', exists (
        select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
        where a.grantee = 0 and a.privilege_type = 'EXECUTE'
      ),
      'anon_exec', has_function_privilege('anon', fn.oid, 'EXECUTE'),
      'authenticated_exec', has_function_privilege('authenticated', fn.oid, 'EXECUTE'),
      'service_role_exec', has_function_privilege('service_role', fn.oid, 'EXECUTE'),
      'body_md5', md5(p.prosrc)
    ) order by 1)
    from fn
    join pg_proc p on p.oid = fn.oid
  ),

  -- 저장소에 원본 SQL이 없는 pilot 함수(pilot_update_person 등)의 실제 정의
  'pilot_function_definitions', (
    select coalesce(jsonb_object_agg(
      fn.schema_name || '.' || fn.proname || '(' || pg_get_function_identity_arguments(fn.oid) || ')',
      pg_get_functiondef(fn.oid)
    ), '{}'::jsonb)
    from fn
    where fn.proname like 'pilot\_%'
  ),

  'default_privileges', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'owner', pg_get_userbyid(d.defaclrole),
      'schema', coalesce(d.defaclnamespace::regnamespace::text, '(all)'),
      'object_type', d.defaclobjtype,
      'acl', d.defaclacl::text
    ) order by 1, 2, 3), '[]'::jsonb)
    from pg_default_acl d
    where d.defaclnamespace = 0
       or d.defaclnamespace::regnamespace::text in ('public', 'personnel_pilot_v1')
  ),

  'storage_buckets', (
    case when to_regclass('storage.buckets') is not null then
      (xpath('/row/j/text()', query_to_xml($q$
        select coalesce(json_agg(json_build_object(
          'id', b.id, 'public', b.public,
          'file_size_limit', b.file_size_limit,
          'allowed_mime_types', b.allowed_mime_types,
          'objects', (select count(*) from storage.objects o where o.bucket_id = b.id)
        ) order by b.id), '[]')::text as j
        from storage.buckets b
      $q$, false, true, '')))[1]::text::jsonb
    end
  ),

  -- 건수만 출력 (이름·전화번호·이메일 없음)
  'counts_people', (
    case when to_regclass('personnel_pilot_v1.people') is not null then
      replace(replace(replace((xpath('/row/j/text()', query_to_xml($q$
        select json_build_object(
          'total', (select count(*) from personnel_pilot_v1.people),
          'distinct_legacy_user_id', (select count(distinct legacy_user_id) from personnel_pilot_v1.people),
          'legacy_ids_with_duplicates', (select count(*) from (
             select legacy_user_id from personnel_pilot_v1.people group by 1 having count(*) > 1) d),
          'rows_in_duplicate_legacy_ids', (select coalesce(sum(n), 0) from (
             select count(*) as n from personnel_pilot_v1.people group by legacy_user_id having count(*) > 1) d),
          'same_name_groups', (select count(*) from (
             select regexp_replace(display_name, '\s', '', 'g') from personnel_pilot_v1.people group by 1 having count(*) > 1) d),
          'by_team', (select json_object_agg(coalesce(team_name, '(미지정)'), n) from (
             select team_name, count(*) as n from personnel_pilot_v1.people group by 1) t),
          'by_employment_status', (select json_object_agg(coalesce(employment_status, '(null)'), n) from (
             select employment_status, count(*) as n from personnel_pilot_v1.people group by 1) t),
          'by_attendance_grade', (select json_object_agg(coalesce(attendance_grade, '(null)'), n) from (
             select attendance_grade, count(*) as n from personnel_pilot_v1.people group by 1) t),
          'by_rank_title', (select json_object_agg(coalesce(rank_title, '(null)'), n) from (
             select rank_title, count(*) as n from personnel_pilot_v1.people group by 1) t)
        )::text as j
      $q$, false, true, '')))[1]::text, '&lt;', '<'), '&gt;', '>'), '&amp;', '&')::jsonb
    end
  ),

  -- 업무 계정은 역할명 계정(관리자·소장·1팀장팀 등)이라 로그인명을 출력한다. 이메일은 출력하지 않는다.
  'login_profiles', (
    case when to_regclass('personnel_pilot_v1.login_profiles') is not null then
      replace(replace(replace((xpath('/row/j/text()', query_to_xml($q$
        select coalesce(json_agg(json_build_object(
          'login_name', lp.login_name, 'app_role', lp.app_role,
          'team_scope', lp.team_scope, 'enabled', lp.enabled,
          'auth_user_exists', exists (select 1 from auth.users u where u.id = lp.auth_user_id)
        ) order by lp.app_role, lp.login_name), '[]')::text as j
        from personnel_pilot_v1.login_profiles lp
      $q$, false, true, '')))[1]::text, '&lt;', '<'), '&gt;', '>'), '&amp;', '&')::jsonb
    end
  ),

  'counts_attendance_grade_edits', (
    case when to_regclass('personnel_pilot_v1.attendance_grade_edits') is not null then
      (xpath('/row/n/text()', query_to_xml(
        'select count(*) as n from personnel_pilot_v1.attendance_grade_edits', false, true, '')))[1]::text::bigint
    end
  ),

  'counts_works', (
    case when to_regclass('public.works') is not null then
      replace(replace(replace((xpath('/row/j/text()', query_to_xml($q$
        select json_build_object(
          'total', (select count(*) from public.works),
          'active', (select count(*) from public.works where is_active),
          'distinct_work_id', (select count(distinct work_id) from public.works),
          'min_work_date', (select min(work_date) from public.works),
          'max_work_date', (select max(work_date) from public.works),
          'by_work_type', (select json_object_agg(coalesce(work_type::text, '(null)'), n) from (
             select work_type, count(*) as n from public.works group by 1) t),
          'by_status', (select json_object_agg(coalesce(status::text, '(null)'), n) from (
             select status, count(*) as n from public.works group by 1) t)
        )::text as j
      $q$, false, true, '')))[1]::text, '&lt;', '<'), '&gt;', '>'), '&amp;', '&')::jsonb
    end
  ),

  'counts_auth_users', (
    case when to_regclass('auth.users') is not null then
      (xpath('/row/j/text()', query_to_xml($q$
        select json_build_object(
          'total', count(*),
          'email_confirmed', count(*) filter (where email_confirmed_at is not null),
          'with_phone', count(*) filter (where coalesce(phone, '') <> ''),
          'signed_in_last_30d', count(*) filter (where last_sign_in_at > now() - interval '30 days')
        )::text as j
        from auth.users
      $q$, false, true, '')))[1]::text::jsonb
    end
  )
)) as inspect_v08;
