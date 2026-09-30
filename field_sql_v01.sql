-- 현장 TBM·현장보고 1단계 · field_pilot_v1 기본 구조와 RPC
-- SQL 버전: field v0.1 / 전환 단계: S1-1 / 작성 2026-09-30
-- 선행 조건: personnel_auth_v08.sql 적용 (current_actor, require_actor 사용)
-- 적용 방법: Supabase SQL Editor에서 전체 실행 → field_sql_v01_check.sql로 확인
-- 추가형 변경만 포함한다.
--   * 새 스키마 field_pilot_v1 (API 비노출, RLS, 직접 권한 없음)과 public RPC만 추가
--   * 기존 personnel_pilot_v1 테이블·행, 기존 함수, public.works는 변경하지 않는다
-- 원칙
--   * 모든 읽기·쓰기는 RPC로만, RPC마다 require_actor로 역할·팀·현장 범위를 서버에서 다시 확인
--   * 작성자·인원은 people.id(UUID) 기준, legacy_user_id는 표시·추적용
--   * 보고 전체의 특이사항·전달사항은 보고(daily_reports), 작업별 변경·지연·위험은 작업(report_tasks)
--   * 날짜는 한국 시간(Asia/Seoul) 기준, 팀장은 오늘 보고만 수정
--   * 모든 변경은 workflow_history에 남긴다
--   * 사진은 보고의 TBM 회차에 한 번만 연결 (작업마다 복제하지 않음), 파일은 field_sql_v02의 비공개 Storage
-- 롤백: field_sql_v01_rollback.sql (field_sql_v02가 있으면 v02 롤백 먼저)
begin;

-- 0. 사전 확인
do $pre$
begin
  if to_regprocedure('personnel_pilot_v1.require_actor(text[])') is null
     or to_regprocedure('personnel_pilot_v1.current_actor()') is null then
    raise exception 'PRECHECK: personnel_auth_v08.sql을 먼저 적용해야 함';
  end if;
  if to_regclass('storage.objects') is null then
    raise exception 'PRECHECK: storage.objects 필요';
  end if;
  if exists (select 1 from pg_namespace where nspname = 'field_pilot_v1') then
    raise exception 'PRECHECK: field_pilot_v1이 이미 있음. 중복 적용 중단';
  end if;
end $pre$;

create schema field_pilot_v1;
revoke all on schema field_pilot_v1 from public;

-- 1. 테이블

-- 팀 일일보고 (현장·팀·일자당 1건). 보고 전체의 위험요인·안전조치·특이사항은 여기에 둔다.
create table field_pilot_v1.daily_reports (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references personnel_pilot_v1.sites(id),
  team_id uuid not null references personnel_pilot_v1.teams(id),
  work_date date not null,
  status text not null default 'PLANNED' check (status in ('PLANNED', 'SUBMITTED', 'CONFIRMED')),
  reporter_person_id uuid references personnel_pilot_v1.people(id),
  reporter_auth_user_id uuid not null,
  reporter_label text not null,
  risks text[] not null default '{}'
    check (risks <@ array['고소작업', '전기', '중량물', '화기', '장비사용', '기타']::text[]),
  risk_other text check (length(risk_other) <= 200),
  safety_note text check (length(safety_note) <= 1000),
  issue_note text check (length(issue_note) <= 1000),
  needs_manager_check boolean not null default false,
  end_time time,
  morning_at timestamptz,
  morning_note text check (length(morning_note) <= 1000),
  afternoon_at timestamptz,
  afternoon_note text check (length(afternoon_note) <= 1000),
  evening_at timestamptz,
  evening_note text check (length(evening_note) <= 1000),
  last_request_id text,
  version integer not null default 1,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (site_id, team_id, work_date)
);

-- 작업. 작업별 변경·지연·위험(alert)과 퇴근 결과(result)·이월(carry)은 여기에 둔다.
create table field_pilot_v1.report_tasks (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references field_pilot_v1.daily_reports(id),
  task_no integer not null check (task_no between 1 and 99),
  place text not null check (length(trim(place)) between 1 and 120),
  content text not null check (length(trim(content)) between 1 and 500),
  is_active boolean not null default true,
  alert text not null default 'NONE' check (alert in ('NONE', 'NORMAL', 'CHANGED', 'DELAYED', 'RISK')),
  alert_note text check (length(alert_note) <= 500),
  alert_action text check (length(alert_action) <= 500),
  alert_at timestamptz,
  result text check (result in ('DONE', 'PARTIAL', 'NOT_DONE', 'EXCLUDED')),
  result_note text check (length(result_note) <= 500),
  result_at timestamptz,
  carry_over boolean not null default false,
  carry_note text check (length(carry_note) <= 500),
  carry_status text check (carry_status in ('PENDING', 'CONTINUED', 'DROPPED')),
  carried_from_task_id uuid references field_pilot_v1.report_tasks(id),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (report_id, task_no),
  check (not carry_over or result in ('PARTIAL', 'NOT_DONE')),
  check ((carry_status is null) = (not carry_over))
);
-- 이월 작업은 한 번만 이어받을 수 있다 (중복 생성 방지)
create unique index report_tasks_carry_once on field_pilot_v1.report_tasks (carried_from_task_id)
  where carried_from_task_id is not null and is_active;
create index report_tasks_report_idx on field_pilot_v1.report_tasks (report_id);

-- 작업별 인원 (people.id 기준, 사용자ID는 추적용 사본)
create table field_pilot_v1.task_assignments (
  task_id uuid not null references field_pilot_v1.report_tasks(id),
  person_id uuid not null references personnel_pilot_v1.people(id),
  work_role text not null default '작업자'
    check (work_role in ('작업자', '작업지휘자', '신호수', '화기감시자', '유도원', '기타')),
  legacy_user_id text,
  created_at timestamptz not null default clock_timestamp(),
  primary key (task_id, person_id)
);
create index task_assignments_person_idx on field_pilot_v1.task_assignments (person_id);

-- 사진 메타데이터 (파일은 비공개 버킷 tbm-photos). 보고의 TBM 회차에 한 번만 연결한다.
create table field_pilot_v1.attachments (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references field_pilot_v1.daily_reports(id),
  kind text not null check (kind in ('MORNING', 'AFTERNOON', 'EVENING')),
  bucket text not null default 'tbm-photos',
  object_path text not null unique,
  status text not null default 'PENDING' check (status in ('PENDING', 'READY', 'DELETED')),
  content_type text not null default 'image/jpeg' check (content_type = 'image/jpeg'),
  size_bytes integer not null check (size_bytes between 1 and 2097152),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  uploaded_by_person_id uuid references personnel_pilot_v1.people(id),
  uploaded_by_auth_user_id uuid not null,
  created_at timestamptz not null default clock_timestamp(),
  ready_at timestamptz,
  deleted_at timestamptz
);
create unique index attachments_no_duplicate on field_pilot_v1.attachments (report_id, kind, sha256)
  where status <> 'DELETED';

-- 변경 이력 (모든 저장·상태 변경)
create table field_pilot_v1.workflow_history (
  id bigint generated always as identity primary key,
  report_id uuid references field_pilot_v1.daily_reports(id),
  entity_type text not null check (entity_type in ('REPORT', 'TASK', 'ATTACHMENT')),
  entity_id uuid not null,
  action text not null,
  before_data jsonb,
  after_data jsonb,
  note text,
  actor_person_id uuid,
  actor_auth_user_id uuid not null,
  actor_label text not null,
  created_at timestamptz not null default clock_timestamp()
);
create index workflow_history_report_idx on field_pilot_v1.workflow_history (report_id, created_at);

alter table field_pilot_v1.daily_reports enable row level security;
alter table field_pilot_v1.report_tasks enable row level security;
alter table field_pilot_v1.task_assignments enable row level security;
alter table field_pilot_v1.attachments enable row level security;
alter table field_pilot_v1.workflow_history enable row level security;
revoke all on all tables in schema field_pilot_v1 from public, anon, authenticated, service_role;
revoke all on all sequences in schema field_pilot_v1 from public, anon, authenticated, service_role;

-- 2. 내부 함수

create function field_pilot_v1.kst_today() returns date
language sql stable set search_path = ''
as $fn$ select (now() at time zone 'Asia/Seoul')::date $fn$;

-- 팀장 범위: 로그인 사용자의 팀장 팀 중 하나 (여러 팀이면 p_team_id 필수)
create function field_pilot_v1.leader_scope(p_actor jsonb, p_team_id uuid)
returns table (team_id uuid, site_id uuid, team_name text, site_code text)
language plpgsql stable security definer set search_path = ''
as $fn$
declare
  v_ids uuid[];
  v_id uuid;
begin
  select array_agg(distinct (s ->> 'team_id')::uuid) into v_ids
  from jsonb_array_elements(coalesce(p_actor -> 'team_scopes', '[]'::jsonb)) s
  where s ->> 'team_id' is not null;
  if v_ids is null or cardinality(v_ids) = 0 then
    raise exception 'TEAM_NOT_READY' using errcode = '42501';
  end if;
  if p_team_id is not null then
    if not p_team_id = any (v_ids) then raise exception 'TEAM_FORBIDDEN' using errcode = '42501'; end if;
    v_id := p_team_id;
  elsif cardinality(v_ids) = 1 then
    v_id := v_ids[1];
  else
    raise exception 'TEAM_REQUIRED' using errcode = '22023';
  end if;
  return query
    select t.id, t.site_id, t.name, s.code
    from personnel_pilot_v1.teams t join personnel_pilot_v1.sites s on s.id = t.site_id
    where t.id = v_id and s.is_active;
  if not found then raise exception 'TEAM_NOT_READY' using errcode = '42501'; end if;
end $fn$;

-- 보고를 볼 수 있는가: 그 팀의 팀장, 또는 그 현장의 소장·관리자
create function field_pilot_v1.can_view_report(p_actor jsonb, p_report_id uuid) returns boolean
language sql stable security definer set search_path = ''
as $fn$
  select exists (
    select 1
    from field_pilot_v1.daily_reports r
    join personnel_pilot_v1.sites s on s.id = r.site_id
    where r.id = p_report_id
      and (
        ((p_actor -> 'roles') ?| array['SITE_MANAGER', 'ADMIN']
          and s.code in (select jsonb_array_elements_text(coalesce(p_actor -> 'site_codes', '[]'::jsonb))))
        or ((p_actor -> 'roles') ? 'TEAM_LEADER'
          and r.team_id in (select (x ->> 'team_id')::uuid
                            from jsonb_array_elements(coalesce(p_actor -> 'team_scopes', '[]'::jsonb)) x
                            where x ->> 'team_id' is not null))
      )
  )
$fn$;

-- 수정 가능한 보고를 잠그고 돌려준다: 그 팀의 팀장, 오늘 보고, 소장 확인 전
create function field_pilot_v1.lock_editable_report(p_actor jsonb, p_report_id uuid)
returns field_pilot_v1.daily_reports
language plpgsql security definer set search_path = ''
as $fn$
declare r field_pilot_v1.daily_reports;
begin
  select * into r from field_pilot_v1.daily_reports where id = p_report_id for update;
  if not found then raise exception 'REPORT_NOT_FOUND' using errcode = 'P0002'; end if;
  if not ((p_actor -> 'roles') ? 'TEAM_LEADER')
     or r.team_id not in (select (x ->> 'team_id')::uuid
                          from jsonb_array_elements(coalesce(p_actor -> 'team_scopes', '[]'::jsonb)) x
                          where x ->> 'team_id' is not null) then
    raise exception 'REPORT_FORBIDDEN' using errcode = '42501';
  end if;
  if r.work_date <> field_pilot_v1.kst_today() or r.status = 'CONFIRMED' then
    raise exception 'REPORT_NOT_EDITABLE' using errcode = '42501';
  end if;
  return r;
end $fn$;

create function field_pilot_v1.log_history(
  p_report_id uuid, p_entity_type text, p_entity_id uuid, p_action text,
  p_before jsonb, p_after jsonb, p_note text, p_actor jsonb)
returns void
language sql security definer set search_path = ''
as $fn$
  insert into field_pilot_v1.workflow_history
    (report_id, entity_type, entity_id, action, before_data, after_data, note, actor_person_id, actor_auth_user_id, actor_label)
  values (p_report_id, p_entity_type, p_entity_id, p_action, p_before, p_after, p_note,
          nullif(p_actor ->> 'person_id', '')::uuid, (p_actor ->> 'auth_user_id')::uuid, coalesce(p_actor ->> 'name', '-'))
$fn$;

-- 작업 인원 검증: 같은 팀 활성 소속, 퇴사 아님, 역할 목록, 같은 날 다른 보고에 배정되지 않음
create function field_pilot_v1.check_members(p_team_id uuid, p_work_date date, p_report_id uuid, p_members jsonb)
returns void
language plpgsql stable security definer set search_path = ''
as $fn$
declare
  m jsonb;
  v_person uuid;
  v_name text;
  v_other text;
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
    join personnel_pilot_v1.memberships ms on ms.person_id = p.id and ms.team_id = p_team_id and ms.valid_to is null
    where p.id = v_person and p.employment_status <> 'inactive';
    if v_name is null then
      raise exception 'MEMBER_NOT_IN_TEAM: %', coalesce((select display_name from personnel_pilot_v1.people where id = v_person), m ->> 'person_id')
        using errcode = '22023';
    end if;
    select t.name into v_other
    from field_pilot_v1.task_assignments a
    join field_pilot_v1.report_tasks k on k.id = a.task_id and k.is_active
    join field_pilot_v1.daily_reports r on r.id = k.report_id
    join personnel_pilot_v1.teams t on t.id = r.team_id
    where a.person_id = v_person and r.work_date = p_work_date and r.id is distinct from p_report_id
    limit 1;
    if v_other is not null then
      raise exception 'MEMBER_ASSIGNED_ELSEWHERE: % (%)', v_name, v_other using errcode = '22023';
    end if;
  end loop;
end $fn$;

create function field_pilot_v1.replace_assignments(p_task_id uuid, p_members jsonb) returns void
language sql security definer set search_path = ''
as $fn$
  delete from field_pilot_v1.task_assignments where task_id = p_task_id;
  insert into field_pilot_v1.task_assignments (task_id, person_id, work_role, legacy_user_id)
  select p_task_id, (e ->> 'person_id')::uuid, coalesce(e ->> 'role', '작업자'), p.legacy_user_id
  from jsonb_array_elements(coalesce(p_members, '[]'::jsonb)) e
  join personnel_pilot_v1.people p on p.id = (e ->> 'person_id')::uuid;
$fn$;

-- 보고 전체 (작업·인원·사진 포함). 팀장·소장 화면 공통.
create function field_pilot_v1.report_json(p_report_id uuid) returns jsonb
language sql stable security definer set search_path = ''
as $fn$
  select jsonb_build_object(
    'id', r.id, 'work_date', r.work_date, 'status', r.status, 'version', r.version,
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
        'alert', k.alert, 'alert_note', k.alert_note, 'alert_action', k.alert_action,
        'result', k.result, 'result_note', k.result_note,
        'carry_over', k.carry_over, 'carry_note', k.carry_note, 'carry_status', k.carry_status,
        'carried_from_task_id', k.carried_from_task_id,
        'members', coalesce((
          select jsonb_agg(jsonb_build_object('person_id', a.person_id, 'name', p.display_name,
                   'legacy_user_id', a.legacy_user_id, 'role', a.work_role) order by p.display_name)
          from field_pilot_v1.task_assignments a join personnel_pilot_v1.people p on p.id = a.person_id
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

-- 3. 팀장 RPC

-- 3-1. 오늘 화면 한 번에 불러오기: 보고, 팀 인원, 다른 팀 배정 잠금, 이월 후보
create function public.tbm_today(p_team_id uuid default null) returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER']);
  sc record;
  v_today date := field_pilot_v1.kst_today();
  v_report uuid;
begin
  select * into sc from field_pilot_v1.leader_scope(a, p_team_id);
  select id into v_report from field_pilot_v1.daily_reports
  where site_id = sc.site_id and team_id = sc.team_id and work_date = v_today;

  return jsonb_build_object(
    'ok', true,
    'today', v_today,
    'team', jsonb_build_object('id', sc.team_id, 'name', sc.team_name),
    'site', jsonb_build_object('id', sc.site_id, 'code', sc.site_code,
             'name', (select name from personnel_pilot_v1.sites where id = sc.site_id)),
    'actor', jsonb_build_object('name', a ->> 'name', 'kind', a ->> 'kind', 'role_label', a ->> 'role_label',
             'person_id', a ->> 'person_id'),
    'report', case when v_report is null then null else field_pilot_v1.report_json(v_report) end,
    'members', coalesce((
      select jsonb_agg(jsonb_build_object('person_id', p.id, 'name', p.display_name, 'legacy_user_id', p.legacy_user_id,
               'rank', p.rank_title, 'job', p.job_title, 'status', p.employment_status,
               'is_leader', exists (select 1 from personnel_pilot_v1.role_assignments ra
                                    where ra.membership_id = ms.id and ra.role_code = 'TEAM_LEADER' and ra.revoked_at is null))
             order by p.display_name)
      from personnel_pilot_v1.memberships ms
      join personnel_pilot_v1.people p on p.id = ms.person_id
      where ms.team_id = sc.team_id and ms.valid_to is null and p.employment_status <> 'inactive'), '[]'::jsonb),
    'locks', coalesce((
      select jsonb_agg(distinct jsonb_build_object('person_id', asg.person_id, 'team_name', t.name,
               'reporter_label', r.reporter_label, 'place', k.place))
      from field_pilot_v1.task_assignments asg
      join field_pilot_v1.report_tasks k on k.id = asg.task_id and k.is_active
      join field_pilot_v1.daily_reports r on r.id = k.report_id
      join personnel_pilot_v1.teams t on t.id = r.team_id
      where r.work_date = v_today and r.team_id <> sc.team_id), '[]'::jsonb),
    'carry_candidates', coalesce((
      select jsonb_agg(jsonb_build_object('task_id', k.id, 'work_date', r.work_date, 'task_no', k.task_no,
               'place', k.place, 'content', k.content, 'carry_note', k.carry_note, 'result', k.result,
               'result_note', k.result_note,
               'members', coalesce((select jsonb_agg(jsonb_build_object('person_id', asg.person_id, 'name', p.display_name, 'role', asg.work_role))
                                    from field_pilot_v1.task_assignments asg join personnel_pilot_v1.people p on p.id = asg.person_id
                                    where asg.task_id = k.id), '[]'::jsonb))
             order by r.work_date, k.task_no)
      from field_pilot_v1.report_tasks k
      join field_pilot_v1.daily_reports r on r.id = k.report_id
      where r.team_id = sc.team_id and r.site_id = sc.site_id
        and r.work_date < v_today and r.work_date >= v_today - 14
        and k.is_active and k.carry_status = 'PENDING'), '[]'::jsonb)
  );
end $fn$;

-- 3-2. 작업계획 저장 (새 보고 생성 또는 수정). 같은 request_id 재전송은 한 번만 반영, 버전이 다르면 충돌.
create function public.tbm_save_plan(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER']);
  sc record;
  v_today date := field_pilot_v1.kst_today();
  r field_pilot_v1.daily_reports;
  v_before jsonb;
  v_request text := nullif(left(p_payload ->> 'request_id', 80), '');
  v_risks text[];
  t jsonb;
  v_task field_pilot_v1.report_tasks;
  v_task_id uuid;
  v_kept uuid[] := array[]::uuid[];
  v_from field_pilot_v1.report_tasks;
  v_next_no int;
begin
  select * into sc from field_pilot_v1.leader_scope(a, nullif(p_payload ->> 'team_id', '')::uuid);

  if jsonb_typeof(p_payload -> 'tasks') <> 'array' or jsonb_array_length(p_payload -> 'tasks') not between 1 and 20 then
    raise exception 'TASKS_REQUIRED' using errcode = '22023';
  end if;
  select coalesce(array_agg(x), array[]::text[]) into v_risks
  from jsonb_array_elements_text(coalesce(p_payload -> 'risks', '[]'::jsonb)) x;
  if not v_risks <@ array['고소작업', '전기', '중량물', '화기', '장비사용', '기타']::text[] then
    raise exception 'INVALID_RISK' using errcode = '22023';
  end if;

  select * into r from field_pilot_v1.daily_reports
  where site_id = sc.site_id and team_id = sc.team_id and work_date = v_today for update;

  if found then
    if v_request is not null and r.last_request_id = v_request then
      return jsonb_build_object('ok', true, 'replayed', true, 'report', field_pilot_v1.report_json(r.id));
    end if;
    if (p_payload ->> 'version') is null or (p_payload ->> 'version')::int <> r.version then
      raise exception 'VERSION_CONFLICT' using errcode = '40001';
    end if;
    perform field_pilot_v1.lock_editable_report(a, r.id);
    v_before := field_pilot_v1.report_json(r.id);
  else
    insert into field_pilot_v1.daily_reports (site_id, team_id, work_date, reporter_person_id, reporter_auth_user_id, reporter_label)
    values (sc.site_id, sc.team_id, v_today, nullif(a ->> 'person_id', '')::uuid, (a ->> 'auth_user_id')::uuid, a ->> 'name')
    on conflict (site_id, team_id, work_date) do nothing
    returning * into r;
    if r.id is null then raise exception 'VERSION_CONFLICT' using errcode = '40001'; end if;
  end if;

  update field_pilot_v1.daily_reports set
    risks = v_risks,
    risk_other = nullif(trim(p_payload ->> 'risk_other'), ''),
    safety_note = nullif(trim(p_payload ->> 'safety_note'), ''),
    issue_note = nullif(trim(p_payload ->> 'issue_note'), ''),
    needs_manager_check = coalesce((p_payload ->> 'needs_manager_check')::boolean, false),
    end_time = nullif(p_payload ->> 'end_time', '')::time,
    reporter_person_id = coalesce(reporter_person_id, nullif(a ->> 'person_id', '')::uuid),
    reporter_label = a ->> 'name'
  where id = r.id;

  for t in select * from jsonb_array_elements(p_payload -> 'tasks') loop
    v_task_id := nullif(t ->> 'id', '')::uuid;
    if v_task_id is not null then
      select * into v_task from field_pilot_v1.report_tasks where id = v_task_id and report_id = r.id and is_active for update;
      if not found then raise exception 'TASK_NOT_FOUND' using errcode = 'P0002'; end if;
      v_kept := v_kept || v_task_id;
      continue when v_task.result is not null;  -- 결과가 난 작업은 계획 저장으로 바꾸지 않는다
      perform field_pilot_v1.check_members(sc.team_id, v_today, r.id, t -> 'members');
      update field_pilot_v1.report_tasks set place = trim(t ->> 'place'), content = trim(t ->> 'content'), updated_at = clock_timestamp()
      where id = v_task_id;
    else
      perform field_pilot_v1.check_members(sc.team_id, v_today, r.id, t -> 'members');
      select coalesce(max(task_no), 0) + 1 into v_next_no from field_pilot_v1.report_tasks where report_id = r.id;
      if nullif(t ->> 'carried_from_task_id', '') is not null then
        select k.* into v_from
        from field_pilot_v1.report_tasks k join field_pilot_v1.daily_reports pr on pr.id = k.report_id
        where k.id = (t ->> 'carried_from_task_id')::uuid and k.is_active and k.carry_status = 'PENDING'
          and pr.team_id = sc.team_id and pr.site_id = sc.site_id and pr.work_date < v_today
        for update of k;
        if not found then raise exception 'CARRY_NOT_AVAILABLE' using errcode = '22023'; end if;
        update field_pilot_v1.report_tasks set carry_status = 'CONTINUED', updated_at = clock_timestamp() where id = v_from.id;
      end if;
      insert into field_pilot_v1.report_tasks (report_id, task_no, place, content, carried_from_task_id)
      values (r.id, v_next_no, trim(t ->> 'place'), trim(t ->> 'content'), nullif(t ->> 'carried_from_task_id', '')::uuid)
      returning id into v_task_id;
      v_kept := v_kept || v_task_id;
    end if;
    perform field_pilot_v1.replace_assignments(v_task_id, t -> 'members');
  end loop;

  -- 목록에서 빠진 작업(결과 없는 것만)은 비활성. 이어받은 이월이면 원래 작업을 다시 후보로 돌린다.
  update field_pilot_v1.report_tasks src set carry_status = 'PENDING', updated_at = clock_timestamp()
  from field_pilot_v1.report_tasks k
  where k.report_id = r.id and k.is_active and k.result is null and not (k.id = any (v_kept))
    and k.carried_from_task_id = src.id;
  update field_pilot_v1.report_tasks set is_active = false, updated_at = clock_timestamp()
  where report_id = r.id and is_active and result is null and not (id = any (v_kept));

  -- 오늘 이어받지 않기로 한 이월 후보
  update field_pilot_v1.report_tasks k set carry_status = 'DROPPED', updated_at = clock_timestamp()
  from field_pilot_v1.daily_reports pr
  where pr.id = k.report_id and pr.team_id = sc.team_id and pr.site_id = sc.site_id and pr.work_date < v_today
    and k.carry_status = 'PENDING'
    and k.id in (select (x #>> '{}')::uuid from jsonb_array_elements(coalesce(p_payload -> 'drop_carry_ids', '[]'::jsonb)) x);

  update field_pilot_v1.daily_reports set version = version + 1, last_request_id = v_request, updated_at = clock_timestamp()
  where id = r.id;
  perform field_pilot_v1.log_history(r.id, 'REPORT', r.id, 'PLAN_SAVE', v_before, field_pilot_v1.report_json(r.id), null, a);
  return jsonb_build_object('ok', true, 'report', field_pilot_v1.report_json(r.id));
end $fn$;

-- 3-3. 출근 TBM 보고 → 보고완료 (다시 누르면 그대로 성공)
create function public.tbm_submit_morning(p_report_id uuid, p_note text default null, p_request_id text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER']);
  r field_pilot_v1.daily_reports := field_pilot_v1.lock_editable_report(a, p_report_id);
begin
  if r.morning_at is not null then
    return jsonb_build_object('ok', true, 'replayed', true, 'report', field_pilot_v1.report_json(r.id));
  end if;
  if not exists (select 1 from field_pilot_v1.report_tasks where report_id = r.id and is_active) then
    raise exception 'TASKS_REQUIRED' using errcode = '22023';
  end if;
  update field_pilot_v1.daily_reports set
    morning_at = clock_timestamp(), morning_note = nullif(trim(p_note), ''),
    status = case when status = 'PLANNED' then 'SUBMITTED' else status end,
    version = version + 1, last_request_id = left(p_request_id, 80), updated_at = clock_timestamp()
  where id = r.id;
  perform field_pilot_v1.log_history(r.id, 'REPORT', r.id, 'MORNING_SUBMIT', jsonb_build_object('status', r.status),
    jsonb_build_object('status', 'SUBMITTED'), nullif(trim(p_note), ''), a);
  return jsonb_build_object('ok', true, 'report', field_pilot_v1.report_json(r.id));
end $fn$;

-- 3-4. 오후 TBM: 아직 확인 안 한 작업을 한 번에 정상으로
create function public.tbm_afternoon_all_clear(p_report_id uuid, p_note text default null, p_request_id text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER']);
  r field_pilot_v1.daily_reports := field_pilot_v1.lock_editable_report(a, p_report_id);
  v_count int;
begin
  if r.morning_at is null then raise exception 'MORNING_REQUIRED' using errcode = '22023'; end if;
  update field_pilot_v1.report_tasks set alert = 'NORMAL', alert_at = clock_timestamp(), updated_at = clock_timestamp()
  where report_id = r.id and is_active and alert = 'NONE' and result is null;
  get diagnostics v_count = row_count;
  update field_pilot_v1.daily_reports set
    afternoon_at = coalesce(afternoon_at, clock_timestamp()),
    afternoon_note = coalesce(nullif(trim(p_note), ''), afternoon_note),
    version = version + 1, last_request_id = left(p_request_id, 80), updated_at = clock_timestamp()
  where id = r.id;
  perform field_pilot_v1.log_history(r.id, 'REPORT', r.id, 'AFTERNOON_ALL_CLEAR', null,
    jsonb_build_object('normal_tasks', v_count), nullif(trim(p_note), ''), a);
  return jsonb_build_object('ok', true, 'report', field_pilot_v1.report_json(r.id));
end $fn$;

-- 3-5. 오후 TBM: 작업 하나의 정상 / 변경 / 지연 / 위험 (변경은 위치·내용·인원 변경 가능)
create function public.tbm_task_alert(
  p_task_id uuid, p_alert text, p_note text default null, p_action text default null,
  p_change jsonb default null, p_request_id text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER']);
  k field_pilot_v1.report_tasks;
  r field_pilot_v1.daily_reports;
  v_before jsonb;
begin
  select * into k from field_pilot_v1.report_tasks where id = p_task_id and is_active;
  if not found then raise exception 'TASK_NOT_FOUND' using errcode = 'P0002'; end if;
  r := field_pilot_v1.lock_editable_report(a, k.report_id);
  if r.morning_at is null then raise exception 'MORNING_REQUIRED' using errcode = '22023'; end if;
  if p_alert not in ('NORMAL', 'CHANGED', 'DELAYED', 'RISK') then raise exception 'INVALID_ALERT' using errcode = '22023'; end if;
  if p_alert <> 'NORMAL' and coalesce(length(trim(p_note)), 0) < 2 then raise exception 'NOTE_REQUIRED' using errcode = '22023'; end if;
  if k.result is not null then raise exception 'TASK_CLOSED' using errcode = '22023'; end if;

  select to_jsonb(x) - 'created_at' - 'updated_at' into v_before from field_pilot_v1.report_tasks x where id = k.id;
  v_before := v_before || jsonb_build_object('members', (select coalesce(jsonb_agg(jsonb_build_object('person_id', person_id, 'role', work_role)), '[]'::jsonb)
                                                       from field_pilot_v1.task_assignments where task_id = k.id));
  if p_alert = 'CHANGED' and p_change is not null then
    if p_change ? 'members' then
      perform field_pilot_v1.check_members(r.team_id, r.work_date, r.id, p_change -> 'members');
      perform field_pilot_v1.replace_assignments(k.id, p_change -> 'members');
    end if;
    update field_pilot_v1.report_tasks set
      place = coalesce(nullif(trim(p_change ->> 'place'), ''), place),
      content = coalesce(nullif(trim(p_change ->> 'content'), ''), content)
    where id = k.id;
  end if;
  update field_pilot_v1.report_tasks set
    alert = p_alert,
    alert_note = case when p_alert = 'NORMAL' then null else trim(p_note) end,
    alert_action = case when p_alert = 'NORMAL' then null else nullif(trim(p_action), '') end,
    alert_at = clock_timestamp(), updated_at = clock_timestamp()
  where id = k.id;
  update field_pilot_v1.daily_reports set afternoon_at = coalesce(afternoon_at, clock_timestamp()),
    version = version + 1, last_request_id = left(p_request_id, 80), updated_at = clock_timestamp()
  where id = r.id;
  perform field_pilot_v1.log_history(r.id, 'TASK', k.id, 'TASK_' || p_alert, v_before,
    (select to_jsonb(x) - 'created_at' - 'updated_at' from field_pilot_v1.report_tasks x where id = k.id)
      || jsonb_build_object('members', (select coalesce(jsonb_agg(jsonb_build_object('person_id', person_id, 'role', work_role)), '[]'::jsonb)
                                        from field_pilot_v1.task_assignments where task_id = k.id)),
    nullif(trim(p_note), ''), a);
  return jsonb_build_object('ok', true, 'report', field_pilot_v1.report_json(r.id));
end $fn$;

-- 3-6. 퇴근 TBM: 작업 하나의 결과 (완료 / 일부완료 / 미완료 / 제외, 일부·미완료는 이월 선택)
create function public.tbm_task_result(
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

-- 3-7. 퇴근 TBM 마감 (p_complete_rest: 결과 없는 작업을 모두 완료로)
create function public.tbm_evening_close(p_report_id uuid, p_note text default null, p_complete_rest boolean default false, p_request_id text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER']);
  r field_pilot_v1.daily_reports := field_pilot_v1.lock_editable_report(a, p_report_id);
  v_open int;
begin
  if r.morning_at is null then raise exception 'MORNING_REQUIRED' using errcode = '22023'; end if;
  if p_complete_rest then
    update field_pilot_v1.report_tasks set result = 'DONE', result_at = clock_timestamp(), updated_at = clock_timestamp()
    where report_id = r.id and is_active and result is null;
  end if;
  select count(*) into v_open from field_pilot_v1.report_tasks where report_id = r.id and is_active and result is null;
  if v_open > 0 then raise exception 'UNRESOLVED_TASKS: %', v_open using errcode = '22023'; end if;
  update field_pilot_v1.daily_reports set
    evening_at = coalesce(evening_at, clock_timestamp()),
    evening_note = coalesce(nullif(trim(p_note), ''), evening_note),
    version = version + 1, last_request_id = left(p_request_id, 80), updated_at = clock_timestamp()
  where id = r.id;
  perform field_pilot_v1.log_history(r.id, 'REPORT', r.id, 'EVENING_CLOSE', null,
    jsonb_build_object('complete_rest', p_complete_rest), nullif(trim(p_note), ''), a);
  return jsonb_build_object('ok', true, 'report', field_pilot_v1.report_json(r.id));
end $fn$;

-- 3-8. 사진 자리 받기 (회차당 3장, 같은 사진은 다시 올리지 않음). 파일은 받은 경로로 Storage에 올린다.
create function public.tbm_photo_prepare(p_report_id uuid, p_kind text, p_size integer, p_sha256 text)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER']);
  r field_pilot_v1.daily_reports := field_pilot_v1.lock_editable_report(a, p_report_id);
  x field_pilot_v1.attachments;
  v_id uuid := gen_random_uuid();
  v_site text;
begin
  if p_kind not in ('MORNING', 'AFTERNOON', 'EVENING') then raise exception 'INVALID_KIND' using errcode = '22023'; end if;
  if p_size is null or p_size not between 1 and 2097152 then raise exception 'PHOTO_TOO_LARGE' using errcode = '22023'; end if;
  if p_sha256 is null or lower(p_sha256) !~ '^[0-9a-f]{64}$' then raise exception 'INVALID_HASH' using errcode = '22023'; end if;

  select * into x from field_pilot_v1.attachments
  where report_id = r.id and kind = p_kind and sha256 = lower(p_sha256) and status <> 'DELETED';
  if found and x.status = 'READY' then
    return jsonb_build_object('ok', true, 'duplicate', true, 'attachment_id', x.id, 'bucket', x.bucket, 'path', x.object_path);
  elsif found then
    update field_pilot_v1.attachments set created_at = clock_timestamp(), uploaded_by_auth_user_id = (a ->> 'auth_user_id')::uuid
    where id = x.id;
    return jsonb_build_object('ok', true, 'attachment_id', x.id, 'bucket', x.bucket, 'path', x.object_path);
  end if;

  if (select count(*) from field_pilot_v1.attachments
      where report_id = r.id and kind = p_kind
        and (status = 'READY' or (status = 'PENDING' and created_at > clock_timestamp() - interval '15 minutes'))) >= 3 then
    raise exception 'PHOTO_LIMIT' using errcode = '22023';
  end if;
  select code into v_site from personnel_pilot_v1.sites where id = r.site_id;
  insert into field_pilot_v1.attachments (id, report_id, kind, object_path, size_bytes, sha256, uploaded_by_person_id, uploaded_by_auth_user_id)
  values (v_id, r.id, p_kind,
          format('%s/%s/%s/%s/%s.jpg', v_site, r.work_date, r.id, lower(p_kind), v_id),
          p_size, lower(p_sha256), nullif(a ->> 'person_id', '')::uuid, (a ->> 'auth_user_id')::uuid);
  return jsonb_build_object('ok', true, 'attachment_id', v_id, 'bucket', 'tbm-photos',
    'path', format('%s/%s/%s/%s/%s.jpg', v_site, r.work_date, r.id, lower(p_kind), v_id));
end $fn$;

-- 3-9. 업로드 확인 (Storage에 파일이 실제로 있어야 READY)
create function public.tbm_photo_confirm(p_attachment_id uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER']);
  x field_pilot_v1.attachments;
begin
  select * into x from field_pilot_v1.attachments where id = p_attachment_id;
  if not found then raise exception 'PHOTO_NOT_FOUND' using errcode = 'P0002'; end if;
  perform field_pilot_v1.lock_editable_report(a, x.report_id);
  if x.status = 'READY' then
    return jsonb_build_object('ok', true, 'report', field_pilot_v1.report_json(x.report_id));
  end if;
  if x.status <> 'PENDING' then raise exception 'PHOTO_NOT_FOUND' using errcode = 'P0002'; end if;
  if not exists (select 1 from storage.objects where bucket_id = x.bucket and name = x.object_path) then
    raise exception 'UPLOAD_NOT_FOUND' using errcode = '22023';
  end if;
  update field_pilot_v1.attachments set status = 'READY', ready_at = clock_timestamp() where id = x.id;
  perform field_pilot_v1.log_history(x.report_id, 'ATTACHMENT', x.id, 'PHOTO_ADD', null,
    jsonb_build_object('kind', x.kind, 'path', x.object_path), null, a);
  return jsonb_build_object('ok', true, 'report', field_pilot_v1.report_json(x.report_id));
end $fn$;

-- 3-10. 사진 빼기 (파일은 지우지 않고 숨김)
create function public.tbm_photo_remove(p_attachment_id uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER']);
  x field_pilot_v1.attachments;
begin
  select * into x from field_pilot_v1.attachments where id = p_attachment_id and status <> 'DELETED';
  if not found then raise exception 'PHOTO_NOT_FOUND' using errcode = 'P0002'; end if;
  perform field_pilot_v1.lock_editable_report(a, x.report_id);
  update field_pilot_v1.attachments set status = 'DELETED', deleted_at = clock_timestamp() where id = x.id;
  perform field_pilot_v1.log_history(x.report_id, 'ATTACHMENT', x.id, 'PHOTO_REMOVE',
    jsonb_build_object('kind', x.kind, 'path', x.object_path), null, null, a);
  return jsonb_build_object('ok', true, 'report', field_pilot_v1.report_json(x.report_id));
end $fn$;

-- 4. 소장·관리자 RPC (읽기 전용)

-- 4-1. 날짜별 팀 현황 (현장 범위의 모든 팀, 보고가 없는 팀은 미보고)
create function public.tbm_site_overview(p_date date default null) returns jsonb
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
      'id', r.id, 'status', r.status, 'reporter_label', r.reporter_label,
      'morning_at', r.morning_at, 'afternoon_at', r.afternoon_at, 'evening_at', r.evening_at,
      'needs_manager_check', r.needs_manager_check, 'issue_note', r.issue_note,
      'risks', to_jsonb(r.risks), 'updated_at', r.updated_at,
      'task_count', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active),
      'tasks', (select coalesce(jsonb_agg(jsonb_build_object('task_no', k.task_no, 'place', k.place, 'content', k.content,
                   'alert', k.alert, 'result', k.result, 'carry_over', k.carry_over) order by k.task_no), '[]'::jsonb)
                from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active),
      'alerts', jsonb_build_object(
        'RISK', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.alert = 'RISK'),
        'CHANGED', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.alert = 'CHANGED'),
        'DELAYED', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.alert = 'DELAYED')),
      'results', jsonb_build_object(
        'DONE', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.result = 'DONE'),
        'PARTIAL', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.result = 'PARTIAL'),
        'NOT_DONE', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.result = 'NOT_DONE'),
        'OPEN', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.result is null)),
      'carry_count', (select count(*) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active and k.carry_over),
      'photo_counts', jsonb_build_object(
        'MORNING', (select count(*) from field_pilot_v1.attachments x where x.report_id = r.id and x.status = 'READY' and x.kind = 'MORNING'),
        'AFTERNOON', (select count(*) from field_pilot_v1.attachments x where x.report_id = r.id and x.status = 'READY' and x.kind = 'AFTERNOON'),
        'EVENING', (select count(*) from field_pilot_v1.attachments x where x.report_id = r.id and x.status = 'READY' and x.kind = 'EVENING'))
    ) end
  ) order by s.code, t.name), '[]'::jsonb)
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

-- 4-2. 보고 상세 (소장·관리자: 현장 범위, 팀장: 자기 팀)
create function public.tbm_report_detail(p_report_id uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare a jsonb := personnel_pilot_v1.require_actor(array['SITE_MANAGER', 'ADMIN', 'TEAM_LEADER']);
begin
  if not field_pilot_v1.can_view_report(a, p_report_id) then
    raise exception 'REPORT_FORBIDDEN' using errcode = '42501';
  end if;
  return jsonb_build_object('ok', true, 'report', field_pilot_v1.report_json(p_report_id),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('action', h.action, 'entity_type', h.entity_type,
                  'note', h.note, 'actor', h.actor_label, 'at', h.created_at) order by h.created_at), '[]'::jsonb)
                from field_pilot_v1.workflow_history h where h.report_id = p_report_id));
end $fn$;

-- 5. 실행 권한 (public 스키마 함수는 Supabase 기본값으로 anon에 자동 허용되므로 명시적으로 회수)
revoke all on all functions in schema field_pilot_v1 from public, anon, authenticated, service_role;
do $grants$
declare f text;
begin
  foreach f in array array[
    'public.tbm_today(uuid)', 'public.tbm_save_plan(jsonb)', 'public.tbm_submit_morning(uuid,text,text)',
    'public.tbm_afternoon_all_clear(uuid,text,text)', 'public.tbm_task_alert(uuid,text,text,text,jsonb,text)',
    'public.tbm_task_result(uuid,text,boolean,text,text,text)', 'public.tbm_evening_close(uuid,text,boolean,text)',
    'public.tbm_photo_prepare(uuid,text,integer,text)', 'public.tbm_photo_confirm(uuid)', 'public.tbm_photo_remove(uuid)',
    'public.tbm_site_overview(date)', 'public.tbm_report_detail(uuid)'] loop
    execute format('revoke all on function %s from public, anon, service_role', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $grants$;

commit;
