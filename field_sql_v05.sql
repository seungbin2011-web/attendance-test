-- field v0.5: 잘못 이월한 작업 정정 (이월 취소 + 사유 이력)
-- CHECK(field_sql_v05_check.sql) → 이 파일 → VERIFY(field_sql_v05_verify.sql). 되돌리기: field_sql_v05_rollback.sql
-- 선행: field_sql_v04.sql
-- 지키는 것
--   * 표·열·제약은 바꾸지 않는다. 새 RPC 하나(public.tbm_carry_cancel)만 더한다.
--   * 기존 보고·작업·배정·사진·이력 행은 이 파일에서 바꾸지 않는다. 바뀌면 전체 취소 (아래 $verify$).
--   * 어제 보고·결과는 지우거나 고치지 않는다. 이월 상태(carry_status)만 'DROPPED'(이어받지 않음)로 바꾸고 사유를 이력에 남긴다.
-- 쓰임
--   1) 아직 이어받지 않은 이월 후보(PENDING): 이월 취소 → DROPPED. 내일부터 후보에 나오지 않는다.
--   2) 오늘 계획에 이미 이어받은 이월 작업(결과 전): 오늘 작업에서 빼고(is_active=false) 원래 작업은 DROPPED.
--   두 경우 모두 원래 작업이 있는 보고에 'CARRY_CANCELLED' 이력(누가·언제·사유·전후 값)을 남기고, 2)는 오늘 보고에도 남긴다.
begin;
set local lock_timeout = '5s';
lock table field_pilot_v1.daily_reports, field_pilot_v1.report_tasks,
  field_pilot_v1.task_assignments, field_pilot_v1.attachments, field_pilot_v1.workflow_history
  in share row exclusive mode;

create temp table field_v05_before (table_name text primary key, rows jsonb) on commit drop;
do $snapshot$
declare t text;
begin
  foreach t in array array['daily_reports','report_tasks','task_assignments','attachments','workflow_history'] loop
    execute format('insert into field_v05_before select %L, coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text), ''[]''::jsonb) from field_pilot_v1.%I x', t, t);
  end loop;
end $snapshot$;

do $pre$
begin
  if to_regprocedure('public.tbm_task_stop(uuid,text,text,text,text)') is null then
    raise exception 'PRECHECK: field_sql_v04.sql을 먼저 적용해야 함';
  end if;
  if to_regprocedure('public.tbm_carry_cancel(uuid,text,text)') is not null then
    raise exception 'PRECHECK: v05 already applied';
  end if;
end $pre$;

-- 이월 취소: p_task_id는 (1) 이전 날짜의 이월 후보 작업 또는 (2) 오늘 계획에 이어받은 작업
create function public.tbm_carry_cancel(p_task_id uuid, p_reason text, p_request_id text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  a jsonb := personnel_pilot_v1.require_actor(array['TEAM_LEADER']);
  v_today date := field_pilot_v1.kst_today();
  k field_pilot_v1.report_tasks;
  src field_pilot_v1.report_tasks;
  r field_pilot_v1.daily_reports;
  sr field_pilot_v1.daily_reports;
  sc record;
  v_reason text := nullif(trim(p_reason), '');
begin
  if coalesce(length(v_reason), 0) < 2 then raise exception 'NOTE_REQUIRED' using errcode = '22023'; end if;
  select * into k from field_pilot_v1.report_tasks where id = p_task_id;
  if not found then raise exception 'TASK_NOT_FOUND' using errcode = 'P0002'; end if;
  select * into r from field_pilot_v1.daily_reports where id = k.report_id;

  if k.carried_from_task_id is not null and r.work_date = v_today then
    -- (2) 오늘 이어받은 작업: 오늘 보고 수정 권한·잠금 확인 (팀 범위, 오늘, 퇴근 마감 전)
    r := field_pilot_v1.lock_editable_report(a, k.report_id);
    select * into k from field_pilot_v1.report_tasks where id = k.id for update;
    if not k.is_active then
      return jsonb_build_object('ok', true, 'replayed', true, 'mode', 'TODAY', 'report', field_pilot_v1.report_json(r.id));
    end if;
    if k.result is not null then raise exception 'TASK_CLOSED' using errcode = '22023'; end if;
    select * into src from field_pilot_v1.report_tasks where id = k.carried_from_task_id for update;
    select * into sr from field_pilot_v1.daily_reports where id = src.report_id;
    update field_pilot_v1.report_tasks set is_active = false, updated_at = clock_timestamp() where id = k.id;
    update field_pilot_v1.report_tasks set carry_status = 'DROPPED', updated_at = clock_timestamp()
    where id = src.id and carry_over;
    update field_pilot_v1.daily_reports set version = version + 1, last_request_id = left(p_request_id, 80), updated_at = clock_timestamp()
    where id = r.id;
    perform field_pilot_v1.log_history(r.id, 'TASK', k.id, 'CARRY_CANCELLED',
      jsonb_build_object('is_active', true, 'carried_from_task_id', k.carried_from_task_id, 'place', k.place, 'content', k.content),
      jsonb_build_object('is_active', false, 'source_work_date', sr.work_date, 'source_task_no', src.task_no), v_reason, a);
    perform field_pilot_v1.log_history(sr.id, 'TASK', src.id, 'CARRY_CANCELLED',
      jsonb_build_object('carry_status', src.carry_status), jsonb_build_object('carry_status', 'DROPPED', 'cancelled_on', v_today, 'today_task_id', k.id),
      v_reason, a);
    return jsonb_build_object('ok', true, 'mode', 'TODAY', 'report', field_pilot_v1.report_json(r.id));
  end if;

  -- (1) 아직 이어받지 않은 이월 후보: 이전 날짜, 같은 팀(팀장 범위), 14일 안
  select * into sc from field_pilot_v1.leader_scope(a, r.team_id);
  if r.site_id <> sc.site_id or r.work_date >= v_today or r.work_date < v_today - 14 or not k.is_active then
    raise exception 'CARRY_NOT_AVAILABLE' using errcode = '22023';
  end if;
  select * into k from field_pilot_v1.report_tasks where id = k.id for update;
  if k.carry_status = 'DROPPED' then
    return jsonb_build_object('ok', true, 'replayed', true, 'mode', 'CANDIDATE');
  end if;
  if k.carry_status is distinct from 'PENDING' then raise exception 'CARRY_NOT_AVAILABLE' using errcode = '22023'; end if;
  update field_pilot_v1.report_tasks set carry_status = 'DROPPED', updated_at = clock_timestamp() where id = k.id;
  perform field_pilot_v1.log_history(r.id, 'TASK', k.id, 'CARRY_CANCELLED',
    jsonb_build_object('carry_status', 'PENDING'), jsonb_build_object('carry_status', 'DROPPED', 'cancelled_on', v_today), v_reason, a);
  return jsonb_build_object('ok', true, 'mode', 'CANDIDATE');
end $fn$;

revoke all on function public.tbm_carry_cancel(uuid, text, text) from public, anon, service_role;
grant execute on function public.tbm_carry_cancel(uuid, text, text) to authenticated;

-- 기존 행이 하나라도 바뀌었으면 전체 취소
do $verify$
declare b record; after_rows jsonb;
begin
  for b in select * from field_v05_before loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text), ''[]''::jsonb) from field_pilot_v1.%I x', b.table_name) into after_rows;
    if b.rows is distinct from after_rows then raise exception 'VERIFY: original data changed in %', b.table_name; end if;
  end loop;
end $verify$;
notify pgrst, 'reload schema';
commit;
