-- personnel_auth v0.8 동작 시험 (로컬 시험 DB 전용, 가짜 데이터)
-- 실패하면 'TEST FAILED'로 즉시 중단된다.
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse

-- 1. 실행 권한
select test_util.expect('anon cannot verify', has_function_privilege('anon','public.pilot_member_login_verify(text,text,text)','EXECUTE')::text, 'false');
select test_util.expect('authenticated cannot verify', has_function_privilege('authenticated','public.pilot_member_login_verify(text,text,text)','EXECUTE')::text, 'false');
select test_util.expect('service_role can verify', has_function_privilege('service_role','public.pilot_member_login_verify(text,text,text)','EXECUTE')::text, 'true');
select test_util.expect('anon cannot link', has_function_privilege('anon','public.pilot_member_link_account(uuid,uuid)','EXECUTE')::text, 'false');
select test_util.expect('authenticated cannot link', has_function_privilege('authenticated','public.pilot_member_link_account(uuid,uuid)','EXECUTE')::text, 'false');
select test_util.expect('anon cannot whoami', has_function_privilege('anon','public.pilot_whoami()','EXECUTE')::text, 'false');
select test_util.expect('authenticated can whoami', has_function_privilege('authenticated','public.pilot_whoami()','EXECUTE')::text, 'true');
select test_util.expect('anon cannot change pin', has_function_privilege('anon','public.pilot_member_change_pin(text,text)','EXECUTE')::text, 'false');
select test_util.expect('internal current_actor closed', (has_function_privilege('anon','personnel_pilot_v1.current_actor()','EXECUTE') or has_function_privilege('authenticated','personnel_pilot_v1.current_actor()','EXECUTE') or has_function_privilege('service_role','personnel_pilot_v1.current_actor()','EXECUTE'))::text, 'false');
select test_util.expect('admin issue closed to service_role', has_function_privilege('service_role','personnel_pilot_v1.admin_issue_temp_pins(uuid[],text)','EXECUTE')::text, 'false');
select test_util.expect('member_pins closed', (has_table_privilege('anon','personnel_pilot_v1.member_pins','SELECT') or has_table_privilege('authenticated','personnel_pilot_v1.member_pins','SELECT') or has_table_privilege('service_role','personnel_pilot_v1.member_pins','SELECT'))::text, 'false');
set role anon;
select test_util.expect_error('anon call verify', $$select public.pilot_member_login_verify('시험팀원가','123456',null)$$, 'permission denied');
reset role;

-- 2. 임시 PIN 발급 (unknown 허용, inactive 거부, 사유 필수)
select temp_pin as pin26 from personnel_pilot_v1.admin_issue_temp_pins(array['c0000000-0000-0000-0000-000000000026'::uuid], '시험 발급') \gset
select temp_pin as pin25 from personnel_pilot_v1.admin_issue_temp_pins(array['c0000000-0000-0000-0000-000000000025'::uuid], '시험 발급') \gset
select temp_pin as pin03 from personnel_pilot_v1.admin_issue_temp_pins(array['c0000000-0000-0000-0000-000000000003'::uuid], '시험 발급') \gset
select temp_pin as pin40 from personnel_pilot_v1.admin_issue_temp_pins(array['c0000000-0000-0000-0000-000000000040'::uuid], '시험 발급') \gset
select temp_pin as pin41 from personnel_pilot_v1.admin_issue_temp_pins(array['c0000000-0000-0000-0000-000000000041'::uuid], '시험 발급') \gset
select test_util.expect('temp pin is 6 digits', (:'pin26' ~ '^[0-9]{6}$')::text, 'true');
select test_util.expect('same-name pins differ', (:'pin40' <> :'pin41')::text, 'true');
select test_util.expect('no plaintext stored', (select count(*)::text from personnel_pilot_v1.member_pins where pin_hash in (:'pin26', :'pin25')), '0');
select test_util.expect('unknown status kept', (select employment_status from personnel_pilot_v1.people where legacy_user_id = 'T-0026'), 'unknown');
select test_util.expect_error('inactive person refused', $$select * from personnel_pilot_v1.admin_issue_temp_pins(array['c0000000-0000-0000-0000-000000000028'::uuid], '시험')$$, 'INACTIVE_PERSON');
select test_util.expect_error('reason required', $$select * from personnel_pilot_v1.admin_issue_temp_pins(array['c0000000-0000-0000-0000-000000000026'::uuid], '')$$, 'REASON_REQUIRED');

-- 3. 검증 (service_role = Edge Function)
set role service_role;
select test_util.expect('wrong pin', public.pilot_member_login_verify('시험팀원가', '482915', '10.0.0.1') ->> 'code', 'INVALID_CREDENTIALS');
select test_util.expect('4 digits invalid', public.pilot_member_login_verify('시험팀원가', '1234', '10.0.0.1') ->> 'code', 'INVALID_INPUT');
select test_util.expect('unknown name', public.pilot_member_login_verify('없는사람', '482915', '10.0.0.1') ->> 'code', 'INVALID_CREDENTIALS');
select test_util.expect('correct pin with spaces in name', public.pilot_member_login_verify(' 시험 팀원가 ', :'pin26', '10.0.0.1') ->> 'code', 'OK');
select test_util.expect('must change on temp', public.pilot_member_login_verify('시험팀원가', :'pin26', '10.0.0.1') ->> 'must_change_pin', 'true');
select test_util.expect('same-name A', public.pilot_member_login_verify('시험동명', :'pin40', null) ->> 'person_id', 'c0000000-0000-0000-0000-000000000040');
select test_util.expect('same-name B', public.pilot_member_login_verify('시험동명', :'pin41', null) ->> 'person_id', 'c0000000-0000-0000-0000-000000000041');
-- 연속 5회 실패 → 30분 잠금
select public.pilot_member_login_verify('시험팀원가', '482916', '10.0.0.2') ->> 'code' from generate_series(1, 5);
select test_util.expect('locked after 5 fails', public.pilot_member_login_verify('시험팀원가', :'pin26', '10.0.0.2') ->> 'code', 'LOCKED');
reset role;
-- 31분 경과 흉내: 이 이름의 기록 전체를 31분 앞으로 이동
update personnel_pilot_v1.member_login_attempts set attempted_at = attempted_at - interval '31 minutes'
where name_key = personnel_pilot_v1.name_key('시험팀원가');
set role service_role;
select test_util.expect('one more fail after lock expiry relocks', public.pilot_member_login_verify('시험팀원가', '482916', '10.0.0.3') ->> 'code', 'INVALID_CREDENTIALS');
select test_util.expect('relocked', public.pilot_member_login_verify('시험팀원가', :'pin26', '10.0.0.3') ->> 'code', 'LOCKED');
reset role;
select personnel_pilot_v1.admin_unlock_member('c0000000-0000-0000-0000-000000000026', '시험 해제');
set role service_role;
select test_util.expect('after admin unlock', public.pilot_member_login_verify('시험팀원가', :'pin26', '10.0.0.3') ->> 'code', 'OK');
-- IP별 한도 (15분 20회)
select count(*) from (select public.pilot_member_login_verify('없는' || g, '482915', '10.8.8.8') from generate_series(1, 20) g) x;
select test_util.expect('ip limited', public.pilot_member_login_verify('시험팀원가', :'pin26', '10.8.8.8') ->> 'code', 'RATE_LIMITED');
select test_util.expect('other ip fine', public.pilot_member_login_verify('시험팀원가', :'pin26', '10.8.8.9') ->> 'code', 'OK');
reset role;
-- 전체 한도 (1시간 100회)
insert into personnel_pilot_v1.member_login_attempts(name_key, outcome) select 'spray' || g, 'NO_MATCH' from generate_series(1, 100) g;
set role service_role;
select test_util.expect('global limited', public.pilot_member_login_verify('시험팀원가', :'pin26', '10.1.1.1') ->> 'code', 'RATE_LIMITED');
reset role;
delete from personnel_pilot_v1.member_login_attempts where name_key like 'spray%';

-- 4. 개인 계정 연결 (Edge Function 흉내)
insert into auth.users (id, email, email_confirmed_at, raw_app_meta_data) values
  ('f0000000-0000-0000-0000-000000000026', 'member-c0000000-0000-0000-0000-000000000026@example.com', now(), '{"attendance_pilot":"v1","kind":"member_pin","person_id":"c0000000-0000-0000-0000-000000000026"}'),
  ('f0000000-0000-0000-0000-000000000025', 'member-c0000000-0000-0000-0000-000000000025@example.com', now(), '{"attendance_pilot":"v1","kind":"member_pin","person_id":"c0000000-0000-0000-0000-000000000025"}'),
  ('f0000000-0000-0000-0000-000000000003', 'member-c0000000-0000-0000-0000-000000000003@example.com', now(), '{"attendance_pilot":"v1","kind":"member_pin","person_id":"c0000000-0000-0000-0000-000000000003"}'),
  ('f0000000-0000-0000-0000-0000000000ff', 'member-c0000000-0000-0000-0000-000000000026@evil.test', now(), '{"attendance_pilot":"v1","kind":"member_pin","person_id":"c0000000-0000-0000-0000-000000000026"}'),
  ('f0000000-0000-0000-0000-0000000000fe', 'signup-self@example.com', now(), '{}');
set role authenticated;
select test_util.expect_error('authenticated cannot link', $$select public.pilot_member_link_account('c0000000-0000-0000-0000-000000000026','f0000000-0000-0000-0000-000000000026')$$, 'permission denied');
reset role;
set role service_role;
select test_util.expect('link ok', public.pilot_member_link_account('c0000000-0000-0000-0000-000000000026', 'f0000000-0000-0000-0000-000000000026') ->> 'auth_user_id', 'f0000000-0000-0000-0000-000000000026');
select test_util.expect('link idempotent', public.pilot_member_link_account('c0000000-0000-0000-0000-000000000026', 'f0000000-0000-0000-0000-000000000026') ->> 'auth_user_id', 'f0000000-0000-0000-0000-000000000026');
select test_util.expect_error('wrong email refused', $$select public.pilot_member_link_account('c0000000-0000-0000-0000-000000000026','f0000000-0000-0000-0000-0000000000ff')$$, 'ACCOUNT_IDENTITY_MISMATCH');
select test_util.expect_error('work account refused', $$select public.pilot_member_link_account('c0000000-0000-0000-0000-000000000026','d0000000-0000-0000-0000-0000000000a1')$$, 'ACCOUNT_IDENTITY_MISMATCH');
select test_util.expect('link leader', public.pilot_member_link_account('c0000000-0000-0000-0000-000000000025', 'f0000000-0000-0000-0000-000000000025') ->> 'person_id', 'c0000000-0000-0000-0000-000000000025');
select test_util.expect('link site manager person', public.pilot_member_link_account('c0000000-0000-0000-0000-000000000003', 'f0000000-0000-0000-0000-000000000003') ->> 'person_id', 'c0000000-0000-0000-0000-000000000003');
select test_util.expect('verify returns link', public.pilot_member_login_verify('시험팀원가', :'pin26', null) ->> 'auth_user_id', 'f0000000-0000-0000-0000-000000000026');
reset role;

-- 5. whoami / PIN 변경 (개인 세션)
insert into auth.sessions (id, user_id, created_at) values
  ('90000000-0000-0000-0000-000000000026', 'f0000000-0000-0000-0000-000000000026', now()),
  ('90000000-0000-0000-0000-000000000025', 'f0000000-0000-0000-0000-000000000025', now()),
  ('90000000-0000-0000-0000-000000000003', 'f0000000-0000-0000-0000-000000000003', now()),
  ('90000000-0000-0000-0000-0000000000aa', 'f0000000-0000-0000-0000-000000000026', now() - interval '17 hours');
select test_util.claims('f0000000-0000-0000-0000-000000000026', '90000000-0000-0000-0000-000000000026');
set role authenticated;
select test_util.expect('member kind', public.pilot_whoami() ->> 'kind', 'MEMBER_PIN');
select test_util.expect('member role', public.pilot_whoami() ->> 'app_role', 'MEMBER');
select test_util.expect('member legacy id', public.pilot_whoami() ->> 'user_id', 'T-0026');
select test_util.expect('member must change', public.pilot_whoami() ->> 'must_change_pin', 'true');
reset role;
select test_util.expect_error('business blocked before change', $$select personnel_pilot_v1.require_actor(null)$$, 'PIN_CHANGE_REQUIRED');
set role authenticated;
select test_util.expect('change wrong current', public.pilot_member_change_pin('000001', '482915') ->> 'code', 'INVALID_CREDENTIALS');
select test_util.expect('change weak 123456', public.pilot_member_change_pin(:'pin26', '123456') ->> 'code', 'PIN_NOT_ALLOWED');
select test_util.expect('change weak 121212', public.pilot_member_change_pin(:'pin26', '121212') ->> 'code', 'PIN_NOT_ALLOWED');
select test_util.expect('change ok', public.pilot_member_change_pin(:'pin26', '482915') ->> 'code', 'OK');
select test_util.expect('must change cleared', public.pilot_whoami() ->> 'must_change_pin', 'false');
reset role;
select test_util.expect('change fail persisted', (select count(*)::text from personnel_pilot_v1.member_pin_events where event = 'CHANGE_FAIL'), '1');
select test_util.expect('require_actor after change', personnel_pilot_v1.require_actor(array['MEMBER']) ->> 'kind', 'MEMBER_PIN');
select test_util.expect_error('require_actor forbidden', $$select personnel_pilot_v1.require_actor(array['SITE_MANAGER'])$$, 'FORBIDDEN');
set role service_role;
select test_util.expect('old temp pin rejected', public.pilot_member_login_verify('시험팀원가', :'pin26', null) ->> 'code', 'INVALID_CREDENTIALS');
select test_util.expect('personal pin ok', public.pilot_member_login_verify('시험팀원가', '482915', null) ->> 'code', 'OK');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000026', '90000000-0000-0000-0000-0000000000aa');
set role authenticated;
select test_util.expect_error('session older than 16h', $$select public.pilot_whoami()$$, 'SESSION_EXPIRED');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000026', null);
set role authenticated;
select test_util.expect_error('no session id', $$select public.pilot_whoami()$$, 'SESSION_EXPIRED');
reset role;

-- 6. 역할 계산
select test_util.claims('f0000000-0000-0000-0000-000000000025', '90000000-0000-0000-0000-000000000025');
set role authenticated;
select test_util.expect('pin leader role', public.pilot_whoami() ->> 'app_role', 'LEADER');
select test_util.expect('pin leader roles', public.pilot_whoami() ->> 'roles', '["MEMBER", "TEAM_LEADER"]');
select test_util.expect('pin leader team', public.pilot_whoami() -> 'team_scopes' -> 0 ->> 'team_name', '공사2팀');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000003', '90000000-0000-0000-0000-000000000003');
set role authenticated;
select test_util.expect('site manager via pin gets member only', public.pilot_whoami() ->> 'roles', '["MEMBER"]');
reset role;
select test_util.claims('d0000000-0000-0000-0000-0000000000a1', null);
set role authenticated;
select test_util.expect('work admin', public.pilot_whoami() ->> 'roles', '["ADMIN"]');
select test_util.expect('work admin source', public.pilot_whoami() ->> 'auth_source', 'supabase-v2');
select test_util.expect('existing pilot_roster works', public.pilot_roster() ->> 'app_role', 'ADMIN');
reset role;
select test_util.claims('d0000000-0000-0000-0000-0000000000a4', null);
set role authenticated;
select test_util.expect('work leader2 team id', public.pilot_whoami() -> 'team_scopes' -> 0 ->> 'team_id', 'b0000000-0000-0000-0000-000000000002');
reset role;
select test_util.claims('d0000000-0000-0000-0000-0000000000a3', null);
set role authenticated;
select test_util.expect('work leader1 has no team row yet', coalesce(public.pilot_whoami() -> 'team_scopes' -> 0 ->> 'team_id', 'null'), 'null');
reset role;
select test_util.claims('f0000000-0000-0000-0000-0000000000fe', null);
set role authenticated;
select test_util.expect_error('self signup user has nothing', $$select public.pilot_whoami()$$, 'ACCOUNT_NOT_LINKED');
reset role;

-- 7. 사용 중지·퇴사
select personnel_pilot_v1.admin_set_member_login('c0000000-0000-0000-0000-000000000026', false, '시험 중지');
select test_util.claims('f0000000-0000-0000-0000-000000000026', '90000000-0000-0000-0000-000000000026');
set role authenticated;
select test_util.expect_error('disabled session blocked', $$select public.pilot_whoami()$$, 'ACCOUNT_NOT_LINKED');
reset role;
set role service_role;
select test_util.expect('disabled login', public.pilot_member_login_verify('시험팀원가', '482915', null) ->> 'code', 'ACCOUNT_DISABLED');
reset role;
select personnel_pilot_v1.admin_set_member_login('c0000000-0000-0000-0000-000000000026', true, '시험 재개');
update personnel_pilot_v1.people set employment_status = 'inactive' where id = 'c0000000-0000-0000-0000-000000000026';
set role service_role;
select test_util.expect('inactive login', public.pilot_member_login_verify('시험팀원가', '482915', null) ->> 'code', 'INVALID_CREDENTIALS');
reset role;
set role authenticated;
select test_util.expect_error('inactive session blocked', $$select public.pilot_whoami()$$, 'ACCOUNT_INACTIVE');
reset role;
update personnel_pilot_v1.people set employment_status = 'unknown' where id = 'c0000000-0000-0000-0000-000000000026';
select test_util.expect('inactive logged', (select count(*)::text from personnel_pilot_v1.member_login_attempts where outcome = 'INACTIVE'), '1');

-- 8. 기존 함수·명부 불변
select test_util.expect('pilot functions unchanged',
  (select md5(string_agg(p.proname || md5(p.prosrc), ',' order by p.proname)) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('pilot_roster', 'pilot_set_attendance_grade', 'pilot_update_person', 'pilot_bind_account')),
  (select value from test_util.snapshot where key = 'pilot_functions'));
select test_util.expect('people count unchanged', (select count(*)::text from personnel_pilot_v1.people), (select value from test_util.snapshot where key = 'people_count'));
select 'personnel_auth v0.8 tests passed';
