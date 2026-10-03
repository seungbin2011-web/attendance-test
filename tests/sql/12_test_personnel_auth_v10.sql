-- personnel_auth v0.10 (개인 로그인 역할 판정: 팀원·팀장·소장) 시험 (로컬 시험 DB 전용, 가짜 데이터)
-- 실행 위치: field v0.1·v0.2 시험 뒤 (보고·사진이 있는 상태)
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse

-- 0. 함수 하나만 바뀌고 권한은 그대로
select test_util.expect('personal roles', (pg_get_functiondef('personnel_pilot_v1.current_actor()'::regprocedure)
  like '%array[''TEAM_LEADER'', ''SITE_MANAGER'']%')::text, 'true');
select test_util.expect('anon cannot current_actor', has_function_privilege('anon', 'personnel_pilot_v1.current_actor()', 'EXECUTE')::text, 'false');
select test_util.expect('authenticated cannot current_actor', has_function_privilege('authenticated', 'personnel_pilot_v1.current_actor()', 'EXECUTE')::text, 'false');
select test_util.expect('pilot functions unchanged',
  (select md5(string_agg(p.proname || md5(p.prosrc), ',' order by p.proname)) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('pilot_roster', 'pilot_set_attendance_grade', 'pilot_update_person', 'pilot_bind_account')),
  (select value from test_util.snapshot where key = 'pilot_functions'));

-- 준비: 소장(T-0003, 현장 소속 + SITE_MANAGER) 개인 세션은 v0.8 시험에서 연결됨. PIN 변경 완료 상태로 둔다.
update personnel_pilot_v1.member_pins set must_change = false, pin_kind = 'PERSONAL' where person_id = 'c0000000-0000-0000-0000-000000000003';
select id as report_id from field_pilot_v1.daily_reports order by created_at limit 1 \gset
select object_path as photo_path from field_pilot_v1.attachments where status = 'READY' order by created_at limit 1 \gset

-- 1. 소장: 서버 역할 SITE_MANAGER → MANAGER, 본인 소속 현장만
select test_util.claims('f0000000-0000-0000-0000-000000000003', '90000000-0000-0000-0000-000000000003');
set role authenticated;
select test_util.expect('manager app_role', public.pilot_whoami() ->> 'app_role', 'MANAGER');
select test_util.expect('manager label', public.pilot_whoami() ->> 'role_label', '소장');
select test_util.expect('manager roles', public.pilot_whoami() ->> 'roles', '["MEMBER", "SITE_MANAGER"]');
select test_util.expect('manager site from membership', public.pilot_whoami() ->> 'site_codes', '["YONGIN_PILOT"]');
select test_util.expect('manager no team scope', public.pilot_whoami() ->> 'team_scopes', '[]');
select test_util.expect('manager still personal', public.pilot_whoami() ->> 'kind', 'MEMBER_PIN');
select test_util.expect('overview ok', public.tbm_site_overview() ->> 'ok', 'true');
select test_util.expect('overview viewer', public.tbm_site_overview() -> 'viewer' ->> 'role_label', '소장');
select test_util.expect('detail ok', public.tbm_report_detail(:'report_id') ->> 'ok', 'true');
select test_util.expect('photo readable', field_pilot_v1.storage_can_read(:'photo_path')::text, 'true');
select test_util.expect_error('manager cannot write tbm', $$select public.tbm_today()$$, 'FORBIDDEN');
select test_util.expect_error('manager cannot save plan', $$select public.tbm_save_plan('{"request_id":"m1","tasks":[{"place":"1동","content":"x","members":[]}]}')$$, 'FORBIDDEN');
select test_util.expect_error('personal manager no roster', $$select public.pilot_roster()$$, 'PILOT_ACCESS_DENIED');
select test_util.expect_error('personal manager cannot edit people', $$select public.pilot_update_person('c0000000-0000-0000-0000-000000000026', 1, '바꿈', '공사2팀', '팀원', '', 'unknown', '')$$, 'EDIT_FORBIDDEN');
reset role;

-- 2. 소장 현장 소속이 끝나면 소장 화면도 닫힘 (현장 범위는 현재 소속 기준)
update personnel_pilot_v1.memberships set valid_to = clock_timestamp() where id = 'e0000000-0000-0000-0000-000000000003';
set role authenticated;
select test_util.expect('ended membership → member', public.pilot_whoami() ->> 'app_role', 'MEMBER');
select test_util.expect_error('ended membership no overview', $$select public.tbm_site_overview()$$, 'FORBIDDEN');
reset role;
update personnel_pilot_v1.memberships set valid_to = null where id = 'e0000000-0000-0000-0000-000000000003';

-- 3. 팀원: 역할 없음 → MEMBER. 화면이 보낸 값(JWT 안의 역할 글자)으로는 바뀌지 않음
select set_config('request.jwt.claims', jsonb_build_object('sub', 'f0000000-0000-0000-0000-000000000026', 'role', 'authenticated',
  'session_id', '90000000-0000-0000-0000-000000000026',
  'app_metadata', jsonb_build_object('app_role', 'MANAGER', 'roles', jsonb_build_array('SITE_MANAGER')),
  'user_metadata', jsonb_build_object('app_role', 'MANAGER'))::text, false);
set role authenticated;
select test_util.expect('member stays member', public.pilot_whoami() ->> 'app_role', 'MEMBER');
select test_util.expect('member label', public.pilot_whoami() ->> 'role_label', '팀원');
select test_util.expect_error('member no overview', $$select public.tbm_site_overview()$$, 'FORBIDDEN');
select test_util.expect_error('member no detail', format('select public.tbm_report_detail(%L)', :'report_id'), 'FORBIDDEN');
select test_util.expect('member no photo', field_pilot_v1.storage_can_read(:'photo_path')::text, 'false');
reset role;

-- 4. 팀장: TEAM_LEADER → LEADER (v0.8과 같음), 소장 화면은 못 봄
select test_util.claims('f0000000-0000-0000-0000-000000000025', '90000000-0000-0000-0000-000000000025');
set role authenticated;
select test_util.expect('leader app_role', public.pilot_whoami() ->> 'app_role', 'LEADER');
select test_util.expect('leader label', public.pilot_whoami() ->> 'role_label', '팀장');
select test_util.expect('leader team', public.tbm_today() -> 'team' ->> 'name', '공사2팀');
select test_util.expect_error('leader no overview', $$select public.tbm_site_overview()$$, 'FORBIDDEN');
reset role;

-- 5. 업무계정은 그대로 (소장 업무계정 = 비상용, 전체 현장)
select test_util.claims('d0000000-0000-0000-0000-0000000000a2', null);
set role authenticated;
select test_util.expect('work manager kind', public.pilot_whoami() ->> 'kind', 'WORK_ACCOUNT');
select test_util.expect('work manager role', public.pilot_whoami() ->> 'app_role', 'MANAGER');
select test_util.expect('work manager overview', public.tbm_site_overview() ->> 'ok', 'true');
select test_util.expect('work manager roster', (public.pilot_roster() ->> 'can_edit'), 'true');
reset role;
select test_util.claims('d0000000-0000-0000-0000-0000000000a1', null);
set role authenticated;
select test_util.expect('work admin role', public.pilot_whoami() ->> 'app_role', 'ADMIN');
reset role;

-- 6. 비활성(퇴사) 소장은 로그인 자체가 막힘
update personnel_pilot_v1.people set employment_status = 'inactive' where id = 'c0000000-0000-0000-0000-000000000003';
select test_util.claims('f0000000-0000-0000-0000-000000000003', '90000000-0000-0000-0000-000000000003');
set role authenticated;
select test_util.expect_error('inactive manager blocked', $$select public.pilot_whoami()$$, 'ACCOUNT_INACTIVE');
reset role;
update personnel_pilot_v1.people set employment_status = 'unknown' where id = 'c0000000-0000-0000-0000-000000000003';

-- 다음 시험(변경 템플릿) 비교용 기록: 삭제가 없어야 하고, 지난 TBM 배정은 그대로 남아야 한다
insert into test_util.snapshot values
  ('memberships_before_change', (select count(*)::text from personnel_pilot_v1.memberships)),
  ('roles_before_change', (select count(*)::text from personnel_pilot_v1.role_assignments)),
  ('assign26_before_change', (select count(*)::text from field_pilot_v1.task_assignments where person_id = 'c0000000-0000-0000-0000-000000000026'))
on conflict (key) do update set value = excluded.value;
select 'personnel_auth v0.10 tests passed';
