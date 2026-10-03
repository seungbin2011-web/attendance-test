-- 소속·역할 변경 템플릿 시험 3: 되돌리기 + 잘못된 명단은 전체 취소 (러너가 실패 실행을 먼저 확인함)
--   ('T-0003','시험소장',null,null,'SITE_MANAGER'), ('T-0016','시험자재','MATERIAL','자재팀','MEMBER')
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse

select test_util.claims('f0000000-0000-0000-0000-000000000003', '90000000-0000-0000-0000-000000000003');
set role authenticated;
select test_util.expect('manager again', public.pilot_whoami() ->> 'app_role', 'MANAGER');
select test_util.expect('manager overview again', public.tbm_site_overview() ->> 'ok', 'true');
reset role;
select test_util.expect('material back to team', (select string_agg(t.name, ',') from personnel_pilot_v1.memberships m
  join personnel_pilot_v1.teams t on t.id = m.team_id
  where m.person_id = 'c0000000-0000-0000-0000-000000000016' and m.valid_to is null), '자재팀');
select test_util.expect('material no manager role', (select count(*)::text from personnel_pilot_v1.role_assignments r
  join personnel_pilot_v1.memberships m on m.id = r.membership_id and m.valid_to is null
  where m.person_id = 'c0000000-0000-0000-0000-000000000016' and r.role_code = 'SITE_MANAGER' and r.revoked_at is null), '0');
-- 실패한 명단의 앞줄(T-0040)도 반영되지 않음
select test_util.expect('failed batch rolled back', (select count(*)::text from personnel_pilot_v1.memberships
  where person_id = 'c0000000-0000-0000-0000-000000000040'), '0');
select test_util.expect('no stray team', (select count(*)::text from personnel_pilot_v1.teams where name = '다른이름' or code = 'NEW_FAIL'), '0');
select 'role change template test 3 passed';
