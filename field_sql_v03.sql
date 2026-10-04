-- field v0.3: 같은 팀·날짜의 순차 작업 묶음. 기존 UUID/내용/사진/시각 보존.
-- CHECK(field_sql_v03_check.sql) → 이 파일 → VERIFY(field_sql_v03_verify.sql).
-- 기존 행은 session_no=1. 완료는 evening_at으로 판정하며 상태 값은 바꾸지 않는다.
begin;
set local lock_timeout = '5s';
lock table field_pilot_v1.daily_reports, field_pilot_v1.report_tasks,
  field_pilot_v1.task_assignments, field_pilot_v1.attachments, field_pilot_v1.workflow_history
  in share row exclusive mode;
create temp table session_v03_before (table_name text primary key, rows jsonb) on commit drop;
do $snapshot$
declare t text;
begin
  foreach t in array array['daily_reports','report_tasks','task_assignments','attachments','workflow_history'] loop
    execute format('insert into session_v03_before select %L, coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text), ''[]''::jsonb) from field_pilot_v1.%I x',t,t);
  end loop;
end $snapshot$;
do $pre$
begin
  if exists(select 1 from information_schema.columns where table_schema='field_pilot_v1' and table_name='daily_reports' and column_name='session_no') then
    raise exception 'PRECHECK: v03 already applied';
  end if;


  if not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname||'.'||p.proname='field_pilot_v1.lock_editable_report' and md5(replace(p.prosrc,chr(13),''))='ea35fef8dac02c34bcba1d5c87bbe728') then raise exception 'PRECHECK: function changed field_pilot_v1.lock_editable_report'; end if;

  if not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname||'.'||p.proname='field_pilot_v1.check_members' and md5(replace(p.prosrc,chr(13),''))='228ddad81caa39c09073b7295403ef93') then raise exception 'PRECHECK: function changed field_pilot_v1.check_members'; end if;

  if not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname||'.'||p.proname='field_pilot_v1.report_json' and md5(replace(p.prosrc,chr(13),''))='2c008ad3ca14f6a3ff524da45c698a63') then raise exception 'PRECHECK: function changed field_pilot_v1.report_json'; end if;

  if not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname||'.'||p.proname='field_pilot_v1.storage_can_upload' and md5(replace(p.prosrc,chr(13),''))='edddf79284e904a3bda027c2736ffc52') then raise exception 'PRECHECK: function changed field_pilot_v1.storage_can_upload'; end if;

  if not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname||'.'||p.proname='public.tbm_today' and md5(replace(p.prosrc,chr(13),''))='1b1046351f53727e1b7ece43ab2e9bcc') then raise exception 'PRECHECK: function changed public.tbm_today'; end if;

  if not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname||'.'||p.proname='public.tbm_save_plan' and md5(replace(p.prosrc,chr(13),''))='b662fcd8afcea6183d21628cd3dd7dc5') then raise exception 'PRECHECK: function changed public.tbm_save_plan'; end if;

  if not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname||'.'||p.proname='public.tbm_site_overview' and md5(replace(p.prosrc,chr(13),''))='e33f8de25d1c3dc85af961984d17c7a5') then raise exception 'PRECHECK: function changed public.tbm_site_overview'; end if;

end $pre$;
alter table field_pilot_v1.daily_reports add column session_no integer not null default 1 check (session_no > 0);
alter table field_pilot_v1.daily_reports drop constraint daily_reports_site_id_team_id_work_date_key;
alter table field_pilot_v1.daily_reports add constraint daily_reports_session_key unique(site_id,team_id,work_date,session_no);
create unique index daily_reports_one_open_session on field_pilot_v1.daily_reports(site_id,team_id,work_date) where evening_at is null;


create or replace function field_pilot_v1.lock_editable_report(p_actor jsonb, p_report_id uuid)
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
  if r.work_date <> field_pilot_v1.kst_today() or r.status = 'CONFIRMED' or r.evening_at is not null then
    raise exception 'REPORT_NOT_EDITABLE' using errcode = '42501';
  end if;
  return r;
end $fn$;

create or replace function field_pilot_v1.check_members(p_team_id uuid, p_work_date date, p_report_id uuid, p_members jsonb)
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
    where a.person_id = v_person and r.work_date = p_work_date and r.id is distinct from p_report_id and r.evening_at is null
    limit 1;
    if v_other is not null then
      raise exception 'MEMBER_ASSIGNED_ELSEWHERE: % (%)', v_name, v_other using errcode = '22023';
    end if;
  end loop;
end $fn$;

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

create or replace function field_pilot_v1.storage_can_upload(p_name text) returns boolean
language plpgsql stable security definer set search_path = ''
as $fn$
declare
  a jsonb;
  x field_pilot_v1.attachments;
  r field_pilot_v1.daily_reports;
begin
  begin
    a := personnel_pilot_v1.current_actor();
  exception when others then
    return false;
  end;
  if coalesce((a ->> 'must_change_pin')::boolean, false) or not ((a -> 'roles') ? 'TEAM_LEADER') then return false; end if;
  select * into x from field_pilot_v1.attachments
  where object_path = p_name and bucket = 'tbm-photos' and status = 'PENDING'
    and uploaded_by_auth_user_id = auth.uid()
    and created_at > clock_timestamp() - interval '15 minutes';
  if not found then return false; end if;
  select * into r from field_pilot_v1.daily_reports where id = x.report_id;
  return r.work_date = field_pilot_v1.kst_today()
    and r.status <> 'CONFIRMED' and r.evening_at is null
    and r.team_id in (select (s ->> 'team_id')::uuid from jsonb_array_elements(coalesce(a -> 'team_scopes', '[]'::jsonb)) s
                      where s ->> 'team_id' is not null);
end $fn$;

create or replace function public.tbm_today(p_team_id uuid default null) returns jsonb
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
  where site_id = sc.site_id and team_id = sc.team_id and work_date = v_today order by session_no desc limit 1;

  return jsonb_build_object(
    'ok', true,
    'today', v_today,
    'team', jsonb_build_object('id', sc.team_id, 'name', sc.team_name),
    'site', jsonb_build_object('id', sc.site_id, 'code', sc.site_code,
             'name', (select name from personnel_pilot_v1.sites where id = sc.site_id)),
    'actor', jsonb_build_object('name', a ->> 'name', 'kind', a ->> 'kind', 'role_label', a ->> 'role_label',
             'person_id', a ->> 'person_id'),
    'report', case when v_report is null then null else field_pilot_v1.report_json(v_report) end,
    'reports', (select coalesce(jsonb_agg(field_pilot_v1.report_json(dr.id) order by dr.session_no desc), '[]'::jsonb) from field_pilot_v1.daily_reports dr where dr.site_id=sc.site_id and dr.team_id=sc.team_id and dr.work_date=v_today),
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
      where r.work_date = v_today and r.team_id <> sc.team_id and r.evening_at is null), '[]'::jsonb),
    'carry_candidates', coalesce((
      select jsonb_agg(jsonb_build_object('task_id', k.id, 'work_date', r.work_date, 'task_no', k.task_no,
               'place', k.place, 'content', k.content, 'carry_note', k.carry_note, 'result', k.result,
               'result_note', k.result_note,
               'reports', (select coalesce(jsonb_agg(field_pilot_v1.report_json(dr.id) order by dr.session_no desc), '[]'::jsonb) from field_pilot_v1.daily_reports dr where dr.site_id=sc.site_id and dr.team_id=sc.team_id and dr.work_date=v_today),
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

create or replace function public.tbm_save_plan(p_payload jsonb) returns jsonb
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

  -- Serialize first creation with opening a later session. Legacy clients can only target session 1.
  perform pg_advisory_xact_lock(hashtextextended(sc.team_id::text || ':' || v_today::text, 0));
  select * into r from field_pilot_v1.daily_reports
  where site_id=sc.site_id and team_id=sc.team_id and work_date=v_today
    and (case when nullif(p_payload->>'report_id','') is null then session_no=1
              else id=(p_payload->>'report_id')::uuid end) for update;
  if not found and nullif(p_payload->>'report_id','') is not null then
    raise exception 'REPORT_NOT_FOUND' using errcode='P0002';
  end if;

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
    on conflict (site_id, team_id, work_date, session_no) do nothing
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

-- Explicit new-session creation: previous UUID is the idempotency key.
create or replace function public.tbm_open_next(p_previous_report_id uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER']);
  previous field_pilot_v1.daily_reports;
  next_report field_pilot_v1.daily_reports;
  sc record;
begin
  select * into previous from field_pilot_v1.daily_reports where id=p_previous_report_id;
  if not found then raise exception 'REPORT_NOT_FOUND' using errcode='P0002'; end if;
  select * into sc from field_pilot_v1.leader_scope(a,previous.team_id);
  if previous.work_date <> field_pilot_v1.kst_today() or previous.site_id<>sc.site_id then
    raise exception 'REPORT_NOT_EDITABLE' using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(sc.team_id::text || ':' || previous.work_date::text, 0));
  select * into previous from field_pilot_v1.daily_reports where id=p_previous_report_id for update;
  if previous.evening_at is null then raise exception 'SESSION_NOT_CLOSED' using errcode='22023'; end if;
  select * into next_report from field_pilot_v1.daily_reports
    where site_id=previous.site_id and team_id=previous.team_id and work_date=previous.work_date and session_no=previous.session_no+1;
  if found then return jsonb_build_object('ok',true,'replayed',true,'report',field_pilot_v1.report_json(next_report.id)); end if;
  insert into field_pilot_v1.daily_reports(site_id,team_id,work_date,session_no,reporter_person_id,reporter_auth_user_id,reporter_label)
    values(previous.site_id,previous.team_id,previous.work_date,previous.session_no+1,
      nullif(a->>'person_id','')::uuid,(a->>'auth_user_id')::uuid,a->>'name') returning * into next_report;
  perform field_pilot_v1.log_history(next_report.id,'REPORT',next_report.id,'SESSION_OPENED',null,
    jsonb_build_object('session_no',next_report.session_no,'previous_report_id',previous.id),null,a);
  return jsonb_build_object('ok',true,'report',field_pilot_v1.report_json(next_report.id));
end $fn$;

-- MEMBER reads only their own assignments, for their current team(s). No client-supplied person ID.
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
      'completed',r.evening_at is not null,'closedAt',r.evening_at,'changed',k.alert='CHANGED',
      'afternoonStatus',case k.alert when 'NORMAL' then '정상' when 'CHANGED' then '변경' when 'DELAYED' then '지연' when 'RISK' then '위험' else null end,
      'eveningStatus',case k.result when 'DONE' then '완료' when 'PARTIAL' then '일부완료' when 'NOT_DONE' then '미완료' when 'EXCLUDED' then '제외' else null end,
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
revoke all on function public.tbm_open_next(uuid),public.tbm_my_today() from public,anon,service_role;
grant execute on function public.tbm_open_next(uuid),public.tbm_my_today() to authenticated;

-- Fail the whole transaction if any original field data changed (ignore the added default column only).
do $verify$
declare b record; after_rows jsonb;
begin
  for b in select * from session_v03_before loop
    if b.table_name='daily_reports' then
      select coalesce(jsonb_agg(to_jsonb(x)-'session_no' order by (to_jsonb(x)-'session_no')::text),'[]'::jsonb) into after_rows from field_pilot_v1.daily_reports x;
    else
      execute format('select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text), ''[]''::jsonb) from field_pilot_v1.%I x',b.table_name) into after_rows;
    end if;
    if b.rows is distinct from after_rows then raise exception 'VERIFY: original data changed in %',b.table_name; end if;
  end loop;
  if exists(select 1 from field_pilot_v1.daily_reports where session_no<>1) then raise exception 'VERIFY: existing session_no'; end if;
end $verify$;
notify pgrst,'reload schema';
commit;
