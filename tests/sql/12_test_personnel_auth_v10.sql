-- personnel_auth v0.10 (개인 로그인 역할 판정: 팀원·팀장·소장) 시험 (로컬 시험 DB 전용, 가짜 데이터)
-- 실행 위치: field v0.1·v0.2 시험 뒤 (보고·사진이 있는 상태)
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse

-- 0. 함수 하나만 바뀌고 권한은 그대로
select test_util.expect('personal roles', (pg_get_functiondef('personnel_pilot_v1.current_actor()'::regprocedure)
  like '%array[''TEAM_LEADER'', ''SITE_MANAGER'', ''ADMIN_DEPT'']%')::text, 'true');
select test_util.expect('anon cannot roster_actor', has_function_privilege('anon', 'personnel_pilot_v1.roster_actor()', 'EXECUTE')::text, 'false');
select test_util.expect('authenticated cannot roster_actor', has_function_privilege('authenticated', 'personnel_pilot_v1.roster_actor()', 'EXECUTE')::text, 'false');
select test_util.expect('anon cannot my_team', has_function_privilege('anon', 'public.pilot_my_team()', 'EXECUTE')::text, 'false');
select test_util.expect('authenticated can my_team', has_function_privilege('authenticated', 'public.pilot_my_team()', 'EXECUTE')::text, 'true');
select test_util.expect('anon cannot current_actor', has_function_privilege('anon', 'personnel_pilot_v1.current_actor()', 'EXECUTE')::text, 'false');
select test_util.expect('authenticated cannot current_actor', has_function_privilege('authenticated', 'personnel_pilot_v1.current_actor()', 'EXECUTE')::text, 'false');
select test_util.expect('roster functions use roster_actor only', (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('pilot_roster', 'pilot_set_attendance_grade', 'pilot_update_person') and p.prosrc like '%roster_actor()%'), '3');
select test_util.expect('bind_account unchanged', (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'pilot_bind_account'), (select md5(prosrc) from pg_proc where proname = 'pilot_bind_account'));

-- 준비: 소장(T-0003, 현장 소속 + SITE_MANAGER) 개인 세션은 v0.8 시험에서 연결됨. PIN 변경 완료 상태로 둔다.
update personnel_pilot_v1.member_pins set must_change = false, pin_kind = 'PERSONAL' where person_id = 'c0000000-0000-0000-0000-000000000003';
select id as report_id from field_pilot_v1.daily_reports order by created_at limit 1 \gset
select object_path as photo_path from field_pilot_v1.attachments where status = 'READY' order by created_at limit 1 \gset

-- 1. 소장: 서버 역할 SITE_MANAGER → MANAGER, 본인 소속 현장만
select test_util.claims('f0000000-0000-0000-0000-000000000003', '90000000-0000-0000-0000-000000000003');
set role authenticated;
select test_util.expect('manager app_role', public.pilot_whoami() ->> 'app_role', 'MANAGER');
select test_util.expect('manager label is not a job title', public.pilot_whoami() ->> 'role_label', '현장관리');
select test_util.expect('manager roles', public.pilot_whoami() ->> 'roles', '["MEMBER", "SITE_MANAGER"]');
select test_util.expect('manager site from membership', public.pilot_whoami() ->> 'site_codes', '["YONGIN_PILOT"]');
select test_util.expect('manager no team scope', public.pilot_whoami() ->> 'team_scopes', '[]');
select test_util.expect('manager still personal', public.pilot_whoami() ->> 'kind', 'MEMBER_PIN');
select test_util.expect('overview ok', public.tbm_site_overview() ->> 'ok', 'true');
select test_util.expect('overview viewer', public.tbm_site_overview() -> 'viewer' ->> 'role_label', '현장관리');
select test_util.expect('detail ok', public.tbm_report_detail(:'report_id') ->> 'ok', 'true');
select test_util.expect('photo readable', field_pilot_v1.storage_can_read(:'photo_path')::text, 'true');
select test_util.expect_error('manager cannot write tbm', $$select public.tbm_today()$$, 'FORBIDDEN');
select test_util.expect_error('manager cannot save plan', $$select public.tbm_save_plan('{"request_id":"m1","tasks":[{"place":"1동","content":"x","members":[]}]}')$$, 'FORBIDDEN');
select test_util.expect_error('personal manager no roster', $$select public.pilot_roster()$$, 'PILOT_ACCESS_DENIED');
select test_util.expect_error('personal manager no grade change', $$select public.pilot_set_attendance_grade('c0000000-0000-0000-0000-000000000026', 1, 'B', '시험 변경')$$, 'EDIT_FORBIDDEN');
select test_util.expect('manager my_team (no team)', public.pilot_my_team() ->> 'team', null);
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
select test_util.expect('leader shown team from membership', public.pilot_whoami() ->> 'team', '공사2팀');
select test_util.expect('my team leaders', (select string_agg(x ->> 'userId', ',' order by x ->> 'userId') from jsonb_array_elements(public.pilot_my_team() -> 'leaders') x), 'T-0025');
select test_util.expect('my team members', (select string_agg(x ->> 'userId', ',' order by x ->> 'userId') from jsonb_array_elements(public.pilot_my_team() -> 'members') x), 'T-0026,T-0027,T-0036');
select test_util.expect('my team no phone', (public.pilot_my_team()::text like '%phone%')::text, 'false');
select test_util.expect_error('leader no roster', $$select public.pilot_roster()$$, 'PILOT_ACCESS_DENIED');
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

-- 5-1. 관리자: 관리부서(ADMIN_DEPT) 역할 → ADMIN. 기존 관리자 업무계정과 같은 명부 조회·편집·등급 변경 + TBM 현황
insert into personnel_pilot_v1.role_assignments (membership_id, role_code) values ('e0000000-0000-0000-0000-000000000016', 'ADMIN_DEPT');
insert into auth.users (id, email, email_confirmed_at, raw_app_meta_data) values
  ('f0000000-0000-0000-0000-000000000016', 'member-c0000000-0000-0000-0000-000000000016@example.com', now(), '{"attendance_pilot":"v1","kind":"member_pin","person_id":"c0000000-0000-0000-0000-000000000016"}');
set role service_role;
select test_util.expect('admin roster login', public.pilot_member_roster_login('시험자재', 'T-0016', true, null) ->> 'ok', 'true');
select test_util.expect('admin link', public.pilot_member_link_account('c0000000-0000-0000-0000-000000000016', 'f0000000-0000-0000-0000-000000000016') ->> 'person_id', 'c0000000-0000-0000-0000-000000000016');
reset role;
insert into auth.sessions (id, user_id) values ('90000000-0000-0000-0000-000000000016', 'f0000000-0000-0000-0000-000000000016');
select test_util.claims('f0000000-0000-0000-0000-000000000016', '90000000-0000-0000-0000-000000000016');
set role authenticated;
select test_util.expect('admin app_role', public.pilot_whoami() ->> 'app_role', 'ADMIN');
select test_util.expect('admin label', public.pilot_whoami() ->> 'role_label', '관리자');
select test_util.expect('admin roles', public.pilot_whoami() ->> 'roles', '["MEMBER", "ADMIN"]');
select test_util.expect('admin roster', public.pilot_roster() ->> 'can_edit', 'true');
select test_util.expect('admin roster name', public.pilot_roster() ->> 'login_name', '시험자재');
select test_util.expect('admin overview', public.tbm_site_overview() ->> 'ok', 'true');
select (public.pilot_roster() -> 'people') as roster27 \gset
select test_util.expect('admin grade change', public.pilot_set_attendance_grade('c0000000-0000-0000-0000-000000000027',
  (select (x ->> 'version')::int from jsonb_array_elements(:'roster27'::jsonb) x where x ->> 'id' = 'c0000000-0000-0000-0000-000000000027'),
  'B', '시험 변경') ->> 'attendance_grade', 'B');
select test_util.expect('admin edit person', (public.pilot_update_person('c0000000-0000-0000-0000-000000000027',
  (select (x ->> 'version')::int + 1 from jsonb_array_elements(:'roster27'::jsonb) x where x ->> 'id' = 'c0000000-0000-0000-0000-000000000027'),
  '시험팀원나', '자재팀', '팀원', '배관', 'unknown', '') ->> 'id'), 'c0000000-0000-0000-0000-000000000027');
select test_util.expect_error('admin cannot write tbm', $$select public.tbm_today()$$, 'FORBIDDEN');
reset role;
select test_util.expect('edit history by personal admin', (select actor_login || '/' || (actor_id = 'f0000000-0000-0000-0000-000000000016')::text
  from personnel_pilot_v1.person_edits where person_id = 'c0000000-0000-0000-0000-000000000027' order by edited_at desc limit 1), '시험자재/true');
-- 관리자 역할이 끝나면 명부도 즉시 닫힘
update personnel_pilot_v1.role_assignments set revoked_at = clock_timestamp()
where membership_id = 'e0000000-0000-0000-0000-000000000016' and role_code = 'ADMIN_DEPT' and revoked_at is null;
set role authenticated;
select test_util.expect_error('ex-admin no roster', $$select public.pilot_roster()$$, 'PILOT_ACCESS_DENIED');
reset role;
update personnel_pilot_v1.people set team_name = '공사2팀', attendance_grade = 'A' where id = 'c0000000-0000-0000-0000-000000000027';
-- 명부 편집의 팀 이름: 기존 목록 또는 teams 표의 현재 팀 이름만
select version as v27 from personnel_pilot_v1.people where id = 'c0000000-0000-0000-0000-000000000027' \gset
select test_util.claims('d0000000-0000-0000-0000-0000000000a1', null);
set role authenticated;
select test_util.expect_error('unknown team refused', format($$select public.pilot_update_person('c0000000-0000-0000-0000-000000000027',
  %s, '시험팀원나', '없는팀', '팀원', '배관', 'unknown', '')$$, :v27), 'INVALID_INPUT');
select test_util.expect('team from teams table ok', (public.pilot_update_person('c0000000-0000-0000-0000-000000000027',
  :v27, '시험팀원나', '시험3팀', '팀원', '배관', 'unknown', '') ->> 'id'), 'c0000000-0000-0000-0000-000000000027');
reset role;
update personnel_pilot_v1.people set team_name = '공사2팀' where id = 'c0000000-0000-0000-0000-000000000027';

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
