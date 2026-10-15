-- field v0.4 되돌리기 (TBM / 출역 관리 개선 v0.1) — 문제가 생겼을 때만, 사용자 확인 후 실행
-- 함수와 제약만 v03 상태로 되돌린다. 데이터는 지우지 않는다.
--   * 출역 표(attendance_records, attendance_history)와 배정 당시 소속 열(task_assignments.home_team_id)은 남긴다.
--     RPC를 없애므로 화면에서는 읽고 쓸 수 없게 된다 (직접 접근은 원래부터 막혀 있음).
--   * 작업정지(STOPPED) 기록이 하나라도 있으면 v03 제약으로 돌아갈 수 없으므로 중단한다. 기록을 지우지 않는다.
--   * 다른 팀 인원이 들어간 기존 배정은 그대로 남는다 (v03 화면에서는 '(팀 외 인원)'으로 보인다).
-- 되돌린 뒤 field_sql_v04.sql을 다시 실행할 수 있다.
begin;
set local lock_timeout = '5s';
lock table field_pilot_v1.report_tasks, field_pilot_v1.task_assignments in share row exclusive mode;

do $pre$
begin
  if to_regprocedure('public.tbm_task_stop(uuid,text,text,text,text)') is null then
    raise exception 'PRECHECK: v04가 적용돼 있지 않음';
  end if;
  if exists (select 1 from field_pilot_v1.report_tasks where alert = 'STOPPED' or result = 'STOPPED') then
    raise exception 'ROLLBACK_BLOCKED: 작업정지 기록 %건이 있어 v03 제약으로 되돌릴 수 없음 (기록은 지우지 않음)',
      (select count(*) from field_pilot_v1.report_tasks where alert = 'STOPPED' or result = 'STOPPED');
  end if;
end $pre$;

drop function public.tbm_task_stop(uuid, text, text, text, text);
drop function public.tbm_site_people(uuid);
drop function public.tbm_attendance_today(uuid);
drop function public.tbm_attendance_save(jsonb);
drop function public.tbm_attendance_overview(date);
drop function field_pilot_v1.attendance_team_json(uuid, uuid, date);

alter table field_pilot_v1.report_tasks
  drop constraint report_tasks_stopped_check,
  drop constraint report_tasks_carry_result_check,
  drop constraint report_tasks_alert_check,
  drop constraint report_tasks_result_check;
alter table field_pilot_v1.report_tasks
  add constraint report_tasks_alert_check check (alert in ('NONE', 'NORMAL', 'CHANGED', 'DELAYED', 'RISK')),
  add constraint report_tasks_result_check check (result in ('DONE', 'PARTIAL', 'NOT_DONE', 'EXCLUDED')),
  add constraint report_tasks_check check (not carry_over or result in ('PARTIAL', 'NOT_DONE'));

-- 아래 함수는 field_sql_v01.sql / field_sql_v03.sql 원문 그대로 (tests/sessions/v04.mjs가 md5로 확인)
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

create or replace function field_pilot_v1.replace_assignments(p_task_id uuid, p_members jsonb) returns void
language sql security definer set search_path = ''
as $fn$
  delete from field_pilot_v1.task_assignments where task_id = p_task_id;
  insert into field_pilot_v1.task_assignments (task_id, person_id, work_role, legacy_user_id)
  select p_task_id, (e ->> 'person_id')::uuid, coalesce(e ->> 'role', '작업자'), p.legacy_user_id
  from jsonb_array_elements(coalesce(p_members, '[]'::jsonb)) e
  join personnel_pilot_v1.people p on p.id = (e ->> 'person_id')::uuid;
$fn$;

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

notify pgrst, 'reload schema';
commit;
