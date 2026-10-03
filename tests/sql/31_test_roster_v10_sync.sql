-- 2026-10 명단 시험 2: 동기화 후 숫자·사람별 역할·로그인·TBM (가짜 명단 53명)
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse

-- 1. 검증 SQL: 숫자와 사람별 팀·역할 모두 일치
select verify_roster::jsonb as v from test_util.roster_verify \gset
select test_util.expect('verify ok', (:'v'::jsonb) ->> 'ok', 'true');
select test_util.expect('active 53', (:'v'::jsonb) -> 'counts' ->> 'total', '53');
select test_util.expect('teams', (:'v'::jsonb) -> 'counts' ->> 'teams', '{"1팀": 15, "2팀": 23, "3팀": 9, "자재팀": 1, "현장·관리": 5}');
select test_util.expect('roles', (:'v'::jsonb) -> 'counts' ->> 'roles', '{"ADMIN": 1, "MEMBER": 35, "TEAM_LEADER": 13, "SITE_MANAGER": 4}');
select test_util.expect('unassigned 0', (:'v'::jsonb) -> 'counts' ->> 'unassigned', '0');
select test_util.expect('per person all match', (:'v'::jsonb) ->> 'mismatches', '[]');
select test_util.expect('per person checked', (:'v'::jsonb) ->> 'roster_checked', '53');

-- 2. 지난 TBM 기록은 그대로 (보고·작업 인원·사진 행 수, 팀 UUID 유지)
select test_util.expect('tbm rows kept', (select count(*) || '/' || (select count(*) from field_pilot_v1.task_assignments) || '/' || (select count(*) from field_pilot_v1.attachments)
  from field_pilot_v1.daily_reports), (select value from test_util.snapshot where key = 'tbm_rows_before'));
select test_util.expect('team uuid reused and renamed', (select name from personnel_pilot_v1.teams where id = 'b0000000-0000-0000-0000-000000000002'), '2팀');
select test_util.expect('no duplicate team meaning', (select count(*)::text from personnel_pilot_v1.teams where name in ('공사1팀', '공사2팀', '공사3팀')), '0');

-- 3. 사람별 역할 (직급·직무 글자는 그대로, 권한만 소속·역할 표)
create or replace function test_util.now_role(p_legacy text, p_name text) returns text language sql as $$
  select coalesce(t.name, '(팀 없음)') || ' ' || coalesce((select string_agg(r.role_code, ',' order by r.role_code) from personnel_pilot_v1.role_assignments r
    where r.membership_id = m.id and r.revoked_at is null), 'MEMBER')
  from personnel_pilot_v1.people p
  left join personnel_pilot_v1.memberships m on m.person_id = p.id and m.valid_to is null
  left join personnel_pilot_v1.teams t on t.id = m.team_id
  where p.legacy_user_id = p_legacy and p.display_name = p_name
$$;
select test_util.expect('old member → 2팀 leader', test_util.now_role('T-0008', '시험일팀장'), '2팀 TEAM_LEADER');
select test_util.expect('leader keeps job text', (select rank_title || '/' || job_title from personnel_pilot_v1.people where legacy_user_id = 'T-0008'), '팀장/전기');
select test_util.expect('other team leader → 2팀 leader', test_util.now_role('T-0026', '시험팀원가'), '2팀 TEAM_LEADER');
select test_util.expect('old leader text but member', test_util.now_role('T-0051', '시험삼팀원'), '2팀 MEMBER');
select test_util.expect('duplicate id kept apart', test_util.now_role('T-0036', '시험중복가'), '1팀 TEAM_LEADER');
select test_util.expect('excluded inactive', (select employment_status from personnel_pilot_v1.people where legacy_user_id = 'T-0036' and display_name = '시험중복나'), 'inactive');
select test_util.expect('excluded no membership', test_util.now_role('T-0036', '시험중복나'), '(팀 없음) MEMBER');
select test_util.expect('material leader, old role ended', test_util.now_role('T-0016', '시험자재'), '자재팀 TEAM_LEADER');
select test_util.expect('site manager', test_util.now_role('T-0003', '시험소장'), '현장·관리 SITE_MANAGER');
select test_util.expect('admin (ADMIN_DEPT)', test_util.now_role('T-1404', '시험관리자'), '현장·관리 ADMIN_DEPT');
select test_util.expect('new team leader', test_util.now_role('T-1301', '시험삼반장'), '3팀 TEAM_LEADER');
select test_util.expect('new person active', (select employment_status || '/' || source_system from personnel_pilot_v1.people where legacy_user_id = 'T-1301'), 'active/roster_sync_2026_10');
select test_util.expect('history kept (ended rows)', (select count(*)::text from personnel_pilot_v1.memberships m
  join personnel_pilot_v1.people p on p.id = m.person_id where p.legacy_user_id = 'T-0026' and m.valid_to is not null), '2');

-- 4. 로그인 판정: 화면 값이 아니라 서버 표
select test_util.claims('f0000000-0000-0000-0000-000000000008', '90000000-0000-0000-0000-000000000008');
set role authenticated;
select test_util.expect('leader login', public.pilot_whoami() ->> 'app_role', 'LEADER');
select test_util.expect('leader shown team', public.pilot_whoami() ->> 'team', '2팀');
select test_util.expect('leader tbm team', public.tbm_today() -> 'team' ->> 'name', '2팀');
select test_util.expect('leader candidates = current 2팀', jsonb_array_length(public.tbm_today() -> 'members')::text, '23');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000003', '90000000-0000-0000-0000-000000000003');
set role authenticated;
select test_util.expect('site manager login', public.pilot_whoami() ->> 'app_role', 'MANAGER');
select test_util.expect('overview teams', (select string_agg(t ->> 'team_name', ',' order by t ->> 'team_name') from jsonb_array_elements(public.tbm_site_overview() -> 'teams') t
  where t ->> 'team_name' in ('1팀', '2팀', '3팀', '자재팀', '현장·관리')), '1팀,2팀,3팀,자재팀');
select test_util.expect_error('site manager no roster edit', $$select public.pilot_roster()$$, 'PILOT_ACCESS_DENIED');
reset role;

-- 자재팀: 팀원 0명이어도 팀장 화면 정상
select test_util.claims('f0000000-0000-0000-0000-000000000016', '90000000-0000-0000-0000-000000000016');
set role authenticated;
select test_util.expect('material leader login', public.pilot_whoami() ->> 'app_role', 'LEADER');
select test_util.expect('material team opens', public.tbm_today() -> 'team' ->> 'name', '자재팀');
select test_util.expect('material candidates only self', (select string_agg(m ->> 'legacy_user_id', ',') from jsonb_array_elements(public.tbm_today() -> 'members') m), 'T-0016');
select test_util.expect('material my team', public.pilot_my_team() ->> 'members', '[]');
reset role;

-- 5. 같은 팀 팀장 여러 명: 같은 보고를 함께 작성·수정 / 다른 팀 팀장은 못 고침
update field_pilot_v1.daily_reports set work_date = work_date - 2
where team_id = 'b0000000-0000-0000-0000-000000000002' and work_date = field_pilot_v1.kst_today();
select test_util.claims('f0000000-0000-0000-0000-000000000008', '90000000-0000-0000-0000-000000000008');
set role authenticated;
select public.tbm_save_plan(jsonb_build_object('request_id', 'roster-p1', 'tasks', jsonb_build_array(jsonb_build_object('place', '7동', 'content', '배관',
  'members', jsonb_build_array(jsonb_build_object('person_id', 'c0000000-0000-0000-0000-000000000051')))))) -> 'report' as rep2 \gset
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000026', '90000000-0000-0000-0000-000000000026');
set role authenticated;
select test_util.expect('co-leader sees same report', public.tbm_today() -> 'report' ->> 'id', (:'rep2'::jsonb) ->> 'id');
select test_util.expect('co-leader edits', (public.tbm_save_plan(jsonb_build_object('request_id', 'roster-p2', 'version', ((:'rep2'::jsonb) ->> 'version')::int,
  'tasks', jsonb_build_array(jsonb_build_object('place', '7동', 'content', '배관 (수정)', 'members', '[]'::jsonb)))) -> 'report' -> 'tasks' -> 0 ->> 'content'), '배관 (수정)');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000008', '90000000-0000-0000-0000-000000000008');
set role authenticated;
select test_util.expect_error('stale version refused', format('select public.tbm_save_plan(%L::jsonb)', jsonb_build_object('request_id', 'roster-p3',
  'version', ((:'rep2'::jsonb) ->> 'version')::int, 'tasks', jsonb_build_array(jsonb_build_object('place', '7동', 'content', 'x', 'members', '[]'::jsonb)))), 'VERSION_CONFLICT');
reset role;
-- 1팀 팀장(시험중복가) 개인 로그인 준비
insert into auth.users (id, email, email_confirmed_at, raw_app_meta_data) values
  ('f0000000-0000-0000-0000-000000000036', 'member-c0000000-0000-0000-0000-000000000036@example.com', now(), '{"attendance_pilot":"v1","kind":"member_pin","person_id":"c0000000-0000-0000-0000-000000000036"}');
set role service_role;
select test_util.expect('1팀 leader roster login', public.pilot_member_roster_login('시험중복가', 'T-0036', true, null) ->> 'person_id', 'c0000000-0000-0000-0000-000000000036');
select test_util.expect('1팀 leader link', public.pilot_member_link_account('c0000000-0000-0000-0000-000000000036', 'f0000000-0000-0000-0000-000000000036') ->> 'person_id', 'c0000000-0000-0000-0000-000000000036');
select test_util.expect('excluded login blocked', public.pilot_member_roster_login('시험중복나', 'T-0036', true, null) ->> 'code', 'ACCOUNT_DISABLED');
reset role;
insert into auth.sessions (id, user_id) values ('90000000-0000-0000-0000-000000000036', 'f0000000-0000-0000-0000-000000000036');
select test_util.claims('f0000000-0000-0000-0000-000000000036', '90000000-0000-0000-0000-000000000036');
set role authenticated;
select test_util.expect('1팀 leader team', public.tbm_today() -> 'team' ->> 'name', '1팀');
select test_util.expect_error('other team report hidden', format('select public.tbm_report_detail(%L)', (:'rep2'::jsonb) ->> 'id'), 'REPORT_FORBIDDEN');
select test_util.expect_error('other team plan refused', format('select public.tbm_save_plan(%L::jsonb)', jsonb_build_object('request_id', 'roster-x1',
  'team_id', 'b0000000-0000-0000-0000-000000000002', 'tasks', jsonb_build_array(jsonb_build_object('place', '7동', 'content', 'x', 'members', '[]'::jsonb)))), 'TEAM_FORBIDDEN');
select test_util.expect_error('other team member refused', format('select public.tbm_save_plan(%L::jsonb)', jsonb_build_object('request_id', 'roster-x2',
  'tasks', jsonb_build_array(jsonb_build_object('place', '1동', 'content', 'x', 'members', jsonb_build_array(jsonb_build_object('person_id', 'c0000000-0000-0000-0000-000000000051')))))), 'MEMBER_NOT_IN_TEAM');
reset role;

-- 6. 관리자(새 인원 시험관리자): 서버 역할 ADMIN_DEPT → 관리자, 기존 관리자와 같은 명부 기능
select id as admin_id from personnel_pilot_v1.people where legacy_user_id = 'T-1404' \gset
insert into auth.users (id, email, email_confirmed_at, raw_app_meta_data) values
  ('f0000000-0000-0000-0000-000000001404', 'member-' || :'admin_id' || '@example.com', now(),
   jsonb_build_object('attendance_pilot', 'v1', 'kind', 'member_pin', 'person_id', :'admin_id'));
set role service_role;
select test_util.expect('admin roster login', public.pilot_member_roster_login('시험관리자', 'T-1404', true, null) ->> 'ok', 'true');
select test_util.expect('admin link', public.pilot_member_link_account(:'admin_id', 'f0000000-0000-0000-0000-000000001404') ->> 'person_id', :'admin_id');
reset role;
insert into auth.sessions (id, user_id) values ('90000000-0000-0000-0000-000000001404', 'f0000000-0000-0000-0000-000000001404');
select test_util.claims('f0000000-0000-0000-0000-000000001404', '90000000-0000-0000-0000-000000001404');
set role authenticated;
select test_util.expect('admin login', public.pilot_whoami() ->> 'app_role', 'ADMIN');
select test_util.expect('admin roster edit', public.pilot_roster() ->> 'can_edit', 'true');
select test_util.expect('admin roster shows current team text', (select x ->> 'team_name' from jsonb_array_elements(public.pilot_roster() -> 'people') x
  where x ->> 'legacy_user_id' = 'T-0008'), '2팀');
select test_util.expect('admin overview', public.tbm_site_overview() ->> 'ok', 'true');
reset role;

-- 7. 팀원 화면: 우리 팀장·팀원 = 현재 소속 (팀장 후보와 같은 기준)
insert into auth.users (id, email, email_confirmed_at, raw_app_meta_data) values
  ('f0000000-0000-0000-0000-000000000051', 'member-c0000000-0000-0000-0000-000000000051@example.com', now(), '{"attendance_pilot":"v1","kind":"member_pin","person_id":"c0000000-0000-0000-0000-000000000051"}');
set role service_role;
select test_util.expect('member roster login', public.pilot_member_roster_login('시험삼팀원', 'T-0051', true, null) ->> 'ok', 'true');
select test_util.expect('member link', public.pilot_member_link_account('c0000000-0000-0000-0000-000000000051', 'f0000000-0000-0000-0000-000000000051') ->> 'person_id', 'c0000000-0000-0000-0000-000000000051');
reset role;
insert into auth.sessions (id, user_id) values ('90000000-0000-0000-0000-000000000051', 'f0000000-0000-0000-0000-000000000051');
select test_util.claims('f0000000-0000-0000-0000-000000000051', '90000000-0000-0000-0000-000000000051');
set role authenticated;
select test_util.expect('member login', public.pilot_whoami() ->> 'app_role', 'MEMBER');
select test_util.expect('member shown team', public.pilot_whoami() ->> 'team', '2팀');
select test_util.expect('my team', public.pilot_my_team() ->> 'team', '2팀');
select test_util.expect('my team leaders 10', jsonb_array_length(public.pilot_my_team() -> 'leaders')::text, '10');
select test_util.expect('my team members 13', jsonb_array_length(public.pilot_my_team() -> 'members')::text, '13');
select test_util.expect_error('member no overview', $$select public.tbm_site_overview()$$, 'FORBIDDEN');
reset role;
select '2026-10 roster sync tests passed';
