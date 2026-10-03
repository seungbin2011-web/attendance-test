-- 2026년 10월 확정 명단으로 현재 소속·역할 맞추기 (동기화)
-- SQL 버전: personnel_auth v0.10 부속 / 작성 2026-10-03
-- 선행: personnel_auth_v10.sql, personnel_auth_v11.sql 적용 → personnel_roster_v10_check.sql로 미리보기 확인
-- 실행: 아래 "명단" 자리에 확정 명단을 넣은 파일만 Supabase SQL Editor 새 탭에서 단독 실행
--       → 별도 탭에서 personnel_roster_v10_verify.sql
--
-- 하는 일 (한 트랜잭션, 한 줄이라도 맞지 않으면 전체 취소, 다시 실행해도 중복 없음)
--   1) 입력 확인: 역할·팀 이름, 2026-10 기준 숫자(총 53, 팀별, 역할별), 사람 찾기
--      사람은 사용자ID + 이름이 모두 같은 기존 행을 쓴다. 사용자ID를 모르면 이름이 정확히 1명일 때만 쓴다.
--      기존 행이 없으면 새 사람으로 만든다 (내부 UUID. 사용자ID는 있으면 참고로 넣고, 없으면 비워 둔다. 임의 ID를 만들지 않음)
--      로그인 번호(휴대폰 뒤 4자리)는 이 파일에서 다루지 않는다 → personnel_login4_import_template.sql 또는 관리자 화면
--   2) 팀: 코드로 찾고, 없으면 같은 이름(또는 이전 이름)의 팀을 재사용, 그래도 없으면 추가. 표시 이름만 바꾼다.
--   3) 명단 인원: 재직 확인 = active, 명부 팀 글자 = 현재 팀, 현재 소속 1개, 로그인 역할 1개(팀원은 없음)
--      이전 소속·역할은 종료일(valid_to · revoked_at)만 기록한다.
--   4) 명단에 없는 인원: 현재 소속·역할 종료, 재직 확인 = inactive (로그인 차단). 행과 지난 기록은 그대로
--   직급·직무 글자, 이름, 사용자ID, 지난 TBM 보고·배정·사진·이월, 업무계정은 바꾸지 않는다. DELETE 없음.
-- 되돌리기: personnel_roster_v10_rollback.sql (가장 최근 동기화 1회)
begin;

create temp table roster_input on commit drop as
select * from (values
  -- ▼ 명단: ('팀', '역할', '이름', '사용자ID' 또는 null, '직급'(새 인원만) 또는 null, '직무'(새 인원만) 또는 null),
  -- ▲ 실제 명단은 Git에 올리지 않는다
  (null::text, null::text, null::text, null::text, null::text, null::text)
) v(team_name, role, display_name, legacy_user_id, rank_title, job_title)
where display_name is not null;

do $sync$
declare
  c_site_code constant text := 'YONGIN_PILOT';
  c_tag constant text := 'roster_sync_2026_10';
  c_actor constant uuid := '00000000-0000-0000-0000-000000000000';
  c_teams constant jsonb := '[
    {"code": "CONSTRUCTION_1", "name": "1팀", "previous": "공사1팀"},
    {"code": "CONSTRUCTION_2", "name": "2팀", "previous": "공사2팀"},
    {"code": "CONSTRUCTION_3", "name": "3팀", "previous": "공사3팀"},
    {"code": "MATERIAL", "name": "자재팀", "previous": null},
    {"code": "SITE_MANAGEMENT", "name": "현장·관리", "previous": null}]';
  c_expect constant jsonb := '{"total": 53,
    "teams": {"1팀": 15, "2팀": 23, "3팀": 9, "자재팀": 1, "현장·관리": 5},
    "roles": {"TEAM_LEADER": 13, "MEMBER": 35, "SITE_MANAGER": 4, "ADMIN": 1}}';
  v_site uuid;
  v_now timestamptz := now();
  v_errors text[] := '{}';
  t jsonb;
  r record;
  m record;
  p record;
  v_person uuid;
  v_team uuid;
  v_keep uuid;
  v_code text;
  v_n int;
  v_rows int;
  v_new_people int := 0;
  v_new_teams int := 0;
  v_renamed_teams int := 0;
  v_people_updated int := 0;
  v_deactivated int := 0;
  v_new_memberships int := 0;
  v_ended_memberships int := 0;
  v_new_roles int := 0;
  v_revoked_roles int := 0;
begin
  select id into v_site from personnel_pilot_v1.sites where code = c_site_code;
  if v_site is null then raise exception 'SITE_NOT_FOUND: %', c_site_code; end if;

  -- 1) 입력 확인
  select count(*) into v_n from roster_input;
  if v_n <> (c_expect ->> 'total')::int then
    v_errors := v_errors || format('총원 %s명 (기준 %s명)', v_n, c_expect ->> 'total');
  end if;
  for r in select role, count(*) n from roster_input group by role loop
    if not (c_expect -> 'roles') ? coalesce(r.role, '') then
      v_errors := v_errors || format('알 수 없는 역할 %s', r.role);
    elsif r.n <> (c_expect -> 'roles' ->> r.role)::int then
      v_errors := v_errors || format('%s %s명 (기준 %s명)', r.role, r.n, c_expect -> 'roles' ->> r.role);
    end if;
  end loop;
  for r in select team_name, count(*) n from roster_input group by team_name loop
    if not (c_expect -> 'teams') ? coalesce(r.team_name, '') then
      v_errors := v_errors || format('알 수 없는 팀 %s', r.team_name);
    elsif r.n <> (c_expect -> 'teams' ->> r.team_name)::int then
      v_errors := v_errors || format('%s %s명 (기준 %s명)', r.team_name, r.n, c_expect -> 'teams' ->> r.team_name);
    end if;
  end loop;
  for r in select display_name, count(*) n from roster_input group by display_name, legacy_user_id having count(*) > 1 loop
    v_errors := v_errors || format('명단 중복 %s', r.display_name);
  end loop;

  -- 사람 찾기
  create temp table roster_resolved (display_name text, legacy_user_id text, team_name text, role text,
    rank_title text, job_title text, person_id uuid, is_new boolean) on commit drop;
  for r in select * from roster_input order by team_name, role, display_name loop
    v_person := null;
    if r.legacy_user_id is not null then
      select count(*) into v_n from personnel_pilot_v1.people where legacy_user_id = r.legacy_user_id and display_name = r.display_name;
      if v_n = 1 then
        select id into v_person from personnel_pilot_v1.people where legacy_user_id = r.legacy_user_id and display_name = r.display_name;
      elsif v_n > 1 then
        v_errors := v_errors || format('AMBIGUOUS %s %s', r.legacy_user_id, r.display_name);
      elsif exists (select 1 from personnel_pilot_v1.people where legacy_user_id = r.legacy_user_id) then
        v_errors := v_errors || format('ID_NAME_MISMATCH %s %s (같은 ID의 다른 이름이 있음, 합치지 않음)', r.legacy_user_id, r.display_name);
      end if;
    else
      select count(*) into v_n from personnel_pilot_v1.people where display_name = r.display_name;
      if v_n = 1 then
        select id into v_person from personnel_pilot_v1.people where display_name = r.display_name;
      elsif v_n > 1 then
        v_errors := v_errors || format('AMBIGUOUS_NAME %s (같은 이름이 여러 명, 사용자ID로 구분 필요)', r.display_name);
      elsif (select is_nullable from information_schema.columns
             where table_schema = 'personnel_pilot_v1' and table_name = 'people' and column_name = 'legacy_user_id') <> 'YES' then
        v_errors := v_errors || format('사용자ID 없는 새 인원 %s: personnel_auth_v11.sql을 먼저 적용', r.display_name);
      end if;
    end if;
    insert into roster_resolved values (r.display_name, r.legacy_user_id, r.team_name, r.role, r.rank_title, r.job_title,
      v_person, v_person is null);
  end loop;
  for r in select person_id from roster_resolved where person_id is not null group by person_id having count(*) > 1 loop
    v_errors := v_errors || format('한 사람이 두 줄 %s', r.person_id);
  end loop;

  if cardinality(v_errors) > 0 then
    raise exception 'ROSTER_NOT_READY: %', array_to_string(v_errors, ' / ');
  end if;

  -- 2) 팀: 코드 → 같은 이름·이전 이름 → 추가
  for t in select * from jsonb_array_elements(c_teams) loop
    select id into v_team from personnel_pilot_v1.teams where site_id = v_site and code = t ->> 'code';
    if v_team is null then
      select count(*) into v_n from personnel_pilot_v1.teams
      where site_id = v_site and name in (t ->> 'name', coalesce(t ->> 'previous', t ->> 'name'));
      if v_n > 1 then raise exception 'TEAM_AMBIGUOUS: %', t ->> 'name'; end if;
      select id into v_team from personnel_pilot_v1.teams
      where site_id = v_site and name in (t ->> 'name', coalesce(t ->> 'previous', t ->> 'name'));
    end if;
    if v_team is null then
      insert into personnel_pilot_v1.teams (site_id, code, name) values (v_site, t ->> 'code', t ->> 'name') returning id into v_team;
      v_new_teams := v_new_teams + 1;
    elsif (select name from personnel_pilot_v1.teams where id = v_team) <> t ->> 'name' then
      update personnel_pilot_v1.teams set name = t ->> 'name' where id = v_team;
      v_renamed_teams := v_renamed_teams + 1;
    end if;
  end loop;
  if exists (select 1 from personnel_pilot_v1.teams where site_id = v_site group by name having count(*) > 1) then
    raise exception 'TEAM_NAME_DUPLICATE: 같은 이름의 팀이 둘 이상';
  end if;

  -- 3) 명단 인원
  for r in select * from roster_resolved order by team_name, role, display_name loop
    select id into v_team from personnel_pilot_v1.teams where site_id = v_site and name = r.team_name;
    if r.is_new then
      insert into personnel_pilot_v1.people (legacy_user_id, display_name, rank_title, job_title, team_name, employment_status, source_system)
      values (r.legacy_user_id, r.display_name, r.rank_title, r.job_title, r.team_name, 'active', c_tag)
      returning id into v_person;
      v_new_people := v_new_people + 1;
    else
      v_person := r.person_id;
      select * into p from personnel_pilot_v1.people where id = v_person for update;
      if p.employment_status <> 'active' or p.team_name is distinct from r.team_name then
        insert into personnel_pilot_v1.person_edits (person_id, actor_id, actor_login, before_data, after_data)
        select v_person, c_actor, c_tag, to_jsonb(p),
               to_jsonb(p) || jsonb_build_object('employment_status', 'active', 'team_name', r.team_name);
        update personnel_pilot_v1.people
        set employment_status = 'active', team_name = r.team_name, version = version + 1, updated_at = clock_timestamp()
        where id = v_person;
        v_people_updated := v_people_updated + 1;
      end if;
    end if;

    -- 현재 소속: 목표 팀 하나만 남김
    v_keep := null;
    for m in select * from personnel_pilot_v1.memberships
             where person_id = v_person and site_id = v_site and valid_to is null order by valid_from loop
      if v_keep is null and m.team_id = v_team then
        v_keep := m.id;
      else
        update personnel_pilot_v1.role_assignments set revoked_at = v_now where membership_id = m.id and revoked_at is null;
        get diagnostics v_rows = row_count; v_revoked_roles := v_revoked_roles + v_rows;
        update personnel_pilot_v1.memberships set valid_to = v_now where id = m.id;
        v_ended_memberships := v_ended_memberships + 1;
      end if;
    end loop;
    if v_keep is null then
      insert into personnel_pilot_v1.memberships (person_id, site_id, team_id) values (v_person, v_site, v_team)
      returning id into v_keep;
      v_new_memberships := v_new_memberships + 1;
    end if;

    -- 현재 역할: 정확히 하나 (팀원은 없음). 관리자는 기존 역할 코드 ADMIN_DEPT
    v_code := case r.role when 'TEAM_LEADER' then 'TEAM_LEADER' when 'SITE_MANAGER' then 'SITE_MANAGER'
                          when 'ADMIN' then 'ADMIN_DEPT' end;
    update personnel_pilot_v1.role_assignments set revoked_at = v_now
    where membership_id = v_keep and revoked_at is null and role_code is distinct from v_code;
    get diagnostics v_rows = row_count; v_revoked_roles := v_revoked_roles + v_rows;
    if v_code is not null and not exists (select 1 from personnel_pilot_v1.role_assignments
                                          where membership_id = v_keep and role_code = v_code and revoked_at is null) then
      insert into personnel_pilot_v1.role_assignments (membership_id, role_code) values (v_keep, v_code);
      v_new_roles := v_new_roles + 1;
    end if;
  end loop;

  -- 4) 명단에 없는 인원: 소속·역할 종료, 로그인 차단 (행·기록 유지)
  for p in select * from personnel_pilot_v1.people
           where id not in (select coalesce(person_id, '00000000-0000-0000-0000-000000000000') from roster_resolved)
             and id not in (select id from personnel_pilot_v1.people where source_system = c_tag and created_at = v_now)
           for update loop
    for m in select * from personnel_pilot_v1.memberships where person_id = p.id and site_id = v_site and valid_to is null loop
      update personnel_pilot_v1.role_assignments set revoked_at = v_now where membership_id = m.id and revoked_at is null;
      get diagnostics v_rows = row_count; v_revoked_roles := v_revoked_roles + v_rows;
      update personnel_pilot_v1.memberships set valid_to = v_now where id = m.id;
      v_ended_memberships := v_ended_memberships + 1;
    end loop;
    if p.employment_status <> 'inactive' then
      insert into personnel_pilot_v1.person_edits (person_id, actor_id, actor_login, before_data, after_data)
      select p.id, c_actor, c_tag, to_jsonb(p), to_jsonb(p) || jsonb_build_object('employment_status', 'inactive');
      update personnel_pilot_v1.people set employment_status = 'inactive', version = version + 1, updated_at = clock_timestamp()
      where id = p.id;
      v_deactivated := v_deactivated + 1;
    end if;
  end loop;

  raise notice '동기화 결과: 새 인원 % / 정보 갱신 % / 비활성 % / 새 팀 % / 팀 이름 변경 % / 새 소속 % / 종료 소속 % / 새 역할 % / 종료 역할 %',
    v_new_people, v_people_updated, v_deactivated, v_new_teams, v_renamed_teams, v_new_memberships, v_ended_memberships, v_new_roles, v_revoked_roles;
end $sync$;

commit;
