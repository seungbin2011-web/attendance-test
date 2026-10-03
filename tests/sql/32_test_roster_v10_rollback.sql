-- 2026-10 명단 시험 3: 되돌리기 후 동기화 전 현재 상태로 (삭제 없이)
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse
select test_util.expect('current state restored', test_util.roster_state_fp(), (select value from test_util.snapshot where key = 'roster_state_before'));
select test_util.expect('new people blocked, rows kept', (select count(*) filter (where employment_status = 'inactive') || '/' || count(*)
  from personnel_pilot_v1.people where source_system = 'roster_sync_2026_10'), '42/42');
select test_util.expect('team names back', (select string_agg(name, ',' order by code) from personnel_pilot_v1.teams where code in ('CONSTRUCTION_1', 'CONSTRUCTION_2')), '공사1팀,공사2팀');
select test_util.expect('rollback logged', (select (count(*) > 0)::text from personnel_pilot_v1.person_edits where actor_login = 'roster_sync_2026_10_rollback'), 'true');
select '2026-10 roster rollback tests passed';
