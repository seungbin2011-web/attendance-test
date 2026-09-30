-- 현장 업무 통합 로그인 v0.8 · 롤백 (필요할 때만, 사용자 확인 후 실행)
-- SQL 버전: personnel_auth v0.8 / 전환 단계: S0-2 / 작성 2026-09-30
-- 선행 조건: field_sql_v01 이상이 적용돼 있으면 field 롤백을 먼저 실행한다. (require_actor 의존)
-- v0.8이 만든 함수·테이블만 제거한다. 기존 테이블·행·함수는 건드리지 않는다.
-- 주의: member_pins를 지우면 발급·변경된 PIN이 모두 사라진다. (재적용 후 임시 PIN 재발급 필요)
begin;

drop function if exists public.pilot_whoami();
drop function if exists public.pilot_member_change_pin(text, text);
drop function if exists public.pilot_member_login_verify(text, text, text);
drop function if exists public.pilot_member_link_account(uuid, uuid);
drop function if exists personnel_pilot_v1.admin_issue_temp_pins(uuid[], text);
drop function if exists personnel_pilot_v1.admin_unlock_member(uuid, text);
drop function if exists personnel_pilot_v1.admin_set_member_login(uuid, boolean, text);
drop function if exists personnel_pilot_v1.require_actor(text[]);
drop function if exists personnel_pilot_v1.current_actor();
drop function if exists personnel_pilot_v1.pin_collides(uuid, text);
drop function if exists personnel_pilot_v1.pin_is_weak(text);
drop function if exists personnel_pilot_v1.name_key(text);

drop table if exists personnel_pilot_v1.member_pin_events;
drop table if exists personnel_pilot_v1.member_login_attempts;
drop table if exists personnel_pilot_v1.member_pins;

commit;

-- 아래는 선택 사항이며 별도 승인 후에만 실행한다. (기본은 주석 상태)
-- v0.8 Edge Function이 만든 개인 계정 연결 해제:
-- delete from personnel_pilot_v1.account_links al
-- using auth.users u
-- where u.id = al.auth_user_id and u.raw_app_meta_data ->> 'kind' = 'member_pin';
-- Auth 사용자(member-...@example.com)는 Dashboard → Authentication에서 확인 후 삭제한다.
