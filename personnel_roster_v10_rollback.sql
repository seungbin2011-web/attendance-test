-- 2026년 10월 명단 동기화 되돌리기 (가장 최근 동기화 1회)
-- SQL 버전: personnel_auth v0.10 부속 / 작성 2026-10-03
-- 실행: Supabase SQL Editor 새 탭에서 이 파일만 단독 실행 (명단 입력 없음) → 별도 탭에서 personnel_roles_v10_inspect_readonly.sql
-- 기준: 동기화가 남긴 표시 (사람 정보 변경 이력 actor_login = 'roster_sync_2026_10', 그 트랜잭션 시각)
--   1) 그 시각에 새로 준 역할·소속 → 종료
--   2) 그 시각에 종료한 소속·역할 → 다시 현재로
--   3) 재직 확인·명부 팀 글자 → 변경 전 값으로 (이력에 남김)
--   4) 그 시각에 새로 만든 인원 → inactive (행 삭제 없음)
--   5) 팀 표시 이름 → 이전 이름 (공사1·2·3팀), 새로 만든 팀 행은 남김 (현재 소속 0명)
-- DELETE 없음. 두 번 실행해도 한 번만 되돌린다.
begin;

do $rollback$
declare
  c_tag constant text := 'roster_sync_2026_10';
  c_actor constant uuid := '00000000-0000-0000-0000-000000000000';
  c_teams constant jsonb := '[
    {"code": "CONSTRUCTION_1", "name": "1팀", "previous": "공사1팀"},
    {"code": "CONSTRUCTION_2", "name": "2팀", "previous": "공사2팀"},
    {"code": "CONSTRUCTION_3", "name": "3팀", "previous": "공사3팀"}]';
  v_t timestamptz;
  v_now timestamptz := now();
  e record;
  p record;
  t jsonb;
  v_rows int;
begin
  select max(edited_at) into v_t from personnel_pilot_v1.person_edits where actor_login = c_tag;
  if v_t is null then raise exception 'NO_SYNC_FOUND: 되돌릴 동기화 기록이 없음'; end if;
  if exists (select 1 from personnel_pilot_v1.person_edits where actor_login = c_tag || '_rollback' and edited_at > v_t) then
    raise notice '이미 되돌린 동기화(%)입니다. 바꾼 것 없음', v_t;
    return;
  end if;

  -- 1) 그 시각에 새로 준 역할·소속 종료
  update personnel_pilot_v1.role_assignments set revoked_at = v_now where granted_at = v_t and revoked_at is null;
  update personnel_pilot_v1.role_assignments r set revoked_at = v_now
  from personnel_pilot_v1.memberships m
  where m.id = r.membership_id and m.valid_from = v_t and m.valid_to is null and r.revoked_at is null;
  update personnel_pilot_v1.memberships set valid_to = v_now where valid_from = v_t and valid_to is null;

  -- 2) 그 시각에 종료한 소속·역할을 다시 현재로
  update personnel_pilot_v1.memberships set valid_to = null where valid_to = v_t;
  update personnel_pilot_v1.role_assignments set revoked_at = null where revoked_at = v_t;

  -- 3) 사람 정보: 재직 확인·명부 팀 글자만 변경 전 값으로
  for e in select * from personnel_pilot_v1.person_edits where actor_login = c_tag and edited_at = v_t order by id loop
    select * into p from personnel_pilot_v1.people where id = e.person_id for update;
    insert into personnel_pilot_v1.person_edits (person_id, actor_id, actor_login, before_data, after_data)
    select p.id, c_actor, c_tag || '_rollback', to_jsonb(p),
           to_jsonb(p) || jsonb_build_object('employment_status', e.before_data ->> 'employment_status', 'team_name', e.before_data ->> 'team_name');
    update personnel_pilot_v1.people
    set employment_status = e.before_data ->> 'employment_status', team_name = e.before_data ->> 'team_name',
        version = version + 1, updated_at = clock_timestamp()
    where id = p.id;
  end loop;

  -- 4) 그 시각에 새로 만든 인원은 로그인 차단
  for p in select * from personnel_pilot_v1.people where source_system = c_tag and created_at = v_t and employment_status <> 'inactive' for update loop
    insert into personnel_pilot_v1.person_edits (person_id, actor_id, actor_login, before_data, after_data)
    select p.id, c_actor, c_tag || '_rollback', to_jsonb(p), to_jsonb(p) || jsonb_build_object('employment_status', 'inactive');
    update personnel_pilot_v1.people set employment_status = 'inactive', version = version + 1, updated_at = clock_timestamp() where id = p.id;
  end loop;

  -- 5) 팀 표시 이름 되돌리기
  for t in select * from jsonb_array_elements(c_teams) loop
    update personnel_pilot_v1.teams set name = t ->> 'previous'
    where code = t ->> 'code' and name = t ->> 'name'
      and not exists (select 1 from personnel_pilot_v1.teams o where o.name = t ->> 'previous');
  end loop;

  raise notice '되돌리기 완료: 동기화 시각 %', v_t;
end $rollback$;

commit;
