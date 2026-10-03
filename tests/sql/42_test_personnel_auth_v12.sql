-- personnel_auth v0.12 (기존 인원 최초 로그인 자동 이관) 시험 (로컬 시험 DB 전용, 가짜 데이터)
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse

select test_util.expect('migrate service_role only', (has_function_privilege('service_role', 'public.pilot_member_login4_migrate(text,text,boolean,text,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.pilot_member_login4_migrate(text,text,boolean,text,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.pilot_member_login4_migrate(text,text,boolean,text,text)', 'EXECUTE'))::text, 'true');

-- 준비: 번호가 없는 현재 인원 (재직 active + 현재 소속)
update personnel_pilot_v1.people set employment_status = 'active'
where id in ('c0000000-0000-0000-0000-000000000036', 'c0000000-0000-0000-0000-000000000051');

-- 1. 번호가 없는 현재 인원 → 최초 이관 대상 (실패 기록 없음), 재직 확인 전(unknown)은 대상 아님
set role service_role;
select test_util.expect('first login required', public.pilot_member_login4('시험중복가', '3636', '10.12.0.1') ->> 'code', 'FIRST_LOGIN_REQUIRED');
reset role;
select test_util.expect('no failure logged for first login', (select count(*)::text from personnel_pilot_v1.member_login_attempts
  where name_key = personnel_pilot_v1.name_key('시험중복가') and outcome = 'NO_MATCH'), '0');
update personnel_pilot_v1.people set employment_status = 'unknown' where id = 'c0000000-0000-0000-0000-000000000036';
set role service_role;
select test_util.expect('unknown status not a target', public.pilot_member_login4('시험중복가', '3636', null) ->> 'code', 'INVALID_CREDENTIALS');
reset role;
update personnel_pilot_v1.people set employment_status = 'active' where id = 'c0000000-0000-0000-0000-000000000036';
delete from personnel_pilot_v1.member_login_attempts where name_key = personnel_pilot_v1.name_key('시험중복가');

-- 2. 정식 인원DB 확인 실패 → 번호 저장 없음, 실패 기록
set role service_role;
select test_util.expect('not verified', public.pilot_member_login4_migrate('시험중복가', '3636', false, null, '10.12.0.1') ->> 'code', 'INVALID_CREDENTIALS');
reset role;
select test_util.expect('no credential after failure', (select count(*)::text from personnel_pilot_v1.member_pins
  where person_id = 'c0000000-0000-0000-0000-000000000036' and login4_hash is not null), '0');
select test_util.expect('failure logged', (select count(*)::text from personnel_pilot_v1.member_login_attempts
  where name_key = personnel_pilot_v1.name_key('시험중복가') and outcome = 'NO_MATCH'), '1');

-- 3. 확인 성공 → 해시 저장, 같은 ID 중복 인원(시험중복나, 비활성 아님)과는 사용자ID로 구분하지 않아도 이름이 달라 1명
set role service_role;
select test_util.expect('migrated', public.pilot_member_login4_migrate('시험중복가', '3636', true, 'T-0036', '10.12.0.1') ->> 'person_id', 'c0000000-0000-0000-0000-000000000036');
reset role;
select test_util.expect('hash only', (select (login4_hash like '$2%' and login4_hash <> '3636')::text from personnel_pilot_v1.member_pins
  where person_id = 'c0000000-0000-0000-0000-000000000036'), 'true');
select test_util.expect('migration logged without code', (select count(*)::text from personnel_pilot_v1.member_pin_events
  where person_id = 'c0000000-0000-0000-0000-000000000036' and actor = 'first_login' and reason not like '%3636%'), '1');
-- 4. 두 번째 로그인은 Supabase만 (최초 이관 대상 아님)
set role service_role;
select test_util.expect('second login direct', public.pilot_member_login4('시험중복가', '3636', null) ->> 'person_id', 'c0000000-0000-0000-0000-000000000036');
select test_util.expect('wrong code after migration', public.pilot_member_login4('시험중복가', '0000', null) ->> 'code', 'INVALID_CREDENTIALS');

-- 5. 기존 사용자ID가 다르면 다른 사람으로 보고 막음, 맞으면 이관
select test_util.expect('first login (member)', public.pilot_member_login4('시험삼팀원', '5151', null) ->> 'code', 'FIRST_LOGIN_REQUIRED');
select test_util.expect('legacy id mismatch', public.pilot_member_login4_migrate('시험삼팀원', '5151', true, 'T-9999', null) ->> 'code', 'AMBIGUOUS');
reset role;
select test_util.expect('no credential on mismatch', (select count(*)::text from personnel_pilot_v1.member_pins
  where person_id = 'c0000000-0000-0000-0000-000000000051' and login4_hash is not null), '0');
set role service_role;
select test_util.expect('legacy id match', public.pilot_member_login4_migrate('시험삼팀원', '5151', true, 'T-0051', null) ->> 'ok', 'true');

-- 6. 명단에 없는 사람, 비활성 인원은 이관하지 않음
select test_util.expect('not in supabase roster', public.pilot_member_login4_migrate('명부밖사람', '1234', true, 'T-7777', null) ->> 'code', 'NOT_IN_PILOT');
select test_util.expect('inactive refused', public.pilot_member_login4_migrate('시험퇴사자', '1111', true, 'T-0028', null) ->> 'code', 'ACCOUNT_DISABLED');
reset role;
select test_util.expect('nothing created for outsiders', (select count(*)::text from personnel_pilot_v1.people where display_name = '명부밖사람'), '0');

-- 7. 같은 이름 두 명: 정식 인원DB 사용자ID로만 구분, 구분 못 하면 AMBIGUOUS
insert into personnel_pilot_v1.people (id, legacy_user_id, display_name, team_name, employment_status) values
  ('c0000000-0000-0000-0000-000000000801', 'T-8001', '시험동명이', '공사2팀', 'active'),
  ('c0000000-0000-0000-0000-000000000802', 'T-8002', '시험동명이', '공사2팀', 'active'),
  ('c0000000-0000-0000-0000-000000000803', null, '시험동명삼', '공사2팀', 'active'),
  ('c0000000-0000-0000-0000-000000000804', null, '시험동명삼', '공사2팀', 'active');
select personnel_pilot_v1.assign_current(id, 'b0000000-0000-0000-0000-000000000002', null)
from unnest(array['c0000000-0000-0000-0000-000000000801', 'c0000000-0000-0000-0000-000000000802',
                  'c0000000-0000-0000-0000-000000000803', 'c0000000-0000-0000-0000-000000000804']::uuid[]) id;
set role service_role;
select test_util.expect('same name: pick by user id', public.pilot_member_login4_migrate('시험동명이', '5555', true, 'T-8002', null) ->> 'person_id', 'c0000000-0000-0000-0000-000000000802');
select test_util.expect('same name, other still unregistered: not decided', public.pilot_member_login4('시험동명이', '5555', null) ->> 'code', 'AMBIGUOUS');
select test_util.expect('same name: other first login', public.pilot_member_login4('시험동명이', '6666', null) ->> 'code', 'FIRST_LOGIN_REQUIRED');
select test_util.expect('same code as registered namesake refused', public.pilot_member_login4_migrate('시험동명이', '5555', true, 'T-8001', null) ->> 'code', 'AMBIGUOUS');
select test_util.expect('same name: second person', public.pilot_member_login4_migrate('시험동명이', '6666', true, 'T-8001', null) ->> 'person_id', 'c0000000-0000-0000-0000-000000000801');
select test_util.expect('both registered: code picks person', public.pilot_member_login4('시험동명이', '5555', null) ->> 'person_id', 'c0000000-0000-0000-0000-000000000802');
select test_util.expect('same name without ids: ambiguous', public.pilot_member_login4_migrate('시험동명삼', '7777', true, 'T-9998', null) ->> 'code', 'AMBIGUOUS');
reset role;
select test_util.expect('ambiguous created nothing', (select count(*)::text from personnel_pilot_v1.member_pins
  where person_id in ('c0000000-0000-0000-0000-000000000803', 'c0000000-0000-0000-0000-000000000804') and login4_hash is not null), '0');
-- 시험용 동명이인 정리 (다음 시험의 명단 숫자에 섞이지 않게 비활성)
select personnel_pilot_v1.end_current(id) from unnest(array['c0000000-0000-0000-0000-000000000801', 'c0000000-0000-0000-0000-000000000802',
  'c0000000-0000-0000-0000-000000000803', 'c0000000-0000-0000-0000-000000000804']::uuid[]) id;
update personnel_pilot_v1.people set employment_status = 'inactive' where display_name in ('시험동명이', '시험동명삼');
select 'personnel_auth v0.12 tests passed';
