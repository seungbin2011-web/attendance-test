-- 소속·역할 변경 템플릿 시험 2: 팀장 교체, 현장 이탈, 소장 교체 (같은 명단 두 번 실행 = 변화 없음)
--   ('T-0008','시험일팀장','CONSTRUCTION_1','공사1팀','MEMBER')        -- 팀장 → 팀원
--   ('T-0026','시험팀원가','CONSTRUCTION_1','공사1팀','TEAM_LEADER')   -- 팀원 → 팀장
--   ('T-0027','시험팀원나',null,null,'LEAVE')                          -- 두 팀 소속 → 현장 이탈
--   ('T-0003','시험소장',null,null,'MEMBER')                           -- 소장 → 소장 아님
--   ('T-0016','시험자재',null,null,'SITE_MANAGER')                     -- 자재팀 → 새 소장
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse

-- 1. 팀장 교체: 같은 소속을 유지하고 역할만 종료·추가 (삭제 없음, 두 번 실행해도 한 번만)
select test_util.expect('old leader keeps one membership', (select count(*)::text from personnel_pilot_v1.memberships
  where person_id = 'c0000000-0000-0000-0000-000000000008'), '1');
select test_util.expect('old leader role revoked not deleted', (select count(*) filter (where r.revoked_at is not null) || '/' || count(*)
  from personnel_pilot_v1.role_assignments r join personnel_pilot_v1.memberships m on m.id = r.membership_id
  where m.person_id = 'c0000000-0000-0000-0000-000000000008'), '1/1');
select test_util.expect('new leader one active role', (select count(*)::text from personnel_pilot_v1.role_assignments r
  join personnel_pilot_v1.memberships m on m.id = r.membership_id and m.valid_to is null
  where m.person_id = 'c0000000-0000-0000-0000-000000000026' and r.role_code = 'TEAM_LEADER' and r.revoked_at is null), '1');
select test_util.expect('new leader memberships not churned', (select count(*)::text from personnel_pilot_v1.memberships
  where person_id = 'c0000000-0000-0000-0000-000000000026'), '2');
select test_util.claims('f0000000-0000-0000-0000-000000000008', '90000000-0000-0000-0000-000000000008');
set role authenticated;
select test_util.expect('old leader now member', public.pilot_whoami() ->> 'app_role', 'MEMBER');
select test_util.expect_error('old leader cannot report', $$select public.tbm_today()$$, 'FORBIDDEN');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000026', '90000000-0000-0000-0000-000000000026');
set role authenticated;
select test_util.expect('new leader', public.pilot_whoami() ->> 'app_role', 'LEADER');
select test_util.expect('new leader team', public.tbm_today() -> 'team' ->> 'name', '공사1팀');
reset role;

-- 2. 현장 이탈: 모든 현재 소속 종료 → 어느 팀 인원 후보에도 없음, 기록은 남음
select test_util.expect('left: no current membership', (select count(*)::text from personnel_pilot_v1.memberships
  where person_id = 'c0000000-0000-0000-0000-000000000027' and valid_to is null), '0');
select test_util.expect('left: rows kept', (select (count(*) >= 2)::text from personnel_pilot_v1.memberships
  where person_id = 'c0000000-0000-0000-0000-000000000027'), 'true');
select test_util.claims('f0000000-0000-0000-0000-000000000025', '90000000-0000-0000-0000-000000000025');
set role authenticated;
select test_util.expect('left: not a candidate', (select count(*)::text
  from jsonb_array_elements(public.tbm_today() -> 'members') m where m ->> 'legacy_user_id' = 'T-0027'), '0');
reset role;

-- 3. 소장 교체: 이전 소장은 소장 화면이 닫히고, 새 소장은 현장 소속 + SITE_MANAGER (자재 소속·역할은 종료)
select test_util.claims('f0000000-0000-0000-0000-000000000003', '90000000-0000-0000-0000-000000000003');
set role authenticated;
select test_util.expect('old manager now member', public.pilot_whoami() ->> 'app_role', 'MEMBER');
select test_util.expect_error('old manager no overview', $$select public.tbm_site_overview()$$, 'FORBIDDEN');
reset role;
select test_util.expect('new manager site membership', (select count(*)::text from personnel_pilot_v1.memberships m
  join personnel_pilot_v1.role_assignments r on r.membership_id = m.id and r.role_code = 'SITE_MANAGER' and r.revoked_at is null
  where m.person_id = 'c0000000-0000-0000-0000-000000000016' and m.valid_to is null and m.team_id is null), '1');
select test_util.expect('new manager old team role ended', (select count(*)::text from personnel_pilot_v1.role_assignments r
  join personnel_pilot_v1.memberships m on m.id = r.membership_id
  where m.person_id = 'c0000000-0000-0000-0000-000000000016' and r.role_code = 'MATERIAL_STAFF' and r.revoked_at is not null and m.valid_to is not null), '1');
select test_util.expect('new manager memberships not churned', (select count(*)::text from personnel_pilot_v1.memberships
  where person_id = 'c0000000-0000-0000-0000-000000000016'), '2');
select 'role change template test 2 passed';
