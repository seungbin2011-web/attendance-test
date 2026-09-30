-- 현장 업무 통합 로그인 v0.8 부속 · 팀·소속·팀장 역할 반입 템플릿
-- SQL 버전: personnel_auth v0.8 부속 / 전환 단계: S0-2 / 작성 2026-09-30
-- 사용 시점: 현장 명부를 확인한 뒤. 추측으로 채우지 않는다.
--
-- 이 파일은 두 부분으로 되어 있다.
--   [1] 미리보기 (읽기 전용): 아직 소속이 없는 인원과 명부 팀 값을 보여준다.
--   [2] 반입: 아래 "반입 대상" 목록에 확인된 사람만 적어서 실행한다.
--       목록이 비어 있으면 아무것도 바꾸지 않는다.
--       기존 행은 수정·삭제하지 않는다. 이미 같은 소속·역할이 있으면 건너뛴다.
--       한 건이라도 맞지 않으면 전체를 취소한다. (사용자ID·이름이 모두 일치해야 함)
--
-- 실행 방법: [1]만 먼저 실행해서 확인 → [2]의 목록을 채운 뒤 [2]만 실행

-- ===== [1] 미리보기 (읽기 전용) =====
select
  p.legacy_user_id as 사용자id,
  p.display_name as 이름,
  coalesce(nullif(p.team_name, ''), '(미지정)') as 명부팀,
  p.rank_title as 직급,
  p.employment_status as 재직상태,
  coalesce((select string_agg(coalesce(t.name, '(팀 없음)'), ', ')
            from personnel_pilot_v1.memberships m
            left join personnel_pilot_v1.teams t on t.id = m.team_id
            where m.person_id = p.id and m.valid_to is null), '') as 현재소속,
  case when exists (select 1 from personnel_pilot_v1.people d
                    where d.legacy_user_id = p.legacy_user_id and d.id <> p.id)
       then '중복ID' else '' end as 비고
from personnel_pilot_v1.people p
order by nullif(p.team_name, '') nulls last, p.display_name;

-- ===== [2] 반입 =====
begin;

create temp table membership_targets (
  legacy_user_id text not null,   -- 기존 사용자ID
  display_name text not null,     -- 이름 (중복ID 구분용, 정확히 일치)
  team_code text not null,        -- 예: CONSTRUCTION_2
  team_name text not null,        -- 예: 공사2팀
  team_leader boolean not null default false
) on commit drop;

-- ▼ 확인된 사람만 적는다. (예시는 주석 상태, 실제 명단은 Git에 올리지 않는다)
-- insert into membership_targets values
--   ('YI-0000', '홍길동', 'CONSTRUCTION_2', '공사2팀', false);
-- ▲

do $import$
declare
  v_site uuid;
  r record;
  v_person uuid;
  v_team uuid;
  v_membership uuid;
  v_new_teams int := 0;
  v_new_memberships int := 0;
  v_new_roles int := 0;
begin
  select id into v_site from personnel_pilot_v1.sites where code = 'YONGIN_PILOT';
  if v_site is null then raise exception 'SITE_NOT_FOUND: YONGIN_PILOT'; end if;

  for r in select * from membership_targets loop
    -- 사람: 사용자ID와 이름이 모두 일치하는 정확히 1명
    select id into v_person from personnel_pilot_v1.people
    where legacy_user_id = r.legacy_user_id and display_name = r.display_name;
    if (select count(*) from personnel_pilot_v1.people
        where legacy_user_id = r.legacy_user_id and display_name = r.display_name) <> 1 then
      raise exception 'PERSON_NOT_UNIQUE: % %', r.legacy_user_id, r.display_name;
    end if;
    if (select employment_status from personnel_pilot_v1.people where id = v_person) = 'inactive' then
      raise exception 'INACTIVE_PERSON: %', r.legacy_user_id;
    end if;

    -- 팀: 없으면 추가 (같은 코드에 다른 이름이면 중단)
    select id into v_team from personnel_pilot_v1.teams where site_id = v_site and code = r.team_code;
    if v_team is null then
      insert into personnel_pilot_v1.teams (site_id, code, name) values (v_site, r.team_code, r.team_name)
      returning id into v_team;
      v_new_teams := v_new_teams + 1;
    elsif (select name from personnel_pilot_v1.teams where id = v_team) <> r.team_name then
      raise exception 'TEAM_NAME_MISMATCH: % %', r.team_code, r.team_name;
    end if;

    -- 소속: 이미 같은 팀 활성 소속이 있으면 건너뜀
    select id into v_membership from personnel_pilot_v1.memberships
    where person_id = v_person and site_id = v_site and team_id = v_team and valid_to is null;
    if v_membership is null then
      insert into personnel_pilot_v1.memberships (person_id, site_id, team_id)
      values (v_person, v_site, v_team) returning id into v_membership;
      v_new_memberships := v_new_memberships + 1;
    end if;

    -- 팀장 역할
    if r.team_leader and not exists (
      select 1 from personnel_pilot_v1.role_assignments
      where membership_id = v_membership and role_code = 'TEAM_LEADER' and revoked_at is null) then
      insert into personnel_pilot_v1.role_assignments (membership_id, role_code) values (v_membership, 'TEAM_LEADER');
      v_new_roles := v_new_roles + 1;
    end if;
  end loop;

  raise notice '반입 결과: 팀 % / 소속 % / 팀장 역할 %', v_new_teams, v_new_memberships, v_new_roles;
end $import$;

commit;
