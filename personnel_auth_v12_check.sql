-- 현장 업무 통합 로그인 v0.12 · 적용 후 확인 + 로그인 번호 이관 현황 (읽기 전용: SELECT만, 별도 탭에서 실행)
-- SQL 버전: personnel_auth v0.12
-- 이관 현황: registered / active 가 같아지면 최초 이관(Apps Script)을 꺼도 된다 (Edge Function Secrets: MEMBER_LOGIN_FIRST_LOGIN_FALLBACK=off)
select jsonb_pretty(jsonb_build_object(
  'migrate_exists', to_regprocedure('public.pilot_member_login4_migrate(text,text,boolean,text,text)') is not null,
  'first_login_code', pg_get_functiondef('public.pilot_member_login4(text,text,text)'::regprocedure) like '%FIRST_LOGIN_REQUIRED%',
  'exec', jsonb_build_object(
      'migrate_anon', has_function_privilege('anon', 'public.pilot_member_login4_migrate(text,text,boolean,text,text)', 'EXECUTE'),
      'migrate_authenticated', has_function_privilege('authenticated', 'public.pilot_member_login4_migrate(text,text,boolean,text,text)', 'EXECUTE'),
      'migrate_service_role', has_function_privilege('service_role', 'public.pilot_member_login4_migrate(text,text,boolean,text,text)', 'EXECUTE')),
  'login_registered', (select count(*) from personnel_pilot_v1.people p where p.employment_status <> 'inactive'
      and exists (select 1 from personnel_pilot_v1.member_pins c where c.person_id = p.id and c.login4_hash is not null)),
  'active_people', (select count(*) from personnel_pilot_v1.people where employment_status <> 'inactive'),
  'first_login_migrated', (select count(*) from personnel_pilot_v1.member_pin_events where actor = 'first_login'),
  'not_registered_names', (select coalesce(jsonb_agg(p.display_name order by p.display_name), '[]'::jsonb) from personnel_pilot_v1.people p
      where p.employment_status <> 'inactive'
        and not exists (select 1 from personnel_pilot_v1.member_pins c where c.person_id = p.id and c.login4_hash is not null)),
  'expected', 'migrate_exists=true, first_login_code=true, exec: migrate_service_role만 true'
)) as check_v12;
