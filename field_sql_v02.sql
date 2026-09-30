-- 현장 TBM·현장보고 1단계 · TBM 사진 비공개 Storage (버킷 tbm-photos + 업로드·보기 정책)
-- SQL 버전: field v0.2 / 전환 단계: S1-5 / 작성 2026-09-30
-- 선행 조건: field_sql_v01.sql 적용 (attachments, tbm_photo_prepare/confirm 사용)
-- 적용 방법: Supabase SQL Editor에서 전체 실행 → field_sql_v02_check.sql로 확인
-- 추가형 변경만 포함한다.
--   * 새 비공개 버킷 tbm-photos (공개 링크 없음, 2MB, image/jpeg만)
--   * storage.objects에 tbm-photos 전용 정책 2개(업로드·보기)만 추가. 다른 버킷·기존 정책은 건드리지 않는다
--   * 수정(update)·삭제(delete) 정책은 만들지 않는다 → 올린 사진은 덮어쓰거나 지울 수 없음 (숨김은 tbm_photo_remove)
-- 동작
--   * 업로드: tbm_photo_prepare가 만든 PENDING 자리(15분 이내, 올린 본인, 수정 가능한 오늘 보고)의 경로에만 가능
--   * 보기: 그 보고를 볼 수 있는 사람(그 팀 팀장, 그 현장 소장·관리자)만 서명 링크로. 숨긴 사진은 볼 수 없음
-- 롤백: field_sql_v02_rollback.sql (정책·함수만 제거. 버킷·파일은 Storage 화면에서만 지울 수 있음)
begin;

-- 0. 사전 확인
do $pre$
begin
  if to_regprocedure('public.tbm_photo_prepare(uuid,text,integer,text)') is null
     or to_regclass('field_pilot_v1.attachments') is null then
    raise exception 'PRECHECK: field_sql_v01.sql을 먼저 적용해야 함';
  end if;
  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then
    raise exception 'PRECHECK: storage 스키마 필요';
  end if;
  if exists (select 1 from storage.buckets where id = 'tbm-photos') then
    raise exception 'PRECHECK: 버킷 tbm-photos가 이미 있음. 중복 적용 중단';
  end if;
  if exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
             and policyname in ('tbm_photos_insert_pending', 'tbm_photos_select_viewer')) then
    raise exception 'PRECHECK: tbm-photos 정책이 이미 있음. 중복 적용 중단';
  end if;
end $pre$;

-- 1. 비공개 버킷
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('tbm-photos', 'tbm-photos', false, 2097152, array['image/jpeg']);

-- 2. 정책용 판단 함수 (오류 대신 false: 로그인 없음·권한 없음·PIN 변경 전은 모두 거부)
create function field_pilot_v1.storage_can_upload(p_name text) returns boolean
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
    and r.status <> 'CONFIRMED'
    and r.team_id in (select (s ->> 'team_id')::uuid from jsonb_array_elements(coalesce(a -> 'team_scopes', '[]'::jsonb)) s
                      where s ->> 'team_id' is not null);
end $fn$;

create function field_pilot_v1.storage_can_read(p_name text) returns boolean
language plpgsql stable security definer set search_path = ''
as $fn$
declare
  a jsonb;
  x field_pilot_v1.attachments;
begin
  begin
    a := personnel_pilot_v1.current_actor();
  exception when others then
    return false;
  end;
  if coalesce((a ->> 'must_change_pin')::boolean, false) then return false; end if;
  select * into x from field_pilot_v1.attachments where object_path = p_name and bucket = 'tbm-photos';
  if not found or x.status = 'DELETED' then return false; end if;
  -- 올리는 중(PENDING)인 사진은 올린 본인만 (업로드 직후 확인용)
  if x.status = 'PENDING' and x.uploaded_by_auth_user_id is distinct from auth.uid() then return false; end if;
  return field_pilot_v1.can_view_report(a, x.report_id);
end $fn$;

revoke all on function field_pilot_v1.storage_can_upload(text) from public, anon, service_role;
revoke all on function field_pilot_v1.storage_can_read(text) from public, anon, service_role;
grant usage on schema field_pilot_v1 to authenticated;  -- 정책에서 두 함수를 부르기 위해서만 (테이블 권한은 없음)
grant execute on function field_pilot_v1.storage_can_upload(text) to authenticated;
grant execute on function field_pilot_v1.storage_can_read(text) to authenticated;

-- 3. storage.objects 정책 (tbm-photos 전용)
create policy tbm_photos_insert_pending on storage.objects
  for insert to authenticated
  with check (bucket_id = 'tbm-photos' and field_pilot_v1.storage_can_upload(name));
create policy tbm_photos_select_viewer on storage.objects
  for select to authenticated
  using (bucket_id = 'tbm-photos' and field_pilot_v1.storage_can_read(name));

commit;
