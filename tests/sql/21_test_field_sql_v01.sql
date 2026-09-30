-- field v0.1 동작 시험 (로컬 시험 DB 전용, 가짜 데이터)
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse

-- 준비: 시험3팀 팀장(T-0050) 개인 세션, T-0025 PIN 변경 완료 상태, T-0027은 두 팀 소속(지원 인력)
insert into auth.users (id, email, email_confirmed_at, raw_app_meta_data) values
  ('f0000000-0000-0000-0000-000000000050', 'member-c0000000-0000-0000-0000-000000000050@example.com', now(), '{"attendance_pilot":"v1","kind":"member_pin","person_id":"c0000000-0000-0000-0000-000000000050"}');
insert into personnel_pilot_v1.account_links values ('f0000000-0000-0000-0000-000000000050', 'c0000000-0000-0000-0000-000000000050', true);
insert into personnel_pilot_v1.member_pins (person_id, pin_hash, pin_kind, must_change)
values ('c0000000-0000-0000-0000-000000000050', extensions.crypt('730519', extensions.gen_salt('bf', 4)), 'PERSONAL', false);
insert into auth.sessions (id, user_id) values ('90000000-0000-0000-0000-000000000050', 'f0000000-0000-0000-0000-000000000050');
update personnel_pilot_v1.member_pins set must_change = false, pin_kind = 'PERSONAL' where person_id = 'c0000000-0000-0000-0000-000000000025';
insert into personnel_pilot_v1.memberships (person_id, site_id, team_id) values
  ('c0000000-0000-0000-0000-000000000027', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003');

-- 1. 권한
select test_util.expect('anon cannot tbm_today', has_function_privilege('anon', 'public.tbm_today(uuid)', 'EXECUTE')::text, 'false');
select test_util.expect('authenticated can tbm_today', has_function_privilege('authenticated', 'public.tbm_today(uuid)', 'EXECUTE')::text, 'true');
select test_util.expect('service_role not granted', has_function_privilege('service_role', 'public.tbm_save_plan(jsonb)', 'EXECUTE')::text, 'false');
select test_util.expect('internal closed', (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'field_pilot_v1' and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))), '0');
select test_util.expect('tables closed', (select count(*)::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'field_pilot_v1' and c.relkind = 'r' and (has_table_privilege('anon', c.oid, 'SELECT') or has_table_privilege('authenticated', c.oid, 'SELECT'))), '0');
set role anon;
select test_util.expect_error('anon call', $$select public.tbm_today()$$, 'permission denied');
reset role;

-- 2. 역할·팀 범위
select test_util.claims('f0000000-0000-0000-0000-000000000026', '90000000-0000-0000-0000-000000000026');
set role authenticated;
select test_util.expect_error('member forbidden', $$select public.tbm_today()$$, 'FORBIDDEN');
reset role;
select test_util.claims('d0000000-0000-0000-0000-0000000000a3', null);
set role authenticated;
select test_util.expect_error('leader1 work account has no team row', $$select public.tbm_today()$$, 'TEAM_NOT_READY');
select test_util.expect_error('leader cannot see overview', $$select public.tbm_site_overview()$$, 'FORBIDDEN');
reset role;

-- 3. 오늘 화면 (PIN 팀장 T-0025, 공사2팀)
select test_util.claims('f0000000-0000-0000-0000-000000000025', '90000000-0000-0000-0000-000000000025');
set role authenticated;
select test_util.expect('today team', public.tbm_today() -> 'team' ->> 'name', '공사2팀');
select test_util.expect('no report yet', coalesce(public.tbm_today() ->> 'report', 'null'), 'null');
select test_util.expect('members from memberships only', (select string_agg(m ->> 'legacy_user_id', ',' order by m ->> 'legacy_user_id')
  from jsonb_array_elements(public.tbm_today() -> 'members') m), 'T-0025,T-0026,T-0027,T-0036');
select test_util.expect('leader flagged', (select m ->> 'is_leader' from jsonb_array_elements(public.tbm_today() -> 'members') m where m ->> 'legacy_user_id' = 'T-0025'), 'true');
select test_util.expect_error('other team member refused', $$select public.tbm_save_plan('{"request_id":"x0","tasks":[{"place":"5동","content":"배관","members":[{"person_id":"c0000000-0000-0000-0000-000000000051"}]}]}')$$, 'MEMBER_NOT_IN_TEAM');
select test_util.expect_error('invalid risk', $$select public.tbm_save_plan('{"request_id":"x1","risks":["태풍"],"tasks":[{"place":"5동","content":"배관","members":[]}]}')$$, 'INVALID_RISK');
select test_util.expect_error('tasks required', $$select public.tbm_save_plan('{"request_id":"x2","tasks":[]}')$$, 'TASKS_REQUIRED');
select test_util.expect_error('duplicate member', $$select public.tbm_save_plan('{"request_id":"x3","tasks":[{"place":"5동","content":"배관","members":[{"person_id":"c0000000-0000-0000-0000-000000000026"},{"person_id":"c0000000-0000-0000-0000-000000000026"}]}]}')$$, 'DUPLICATE_MEMBER');
select public.tbm_save_plan(jsonb_build_object(
  'request_id', 'req-plan-1',
  'risks', jsonb_build_array('고소작업', '전기'),
  'safety_note', '안전대 착용', 'issue_note', '5동 자재 부족 우려', 'needs_manager_check', true, 'end_time', '17:00',
  'tasks', jsonb_build_array(
    jsonb_build_object('place', '5동 3F', 'content', '배관 설치', 'members', jsonb_build_array(
      jsonb_build_object('person_id', 'c0000000-0000-0000-0000-000000000025', 'role', '작업지휘자'),
      jsonb_build_object('person_id', 'c0000000-0000-0000-0000-000000000026', 'role', '작업자'))),
    jsonb_build_object('place', 'EPS실', 'content', '케이블 포설', 'members', jsonb_build_array(
      jsonb_build_object('person_id', 'c0000000-0000-0000-0000-000000000036', 'role', '신호수'))),
    jsonb_build_object('place', '6동 1F', 'content', '기구 취부', 'members', '[]'::jsonb)))) -> 'report' as saved \gset
reset role;
select (:'saved'::jsonb) ->> 'id' as report_id, (:'saved'::jsonb) ->> 'version' as v1,
       (:'saved'::jsonb) -> 'tasks' -> 0 ->> 'id' as task1, (:'saved'::jsonb) -> 'tasks' -> 1 ->> 'id' as task2,
       (:'saved'::jsonb) -> 'tasks' -> 2 ->> 'id' as task3 \gset
select test_util.expect('created planned', (select status from field_pilot_v1.daily_reports where id = :'report_id'), 'PLANNED');
select test_util.expect('reporter person uuid', (select reporter_person_id::text from field_pilot_v1.daily_reports where id = :'report_id'), 'c0000000-0000-0000-0000-000000000025');
select test_util.expect('assignment by uuid with legacy copy', (select string_agg(legacy_user_id || ':' || work_role, ',' order by legacy_user_id) from field_pilot_v1.task_assignments where task_id = :'task1'), 'T-0025:작업지휘자,T-0026:작업자');
select test_util.expect('report-level issue note', (select issue_note from field_pilot_v1.daily_reports where id = :'report_id'), '5동 자재 부족 우려');
select test_util.expect('version after create', :'v1', '2');

select test_util.claims('f0000000-0000-0000-0000-000000000025', '90000000-0000-0000-0000-000000000025');
set role authenticated;
select test_util.expect('same request replayed', public.tbm_save_plan('{"request_id":"req-plan-1","tasks":[{"place":"x","content":"y","members":[]}]}') ->> 'replayed', 'true');
reset role;
select test_util.expect('replay made no tasks', (select count(*)::text from field_pilot_v1.report_tasks where report_id = :'report_id'), '3');
set role authenticated;
select test_util.expect_error('stale version conflict', $$select public.tbm_save_plan('{"request_id":"req-old","version":1,"tasks":[{"place":"x","content":"y","members":[]}]}')$$, 'VERSION_CONFLICT');
select test_util.expect_error('missing version conflict', $$select public.tbm_save_plan('{"request_id":"req-new","tasks":[{"place":"x","content":"y","members":[]}]}')$$, 'VERSION_CONFLICT');
reset role;

-- 4. 다른 팀 차단 (시험3팀 팀장 T-0050, T-0027은 두 팀 소속)
select test_util.claims('f0000000-0000-0000-0000-000000000050', '90000000-0000-0000-0000-000000000050');
set role authenticated;
select test_util.expect('team3 today', public.tbm_today() -> 'team' ->> 'name', '시험3팀');
select test_util.expect('team3 plan saved', public.tbm_save_plan('{"request_id":"t3-1","tasks":[{"place":"7동","content":"지원 작업","members":[{"person_id":"c0000000-0000-0000-0000-000000000027"}]}]}') -> 'report' ->> 'status', 'PLANNED');
select test_util.expect_error('cannot edit other team report', format('select public.tbm_submit_morning(%L)', :'report_id'), 'REPORT_FORBIDDEN');
select test_util.expect_error('cannot read other team detail', format('select public.tbm_report_detail(%L)', :'report_id'), 'REPORT_FORBIDDEN');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000025', '90000000-0000-0000-0000-000000000025');
set role authenticated;
select test_util.expect('lock shows member of other team', (select l ->> 'team_name' from jsonb_array_elements(public.tbm_today() -> 'locks') l where l ->> 'person_id' = 'c0000000-0000-0000-0000-000000000027'), '시험3팀');
select jsonb_build_object('request_id', 'req-lock', 'version', 2, 'tasks', jsonb_build_array(
  jsonb_build_object('id', :'task1', 'place', '5동 3F', 'content', '배관 설치', 'members',
    jsonb_build_array(jsonb_build_object('person_id', 'c0000000-0000-0000-0000-000000000027'))))) as lockpayload \gset
select test_util.expect_error('assigned elsewhere refused', format('select public.tbm_save_plan(%L::jsonb)', :'lockpayload'), 'MEMBER_ASSIGNED_ELSEWHERE');

-- 5. 출근·오후·퇴근
select test_util.expect_error('afternoon before morning', format('select public.tbm_afternoon_all_clear(%L)', :'report_id'), 'MORNING_REQUIRED');
select test_util.expect('morning submitted', public.tbm_submit_morning(:'report_id', '작업 전 체조', 'req-m1') -> 'report' ->> 'status', 'SUBMITTED');
select test_util.expect('morning again ok', public.tbm_submit_morning(:'report_id', null, 'req-m2') ->> 'replayed', 'true');
select test_util.expect_error('delay needs note', format($q$select public.tbm_task_alert(%L, 'DELAYED')$q$, :'task2'), 'NOTE_REQUIRED');
select test_util.expect('delay saved', (public.tbm_task_alert(:'task2', 'DELAYED', '자재 입고 지연', '오후 입고 확인', null, 'req-a1') -> 'report' -> 'tasks' -> 1 ->> 'alert'), 'DELAYED');
select test_util.expect('change saved', (public.tbm_task_alert(:'task3', 'CHANGED', '위치 변경', null,
  jsonb_build_object('place', '6동 2F', 'members', jsonb_build_array(jsonb_build_object('person_id', 'c0000000-0000-0000-0000-000000000026', 'role', '유도원'))), 'req-a2')
  -> 'report' -> 'tasks' -> 2 ->> 'place'), '6동 2F');
select test_util.expect('all clear only untouched', (select string_agg(t ->> 'alert', ',' order by (t ->> 'task_no')::int)
  from jsonb_array_elements(public.tbm_afternoon_all_clear(:'report_id', '이상 없음', 'req-a3') -> 'report' -> 'tasks') t), 'NORMAL,DELAYED,CHANGED');
select test_util.expect_error('invalid alert', format($q$select public.tbm_task_alert(%L, 'FIRE', '불')$q$, :'task1'), 'INVALID_ALERT');
select test_util.expect('task1 done', public.tbm_task_result(:'task1', 'DONE', null, null, null, 'req-e1') -> 'report' -> 'tasks' -> 0 ->> 'result', 'DONE');
select test_util.expect('task2 not done carries', public.tbm_task_result(:'task2', 'NOT_DONE', null, null, '자재 미입고', 'req-e2') -> 'report' -> 'tasks' -> 1 ->> 'carry_status', 'PENDING');
select test_util.expect_error('close with open tasks', format('select public.tbm_evening_close(%L)', :'report_id'), 'UNRESOLVED_TASKS');
select test_util.expect('task3 partial carries note', public.tbm_task_result(:'task3', 'PARTIAL', true, '2F 나머지 취부', null, 'req-e3') -> 'report' -> 'tasks' -> 2 ->> 'carry_note', '2F 나머지 취부');
select test_util.expect('evening closed', ((public.tbm_evening_close(:'report_id', '정리 완료', false, 'req-e4') -> 'report' ->> 'evening_at') is not null)::text, 'true');
select test_util.expect_error('closed task cannot get alert', format($q$select public.tbm_task_alert(%L, 'RISK', '추락 위험')$q$, :'task1'), 'TASK_CLOSED');
reset role;
select test_util.expect('carry note default is content', (select carry_note from field_pilot_v1.report_tasks where id = :'task2'), '케이블 포설');
select test_util.expect('history has before/after for change', (select count(*)::text from field_pilot_v1.workflow_history
  where entity_id = :'task3' and action = 'TASK_CHANGED' and before_data ->> 'place' = '6동 1F' and after_data ->> 'place' = '6동 2F'), '1');
select test_util.expect('history actor is person', (select count(distinct actor_person_id)::text from field_pilot_v1.workflow_history where report_id = :'report_id'), '1');

-- 6. 사진 (자리 받기·한도·중복·확인)
select test_util.claims('f0000000-0000-0000-0000-000000000025', '90000000-0000-0000-0000-000000000025');
set role authenticated;
select public.tbm_photo_prepare(:'report_id', 'MORNING', 120000, repeat('a', 64)) as p1 \gset
select public.tbm_photo_prepare(:'report_id', 'MORNING', 120000, repeat('b', 64)) as p2 \gset
select public.tbm_photo_prepare(:'report_id', 'MORNING', 120000, repeat('c', 64)) as p3 \gset
select test_util.expect_error('fourth photo refused', format($q$select public.tbm_photo_prepare(%L, 'MORNING', 1000, repeat('d', 64))$q$, :'report_id'), 'PHOTO_LIMIT');
select test_util.expect('same photo reuses slot', public.tbm_photo_prepare(:'report_id', 'MORNING', 120000, repeat('a', 64)) ->> 'attachment_id', (:'p1'::jsonb) ->> 'attachment_id');
select test_util.expect('path has no names', (((:'p1'::jsonb) ->> 'path') ~ '^YONGIN_PILOT/[0-9-]+/[0-9a-f-]+/morning/[0-9a-f-]+\.jpg$')::text, 'true');
select test_util.expect_error('too large', format($q$select public.tbm_photo_prepare(%L, 'EVENING', 3000000, repeat('e', 64))$q$, :'report_id'), 'PHOTO_TOO_LARGE');
select test_util.expect_error('confirm without upload', format('select public.tbm_photo_confirm(%L)', (:'p1'::jsonb) ->> 'attachment_id'), 'UPLOAD_NOT_FOUND');
reset role;
insert into storage.buckets (id, name) values ('tbm-photos', 'tbm-photos') on conflict do nothing;
insert into storage.objects (bucket_id, name) values ('tbm-photos', (:'p1'::jsonb) ->> 'path'), ('tbm-photos', (:'p2'::jsonb) ->> 'path');
set role authenticated;
select test_util.expect('confirm ready', (select count(*)::text from jsonb_array_elements(public.tbm_photo_confirm(((:'p1'::jsonb) ->> 'attachment_id')::uuid) -> 'report' -> 'photos')), '1');
select test_util.expect('duplicate after ready', public.tbm_photo_prepare(:'report_id', 'MORNING', 120000, repeat('a', 64)) ->> 'duplicate', 'true');
select test_util.expect('confirm second', (select count(*)::text from jsonb_array_elements(public.tbm_photo_confirm(((:'p2'::jsonb) ->> 'attachment_id')::uuid) -> 'report' -> 'photos')), '2');
select test_util.expect('remove hides', (select count(*)::text from jsonb_array_elements(public.tbm_photo_remove(((:'p2'::jsonb) ->> 'attachment_id')::uuid) -> 'report' -> 'photos')), '1');
reset role;
select test_util.expect('photos stored once per round (not per task)', (select count(*)::text from field_pilot_v1.attachments where report_id = :'report_id' and status = 'READY'), '1');

-- 7. 소장 현황·상세 (읽기 전용)
select test_util.claims('d0000000-0000-0000-0000-0000000000a2', null);
set role authenticated;
select test_util.expect('overview teams (TBM teams only)', (select string_agg(t ->> 'team_name', ',' order by t ->> 'team_name') from jsonb_array_elements(public.tbm_site_overview() -> 'teams') t), '공사2팀,시험3팀');
select test_util.expect('overview status', (select t -> 'report' ->> 'status' from jsonb_array_elements(public.tbm_site_overview() -> 'teams') t where t ->> 'team_name' = '공사2팀'), 'SUBMITTED');
select test_util.expect('overview alerts', (select (t -> 'report' -> 'alerts')::text from jsonb_array_elements(public.tbm_site_overview() -> 'teams') t where t ->> 'team_name' = '공사2팀'), '{"RISK": 0, "CHANGED": 1, "DELAYED": 1}');
select test_util.expect('overview carry', (select t -> 'report' ->> 'carry_count' from jsonb_array_elements(public.tbm_site_overview() -> 'teams') t where t ->> 'team_name' = '공사2팀'), '2');
select test_util.expect('overview photos', (select t -> 'report' -> 'photo_counts' ->> 'MORNING' from jsonb_array_elements(public.tbm_site_overview() -> 'teams') t where t ->> 'team_name' = '공사2팀'), '1');
select test_util.expect('overview manager check', (select t -> 'report' ->> 'needs_manager_check' from jsonb_array_elements(public.tbm_site_overview() -> 'teams') t where t ->> 'team_name' = '공사2팀'), 'true');
select test_util.expect('material placeholder', public.tbm_site_overview() ->> 'material_requests_available', 'false');
select test_util.expect('detail for manager', public.tbm_report_detail(:'report_id') -> 'report' ->> 'team_name', '공사2팀');
select test_util.expect('detail has history', (jsonb_array_length(public.tbm_report_detail(:'report_id') -> 'history') > 5)::text, 'true');
select test_util.expect_error('manager cannot edit', format('select public.tbm_submit_morning(%L)', :'report_id'), 'FORBIDDEN');
reset role;

-- 8. 다음 날 이월 (보고 날짜를 하루 앞으로 옮겨 흉내)
update field_pilot_v1.daily_reports set work_date = work_date - 1 where id = :'report_id';
update field_pilot_v1.daily_reports set work_date = work_date - 1 where team_id = 'b0000000-0000-0000-0000-000000000003';
select test_util.claims('f0000000-0000-0000-0000-000000000025', '90000000-0000-0000-0000-000000000025');
set role authenticated;
select test_util.expect_error('yesterday not editable', format('select public.tbm_submit_morning(%L)', :'report_id'), 'REPORT_NOT_EDITABLE');
select test_util.expect('carry candidates', (select string_agg(c ->> 'place', ',' order by (c ->> 'task_no')::int) from jsonb_array_elements(public.tbm_today() -> 'carry_candidates') c), 'EPS실,6동 2F');
select test_util.expect('carry keeps members', (select c -> 'members' -> 0 ->> 'role' from jsonb_array_elements(public.tbm_today() -> 'carry_candidates') c where c ->> 'place' = 'EPS실'), '신호수');
select public.tbm_save_plan(jsonb_build_object('request_id', 'req-day2', 'drop_carry_ids', jsonb_build_array(:'task3'),
  'tasks', jsonb_build_array(jsonb_build_object('place', 'EPS실', 'content', '케이블 포설 (이월)', 'carried_from_task_id', :'task2',
    'members', jsonb_build_array(jsonb_build_object('person_id', 'c0000000-0000-0000-0000-000000000036', 'role', '신호수')))))) -> 'report' as day2 \gset
select test_util.expect('continued task linked', (:'day2'::jsonb) -> 'tasks' -> 0 ->> 'carried_from_task_id', :'task2');
select jsonb_build_object('request_id', 'req-day2b', 'version', ((:'day2'::jsonb) ->> 'version')::int,
  'tasks', jsonb_build_array(
    jsonb_build_object('id', (:'day2'::jsonb) -> 'tasks' -> 0 ->> 'id', 'place', 'EPS실', 'content', '케이블 포설 (이월)', 'members', '[]'::jsonb),
    jsonb_build_object('place', 'EPS실', 'content', '또 이어받기', 'carried_from_task_id', :'task2', 'members', '[]'::jsonb))) as twice \gset
select test_util.expect_error('cannot continue twice', format('select public.tbm_save_plan(%L::jsonb)', :'twice'), 'CARRY_NOT_AVAILABLE');
select test_util.expect('no more candidates', jsonb_array_length(public.tbm_today() -> 'carry_candidates')::text, '0');
-- 이어받은 작업을 계획에서 빼면 원래 작업이 다시 후보가 된다
select public.tbm_save_plan(jsonb_build_object('request_id', 'req-day2c', 'version', ((:'day2'::jsonb) ->> 'version')::int,
  'tasks', jsonb_build_array(jsonb_build_object('place', '8동', 'content', '새 작업', 'members', '[]'::jsonb)))) -> 'report' ->> 'version' as v3 \gset
select test_util.expect('removed continuation returns candidate', (select string_agg(c ->> 'place', ',') from jsonb_array_elements(public.tbm_today() -> 'carry_candidates') c), 'EPS실');
reset role;
select test_util.expect('dropped carry recorded', (select carry_status from field_pilot_v1.report_tasks where id = :'task3'), 'DROPPED');

-- 9. 소장 확인 후 잠금 (2단계 기능 흉내: 상태를 직접 CONFIRMED로)
update field_pilot_v1.daily_reports set status = 'CONFIRMED' where team_id = 'b0000000-0000-0000-0000-000000000002' and work_date = field_pilot_v1.kst_today();
set role authenticated;
select jsonb_build_object('request_id', 'req-lock2', 'version', :'v3'::int,
  'tasks', jsonb_build_array(jsonb_build_object('place', '8동', 'content', '수정', 'members', '[]'::jsonb))) as lockedpayload \gset
select test_util.expect_error('confirmed report locked', format('select public.tbm_save_plan(%L::jsonb)', :'lockedpayload'), 'REPORT_NOT_EDITABLE');
reset role;

-- 흉내 버킷 정리 (로컬 시험 DB만. 실제 버킷·정책은 field_sql_v02가 만든다)
delete from storage.objects where bucket_id = 'tbm-photos';
delete from storage.buckets where id = 'tbm-photos';

-- 10. 기존 구조 불변
select test_util.expect('pilot functions unchanged',
  (select md5(string_agg(p.proname || md5(p.prosrc), ',' order by p.proname)) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('pilot_roster', 'pilot_set_attendance_grade', 'pilot_update_person', 'pilot_bind_account')),
  (select value from test_util.snapshot where key = 'pilot_functions'));
select test_util.expect('works policies unchanged', (select string_agg(policyname, ',' order by policyname) from pg_policies where tablename = 'works'),
  (select value from test_util.snapshot where key = 'works_policies'));
select 'field v0.1 tests passed';
