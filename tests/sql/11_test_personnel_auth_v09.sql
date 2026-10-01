-- personnel_auth v0.9 (휴대폰 뒤 4자리 로그인 연결) 시험 (로컬 시험 DB 전용, 가짜 데이터)
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse

-- 1. 실행 권한: Edge Function(service_role)만
select test_util.expect('anon cannot roster login', has_function_privilege('anon', 'public.pilot_member_roster_login(text,text,boolean,text)', 'EXECUTE')::text, 'false');
select test_util.expect('authenticated cannot roster login', has_function_privilege('authenticated', 'public.pilot_member_roster_login(text,text,boolean,text)', 'EXECUTE')::text, 'false');
select test_util.expect('service_role can roster login', has_function_privilege('service_role', 'public.pilot_member_roster_login(text,text,boolean,text)', 'EXECUTE')::text, 'true');
set role anon;
select test_util.expect_error('anon call', $$select public.pilot_member_roster_login('시험팀원나', 'T-0027', true, null)$$, 'permission denied');
reset role;

set role service_role;
-- 2. 입력 오류·확인 실패
select test_util.expect('empty name', public.pilot_member_roster_login(' ', 'T-0027', true, null) ->> 'code', 'INVALID_INPUT');
select test_util.expect('verified without id', public.pilot_member_roster_login('시험팀원나', null, true, null) ->> 'code', 'INVALID_INPUT');
select test_util.expect('not verified', public.pilot_member_roster_login('시험팀원나', null, false, '10.9.0.1') ->> 'code', 'INVALID_CREDENTIALS');

-- 3. 정상: PIN이 없던 인원은 로그인 허용 표시 행이 생기고, 바로 사용할 수 있다 (PIN 변경 없음)
select public.pilot_member_roster_login('시험팀원나', 'T-0027', true, '10.9.0.1') as ok27 \gset
select test_util.expect('ok', (:'ok27'::jsonb) ->> 'ok', 'true');
select test_util.expect('person', (:'ok27'::jsonb) ->> 'person_id', 'c0000000-0000-0000-0000-000000000027');
select test_util.expect('no pin change', (:'ok27'::jsonb) ->> 'must_change_pin', 'false');
select test_util.expect('not linked yet', coalesce((:'ok27'::jsonb) ->> 'auth_user_id', 'null'), 'null');
select test_util.expect('second login same result', public.pilot_member_roster_login('시험팀원나', 'T-0027', true, null) ->> 'person_id', 'c0000000-0000-0000-0000-000000000027');
reset role;
select test_util.expect('allow row created once', (select count(*)::text from personnel_pilot_v1.member_pins where person_id = 'c0000000-0000-0000-0000-000000000027'
  and pin_kind = 'PERSONAL' and not must_change and enabled and pin_hash like '$2_$%'), '1');
select test_util.expect('allow row is not a usable pin', (select count(*)::text from personnel_pilot_v1.member_pins
  where person_id = 'c0000000-0000-0000-0000-000000000027' and pin_hash = extensions.crypt('000000', pin_hash)), '0');
set role service_role;

-- 4. 기존 ID 중복은 이름으로 구분, 구분이 안 되면 AMBIGUOUS
select test_util.expect('dup id resolved by name', public.pilot_member_roster_login('시험중복나', 'T-0036', true, null) ->> 'person_id', 'c0000000-0000-0000-0000-000000000136');
select test_util.expect('dup id other name ambiguous', public.pilot_member_roster_login('엉뚱한이름', 'T-0036', true, null) ->> 'code', 'AMBIGUOUS');

-- 5. 새 시스템 명부에 없는 인원, 퇴사(inactive) 인원
select test_util.expect('not in pilot', public.pilot_member_roster_login('명부밖인원', 'T-9999', true, null) ->> 'code', 'NOT_IN_PILOT');
select test_util.expect('inactive blocked', public.pilot_member_roster_login('시험퇴사자', 'T-0028', true, null) ->> 'code', 'ACCOUNT_DISABLED');
reset role;
select test_util.expect('inactive gets no allow row', (select count(*)::text from personnel_pilot_v1.member_pins where person_id = 'c0000000-0000-0000-0000-000000000028'), '0');

-- 6. 관리자 사용 중지는 휴대폰 로그인에도 적용
select personnel_pilot_v1.admin_set_member_login('c0000000-0000-0000-0000-000000000027', false, '시험 중지');
set role service_role;
select test_util.expect('disabled', public.pilot_member_roster_login('시험팀원나', 'T-0027', true, null) ->> 'code', 'ACCOUNT_DISABLED');
reset role;
select personnel_pilot_v1.admin_set_member_login('c0000000-0000-0000-0000-000000000027', true, '시험 재개');

-- 7. 같은 이름 연속 5회 실패 → 30분 잠금 (맞는 번호여도 잠금), 성공하면 실패 횟수 초기화
set role service_role;
select test_util.expect('reset by ok', public.pilot_member_roster_login('시험팀원나', 'T-0027', true, null) ->> 'ok', 'true');
select count(*) from (select public.pilot_member_roster_login('시험팀원나', null, false, '10.9.0.2') from generate_series(1, 5)) f;
select test_util.expect('locked after 5', public.pilot_member_roster_login('시험팀원나', 'T-0027', true, '10.9.0.2') ->> 'code', 'LOCKED');
reset role;
update personnel_pilot_v1.member_login_attempts set attempted_at = attempted_at - interval '31 minutes'
where name_key = personnel_pilot_v1.name_key('시험팀원나');
set role service_role;
select test_util.expect('unlocked after 30 min', public.pilot_member_roster_login('시험팀원나', 'T-0027', true, null) ->> 'ok', 'true');
reset role;

-- 8. 기존 PIN 로그인 함수와 기존 pilot 함수는 그대로
select test_util.expect('v08 verify unchanged', (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('pilot_member_login_verify', 'pilot_member_link_account', 'pilot_whoami', 'pilot_member_change_pin')), '4');
select test_util.expect('pilot functions unchanged',
  (select md5(string_agg(p.proname || md5(p.prosrc), ',' order by p.proname)) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('pilot_roster', 'pilot_set_attendance_grade', 'pilot_update_person', 'pilot_bind_account')),
  (select value from test_util.snapshot where key = 'pilot_functions'));
select 'personnel_auth v0.9 tests passed';
