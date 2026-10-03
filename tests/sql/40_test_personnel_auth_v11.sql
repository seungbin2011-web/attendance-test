-- personnel_auth v0.11 (Supabase 단독 로그인 + 관리자 인원 관리 + 조직도 권한) 시험 (로컬 시험 DB 전용, 가짜 데이터)
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse

-- 0. 권한·구조
select test_util.expect('login4 service_role only', (has_function_privilege('service_role', 'public.pilot_member_login4(text,text,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.pilot_member_login4(text,text,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.pilot_member_login4(text,text,text)', 'EXECUTE'))::text, 'true');
select test_util.expect('admin save not anon', has_function_privilege('anon', 'public.pilot_admin_save_person(jsonb)', 'EXECUTE')::text, 'false');
select test_util.expect('org chart not anon', has_function_privilege('anon', 'public.pilot_org_chart()', 'EXECUTE')::text, 'false');
select test_util.expect('helpers closed', (has_function_privilege('authenticated', 'personnel_pilot_v1.set_login4(uuid,text,text)', 'EXECUTE')
  or has_function_privilege('authenticated', 'personnel_pilot_v1.assign_current(uuid,uuid,text)', 'EXECUTE')
  or has_function_privilege('service_role', 'personnel_pilot_v1.set_login4(uuid,text,text)', 'EXECUTE'))::text, 'false');
select test_util.expect('legacy id optional', (select is_nullable from information_schema.columns where table_schema = 'personnel_pilot_v1'
  and table_name = 'people' and column_name = 'legacy_user_id'), 'YES');
set role anon;
select test_util.expect_error('anon org chart', $$select public.pilot_org_chart()$$, 'permission denied');
reset role;

-- 1. 로그인 번호 등록 (해시만) · 같은 이름 다른 번호는 허용, 같은 이름 같은 번호는 거절
select personnel_pilot_v1.set_login4(id, code, 'test') from (values
  ('c0000000-0000-0000-0000-000000000025'::uuid, '2525'), ('c0000000-0000-0000-0000-000000000026'::uuid, '2626'),
  ('c0000000-0000-0000-0000-000000000003'::uuid, '0303'), ('c0000000-0000-0000-0000-000000000016'::uuid, '1616'),
  ('c0000000-0000-0000-0000-000000000008'::uuid, '0808'), ('c0000000-0000-0000-0000-000000000028'::uuid, '2828'),
  ('c0000000-0000-0000-0000-000000000040'::uuid, '4040'), ('c0000000-0000-0000-0000-000000000041'::uuid, '4141')) v(id, code);
select test_util.expect('hash only', (select count(*)::text from personnel_pilot_v1.member_pins where login4_hash is not null
  and (login4_hash not like '$2%' or login4_hash in ('2525', '2626', '0303', '1616', '0808', '2828', '4040', '4141'))), '0');
select test_util.expect_error('same name same code refused', $$select personnel_pilot_v1.set_login4('c0000000-0000-0000-0000-000000000041', '4040', 'test')$$, 'LOGIN_DUPLICATE');
select test_util.expect_error('code format', $$select personnel_pilot_v1.set_login4('c0000000-0000-0000-0000-000000000041', '12a4', 'test')$$, 'INVALID_LOGIN_CODE');

-- 2. 로그인 (Apps Script 없이 DB만)
set role service_role;
select test_util.expect('leader ok', public.pilot_member_login4('시험이팀장', '2525', '10.11.0.1') ->> 'person_id', 'c0000000-0000-0000-0000-000000000025');
select test_util.expect('manager ok', public.pilot_member_login4('시험소장', '0303', null) ->> 'person_id', 'c0000000-0000-0000-0000-000000000003');
select test_util.expect('wrong code', public.pilot_member_login4('시험이팀장', '9999', '10.11.0.1') ->> 'code', 'INVALID_CREDENTIALS');
select test_util.expect('unknown name', public.pilot_member_login4('없는사람', '1234', '10.11.0.1') ->> 'code', 'INVALID_CREDENTIALS');
select test_util.expect('inactive blocked', public.pilot_member_login4('시험퇴사자', '2828', null) ->> 'code', 'ACCOUNT_DISABLED');
select test_util.expect('bad input', public.pilot_member_login4('시험이팀장', '25a5', null) ->> 'code', 'INVALID_INPUT');
select test_util.expect('same name: code picks person A', public.pilot_member_login4('시험동명', '4040', null) ->> 'person_id', 'c0000000-0000-0000-0000-000000000040');
select test_util.expect('same name: code picks person B', public.pilot_member_login4('시험 동명', '4141', null) ->> 'person_id', 'c0000000-0000-0000-0000-000000000041');
reset role;
-- 같은 이름 + 같은 번호가 생기면(직접 수정 흉내) 자동 로그인 대신 AMBIGUOUS
update personnel_pilot_v1.member_pins set login4_hash = extensions.crypt('4040', extensions.gen_salt('bf', 4))
where person_id = 'c0000000-0000-0000-0000-000000000041';
set role service_role;
select test_util.expect('same name same code ambiguous', public.pilot_member_login4('시험동명', '4040', null) ->> 'code', 'AMBIGUOUS');
reset role;
select personnel_pilot_v1.set_login4('c0000000-0000-0000-0000-000000000041', '4141', 'test');
-- 사용 중지·잠금은 기존 기준 그대로
select personnel_pilot_v1.admin_set_member_login('c0000000-0000-0000-0000-000000000008', false, '시험 중지');
set role service_role;
select test_util.expect('disabled blocked', public.pilot_member_login4('시험일팀장', '0808', null) ->> 'code', 'ACCOUNT_DISABLED');
reset role;
select personnel_pilot_v1.admin_set_member_login('c0000000-0000-0000-0000-000000000008', true, '시험 재개');
set role service_role;
select count(*) from (select public.pilot_member_login4('시험팀원가', '0000', '10.11.0.2') from generate_series(1, 5)) f;
select test_util.expect('locked after 5 even with right code', public.pilot_member_login4('시험팀원가', '2626', '10.11.0.2') ->> 'code', 'LOCKED');
reset role;
update personnel_pilot_v1.member_login_attempts set attempted_at = attempted_at - interval '31 minutes'
where name_key = personnel_pilot_v1.name_key('시험팀원가');
set role service_role;
select test_util.expect('unlocked after 30 min', public.pilot_member_login4('시험팀원가', '2626', null) ->> 'ok', 'true');
reset role;
select test_util.expect('ok logged with person', (select count(*)::text from personnel_pilot_v1.member_login_attempts
  where person_id = 'c0000000-0000-0000-0000-000000000025' and outcome = 'OK'), '1');

-- 3. 관리자 인원 관리 (개인 로그인 관리자: 시험자재를 관리자 역할로)
select personnel_pilot_v1.assign_current('c0000000-0000-0000-0000-000000000016', 'b0000000-0000-0000-0000-00000000000a', 'ADMIN_DEPT');
select test_util.claims('f0000000-0000-0000-0000-000000000016', '90000000-0000-0000-0000-000000000016');
set role authenticated;
select test_util.expect('admin role', public.pilot_whoami() ->> 'app_role', 'ADMIN');
select test_util.expect('roster teams list', ((public.pilot_roster() -> 'teams' -> 0 ->> 'name') is not null)::text, 'true');
select test_util.expect('roster has_login, no secret', (select (x ? 'has_login')::text || '/' || (public.pilot_roster()::text like '%$2%')::text
  from jsonb_array_elements(public.pilot_roster() -> 'people') x where x ->> 'legacy_user_id' = 'T-0025'), 'true/false');
-- 추가
select public.pilot_admin_save_person(jsonb_build_object('name', '시험신규', 'team_id', 'b0000000-0000-0000-0000-000000000003', 'role', 'MEMBER',
  'rank', '팀원', 'job', '배관', 'login_code', '7777')) ->> 'id' as new_id \gset
select test_util.expect_error('new without code', $$select public.pilot_admin_save_person('{"name":"시험무번호","team_id":"b0000000-0000-0000-0000-000000000003"}')$$, 'LOGIN_CODE_REQUIRED');
select test_util.expect_error('active without team', $$select public.pilot_admin_save_person('{"name":"시험무팀","login_code":"1234"}')$$, 'TEAM_REQUIRED');
select test_util.expect_error('bad code', $$select public.pilot_admin_save_person('{"name":"시험짧은","team_id":"b0000000-0000-0000-0000-000000000003","login_code":"12"}')$$, 'INVALID_INPUT');
select test_util.expect_error('same name same code new person', $$select public.pilot_admin_save_person('{"name":"시험신규","team_id":"b0000000-0000-0000-0000-000000000002","login_code":"7777"}')$$, 'LOGIN_DUPLICATE');
reset role;
select test_util.expect('created without legacy id', (select coalesce(legacy_user_id, 'null') || '/' || employment_status || '/' || team_name || '/' || source_system
  from personnel_pilot_v1.people where id = :'new_id'), 'null/active/시험3팀/admin_screen');
select test_util.expect('duplicate rolled back', (select count(*)::text from personnel_pilot_v1.people where display_name = '시험신규'), '1');
select test_util.expect('failed creates left nothing', (select count(*)::text from personnel_pilot_v1.people where display_name in ('시험무번호', '시험무팀', '시험짧은')), '0');
set role service_role;
select test_util.expect('new person logs in', public.pilot_member_login4('시험신규', '7777', null) ->> 'person_id', :'new_id');
reset role;
-- 팀 이동 + 팀장
select test_util.claims('f0000000-0000-0000-0000-000000000016', '90000000-0000-0000-0000-000000000016');
set role authenticated;
select public.pilot_admin_save_person(jsonb_build_object('id', :'new_id', 'version', 1, 'name', '시험신규', 'team_id', 'b0000000-0000-0000-0000-000000000002',
  'role', 'TEAM_LEADER', 'rank', '팀원', 'job', '배관', 'status', 'active')) ->> 'version' as v2 \gset
select test_util.expect_error('stale version', format('select public.pilot_admin_save_person(%L::jsonb)', jsonb_build_object('id', :'new_id', 'version', 1,
  'name', '시험신규', 'team_id', 'b0000000-0000-0000-0000-000000000002')), 'VERSION_CONFLICT');
reset role;
create or replace function test_util.cur(p uuid) returns text language sql as $$
  select coalesce(string_agg(t.name || ':' || coalesce((select string_agg(r.role_code, ',') from personnel_pilot_v1.role_assignments r
    where r.membership_id = m.id and r.revoked_at is null), 'MEMBER'), ';'), '(없음)')
  from personnel_pilot_v1.memberships m join personnel_pilot_v1.teams t on t.id = m.team_id where m.person_id = p and m.valid_to is null
$$;
select test_util.expect('moved + leader', test_util.cur(:'new_id'), '공사2팀:TEAM_LEADER');
select test_util.expect('old membership kept as history', (select count(*)::text from personnel_pilot_v1.memberships where person_id = :'new_id' and valid_to is not null), '1');
-- 팀장 → 팀원, 로그인 번호 변경
select test_util.claims('f0000000-0000-0000-0000-000000000016', '90000000-0000-0000-0000-000000000016');
set role authenticated;
select public.pilot_admin_save_person(jsonb_build_object('id', :'new_id', 'version', :v2, 'name', '시험신규', 'team_id', 'b0000000-0000-0000-0000-000000000002',
  'role', 'MEMBER', 'status', 'active', 'login_code', '8888')) ->> 'version' as v3 \gset
reset role;
select test_util.expect('leader → member', test_util.cur(:'new_id'), '공사2팀:MEMBER');
set role service_role;
select test_util.expect('old code fails', public.pilot_member_login4('시험신규', '7777', null) ->> 'code', 'INVALID_CREDENTIALS');
select test_util.expect('new code ok', public.pilot_member_login4('시험신규', '8888', null) ->> 'ok', 'true');
reset role;
-- 비활성 → 로그인·소속·역할 종료, 기록 유지 / 재투입 → 같은 사람
select test_util.claims('f0000000-0000-0000-0000-000000000016', '90000000-0000-0000-0000-000000000016');
set role authenticated;
select public.pilot_admin_save_person(jsonb_build_object('id', :'new_id', 'version', :v3, 'name', '시험신규', 'status', 'inactive')) ->> 'version' as v4 \gset
reset role;
select test_util.expect('inactive: no current team', test_util.cur(:'new_id'), '(없음)');
set role service_role;
select test_util.expect('inactive: login blocked', public.pilot_member_login4('시험신규', '8888', null) ->> 'code', 'ACCOUNT_DISABLED');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000016', '90000000-0000-0000-0000-000000000016');
set role authenticated;
select public.pilot_admin_save_person(jsonb_build_object('id', :'new_id', 'version', :v4, 'name', '시험신규', 'status', 'active',
  'team_id', 'b0000000-0000-0000-0000-000000000003', 'role', 'MEMBER'));
reset role;
select test_util.expect('rejoined same uuid', test_util.cur(:'new_id'), '시험3팀:MEMBER');
set role service_role;
select test_util.expect('rejoined login', public.pilot_member_login4('시험신규', '8888', null) ->> 'person_id', :'new_id');
reset role;
select test_util.expect('edit history', (select (count(*) >= 5)::text from personnel_pilot_v1.person_edits where person_id = :'new_id'), 'true');

-- 4. 관리자 말고는 인원 관리 불가 (현장관리 개인·소장 업무계정·팀장)
select test_util.claims('f0000000-0000-0000-0000-000000000003', '90000000-0000-0000-0000-000000000003');
set role authenticated;
select test_util.expect('site manager personal', public.pilot_whoami() ->> 'app_role', 'MANAGER');
select test_util.expect_error('site manager cannot manage', format('select public.pilot_admin_save_person(%L::jsonb)', jsonb_build_object('name', '시험x', 'team_id', 'b0000000-0000-0000-0000-000000000002', 'login_code', '1111')), 'EDIT_FORBIDDEN');
reset role;
select test_util.claims('d0000000-0000-0000-0000-0000000000a2', null);
set role authenticated;
select test_util.expect_error('work manager cannot manage', $$select public.pilot_admin_save_person('{"name":"시험y","team_id":"b0000000-0000-0000-0000-000000000002","login_code":"2222"}')$$, 'EDIT_FORBIDDEN');
select test_util.expect('work manager roster: grade only', (public.pilot_roster() ->> 'can_edit') || '/' || (public.pilot_roster() ->> 'can_change_grade'), 'false/true');
select test_util.expect_error('work manager old edit closed', $$select public.pilot_update_person('c0000000-0000-0000-0000-000000000026', 1, '바꿈', '', '팀원', '', 'unknown', '')$$, 'EDIT_FORBIDDEN');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000025', '90000000-0000-0000-0000-000000000025');
set role authenticated;
select test_util.expect_error('leader cannot manage', $$select public.pilot_admin_save_person('{"name":"시험z","team_id":"b0000000-0000-0000-0000-000000000002","login_code":"3333"}')$$, 'EDIT_FORBIDDEN');
reset role;
select test_util.claims('d0000000-0000-0000-0000-0000000000a1', null);
set role authenticated;
select test_util.expect('work admin can manage', (public.pilot_roster() ->> 'can_edit'), 'true');
reset role;

-- 5. 조직도: 현장관리·관리자만, 민감정보 없음
select test_util.claims('f0000000-0000-0000-0000-000000000003', '90000000-0000-0000-0000-000000000003');
set role authenticated;
select public.pilot_org_chart() as org \gset
select test_util.expect('org for site manager', (:'org'::jsonb) ->> 'ok', 'true');
select test_util.expect('org has people with team and role', (select x ->> 'team' || '/' || (x ->> 'role') from jsonb_array_elements((:'org'::jsonb) -> 'people') x
  where x ->> 'person_id' = 'c0000000-0000-0000-0000-000000000025'), '공사2팀/TEAM_LEADER');
select test_util.expect('org no inactive', (select count(*)::text from jsonb_array_elements((:'org'::jsonb) -> 'people') x where x ->> 'name' = '시험퇴사자'), '0');
select test_util.expect('org no secrets', ((:'org'::jsonb)::text ~ '(\$2[abxy]\$|phone|H/P|login4|pin)')::text, 'false');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000016', '90000000-0000-0000-0000-000000000016');
set role authenticated;
select test_util.expect('org for admin', public.pilot_org_chart() ->> 'ok', 'true');
reset role;
select test_util.claims('d0000000-0000-0000-0000-0000000000a2', null);
set role authenticated;
select test_util.expect('org for work manager', public.pilot_org_chart() ->> 'ok', 'true');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000025', '90000000-0000-0000-0000-000000000025');
set role authenticated;
select test_util.expect_error('org leader blocked', $$select public.pilot_org_chart()$$, 'FORBIDDEN');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000008', '90000000-0000-0000-0000-000000000008');
set role authenticated;
select test_util.expect('member role', public.pilot_whoami() ->> 'app_role', 'MEMBER');
select test_util.expect_error('org member blocked', $$select public.pilot_org_chart()$$, 'FORBIDDEN');
reset role;

-- 6. 사용자ID 없는 인원도 TBM 정상 (작업 인원 후보·배정은 UUID 기준). 오늘 시험3팀 보고는 앞 시험이 만든 것이라 날짜만 옮김
update field_pilot_v1.daily_reports set work_date = work_date - 3
where team_id = 'b0000000-0000-0000-0000-000000000003' and work_date = field_pilot_v1.kst_today();
select test_util.claims('f0000000-0000-0000-0000-000000000050', '90000000-0000-0000-0000-000000000050');
set role authenticated;
select test_util.expect('candidate without legacy id', (select count(*)::text from jsonb_array_elements(public.tbm_today() -> 'members') m
  where m ->> 'person_id' = :'new_id'), '1');
select test_util.expect('assign by uuid', (public.tbm_save_plan(jsonb_build_object('request_id', 'v11-noid', 'tasks', jsonb_build_array(jsonb_build_object(
  'place', '9동', 'content', '정리', 'members', jsonb_build_array(jsonb_build_object('person_id', :'new_id')))))) -> 'report' -> 'tasks' -> 0 -> 'members' -> 0 ->> 'person_id'), :'new_id');
reset role;
select test_util.expect('assignment stored with uuid', (select count(*)::text from field_pilot_v1.task_assignments where person_id = :'new_id' and legacy_user_id is null), '1');
select 'personnel_auth v0.11 tests passed';
