-- 인원 소속·역할 변경 템플릿 (현재 상태 지정형)
-- SQL 버전: personnel_auth v0.10 부속 / 작성 2026-10-03
-- 쓰는 때: 신규 투입, 팀 이동, 팀원↔팀장 변경, 팀장·소장 교체, 현장 이탈
--          화면 코드는 고치지 않는다. 이 표만 바꾸면 로그인 화면·TBM 인원 후보·소장 현황이 따라간다.
--
-- 순서
--   1) personnel_roles_v10_inspect_readonly.sql로 현재 상태 확인 (별도 탭)
--   2) 아래 "변경 대상"에 확인된 사람만 적고 이 파일만 단독 실행
--   3) 1)을 다시 별도 탭에서 실행해 결과 확인
--
-- 한 줄 = 그 사람의 "앞으로의 현재 상태"
--   role: MEMBER(팀원) / TEAM_LEADER(팀장, 팀 필수) / SITE_MANAGER(현장관리) / ADMIN(관리자) / LEAVE(현장 이탈: 현재 소속 종료)
--   team_code·team_name: 현재 팀 (2026-10 기준 예: CONSTRUCTION_1 1팀, CONSTRUCTION_2 2팀, CONSTRUCTION_3 3팀, MATERIAL 자재팀,
--                        SITE_MANAGEMENT 현장·관리). 현장관리·관리자는 null 가능 (현장 소속만), LEAVE는 null
--   팀을 지정하면 명부 팀 글자(people.team_name)도 같은 이름으로 맞춘다 (변경 이력에 남김)
--
-- 지켜지는 것
--   * 삭제 없음. 이전 소속·역할은 종료일(valid_to·revoked_at)만 기록해 이력으로 남는다.
--   * 지난 TBM 보고·인원 배정·사진은 당시 팀 기준 그대로 남는다. (보고는 팀 ID·인원 ID로 저장됨)
--   * 사용자ID와 이름이 모두 맞는 정확히 1명만 바꾼다. 한 줄이라도 맞지 않으면 전체 취소.
--   * 명단이 비어 있으면 아무것도 바꾸지 않는다. 실제 명단은 Git에 올리지 않는다.
--   * 관리자는 기존 역할 코드 ADMIN_DEPT로 저장한다. 자재(MATERIAL_STAFF) 역할은 유지 소속에서 건드리지 않는다.
--   * 퇴사는 기존 인원 편집 화면에서 재직상태를 "비활성"으로 바꾸면 로그인이 막힌다. (필요하면 LEAVE도 함께)
begin;

create temp table role_targets (
  legacy_user_id text not null,   -- 기존 사용자ID
  display_name text not null,     -- 이름 (정확히 일치)
  team_code text,                 -- 예: CONSTRUCTION_2 (teams.code)
  team_name text,                 -- 예: 공사2팀 (teams.name, 새 팀이면 이 이름으로 추가)
  role text not null              -- MEMBER / TEAM_LEADER / SITE_MANAGER / ADMIN / LEAVE
) on commit drop;

-- ▼ 변경 대상 (예시는 주석 상태)
-- insert into role_targets values
--   ('YI-0000', '홍길동', 'CONSTRUCTION_1', '공사1팀', 'TEAM_LEADER'),
--   ('YI-0001', '김철수', null, null, 'SITE_MANAGER');
-- ▲

do $change$
declare
  c_site_code constant text := 'YONGIN_PILOT';
  c_login_roles constant text[] := array['TEAM_LEADER', 'SITE_MANAGER', 'ADMIN_DEPT'];
  v_code text;
  pp record;
  v_site uuid;
  r record;
  m record;
  v_person uuid;
  v_team uuid;
  v_keep uuid;
  v_now timestamptz;
  v_new_teams int := 0;
  v_new_memberships int := 0;
  v_ended_memberships int := 0;
  v_new_roles int := 0;
  v_revoked_roles int := 0;
  v_rows int;
begin
  select id into v_site from personnel_pilot_v1.sites where code = c_site_code;
  if v_site is null then raise exception 'SITE_NOT_FOUND: %', c_site_code; end if;

  if exists (select 1 from role_targets group by legacy_user_id, display_name having count(*) > 1) then
    raise exception 'DUPLICATE_TARGET: 같은 사람이 두 줄 이상 있음';
  end if;

  for r in select * from role_targets loop
    if r.role not in ('MEMBER', 'TEAM_LEADER', 'SITE_MANAGER', 'ADMIN', 'LEAVE') then
      raise exception 'INVALID_ROLE: % %', r.legacy_user_id, r.role;
    end if;
    if r.role = 'TEAM_LEADER' and r.team_code is null then
      raise exception 'TEAM_REQUIRED: 팀장은 팀이 필요함 %', r.legacy_user_id;
    end if;
    if r.role = 'LEAVE' and r.team_code is not null then
      raise exception 'TEAM_NOT_ALLOWED: LEAVE는 팀을 비움 %', r.legacy_user_id;
    end if;
    if (r.team_code is null) <> (r.team_name is null) then
      raise exception 'TEAM_INCOMPLETE: team_code와 team_name을 함께 적음 %', r.legacy_user_id;
    end if;

    -- 사람: 사용자ID와 이름이 모두 일치하는 정확히 1명
    if (select count(*) from personnel_pilot_v1.people
        where legacy_user_id = r.legacy_user_id and display_name = r.display_name) <> 1 then
      raise exception 'PERSON_NOT_UNIQUE: % %', r.legacy_user_id, r.display_name;
    end if;
    select id into v_person from personnel_pilot_v1.people
    where legacy_user_id = r.legacy_user_id and display_name = r.display_name;
    if r.role <> 'LEAVE' and (select employment_status from personnel_pilot_v1.people where id = v_person) = 'inactive' then
      raise exception 'INACTIVE_PERSON: %', r.legacy_user_id;
    end if;

    -- 팀: 없으면 추가 (같은 코드에 다른 이름이면 중단)
    v_team := null;
    if r.team_code is not null then
      select id into v_team from personnel_pilot_v1.teams where site_id = v_site and code = r.team_code;
      if v_team is null then
        insert into personnel_pilot_v1.teams (site_id, code, name) values (v_site, r.team_code, r.team_name)
        returning id into v_team;
        v_new_teams := v_new_teams + 1;
      elsif (select name from personnel_pilot_v1.teams where id = v_team) <> r.team_name then
        raise exception 'TEAM_NAME_MISMATCH: % %', r.team_code, r.team_name;
      end if;
    end if;

    -- 소속: 지정한 소속 하나만 남기고 이 현장의 다른 현재 소속은 종료 (역할도 함께 종료)
    v_keep := null;
    for m in select * from personnel_pilot_v1.memberships
             where person_id = v_person and site_id = v_site and valid_to is null loop
      if r.role <> 'LEAVE' and v_keep is null and m.team_id is not distinct from v_team then
        v_keep := m.id;
      else
        v_now := clock_timestamp();
        update personnel_pilot_v1.role_assignments set revoked_at = v_now
        where membership_id = m.id and revoked_at is null;
        get diagnostics v_rows = row_count;
        v_revoked_roles := v_revoked_roles + v_rows;
        update personnel_pilot_v1.memberships set valid_to = v_now where id = m.id;
        v_ended_memberships := v_ended_memberships + 1;
      end if;
    end loop;
    if r.role = 'LEAVE' then continue; end if;
    -- 명부 팀 글자도 현재 팀 이름으로 (변경 이력)
    if r.team_name is not null then
      select * into pp from personnel_pilot_v1.people where id = v_person for update;
      if pp.team_name is distinct from r.team_name then
        insert into personnel_pilot_v1.person_edits (person_id, actor_id, actor_login, before_data, after_data)
        select v_person, '00000000-0000-0000-0000-000000000000', 'roles_change_template', to_jsonb(pp), to_jsonb(pp) || jsonb_build_object('team_name', r.team_name);
        update personnel_pilot_v1.people set team_name = r.team_name, version = version + 1, updated_at = clock_timestamp() where id = v_person;
      end if;
    end if;
    if v_keep is null then
      insert into personnel_pilot_v1.memberships (person_id, site_id, team_id)
      values (v_person, v_site, v_team) returning id into v_keep;
      v_new_memberships := v_new_memberships + 1;
    end if;

    -- 역할: 로그인 역할(팀장·현장관리·관리자)은 지정한 것만 남긴다
    v_code := case r.role when 'ADMIN' then 'ADMIN_DEPT' else r.role end;
    update personnel_pilot_v1.role_assignments set revoked_at = clock_timestamp()
    where membership_id = v_keep and revoked_at is null
      and role_code = any (c_login_roles) and role_code <> v_code;
    get diagnostics v_rows = row_count;
    v_revoked_roles := v_revoked_roles + v_rows;
    if v_code = any (c_login_roles) and not exists (
        select 1 from personnel_pilot_v1.role_assignments
        where membership_id = v_keep and role_code = v_code and revoked_at is null) then
      insert into personnel_pilot_v1.role_assignments (membership_id, role_code) values (v_keep, v_code);
      v_new_roles := v_new_roles + 1;
    end if;
  end loop;

  raise notice '변경 결과: 새 팀 % / 새 소속 % / 종료 소속 % / 새 역할 % / 종료 역할 %',
    v_new_teams, v_new_memberships, v_ended_memberships, v_new_roles, v_revoked_roles;
end $change$;

commit;
