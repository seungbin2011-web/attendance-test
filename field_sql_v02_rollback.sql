-- 현장 TBM·현장보고 1단계 · field v0.2 롤백 (필요할 때만, 사용자 확인 후 실행)
-- SQL 버전: field v0.2 / 전환 단계: S1-5
-- 제거: tbm-photos 정책 2개, 판단 함수 2개, field_pilot_v1 스키마 USAGE(authenticated)
-- 남는 것: 버킷 tbm-photos와 올라간 사진 파일. Supabase는 SQL로 Storage 행을 직접 지우는 것을 막으므로
--          정말 지워야 하면 Dashboard → Storage → tbm-photos에서 비운 뒤 삭제한다. 정책이 없으면 아무도 접근할 수 없다.
begin;
drop policy if exists tbm_photos_insert_pending on storage.objects;
drop policy if exists tbm_photos_select_viewer on storage.objects;
drop function if exists field_pilot_v1.storage_can_upload(text);
drop function if exists field_pilot_v1.storage_can_read(text);
revoke usage on schema field_pilot_v1 from authenticated;
commit;
