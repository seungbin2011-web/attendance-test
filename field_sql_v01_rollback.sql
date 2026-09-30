-- 현장 TBM·현장보고 1단계 · field v0.1 롤백 (필요할 때만, 사용자 확인 후 실행)
-- SQL 버전: field v0.1 / 전환 단계: S1-1
-- 주의: field_pilot_v1의 시험 보고·작업·인원·사진 기록·이력이 모두 사라진다. (기존 personnel_pilot_v1·public.works는 영향 없음)
-- 선행: field_sql_v02가 적용돼 있으면 field_sql_v02_rollback.sql을 먼저 실행한다.
begin;
drop function if exists public.tbm_today(uuid);
drop function if exists public.tbm_save_plan(jsonb);
drop function if exists public.tbm_submit_morning(uuid, text, text);
drop function if exists public.tbm_afternoon_all_clear(uuid, text, text);
drop function if exists public.tbm_task_alert(uuid, text, text, text, jsonb, text);
drop function if exists public.tbm_task_result(uuid, text, boolean, text, text, text);
drop function if exists public.tbm_evening_close(uuid, text, boolean, text);
drop function if exists public.tbm_photo_prepare(uuid, text, integer, text);
drop function if exists public.tbm_photo_confirm(uuid);
drop function if exists public.tbm_photo_remove(uuid);
drop function if exists public.tbm_site_overview(date);
drop function if exists public.tbm_report_detail(uuid);
drop function if exists field_pilot_v1.report_json(uuid);
drop function if exists field_pilot_v1.replace_assignments(uuid, jsonb);
drop function if exists field_pilot_v1.check_members(uuid, date, uuid, jsonb);
drop function if exists field_pilot_v1.log_history(uuid, text, uuid, text, jsonb, jsonb, text, jsonb);
drop function if exists field_pilot_v1.lock_editable_report(jsonb, uuid);
drop function if exists field_pilot_v1.can_view_report(jsonb, uuid);
drop function if exists field_pilot_v1.leader_scope(jsonb, uuid);
drop function if exists field_pilot_v1.kst_today();
drop table if exists field_pilot_v1.workflow_history;
drop table if exists field_pilot_v1.attachments;
drop table if exists field_pilot_v1.task_assignments;
drop table if exists field_pilot_v1.report_tasks;
drop table if exists field_pilot_v1.daily_reports;
drop schema if exists field_pilot_v1;
commit;
