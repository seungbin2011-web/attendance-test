-- 소속·역할 변경 템플릿 시험 1: 명부상 팀장인데 역할이 없던 사람 보정 + 팀 이동 (로컬 시험 DB 전용, 가짜 데이터)
-- 실행 전 상태(러너): inspect_before 저장 → 템플릿 실행
--   ('T-0008','시험일팀장','CONSTRUCTION_1','공사1팀','TEAM_LEADER')  -- 공사1팀은 teams에 없던 팀
--   ('T-0026','시험팀원가','CONSTRUCTION_1','공사1팀','MEMBER')       -- 공사2팀 → 공사1팀 이동
-- → inspect_after 저장
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse

-- 1. 점검 SQL(보정 전): 명부 팀장인데 역할 없는 사람을 찾아내고, 로그인 예상은 MEMBER
select test_util.expect('inspect finds leader without role',
  (select p ->> 'expected_app_role' from test_util.inspect_before i, jsonb_array_elements(i.check_roles::jsonb -> 'problems') p
   where p ->> 'user_id' = 'T-0008'), 'MEMBER');
select test_util.expect('inspect note text (참고, 권한 아님)',
  (select (p -> 'notes') ? '명부 팀장 · 팀장 역할 없음' from test_util.inspect_before i, jsonb_array_elements(i.check_roles::jsonb -> 'problems') p
   where p ->> 'user_id' = 'T-0008')::text, 'true');
select test_util.expect('inspect finds missing team',
  (select (p -> 'issues') ? '명부팀이 팀 목록(teams)에 없음' from test_util.inspect_before i, jsonb_array_elements(i.check_roles::jsonb -> 'problems') p
   where p ->> 'user_id' = 'T-0008')::text, 'true');
select test_util.expect('inspect manager expected',
  (select count(*)::text from test_util.inspect_before i, jsonb_array_elements_text(i.check_roles::jsonb -> 'ok') o where o like '시험소장 T-0003 %→ MANAGER'), '1');
select test_util.expect('inspect has no phone field', (select (check_roles like '%phone%' or check_roles like '%010-%')::text from test_util.inspect_before), 'false');

-- 2. 데이터: 새 팀, 새 소속, 팀장 역할. 이전 소속은 지우지 않고 종료일만 기록
select test_util.expect('team added', (select name from personnel_pilot_v1.teams where code = 'CONSTRUCTION_1'), '공사1팀');
select test_util.expect('leader membership', (select count(*)::text from personnel_pilot_v1.memberships m
  join personnel_pilot_v1.teams t on t.id = m.team_id and t.code = 'CONSTRUCTION_1'
  join personnel_pilot_v1.role_assignments r on r.membership_id = m.id and r.role_code = 'TEAM_LEADER' and r.revoked_at is null
  where m.person_id = 'c0000000-0000-0000-0000-000000000008' and m.valid_to is null), '1');
select test_util.expect('moved: old membership ended, kept', (select count(*)::text from personnel_pilot_v1.memberships m
  join personnel_pilot_v1.teams t on t.id = m.team_id and t.code = 'CONSTRUCTION_2'
  where m.person_id = 'c0000000-0000-0000-0000-000000000026' and m.valid_to is not null), '1');
select test_util.expect('moved: one current team', (select string_agg(t.name, ',') from personnel_pilot_v1.memberships m
  join personnel_pilot_v1.teams t on t.id = m.team_id
  where m.person_id = 'c0000000-0000-0000-0000-000000000026' and m.valid_to is null), '공사1팀');
select test_util.expect('no rows deleted', (select count(*)::text from personnel_pilot_v1.memberships),
  ((select value::int from test_util.snapshot where key = 'memberships_before_change') + 2)::text);
select test_util.expect('roles only added', (select count(*)::text from personnel_pilot_v1.role_assignments),
  ((select value::int from test_util.snapshot where key = 'roles_before_change') + 1)::text);
select test_util.expect('past tbm assignments kept', (select count(*)::text from field_pilot_v1.task_assignments where person_id = 'c0000000-0000-0000-0000-000000000026'),
  (select value from test_util.snapshot where key = 'assign26_before_change'));

-- 3. 로그인: 코드 수정 없이 팀장으로 판정, 팀·인원 후보는 현재 소속 기준
insert into auth.users (id, email, email_confirmed_at, raw_app_meta_data) values
  ('f0000000-0000-0000-0000-000000000008', 'member-c0000000-0000-0000-0000-000000000008@example.com', now(), '{"attendance_pilot":"v1","kind":"member_pin","person_id":"c0000000-0000-0000-0000-000000000008"}');
set role service_role;
select test_util.expect('roster login ok', public.pilot_member_roster_login('시험일팀장', 'T-0008', true, null) ->> 'ok', 'true');
select test_util.expect('link ok', public.pilot_member_link_account('c0000000-0000-0000-0000-000000000008', 'f0000000-0000-0000-0000-000000000008') ->> 'person_id', 'c0000000-0000-0000-0000-000000000008');
reset role;
insert into auth.sessions (id, user_id) values ('90000000-0000-0000-0000-000000000008', 'f0000000-0000-0000-0000-000000000008');
select test_util.claims('f0000000-0000-0000-0000-000000000008', '90000000-0000-0000-0000-000000000008');
set role authenticated;
select test_util.expect('now leader', public.pilot_whoami() ->> 'app_role', 'LEADER');
select test_util.expect('team from membership', public.tbm_today() -> 'team' ->> 'name', '공사1팀');
select test_util.expect('members of new team', (select string_agg(m ->> 'legacy_user_id', ',' order by m ->> 'legacy_user_id')
  from jsonb_array_elements(public.tbm_today() -> 'members') m), 'T-0008,T-0026');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000025', '90000000-0000-0000-0000-000000000025');
set role authenticated;
select test_util.expect('moved member left old team list', (select count(*)::text
  from jsonb_array_elements(public.tbm_today() -> 'members') m where m ->> 'legacy_user_id' = 'T-0026'), '0');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000026', '90000000-0000-0000-0000-000000000026');
set role authenticated;
select test_util.expect('moved member still member', public.pilot_whoami() ->> 'app_role', 'MEMBER');
select test_util.expect('moved member membership', public.pilot_whoami() -> 'memberships' -> 0 ->> 'team_name', '공사1팀');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000003', '90000000-0000-0000-0000-000000000003');
set role authenticated;
select test_util.expect('manager sees new team', (select count(*)::text from jsonb_array_elements(public.tbm_site_overview() -> 'teams') t
  where t ->> 'team_name' = '공사1팀'), '1');
reset role;

-- 4. 점검 SQL(보정 후): 팀장 문제는 사라지고, 이동한 사람의 명부 팀 글자도 같이 바뀐다
select test_util.expect('leader fixed in inspect', (select count(*)::text from test_util.inspect_after i,
  jsonb_array_elements_text(i.check_roles::jsonb -> 'ok') o where o = '시험일팀장 T-0008 · 공사1팀 · 팀장 → LEADER'), '1');
select test_util.expect('moved member roster text follows',
  (select count(*)::text from test_util.inspect_after i, jsonb_array_elements(i.check_roles::jsonb -> 'problems') p
   where p ->> 'user_id' = 'T-0026'), '0');
select test_util.expect('roster text updated with history', (select team_name || '/' || (select count(*) from personnel_pilot_v1.person_edits e
  where e.person_id = p.id and e.actor_login = 'roles_change_template')::text from personnel_pilot_v1.people p where p.legacy_user_id = 'T-0026'), '공사1팀/1');
select 'role change template test 1 passed';
