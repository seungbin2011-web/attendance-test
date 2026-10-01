-- 현장 업무 통합 로그인 v0.9 롤백 (필요할 때만, 사용자 확인 후 실행)
-- SQL 버전: personnel_auth v0.9
-- 제거: 휴대폰 뒤 4자리 로그인 함수 1개. 로그인 기록·계정 연결·로그인 허용 표시 행은 남긴다(삭제 없음).
-- 선행: Edge Function member-login을 v0.1로 되돌리거나 휴대폰 로그인을 쓰지 않는 상태여야 한다.
begin;
drop function if exists public.pilot_member_roster_login(text, text, boolean, text);
commit;
