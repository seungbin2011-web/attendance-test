-- 현장 업무 통합 로그인 v0.11 · 적용 후 확인 (읽기 전용: SELECT만, 별도 탭에서 실행)
-- SQL 버전: personnel_auth v0.11
select jsonb_pretty(jsonb_build_object(
  'functions', jsonb_build_object(
      'login4', to_regprocedure('public.pilot_member_login4(text,text,text)') is not null,
      'admin_save', to_regprocedure('public.pilot_admin_save_person(jsonb)') is not null,
      'org_chart', to_regprocedure('public.pilot_org_chart()') is not null),
  'exec', jsonb_build_object(
      'login4_anon', has_function_privilege('anon', 'public.pilot_member_login4(text,text,text)', 'EXECUTE'),
      'login4_authenticated', has_function_privilege('authenticated', 'public.pilot_member_login4(text,text,text)', 'EXECUTE'),
      'login4_service_role', has_function_privilege('service_role', 'public.pilot_member_login4(text,text,text)', 'EXECUTE'),
      'admin_save_anon', has_function_privilege('anon', 'public.pilot_admin_save_person(jsonb)', 'EXECUTE'),
      'org_chart_anon', has_function_privilege('anon', 'public.pilot_org_chart()', 'EXECUTE'),
      'set_login4_authenticated', has_function_privilege('authenticated', 'personnel_pilot_v1.set_login4(uuid,text,text)', 'EXECUTE')),
  'legacy_user_id_optional', (select is_nullable = 'YES' from information_schema.columns
      where table_schema = 'personnel_pilot_v1' and table_name = 'people' and column_name = 'legacy_user_id'),
  'login4_plaintext_free', not exists (select 1 from personnel_pilot_v1.member_pins where login4_hash is not null and login4_hash !~ '^\$2[abxy]\$'),
  'active_people', (select count(*) from personnel_pilot_v1.people where employment_status <> 'inactive'),
  'active_without_login', (select count(*) from personnel_pilot_v1.people p where p.employment_status <> 'inactive'
      and not exists (select 1 from personnel_pilot_v1.member_pins c where c.person_id = p.id and c.login4_hash is not null)),
  'active_without_login_names', (select coalesce(jsonb_agg(p.display_name order by p.display_name), '[]'::jsonb) from personnel_pilot_v1.people p
      where p.employment_status <> 'inactive'
        and not exists (select 1 from personnel_pilot_v1.member_pins c where c.person_id = p.id and c.login4_hash is not null)),
  'expected', 'functions 모두 true, exec: login4_service_role만 true 나머지 false, legacy_user_id_optional=true, login4_plaintext_free=true, active_without_login=0 (명단·로그인 번호 반영 후)'
)) as check_v11;
