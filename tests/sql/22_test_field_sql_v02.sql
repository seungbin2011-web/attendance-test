-- field v0.2 (TBM 사진 비공개 Storage) 시험 (로컬 시험 DB 전용, 가짜 데이터)
-- storage.objects 행 추가·조회를 실제 정책(RLS)으로 거치게 해서 Storage API 업로드·서명 링크 권한을 흉내 낸다.
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\set VERBOSITY terse

-- 1. 구성
select test_util.expect('bucket private', (select public::text from storage.buckets where id = 'tbm-photos'), 'false');
select test_util.expect('bucket limit', (select file_size_limit::text from storage.buckets where id = 'tbm-photos'), '2097152');
select test_util.expect('bucket mime', (select array_to_string(allowed_mime_types, ',') from storage.buckets where id = 'tbm-photos'), 'image/jpeg');
select test_util.expect('two policies only', (select string_agg(cmd || ':' || policyname, ',' order by policyname) from pg_policies
  where schemaname = 'storage' and tablename = 'objects' and policyname like 'tbm\_photos\_%'), 'INSERT:tbm_photos_insert_pending,SELECT:tbm_photos_select_viewer');
select test_util.expect('anon cannot call helper', has_function_privilege('anon', 'field_pilot_v1.storage_can_upload(text)', 'EXECUTE')::text, 'false');
select test_util.expect('tables still closed', (select count(*)::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'field_pilot_v1' and c.relkind = 'r' and has_table_privilege('authenticated', c.oid, 'SELECT')), '0');

-- 2. 준비: 시험3팀 팀장(T-0050) 오늘 보고와 사진 자리 3개
select test_util.claims('f0000000-0000-0000-0000-000000000050', '90000000-0000-0000-0000-000000000050');
set role authenticated;
select public.tbm_save_plan('{"request_id":"v2-plan","tasks":[{"place":"시험3 구역","content":"사진 시험","members":[]}]}') -> 'report' ->> 'id' as r3 \gset
select public.tbm_photo_prepare(:'r3', 'MORNING', 50000, repeat('1', 64)) as ph1 \gset
select public.tbm_photo_prepare(:'r3', 'MORNING', 50000, repeat('2', 64)) as ph2 \gset
select public.tbm_photo_prepare(:'r3', 'AFTERNOON', 50000, repeat('3', 64)) as ph3 \gset
select (:'ph1'::jsonb) ->> 'path' as path1, (:'ph2'::jsonb) ->> 'path' as path2, (:'ph3'::jsonb) ->> 'path' as path3 \gset

-- 3. 업로드 정책
with i as (insert into storage.objects (bucket_id, name, owner_id) values ('tbm-photos', :'path1', 'f0000000-0000-0000-0000-000000000050') returning 1) select test_util.expect('own pending slot upload', count(*)::text, '1') from i;
select test_util.expect_error('random path refused', $$insert into storage.objects (bucket_id, name) values ('tbm-photos', 'YONGIN_PILOT/x/y.jpg')$$, 'row-level security');
select test_util.expect_error('same path twice refused (no overwrite)', format($q$insert into storage.objects (bucket_id, name) values ('tbm-photos', %L)$q$, :'path1'), 'duplicate key');
select test_util.expect('uploader sees pending file', (select count(*)::text from storage.objects where name = :'path1'), '1');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000025', '90000000-0000-0000-0000-000000000025');
set role authenticated;
select test_util.expect_error('other leader cannot use slot', format($q$insert into storage.objects (bucket_id, name) values ('tbm-photos', %L)$q$, :'path2'), 'row-level security');
select test_util.expect('other leader cannot see pending', (select count(*)::text from storage.objects where name = :'path1'), '0');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000026', '90000000-0000-0000-0000-000000000026');
set role authenticated;
select test_util.expect_error('member cannot upload', format($q$insert into storage.objects (bucket_id, name) values ('tbm-photos', %L)$q$, :'path2'), 'row-level security');
reset role;
set role anon;
select test_util.expect_error('anon cannot upload', format($q$insert into storage.objects (bucket_id, name) values ('tbm-photos', %L)$q$, :'path2'), 'row-level security');
select test_util.expect('anon sees nothing', (select count(*)::text from storage.objects where bucket_id = 'tbm-photos'), '0');
reset role;

-- 4. 확인 후 보기 정책
select test_util.claims('f0000000-0000-0000-0000-000000000050', '90000000-0000-0000-0000-000000000050');
set role authenticated;
select test_util.expect('confirm after upload', (select count(*)::text from jsonb_array_elements(public.tbm_photo_confirm(((:'ph1'::jsonb) ->> 'attachment_id')::uuid) -> 'report' -> 'photos')), '1');
reset role;
select test_util.claims('d0000000-0000-0000-0000-0000000000a2', null);
set role authenticated;
select test_util.expect('site manager sees ready photo', (select count(*)::text from storage.objects where name = :'path1'), '1');
reset role;
select test_util.claims('d0000000-0000-0000-0000-0000000000a1', null);
set role authenticated;
select test_util.expect('admin sees ready photo', (select count(*)::text from storage.objects where name = :'path1'), '1');
select test_util.expect_error('admin cannot upload', format($q$insert into storage.objects (bucket_id, name) values ('tbm-photos', %L)$q$, :'path2'), 'row-level security');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000025', '90000000-0000-0000-0000-000000000025');
set role authenticated;
select test_util.expect('other team leader cannot see', (select count(*)::text from storage.objects where name = :'path1'), '0');
reset role;
select test_util.claims('f0000000-0000-0000-0000-000000000026', '90000000-0000-0000-0000-000000000026');
set role authenticated;
select test_util.expect('member cannot see', (select count(*)::text from storage.objects where name = :'path1'), '0');
reset role;

-- 5. 덮어쓰기·삭제 불가, 만료된 자리·숨긴 사진·확인 끝난 보고·PIN 변경 전
select test_util.claims('f0000000-0000-0000-0000-000000000050', '90000000-0000-0000-0000-000000000050');
set role authenticated;
with u as (update storage.objects set metadata = '{}' where name = :'path1' returning 1) select test_util.expect('no update', count(*)::text, '0') from u;
with d as (delete from storage.objects where name = :'path1' returning 1) select test_util.expect('no delete', count(*)::text, '0') from d;
reset role;
update field_pilot_v1.attachments set created_at = now() - interval '20 minutes' where object_path = :'path2';
set role authenticated;
select test_util.expect_error('expired slot refused', format($q$insert into storage.objects (bucket_id, name) values ('tbm-photos', %L)$q$, :'path2'), 'row-level security');
select test_util.expect('removed', (select count(*)::text from jsonb_array_elements(public.tbm_photo_remove(((:'ph1'::jsonb) ->> 'attachment_id')::uuid) -> 'report' -> 'photos')), '0');
select test_util.expect('removed photo hidden from uploader', (select count(*)::text from storage.objects where name = :'path1'), '0');
reset role;
update personnel_pilot_v1.member_pins set must_change = true where person_id = 'c0000000-0000-0000-0000-000000000050';
set role authenticated;
select test_util.expect_error('pin change required blocks upload', format($q$insert into storage.objects (bucket_id, name) values ('tbm-photos', %L)$q$, :'path3'), 'row-level security');
reset role;
update personnel_pilot_v1.member_pins set must_change = false where person_id = 'c0000000-0000-0000-0000-000000000050';
update field_pilot_v1.daily_reports set status = 'CONFIRMED' where id = :'r3';
set role authenticated;
select test_util.expect_error('confirmed report blocks upload', format($q$insert into storage.objects (bucket_id, name) values ('tbm-photos', %L)$q$, :'path3'), 'row-level security');
reset role;
update field_pilot_v1.daily_reports set status = 'SUBMITTED' where id = :'r3';
set role authenticated;
with i as (insert into storage.objects (bucket_id, name) values ('tbm-photos', :'path3') returning 1) select test_util.expect('upload allowed again', count(*)::text, '1') from i;
reset role;

-- 6. 다른 버킷에는 영향 없음 (정책은 tbm-photos 전용)
insert into storage.buckets (id, name, public) values ('other-test', 'other-test', false);
select test_util.claims('f0000000-0000-0000-0000-000000000050', '90000000-0000-0000-0000-000000000050');
set role authenticated;
select test_util.expect_error('other bucket not opened', $$insert into storage.objects (bucket_id, name) values ('other-test', 'a.jpg')$$, 'row-level security');
reset role;
delete from storage.buckets where id = 'other-test';
select 'field v0.2 tests passed';
