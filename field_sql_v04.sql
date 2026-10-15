-- field v0.4: TBM / 출역 관리 개선 v0.1 (작업정지 · 타 팀원 투입 · 팀장 출역 관리)
-- CHECK(field_sql_v04_check.sql) → 이 파일 → VERIFY(field_sql_v04_verify.sql). 되돌리기: field_sql_v04_rollback.sql
-- 선행: field_sql_v03.sql (같은 날 순차 작업) 적용
-- 지키는 것
--   * 기존 보고·작업·배정·사진·이력 행은 바꾸지 않는다. 바뀌면 전체 취소 (아래 $verify$).
--   * 인원·소속·역할·로그인 표는 건드리지 않는다. 타 팀원 투입은 작업 배정일 뿐 공식 소속을 바꾸지 않는다.
--   * 새 표(출역)는 직접 접근을 막고(RLS + 권한 없음) RPC로만 읽고 쓴다.
-- 바뀌는 것
--   1) 작업정지: report_tasks.alert / result에 'STOPPED' 추가. 오후 TBM에서 사유와 처리(내일 이월 / 오늘 정지로 종료)를 함께 저장.
--      이월은 기존 carry_over · carry_status(PENDING) 구조를 그대로 쓴다. 퇴근 TBM에서 다시 결과를 입력하지 않는다.
--   2) 작업 인원: 같은 현장의 현재 인원이면 다른 팀 소속도 작업에 넣을 수 있다. 배정 당시 공식 소속 팀(home_team_id)을 남긴다.
--   3) 출역 관리: attendance_records(하루·사람 1행) + attendance_history(모든 입력·수정). 팀장은 자기 팀, 현장관리·관리자는 조회, 관리자는 정정.
begin;
set local lock_timeout = '5s';
lock table field_pilot_v1.daily_reports, field_pilot_v1.report_tasks,
  field_pilot_v1.task_assignments, field_pilot_v1.attachments, field_pilot_v1.workflow_history
  in share row exclusive mode;

create temp table field_v04_before (table_name text primary key, rows jsonb) on commit drop;
do $snapshot$
declare t text;
begin
  foreach t in array array['daily_reports','report_tasks','task_assignments','attachments','workflow_history'] loop
    execute format('insert into field_v04_before select %L, coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text), ''[]''::jsonb) from field_pilot_v1.%I x', t, t);
  end loop;
end $snapshot$;

do $pre$
declare e record;
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'field_pilot_v1' and table_name = 'daily_reports' and column_name = 'session_no') then
    raise exception 'PRECHECK: field_sql_v03.sql을 먼저 적용해야 함';
  end if;
  if to_regclass('field_pilot_v1.attendance_records') is not null or to_regprocedure('public.tbm_task_stop(uuid,text,text,text,text)') is not null then
    raise exception 'PRECHECK: v04 already applied';
  end if;
  -- 바꾸는 함수가 저장소 v01/v03 사본과 같은지 (SQL Editor 붙여넣기의 CR 줄바꿈은 무시)
  for e in select * from (values
    ('field_pilot_v1.check_members', 'a5ef2c740dda8257b1f6e5430408e951'),
    ('field_pilot_v1.report_json', '3d28bb61a481ec9ec7e53e4179e17345'),
    ('field_pilot_v1.replace_assignments', 'c74f67c1ece84a11e19652cf747d123c'),
    ('public.tbm_site_overview', 'fc9bb669bfd952fd85df09dc054f83d5'),
    ('public.tbm_my_today', '377b06000f65ff5cd49a0e9be01eab8e'),
    ('public.tbm_task_result', 'b6b7a28ab2ef8f33da672199de6dc074')) v(name, hash) loop
    if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname || '.' || p.proname = e.name and md5(replace(p.prosrc, chr(13), '')) = e.hash) then
      raise exception 'PRECHECK: function changed %', e.name;
    end if;
  end loop;
end $pre$;

-- 1) 작업정지 상태 ------------------------------------------------------------
do $constraints$
declare c record;
begin
  -- 이름은 자동 생성(report_tasks_alert_check 등)이므로 정의로 찾아 바꾼다
  for c in select conname, pg_get_constraintdef(oid) as def from pg_constraint
           where conrelid = 'field_pilot_v1.report_tasks'::regclass and contype = 'c' loop
    if c.def like '%alert = ANY%' or c.def like '%result = ANY%' then
      execute format('alter table field_pilot_v1.report_tasks drop constraint %I', c.conname);
    end if;
  end loop;
end $constraints$;
alter table field_pilot_v1.report_tasks
  add constraint report_tasks_alert_check check (alert in ('NONE', 'NORMAL', 'CHANGED', 'DELAYED', 'RISK', 'STOPPED')),
  add constraint report_tasks_result_check check (result in ('DONE', 'PARTIAL', 'NOT_DONE', 'EXCLUDED', 'STOPPED')),
  add constraint report_tasks_carry_result_check check (not carry_over or result in ('PARTIAL', 'NOT_DONE', 'STOPPED')),
  -- 작업정지는 오후 상태와 최종 결과가 항상 함께 (정지 사유는 alert_note)
  add constraint report_tasks_stopped_check check ((alert = 'STOPPED') = (coalesce(result, '') = 'STOPPED'));

-- 2) 배정 당시 공식 소속 팀 (기존 행은 null: 화면은 현재 소속으로 표시) -------------
alter table field_pilot_v1.task_assignments add column home_team_id uuid references personnel_pilot_v1.teams(id);

-- 3) 출역 ---------------------------------------------------------------------
create table field_pilot_v1.attendance_records (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references personnel_pilot_v1.sites(id),
  work_date date not null,
  person_id uuid not null references personnel_pilot_v1.people(id),
  team_id uuid references personnel_pilot_v1.teams(id),          -- 처음 기록할 때의 공식 소속 팀
  check_in_status text check (check_in_status in ('PRESENT', 'LATE', 'ABSENT', 'OFF')),
  check_in_at timestamptz,
  check_in_by_person_id uuid,
  check_in_by_auth_user_id uuid,
  check_in_by_label text,
  check_in_by_role text,
  check_out_status text check (check_out_status in ('LEFT', 'EARLY', 'NOT_LEFT')),
  check_out_at timestamptz,
  check_out_by_person_id uuid,
  check_out_by_auth_user_id uuid,
  check_out_by_label text,
  check_out_by_role text,
  version integer not null default 1,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (site_id, work_date, person_id),
  check ((check_in_status is null) = (check_in_at is null)),
  check ((check_out_status is null) = (check_out_at is null)),
  check (check_out_status is null or check_in_status in ('PRESENT', 'LATE'))
);
create index attendance_records_team_date on field_pilot_v1.attendance_records (site_id, work_date, team_id);

create table field_pilot_v1.attendance_history (
  id bigint generated always as identity primary key,
  attendance_id uuid not null references field_pilot_v1.attendance_records(id),
  action text not null check (action in ('CHECK_IN', 'CHECK_IN_CORRECT', 'CHECK_OUT', 'CHECK_OUT_CORRECT')),
  before_data jsonb,
  after_data jsonb,
  actor_person_id uuid,
  actor_auth_user_id uuid not null,
  actor_label text not null,
  actor_role text not null,
  request_id text,
  created_at timestamptz not null default clock_timestamp()
);
create index attendance_history_record on field_pilot_v1.attendance_history (attendance_id, created_at);
create index attendance_history_request on field_pilot_v1.attendance_history (request_id) where request_id is not null;

alter table field_pilot_v1.attendance_records enable row level security;
alter table field_pilot_v1.attendance_history enable row level security;
revoke all on field_pilot_v1.attendance_records, field_pilot_v1.attendance_history from public, anon, authenticated, service_role;
revoke all on all sequences in schema field_pilot_v1 from public, anon, authenticated, service_role;

-- 4) 함수 ---------------------------------------------------------------------

-- 작업 인원: 같은 현장의 현재 인원(퇴사 아님)이면 다른 팀 소속이어도 넣을 수 있다. 같은 날 다른 팀 진행 중 작업과 중복은 막는다.
create or replace function field_pilot_v1.check_members(p_team_id uuid, p_work_date date, p_report_id uuid, p_members jsonb)
returns void
language plpgsql stable security definer set search_path = ''
as $fn$
declare
  m jsonb;
  v_person uuid;
  v_name text;
  v_other text;
  v_site uuid := (select site_id from personnel_pilot_v1.teams where id = p_team_id);
begin
  if jsonb_typeof(coalesce(p_members, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_members, '[]'::jsonb)) > 30 then
    raise exception 'INVALID_MEMBERS' using errcode = '22023';
  end if;
  if (select count(*) <> count(distinct e ->> 'person_id') from jsonb_array_elements(coalesce(p_members, '[]'::jsonb)) e) then
    raise exception 'DUPLICATE_MEMBER' using errcode = '22023';
  end if;
  for m in select * from jsonb_array_elements(coalesce(p_members, '[]'::jsonb)) loop
    v_person := (m ->> 'person_id')::uuid;
    if coalesce(m ->> 'role', '작업자') not in ('작업자', '작업지휘자', '신호수', '화기감시자', '유도원', '기타') then
      raise exception 'INVALID_ROLE' using errcode = '22023';
    end if;
    select p.display_name into v_name
    from personnel_pilot_v1.people p
    where p.id = v_person and p.employment_status <> 'inactive'
      and exists (select 1 from personnel_pilot_v1.memberships ms
                  where ms.person_id = p.id and ms.site_id = v_site and ms.valid_to is null);
    if v_name is null then
      raise exception 'MEMBER_NOT_AVAILABLE: %', coalesce((select display_name from personnel_pilot_v1.people where id = v_person), m ->> 'person_id')
        using errcode = '22023';
    end if;
    select t.name into v_other
    from field_pilot_v1.task_assignments a
    join field_pilot_v1.report_tasks k on k.id = a.task_id and k.is_active
    join field_pilot_v1.daily_reports r on r.id = k.report_id
    join personnel_pilot_v1.teams t on t.id = r.team_id
    where a.person_id = v_person and r.work_date = p_work_date and r.id is distinct from p_report_id and r.evening_at is null
    limit 1;
    if v_other is not null then
      raise exception 'MEMBER_ASSIGNED_ELSEWHERE: % (%)', v_name, v_other using errcode = '22023';
    end if;
  end loop;
end $fn$;

-- 배정 저장: 배정 당시 공식 소속 팀을 함께 남긴다 (공식 소속은 바꾸지 않음)
create or replace function field_pilot_v1.replace_assignments(p_task_id uuid, p_members jsonb) returns void
language sql security definer set search_path = ''
as $fn$
  delete from field_pilot_v1.task_assignments where task_id = p_task_id;
  insert into field_pilot_v1.task_assignments (task_id, person_id, work_role, legacy_user_id, home_team_id)
  select p_task_id, (e ->> 'person_id')::uuid, coalesce(e ->> 'role', '작업자'), p.legacy_user_id,
    (select ms.team_id from personnel_pilot_v1.memberships ms
     join field_pilot_v1.report_tasks k on k.id = p_task_id
     join field_pilot_v1.daily_reports r on r.id = k.report_id
     where ms.person_id = p.id and ms.site_id = r.site_id and ms.valid_to is null and ms.team_id is not null
     order by ms.valid_from desc limit 1)
  from jsonb_array_elements(coalesce(p_members, '[]'::jsonb)) e
  join personnel_pilot_v1.people p on p.id = (e ->> 'person_id')::uuid;
$fn$;

-- 보고 전체: 인원의 공식 소속 팀(배정 당시, 없으면 현재)과 타 팀원 여부, 작업정지 시각을 더한다
create or replace function field_pilot_v1.report_json(p_report_id uuid) returns jsonb
language sql stable security definer set search_path = ''
as $fn$
  select jsonb_build_object(
    'id', r.id, 'session_no', r.session_no, 'created_at', r.created_at, 'work_date', r.work_date, 'status', r.status, 'version', r.version,
    'team_id', r.team_id, 'team_name', t.name, 'site_code', s.code,
    'reporter_label', r.reporter_label, 'reporter_person_id', r.reporter_person_id,
    'risks', to_jsonb(r.risks), 'risk_other', r.risk_other, 'safety_note', r.safety_note,
    'issue_note', r.issue_note, 'needs_manager_check', r.needs_manager_check,
    'end_time', to_char(r.end_time, 'HH24:MI'),
    'morning_at', r.morning_at, 'morning_note', r.morning_note,
    'afternoon_at', r.afternoon_at, 'afternoon_note', r.afternoon_note,
    'evening_at', r.evening_at, 'evening_note', r.evening_note,
    'updated_at', r.updated_at,
    'tasks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', k.id, 'task_no', k.task_no, 'place', k.place, 'content', k.content,
        'alert', k.alert, 'alert_note', k.alert_note, 'alert_action', k.alert_action, 'alert_at', k.alert_at,
        'result', k.result, 'result_note', k.result_note, 'result_at', k.result_at,
        'carry_over', k.carry_over, 'carry_note', k.carry_note, 'carry_status', k.carry_status,
        'carried_from_task_id', k.carried_from_task_id,
        'members', coalesce((
          select jsonb_agg(jsonb_build_object('person_id', a.person_id, 'name', p.display_name,
                   'legacy_user_id', a.legacy_user_id, 'role', a.work_role,
                   'home_team_id', ht.id, 'home_team_name', ht.name,
                   'other_team', ht.id is not null and ht.id <> r.team_id) order by p.display_name)
          from field_pilot_v1.task_assignments a join personnel_pilot_v1.people p on p.id = a.person_id
          left join lateral (
            select tt.id, tt.name from personnel_pilot_v1.teams tt
            where tt.id = coalesce(a.home_team_id, (
              select ms.team_id from personnel_pilot_v1.memberships ms
              where ms.person_id = a.person_id and ms.site_id = r.site_id and ms.valid_to is null and ms.team_id is not null
              order by ms.valid_from desc limit 1))) ht on true
          where a.task_id = k.id), '[]'::jsonb)
      ) order by k.task_no)
      from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active), '[]'::jsonb),
    'photos', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'kind', x.kind, 'bucket', x.bucket, 'path', x.object_path,
               'created_at', x.created_at) order by x.created_at)
      from field_pilot_v1.attachments x where x.report_id = r.id and x.status = 'READY'), '[]'::jsonb)
  )
  from field_pilot_v1.daily_reports r
  join personnel_pilot_v1.teams t on t.id = r.team_id
  join personnel_pilot_v1.sites s on s.id = r.site_id
  where r.id = p_report_id
$fn$;

-- 오후 TBM 작업정지: 사유(필수)와 처리(CARRY 내일 이월 / END 오늘 정지로 종료). 퇴근 TBM 결과까지 한 번에 확정한다.
-- 같은 작업에 다시 보내면 사유·처리만 고친다(퇴근 마감 전). 정지 시각(alert_at)은 처음 시각을 유지한다.
create or replace function public.tbm_task_stop(
  p_task_id uuid, p_reason text, p_disposition text, p_action text default null, p_request_id text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER']);
  k field_pilot_v1.report_tasks;
  r field_pilot_v1.daily_reports;
  v_carry boolean;
  v_before jsonb;
begin
  select * into k from field_pilot_v1.report_tasks where id = p_task_id and is_active;
  if not found then raise exception 'TASK_NOT_FOUND' using errcode = 'P0002'; end if;
  r := field_pilot_v1.lock_editable_report(a, k.report_id);
  if r.morning_at is null then raise exception 'MORNING_REQUIRED' using errcode = '22023'; end if;
  if coalesce(length(trim(p_reason)), 0) < 2 then raise exception 'NOTE_REQUIRED' using errcode = '22023'; end if;
  if p_disposition is null or p_disposition not in ('CARRY', 'END') then raise exception 'INVALID_DISPOSITION' using errcode = '22023'; end if;
  select * into k from field_pilot_v1.report_tasks where id = k.id for update;
  if k.result is not null and k.alert <> 'STOPPED' then raise exception 'TASK_CLOSED' using errcode = '22023'; end if;
  if k.carry_status = 'CONTINUED' then raise exception 'CARRY_ALREADY_TAKEN' using errcode = '22023'; end if;
  v_carry := p_disposition = 'CARRY';
  if k.alert = 'STOPPED' and k.alert_note = trim(p_reason) and k.carry_over = v_carry
     and coalesce(k.alert_action, '') = coalesce(nullif(trim(p_action), ''), '') then
    return jsonb_build_object('ok', true, 'replayed', true, 'report', field_pilot_v1.report_json(r.id));
  end if;
  select to_jsonb(x) - 'created_at' - 'updated_at' into v_before from field_pilot_v1.report_tasks x where id = k.id;
  update field_pilot_v1.report_tasks set
    alert = 'STOPPED', alert_note = trim(p_reason), alert_action = nullif(trim(p_action), ''),
    alert_at = coalesce(case when k.alert = 'STOPPED' then k.alert_at end, clock_timestamp()),
    result = 'STOPPED', result_note = null,
    result_at = coalesce(case when k.alert = 'STOPPED' then k.result_at end, clock_timestamp()),
    carry_over = v_carry,
    carry_note = case when v_carry then content end,
    carry_status = case when v_carry then 'PENDING' end,
    updated_at = clock_timestamp()
  where id = k.id;
  update field_pilot_v1.daily_reports set afternoon_at = coalesce(afternoon_at, clock_timestamp()),
    version = version + 1, last_request_id = left(p_request_id, 80), updated_at = clock_timestamp()
  where id = r.id;
  perform field_pilot_v1.log_history(r.id, 'TASK', k.id, 'TASK_STOPPED', v_before,
    (select to_jsonb(x) - 'created_at' - 'updated_at' from field_pilot_v1.report_tasks x where id = k.id),
    trim(p_reason) || case when v_carry then ' · 내일 이월' else ' · 정지로 종료' end, a);
  return jsonb_build_object('ok', true, 'report', field_pilot_v1.report_json(r.id));
end $fn$;

-- 퇴근 TBM 결과: 작업정지된 작업은 다시 결과를 입력하지 않는다 (정지 처리만 tbm_task_stop으로 고친다)
create or replace function public.tbm_task_result(
  p_task_id uuid, p_result text, p_carry boolean default null, p_carry_note text default null,
  p_note text default null, p_request_id text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER']);
  k field_pilot_v1.report_tasks;
  r field_pilot_v1.daily_reports;
  v_carry boolean;
begin
  select * into k from field_pilot_v1.report_tasks where id = p_task_id and is_active;
  if not found then raise exception 'TASK_NOT_FOUND' using errcode = 'P0002'; end if;
  r := field_pilot_v1.lock_editable_report(a, k.report_id);
  if r.morning_at is null then raise exception 'MORNING_REQUIRED' using errcode = '22023'; end if;
  if p_result not in ('DONE', 'PARTIAL', 'NOT_DONE', 'EXCLUDED') then raise exception 'INVALID_RESULT' using errcode = '22023'; end if;
  if k.alert = 'STOPPED' then raise exception 'TASK_STOPPED' using errcode = '22023'; end if;
  v_carry := p_result in ('PARTIAL', 'NOT_DONE') and coalesce(p_carry, true);
  update field_pilot_v1.report_tasks set
    result = p_result, result_note = nullif(trim(p_note), ''), result_at = clock_timestamp(),
    carry_over = v_carry,
    carry_note = case when v_carry then coalesce(nullif(trim(p_carry_note), ''), content) end,
    carry_status = case when v_carry then 'PENDING' end,
    updated_at = clock_timestamp()
  where id = k.id;
  update field_pilot_v1.daily_reports set version = version + 1, last_request_id = left(p_request_id, 80), updated_at = clock_timestamp()
  where id = r.id;
  perform field_pilot_v1.log_history(r.id, 'TASK', k.id, 'TASK_RESULT',
    jsonb_build_object('result', k.result, 'carry_over', k.carry_over),
    jsonb_build_object('result', p_result, 'carry_over', v_carry), nullif(trim(p_note), ''), a);
  return jsonb_build_object('ok', true, 'report', field_pilot_v1.report_json(r.id));
end $fn$;

-- 소장 현황: 작업정지 수와 작업별 정지 사유를 더한다
create or replace function public.tbm_site_overview(p_date date default null) returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['SITE_MANAGER', 'ADMIN']);
  v_date date := coalesce(p_date, field_pilot_v1.kst_today());
  v_teams jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
    'team_id', t.id, 'team_name', t.name, 'site_code', s.code,
    'report', case when r.id is null then null else jsonb_build_object(
      'id', r.id, 'session_no', r.session_no, 'status', r.status, 'reporter_label', r.reporter_label,
      'morning_at', r.morning_at, 'afternoon_at', r.afternoon_at, 'evening_at', r.evening_at,
      'needs_manager_check', r.needs_manager_check, 'issue_note', r.issue_note,
      'risks', to_jsonb(r.risks), 'updated_at', r.updated_at,
      'task_count', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active),
      'tasks', (select coalesce(jsonb_agg(jsonb_build_object('task_no', k.task_no, 'place', k.place, 'content', k.content,
                   'alert', k.alert, 'result', k.result, 'carry_over', k.carry_over,
                   'alert_note', case when k.alert = 'STOPPED' then k.alert_note end,
                   'alert_at', case when k.alert = 'STOPPED' then k.alert_at end) order by k.task_no), '[]'::jsonb)
                from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active),
      'alerts', jsonb_build_object(
        'RISK', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.alert = 'RISK'),
        'CHANGED', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.alert = 'CHANGED'),
        'DELAYED', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.alert = 'DELAYED'),
        'STOPPED', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.alert = 'STOPPED')),
      'results', jsonb_build_object(
        'DONE', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.result = 'DONE'),
        'PARTIAL', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.result = 'PARTIAL'),
        'NOT_DONE', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.result = 'NOT_DONE'),
        'STOPPED', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.result = 'STOPPED'),
        'OPEN', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.result is null)),
      'carry_count', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.carry_over),
      'photo_counts', jsonb_build_object(
        'MORNING', (select count(*) from field_pilot_v1.attachments x where x.report_id = r.id and x.status = 'READY' and x.kind = 'MORNING'),
        'AFTERNOON', (select count(*) from field_pilot_v1.attachments x where x.report_id = r.id and x.status = 'READY' and x.kind = 'AFTERNOON'),
        'EVENING', (select count(*) from field_pilot_v1.attachments x where x.report_id = r.id and x.status = 'READY' and x.kind = 'EVENING'))
    ) end
  ) order by s.code, t.name, r.session_no desc), '[]'::jsonb)
  into v_teams
  from personnel_pilot_v1.teams t
  join personnel_pilot_v1.sites s on s.id = t.site_id and s.is_active
  left join field_pilot_v1.daily_reports r on r.team_id = t.id and r.site_id = t.site_id and r.work_date = v_date
  where s.code in (select jsonb_array_elements_text(coalesce(a -> 'site_codes', '[]'::jsonb)))
    and (r.id is not null
         or exists (select 1 from personnel_pilot_v1.memberships m
                    join personnel_pilot_v1.role_assignments ra on ra.membership_id = m.id and ra.role_code = 'TEAM_LEADER' and ra.revoked_at is null
                    where m.team_id = t.id and m.valid_to is null)
         or exists (select 1 from personnel_pilot_v1.login_profiles lp where lp.app_role = 'LEADER' and lp.enabled and lp.team_scope = t.name));

  return jsonb_build_object('ok', true, 'date', v_date, 'today', field_pilot_v1.kst_today(),
    'viewer', jsonb_build_object('name', a ->> 'name', 'role_label', a ->> 'role_label'),
    'material_requests_available', false,
    'teams', v_teams);
end $fn$;

-- 팀원 오늘 작업: 작업정지 표시를 더한다
create or replace function public.tbm_my_today() returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare a jsonb := personnel_pilot_v1.require_actor(array['MEMBER','TEAM_LEADER','SITE_MANAGER','ADMIN']);
  person uuid := nullif(a->>'person_id','')::uuid;
begin
  if person is null then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  return jsonb_build_object('ok',true,'tasks',coalesce((
    select jsonb_agg(jsonb_build_object(
      'report_id',r.id,'sessionNo',r.session_no,'taskNo',k.task_no,'place',k.place,'content',k.content,
      'role',asg.work_role,'leader',r.reporter_label,'site',s.name,'endTime',to_char(r.end_time,'HH24:MI'),
      'completed',r.evening_at is not null,'closedAt',r.evening_at,'changed',k.alert='CHANGED','stopped',k.alert='STOPPED',
      'afternoonStatus',case k.alert when 'NORMAL' then '정상' when 'CHANGED' then '변경' when 'DELAYED' then '지연' when 'RISK' then '위험' when 'STOPPED' then '작업정지' else null end,
      'eveningStatus',case k.result when 'DONE' then '완료' when 'PARTIAL' then '일부완료' when 'NOT_DONE' then '미완료' when 'EXCLUDED' then '제외'
        when 'STOPPED' then case when k.carry_over then '작업정지 · 내일 이월' else '작업정지 종료' end else null end,
      'risks',array_to_string(r.risks,', '),'safety',r.safety_note)
      order by (r.evening_at is not null),r.session_no desc,k.task_no)
    from field_pilot_v1.task_assignments asg
    join field_pilot_v1.report_tasks k on k.id=asg.task_id and k.is_active
    join field_pilot_v1.daily_reports r on r.id=k.report_id and r.work_date=field_pilot_v1.kst_today()
    join personnel_pilot_v1.sites s on s.id=r.site_id and s.is_active
    where asg.person_id=person and exists(select 1 from personnel_pilot_v1.memberships m
      where m.person_id=person and m.team_id=r.team_id and m.site_id=r.site_id and m.valid_to is null)
  ),'[]'::jsonb));
end $fn$;

-- 작업계획 인원 검색: 같은 현장의 현재 인원 전체(이름·공식 소속 팀만). 퇴사·비활성은 나오지 않는다.
create or replace function public.tbm_site_people(p_team_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER']);
  sc record;
begin
  select * into sc from field_pilot_v1.leader_scope(a, p_team_id);
  return jsonb_build_object('ok', true, 'team_id', sc.team_id, 'people', coalesce((
    select jsonb_agg(jsonb_build_object('person_id', p.id, 'name', p.display_name,
             'team_id', t.id, 'team_name', coalesce(t.name, '팀 없음'),
             'is_leader', exists (select 1 from personnel_pilot_v1.role_assignments ra
                                  where ra.membership_id = ms.id and ra.role_code = 'TEAM_LEADER' and ra.revoked_at is null))
           order by (t.id is distinct from sc.team_id), t.name, p.display_name)
    from personnel_pilot_v1.memberships ms
    join personnel_pilot_v1.people p on p.id = ms.person_id and p.employment_status <> 'inactive'
    left join personnel_pilot_v1.teams t on t.id = ms.team_id
    where ms.site_id = sc.site_id and ms.valid_to is null), '[]'::jsonb));
end $fn$;

-- 출역: 한 팀의 날짜별 인원·기록 (공식 소속 기준)
create or replace function field_pilot_v1.attendance_team_json(p_site_id uuid, p_team_id uuid, p_date date) returns jsonb
language sql stable security definer set search_path = ''
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
      'person_id', p.id, 'name', p.display_name, 'team_name', t.name,
      'is_leader', exists (select 1 from personnel_pilot_v1.role_assignments ra
                           where ra.membership_id = ms.id and ra.role_code = 'TEAM_LEADER' and ra.revoked_at is null),
      'check_in_status', ar.check_in_status, 'check_in_at', ar.check_in_at, 'check_in_by', ar.check_in_by_label, 'check_in_role', ar.check_in_by_role,
      'check_out_status', ar.check_out_status, 'check_out_at', ar.check_out_at, 'check_out_by', ar.check_out_by_label, 'check_out_role', ar.check_out_by_role,
      'updated_at', ar.updated_at,
      'corrections', (select count(*) from field_pilot_v1.attendance_history h where h.attendance_id = ar.id and h.action like '%_CORRECT'))
    order by p.display_name), '[]'::jsonb)
  from personnel_pilot_v1.memberships ms
  join personnel_pilot_v1.people p on p.id = ms.person_id and p.employment_status <> 'inactive'
  join personnel_pilot_v1.teams t on t.id = ms.team_id
  left join field_pilot_v1.attendance_records ar on ar.site_id = p_site_id and ar.work_date = p_date and ar.person_id = p.id
  where ms.site_id = p_site_id and ms.team_id = p_team_id and ms.valid_to is null
$fn$;

-- 팀장 출역 화면: 오늘 우리 팀 (들어오기만 해서는 아무 기록도 만들지 않는다)
create or replace function public.tbm_attendance_today(p_team_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER']);
  sc record;
  v_today date := field_pilot_v1.kst_today();
begin
  select * into sc from field_pilot_v1.leader_scope(a, p_team_id);
  return jsonb_build_object('ok', true, 'date', v_today,
    'team', jsonb_build_object('id', sc.team_id, 'name', sc.team_name),
    'actor', jsonb_build_object('name', a ->> 'name', 'role_label', a ->> 'role_label'),
    'people', field_pilot_v1.attendance_team_json(sc.site_id, sc.team_id, v_today));
end $fn$;

-- 출역 저장: kind IN(출근: PRESENT·LATE·ABSENT·OFF) / OUT(퇴근: LEFT·EARLY·NOT_LEFT)
--   팀장: 자기 팀, 오늘만. 관리자(ADMIN): 정정 — 현장 안 모든 팀, 오늘부터 7일 전까지.
--   같은 값은 그대로 두고, 바뀐 값만 수정 이력(_CORRECT)을 남긴다. 출근을 결근·휴무로 고치면 퇴근 기록은 지운다(이력에 남음).
create or replace function public.tbm_attendance_save(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER', 'ADMIN']);
  v_kind text := p_payload ->> 'kind';
  v_request text := nullif(left(p_payload ->> 'request_id', 80), '');
  v_today date := field_pilot_v1.kst_today();
  v_date date;
  v_team uuid := nullif(p_payload ->> 'team_id', '')::uuid;
  v_site uuid;
  v_team_name text;
  v_role text;
  sc record;
  e jsonb;
  v_person uuid;
  v_status text;
  v_name text;
  rec field_pilot_v1.attendance_records;
  v_before jsonb;
  v_changed int := 0;
begin
  if v_kind is null or v_kind not in ('IN', 'OUT') then raise exception 'INVALID_INPUT' using errcode = '22023'; end if;
  if jsonb_typeof(p_payload -> 'entries') <> 'array' or jsonb_array_length(p_payload -> 'entries') not between 1 and 80 then
    raise exception 'INVALID_INPUT' using errcode = '22023';
  end if;
  if (select count(*) <> count(distinct x ->> 'person_id') from jsonb_array_elements(p_payload -> 'entries') x) then
    raise exception 'DUPLICATE_MEMBER' using errcode = '22023';
  end if;

  if (a -> 'roles') ? 'TEAM_LEADER' and (v_team is null or v_team in (
        select (x ->> 'team_id')::uuid from jsonb_array_elements(coalesce(a -> 'team_scopes', '[]'::jsonb)) x where x ->> 'team_id' is not null)) then
    select * into sc from field_pilot_v1.leader_scope(a, v_team);
    v_team := sc.team_id; v_site := sc.site_id; v_team_name := sc.team_name; v_role := 'TEAM_LEADER';
    v_date := v_today;
    if nullif(p_payload ->> 'work_date', '') is not null and (p_payload ->> 'work_date')::date <> v_today then
      raise exception 'ATTENDANCE_DATE_LOCKED' using errcode = '42501';
    end if;
  elsif (a -> 'roles') ? 'ADMIN' and v_team is not null then
    select t.site_id, t.name into v_site, v_team_name
    from personnel_pilot_v1.teams t join personnel_pilot_v1.sites s on s.id = t.site_id and s.is_active
    where t.id = v_team and s.code in (select jsonb_array_elements_text(coalesce(a -> 'site_codes', '[]'::jsonb)));
    if v_site is null then raise exception 'TEAM_FORBIDDEN' using errcode = '42501'; end if;
    v_role := 'ADMIN';
    v_date := coalesce(nullif(p_payload ->> 'work_date', '')::date, v_today);
    if v_date > v_today or v_date < v_today - 7 then raise exception 'ATTENDANCE_DATE_LOCKED' using errcode = '42501'; end if;
  else
    raise exception 'TEAM_FORBIDDEN' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('attendance:' || v_team::text || ':' || v_date::text, 0));
  if v_request is not null and exists (select 1 from field_pilot_v1.attendance_history h
                                       where h.request_id = v_request and h.actor_auth_user_id = (a ->> 'auth_user_id')::uuid) then
    return jsonb_build_object('ok', true, 'replayed', true, 'date', v_date, 'changed', 0,
      'team', jsonb_build_object('id', v_team, 'name', v_team_name),
      'people', field_pilot_v1.attendance_team_json(v_site, v_team, v_date));
  end if;

  for e in select * from jsonb_array_elements(p_payload -> 'entries') loop
    v_person := nullif(e ->> 'person_id', '')::uuid;
    v_status := e ->> 'status';
    if v_kind = 'IN' and (v_status is null or v_status not in ('PRESENT', 'LATE', 'ABSENT', 'OFF')) then raise exception 'INVALID_STATUS' using errcode = '22023'; end if;
    if v_kind = 'OUT' and (v_status is null or v_status not in ('LEFT', 'EARLY', 'NOT_LEFT')) then raise exception 'INVALID_STATUS' using errcode = '22023'; end if;
    -- 공식 소속이 이 팀인 현재 인원만 (타 팀 작업 투입 인원은 원래 팀에서 출역 처리)
    select p.display_name into v_name from personnel_pilot_v1.people p
    where p.id = v_person and p.employment_status <> 'inactive'
      and exists (select 1 from personnel_pilot_v1.memberships ms where ms.person_id = p.id and ms.site_id = v_site and ms.team_id = v_team and ms.valid_to is null);
    if v_name is null then
      raise exception 'MEMBER_NOT_IN_TEAM: %', coalesce((select display_name from personnel_pilot_v1.people where id = v_person), e ->> 'person_id') using errcode = '22023';
    end if;

    select * into rec from field_pilot_v1.attendance_records where site_id = v_site and work_date = v_date and person_id = v_person for update;
    if not found then
      if v_kind = 'OUT' then raise exception 'ATTENDANCE_NOT_CHECKED_IN: %', v_name using errcode = '22023'; end if;
      insert into field_pilot_v1.attendance_records (site_id, work_date, person_id, team_id)
      values (v_site, v_date, v_person, v_team) returning * into rec;
    end if;
    v_before := to_jsonb(rec) - 'created_at' - 'updated_at' - 'version';

    if v_kind = 'IN' then
      continue when rec.check_in_status = v_status;
      update field_pilot_v1.attendance_records set
        check_in_status = v_status,
        check_in_at = coalesce(check_in_at, clock_timestamp()),
        check_in_by_person_id = nullif(a ->> 'person_id', '')::uuid, check_in_by_auth_user_id = (a ->> 'auth_user_id')::uuid,
        check_in_by_label = a ->> 'name', check_in_by_role = v_role,
        -- 결근·휴무로 바꾸면 퇴근 기록은 의미가 없으므로 지운다 (이력 before_data에 남음)
        check_out_status = case when v_status in ('ABSENT', 'OFF') then null else check_out_status end,
        check_out_at = case when v_status in ('ABSENT', 'OFF') then null else check_out_at end,
        check_out_by_person_id = case when v_status in ('ABSENT', 'OFF') then null else check_out_by_person_id end,
        check_out_by_auth_user_id = case when v_status in ('ABSENT', 'OFF') then null else check_out_by_auth_user_id end,
        check_out_by_label = case when v_status in ('ABSENT', 'OFF') then null else check_out_by_label end,
        check_out_by_role = case when v_status in ('ABSENT', 'OFF') then null else check_out_by_role end,
        version = version + 1, updated_at = clock_timestamp()
      where id = rec.id returning * into rec;
      insert into field_pilot_v1.attendance_history (attendance_id, action, before_data, after_data, actor_person_id, actor_auth_user_id, actor_label, actor_role, request_id)
      values (rec.id, case when v_before ->> 'check_in_status' is null then 'CHECK_IN' else 'CHECK_IN_CORRECT' end,
              v_before, to_jsonb(rec) - 'created_at' - 'updated_at' - 'version',
              nullif(a ->> 'person_id', '')::uuid, (a ->> 'auth_user_id')::uuid, coalesce(a ->> 'name', '-'), v_role, v_request);
    else
      if rec.check_in_status is null or rec.check_in_status not in ('PRESENT', 'LATE') then
        raise exception 'ATTENDANCE_NOT_CHECKED_IN: %', v_name using errcode = '22023';
      end if;
      continue when rec.check_out_status = v_status;
      update field_pilot_v1.attendance_records set
        check_out_status = v_status,
        check_out_at = coalesce(check_out_at, clock_timestamp()),
        check_out_by_person_id = nullif(a ->> 'person_id', '')::uuid, check_out_by_auth_user_id = (a ->> 'auth_user_id')::uuid,
        check_out_by_label = a ->> 'name', check_out_by_role = v_role,
        version = version + 1, updated_at = clock_timestamp()
      where id = rec.id returning * into rec;
      insert into field_pilot_v1.attendance_history (attendance_id, action, before_data, after_data, actor_person_id, actor_auth_user_id, actor_label, actor_role, request_id)
      values (rec.id, case when v_before ->> 'check_out_status' is null then 'CHECK_OUT' else 'CHECK_OUT_CORRECT' end,
              v_before, to_jsonb(rec) - 'created_at' - 'updated_at' - 'version',
              nullif(a ->> 'person_id', '')::uuid, (a ->> 'auth_user_id')::uuid, coalesce(a ->> 'name', '-'), v_role, v_request);
    end if;
    v_changed := v_changed + 1;
  end loop;

  return jsonb_build_object('ok', true, 'date', v_date, 'changed', v_changed,
    'team', jsonb_build_object('id', v_team, 'name', v_team_name),
    'people', field_pilot_v1.attendance_team_json(v_site, v_team, v_date));
end $fn$;

-- 현장관리·관리자 출역 현황 (조회만). 날짜는 오늘부터 31일 전까지.
create or replace function public.tbm_attendance_overview(p_date date default null) returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['SITE_MANAGER', 'ADMIN']);
  v_today date := field_pilot_v1.kst_today();
  v_date date := coalesce(p_date, v_today);
begin
  if v_date > v_today or v_date < v_today - 31 then raise exception 'ATTENDANCE_DATE_LOCKED' using errcode = '42501'; end if;
  return jsonb_build_object('ok', true, 'date', v_date, 'today', v_today,
    'can_correct', (a -> 'roles') ? 'ADMIN',
    'teams', coalesce((
      select jsonb_agg(jsonb_build_object('team_id', x.team_id, 'team_name', x.team_name, 'people', x.people) order by x.team_name)
      from (
        select t.id as team_id, t.name as team_name, field_pilot_v1.attendance_team_json(s.id, t.id, v_date) as people
        from personnel_pilot_v1.teams t
        join personnel_pilot_v1.sites s on s.id = t.site_id and s.is_active
        where s.code in (select jsonb_array_elements_text(coalesce(a -> 'site_codes', '[]'::jsonb)))
          and exists (select 1 from personnel_pilot_v1.memberships ms join personnel_pilot_v1.people p on p.id = ms.person_id
                      where ms.team_id = t.id and ms.valid_to is null and p.employment_status <> 'inactive')
      ) x), '[]'::jsonb));
end $fn$;

revoke all on function field_pilot_v1.attendance_team_json(uuid, uuid, date) from public, anon, authenticated, service_role;
revoke all on function public.tbm_task_stop(uuid, text, text, text, text), public.tbm_site_people(uuid),
  public.tbm_attendance_today(uuid), public.tbm_attendance_save(jsonb), public.tbm_attendance_overview(date)
  from public, anon, service_role;
grant execute on function public.tbm_task_stop(uuid, text, text, text, text), public.tbm_site_people(uuid),
  public.tbm_attendance_today(uuid), public.tbm_attendance_save(jsonb), public.tbm_attendance_overview(date)
  to authenticated;

-- 기존 행이 하나라도 바뀌었으면 전체 취소 (배정 표는 새 열 home_team_id만 빼고 비교)
do $verify$
declare b record; after_rows jsonb;
begin
  for b in select * from field_v04_before loop
    if b.table_name = 'task_assignments' then
      select coalesce(jsonb_agg(x.j order by x.j::text), '[]'::jsonb) into after_rows
      from (select to_jsonb(t) - 'home_team_id' as j from field_pilot_v1.task_assignments t) x;
    else
      execute format('select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text), ''[]''::jsonb) from field_pilot_v1.%I x', b.table_name) into after_rows;
    end if;
    if b.rows is distinct from after_rows then raise exception 'VERIFY: original data changed in %', b.table_name; end if;
  end loop;
  if exists (select 1 from field_pilot_v1.task_assignments where home_team_id is not null) then
    raise exception 'VERIFY: existing assignments changed';
  end if;
end $verify$;
notify pgrst, 'reload schema';
commit;
