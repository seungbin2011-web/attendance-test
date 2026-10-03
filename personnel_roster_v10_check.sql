-- 2026년 10월 확정 명단 비교 미리보기 (읽기 전용: SELECT만, 아무것도 바꾸지 않음)
-- SQL 버전: personnel_auth v0.10 부속 / 작성 2026-10-03
-- 실행: 아래 "명단" 자리에 확정 명단을 넣은 파일을 Supabase SQL Editor 새 탭에서 실행 → 결과(check_roster) 전달
-- 결과
--   ready: 동기화를 실행해도 되는지 (입력 숫자·사람 찾기 모두 정상일 때 true)
--   input: 명단 숫자와 2026-10 기준 비교 / resolve: 기존 인원 연결, 새 인원, 사용자ID 필요, 충돌
--   teams_plan: 팀 이름 변경·추가 / changes: 팀 이동·역할 변경·비활성 대상
--   before: 바뀌는 사람의 현재 상태 (되돌리기 확인용으로 보관)
with roster as (
  select * from (values
    -- ▼ 명단: ('팀', '역할', '이름', '사용자ID' 또는 null, '직급'(새 인원만) 또는 null, '직무'(새 인원만) 또는 null),
    -- ▲ 실제 명단은 Git에 올리지 않는다
    (null::text, null::text, null::text, null::text, null::text, null::text)
  ) v(team_name, role, display_name, legacy_user_id, rank_title, job_title)
  where display_name is not null
), expected as (
  select '{"total": 53, "teams": {"1팀": 15, "2팀": 23, "3팀": 9, "자재팀": 1, "현장·관리": 5},
           "roles": {"TEAM_LEADER": 13, "MEMBER": 35, "SITE_MANAGER": 4, "ADMIN": 1}}'::jsonb as j
), specs as (
  select * from jsonb_to_recordset('[
    {"code": "CONSTRUCTION_1", "name": "1팀", "previous": "공사1팀"},
    {"code": "CONSTRUCTION_2", "name": "2팀", "previous": "공사2팀"},
    {"code": "CONSTRUCTION_3", "name": "3팀", "previous": "공사3팀"},
    {"code": "MATERIAL", "name": "자재팀", "previous": null},
    {"code": "SITE_MANAGEMENT", "name": "현장·관리", "previous": null}]'::jsonb) as s(code text, name text, previous text)
), cur as (
  select p.id, p.display_name, p.legacy_user_id, p.employment_status, p.team_name, p.rank_title, p.job_title,
    coalesce((select string_agg(coalesce(s.name, t.name, '(현장 소속·팀 없음)'), ',' order by t.name)
              from personnel_pilot_v1.memberships m
              left join personnel_pilot_v1.teams t on t.id = m.team_id
              left join specs s on s.code = t.code
              where m.person_id = p.id and m.valid_to is null), '') as team_now,
    coalesce((select string_agg(distinct r.role_code, ',')
              from personnel_pilot_v1.memberships m
              join personnel_pilot_v1.role_assignments r on r.membership_id = m.id and r.revoked_at is null
              where m.person_id = p.id and m.valid_to is null), '') as roles_now
  from personnel_pilot_v1.people p
), res as (
  select r.*,
    (select count(*) from personnel_pilot_v1.people x where x.legacy_user_id = r.legacy_user_id and x.display_name = r.display_name) as n_idname,
    (select count(*) from personnel_pilot_v1.people x where x.legacy_user_id = r.legacy_user_id) as n_id,
    (select count(*) from personnel_pilot_v1.people x where x.display_name = r.display_name) as n_name,
    case when r.legacy_user_id is not null
         then (select x.id from personnel_pilot_v1.people x where x.legacy_user_id = r.legacy_user_id and x.display_name = r.display_name limit 1)
         else (select x.id from personnel_pilot_v1.people x where x.display_name = r.display_name limit 1) end as person_id,
    case r.role when 'TEAM_LEADER' then 'TEAM_LEADER' when 'SITE_MANAGER' then 'SITE_MANAGER' when 'ADMIN' then 'ADMIN_DEPT' else '' end as role_code
  from roster r
), res2 as (
  select res.*, case
    when legacy_user_id is not null and n_idname = 1 then 'MATCH'
    when legacy_user_id is not null and n_idname > 1 then 'AMBIGUOUS'
    when legacy_user_id is not null and n_id > 0 then 'ID_NAME_MISMATCH'
    when legacy_user_id is not null then 'NEW_WITH_ID'
    when n_name = 1 then 'MATCH'
    when n_name > 1 then 'AMBIGUOUS_NAME'
    else 'NEEDS_ID' end as status
  from res
), matched as (
  select r.display_name, r.legacy_user_id as roster_id, r.team_name as team_target, r.role, r.role_code,
         c.id, c.employment_status, c.team_name, c.team_now, c.roles_now
  from res2 r join cur c on c.id = r.person_id where r.status = 'MATCH'
), input_check as (
  select array_remove(array[
      case when (select count(*) from roster) <> (e.j ->> 'total')::int then format('총원 %s명 (기준 %s명)', (select count(*) from roster), e.j ->> 'total') end]
    || coalesce((select array_agg(format('%s %s명 (기준 %s명)', k, coalesce(n, 0), e.j -> 'teams' ->> k))
                 from jsonb_object_keys(e.j -> 'teams') k
                 left join (select team_name, count(*) n from roster group by 1) x on x.team_name = k
                 where coalesce(n, 0) <> (e.j -> 'teams' ->> k)::int), '{}')
    || coalesce((select array_agg(format('%s %s명 (기준 %s명)', k, coalesce(n, 0), e.j -> 'roles' ->> k))
                 from jsonb_object_keys(e.j -> 'roles') k
                 left join (select role, count(*) n from roster group by 1) x on x.role = k
                 where coalesce(n, 0) <> (e.j -> 'roles' ->> k)::int), '{}')
    || coalesce((select array_agg(format('알 수 없는 팀·역할 %s / %s', team_name, role)) from roster
                 where not (e.j -> 'teams') ? coalesce(team_name, '') or not (e.j -> 'roles') ? coalesce(role, '')), '{}')
    || coalesce((select array_agg(format('명단 중복 %s', display_name)) from (
                 select display_name from roster group by display_name, legacy_user_id having count(*) > 1) d), '{}')
    || coalesce((select array_agg(format('한 사람이 두 줄 %s', person_id)) from (
                 select person_id from res2 where status = 'MATCH' group by person_id having count(*) > 1) d), '{}'),
    null) as problems
  from expected e
)
select jsonb_pretty(jsonb_build_object(
  'ready', (select cardinality(problems) = 0 from input_check) and not exists (select 1 from res2 where status not in ('MATCH', 'NEW_WITH_ID')),
  'input', jsonb_build_object(
    'total', (select count(*) from roster),
    'teams', (select coalesce(jsonb_object_agg(team_name, n), '{}'::jsonb) from (select team_name, count(*) n from roster group by 1) x),
    'roles', (select coalesce(jsonb_object_agg(role, n), '{}'::jsonb) from (select role, count(*) n from roster group by 1) x),
    'problems', (select to_jsonb(problems) from input_check)),
  'resolve', jsonb_build_object(
    'matched', (select count(*) from res2 where status = 'MATCH'),
    'new_with_id', (select coalesce(jsonb_agg(display_name || ' ' || legacy_user_id || ' → ' || team_name order by team_name, display_name), '[]'::jsonb) from res2 where status = 'NEW_WITH_ID'),
    'needs_id', (select coalesce(jsonb_agg(display_name || ' → ' || team_name order by team_name, display_name), '[]'::jsonb) from res2 where status = 'NEEDS_ID'),
    'conflicts', (select coalesce(jsonb_agg(status || ' ' || display_name || coalesce(' ' || legacy_user_id, '') order by display_name), '[]'::jsonb)
                  from res2 where status in ('AMBIGUOUS', 'AMBIGUOUS_NAME', 'ID_NAME_MISMATCH'))),
  'teams_plan', (select jsonb_agg(jsonb_build_object('code', s.code, 'name', s.name,
      'action', case when t.id is null and o.id is null then '추가'
                     when coalesce(t.name, o.name) = s.name then '그대로'
                     else '이름 변경 ' || coalesce(t.name, o.name) || ' → ' || s.name end) order by s.name)
    from specs s
    left join personnel_pilot_v1.teams t on t.code = s.code
    left join personnel_pilot_v1.teams o on t.id is null and o.name in (s.name, coalesce(s.previous, s.name))),
  'changes', jsonb_build_object(
    'team_moves', (select coalesce(jsonb_agg(display_name || ': ' || coalesce(nullif(team_now, ''), '팀 없음') || ' → ' || team_target order by team_target, display_name), '[]'::jsonb)
                   from matched where team_now is distinct from team_target),
    'role_changes', (select coalesce(jsonb_agg(display_name || ': ' || coalesce(nullif(roles_now, ''), '역할 없음') || ' → ' || coalesce(nullif(role_code, ''), '팀원') order by display_name), '[]'::jsonb)
                     from matched where roles_now is distinct from role_code),
    'deactivate', (select coalesce(jsonb_agg(c.display_name || ' ' || c.legacy_user_id || ' (' || coalesce(nullif(c.team_name, ''), '팀 없음') || ')' order by c.display_name), '[]'::jsonb)
                   from cur c where c.employment_status <> 'inactive' and c.id not in (select id from matched))),
  'before', (select coalesce(jsonb_agg(jsonb_build_object('name', c.display_name, 'user_id', c.legacy_user_id, 'status', c.employment_status,
                 'roster_team', c.team_name, 'team_now', c.team_now, 'roles_now', c.roles_now) order by c.display_name), '[]'::jsonb)
             from cur c
             where c.id not in (select id from matched)
                or c.id in (select id from matched where team_now is distinct from team_target or roles_now is distinct from role_code
                                                     or employment_status <> 'active' or team_name is distinct from team_target))
)) as check_roster;
