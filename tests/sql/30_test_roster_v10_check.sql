-- 2026-10 명단 시험 1: 읽기 전용 미리보기 결과와, 잘못된 명단은 아무것도 바꾸지 않음 (가짜 명단)
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse
select check_roster::jsonb as c from test_util.roster_check \gset
select test_util.expect('ready', (:'c'::jsonb) ->> 'ready', 'true');
select test_util.expect('input total', (:'c'::jsonb) -> 'input' ->> 'total', '53');
select test_util.expect('input ok', (:'c'::jsonb) -> 'input' ->> 'problems', '[]');
select test_util.expect('matched existing', (:'c'::jsonb) -> 'resolve' ->> 'matched', '11');
select test_util.expect('new with id', jsonb_array_length((:'c'::jsonb) -> 'resolve' -> 'new_with_id')::text, '29');
select test_util.expect('new without id (internal uuid)', jsonb_array_length((:'c'::jsonb) -> 'resolve' -> 'new_without_id')::text, '13');
select test_util.expect('no conflicts', (:'c'::jsonb) -> 'resolve' ->> 'conflicts', '[]');
select test_util.expect('team plan', (select string_agg(x ->> 'name' || '=' || (x ->> 'action'), ',' order by x ->> 'name')
  from jsonb_array_elements((:'c'::jsonb) -> 'teams_plan') x), '1팀=이름 변경 공사1팀 → 1팀,2팀=이름 변경 공사2팀 → 2팀,3팀=추가,자재팀=그대로,현장·관리=추가');
select test_util.expect('deactivate list', (select count(*)::text from jsonb_array_elements_text((:'c'::jsonb) -> 'changes' -> 'deactivate') d
  where d like '시험중복나 T-0036%'), '1');
select test_util.expect('already inactive not listed', (select count(*)::text from jsonb_array_elements_text((:'c'::jsonb) -> 'changes' -> 'deactivate') d
  where d like '시험퇴사자%'), '0');
select test_util.expect('role change preview', (select count(*)::text from jsonb_array_elements_text((:'c'::jsonb) -> 'changes' -> 'role_changes') d
  where d = '시험자재: ADMIN_DEPT → TEAM_LEADER'), '1');
select test_util.expect('before keeps current state', (select x ->> 'team_now' from jsonb_array_elements((:'c'::jsonb) -> 'before') x
  where x ->> 'name' = '시험중복나'), '');
select test_util.expect('check has no phone', ((:'c'::jsonb)::text like '%phone%')::text, 'false');
-- 사용자ID가 없는 새 인원도 준비 완료 (임의 ID를 만들지 않고 내부 UUID로)
select check_roster::jsonb as c2 from test_util.roster_check_missing \gset
select test_util.expect('missing id still ready', (:'c2'::jsonb) ->> 'ready', 'true');
select test_util.expect('missing id listed as new', (select count(*)::text from jsonb_array_elements_text((:'c2'::jsonb) -> 'resolve' -> 'new_without_id') x
  where x = '시험삼반장 → 3팀'), '1');
-- 실패한 동기화(ID 이름 불일치·숫자 불일치)는 아무것도 바꾸지 않음
select test_util.expect('failed syncs changed nothing', test_util.roster_fp(), (select value from test_util.snapshot where key = 'roster_fp_before'));
select '2026-10 roster check tests passed';
