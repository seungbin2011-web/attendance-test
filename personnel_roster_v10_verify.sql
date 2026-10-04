-- 2026년 10월 확정 명단 적용 후 검증 (읽기 전용: SELECT만, 별도 탭에서 실행)
-- SQL 버전: personnel_auth v0.10 부속 / 작성 2026-10-03
-- ok = true 일 때만 성공. 숫자(총 53, 팀별, 역할별, 미지정 0)와, 명단을 넣었으면 사람별 팀·역할까지 비교한다.
-- 비활성 인원은 현재 소속·현재 역할이 없어야 하고, 명단을 넣었으면 명단 밖 현재 인원이 0명이어야 한다.
-- 역할 판정은 로그인과 같은 기준: 현재 소속(valid_to 없음) + 현재 역할(revoked_at 없음). 관리자 = ADMIN_DEPT
with roster as (
  select * from (values
    -- ▼ 명단 (선택): ('팀', '역할', '이름', '사용자ID' 또는 null, null, null),
    -- ▲ 실제 명단은 Git에 올리지 않는다
    (null::text, null::text, null::text, null::text, null::text, null::text)
  ) v(team_name, role, display_name, legacy_user_id, rank_title, job_title)
  where display_name is not null
), expected as (
  select '{"total": 53, "teams": {"1팀": 15, "2팀": 23, "3팀": 9, "자재팀": 1, "현장·관리": 5},
           "roles": {"TEAM_LEADER": 13, "MEMBER": 35, "SITE_MANAGER": 4, "ADMIN": 1}}'::jsonb as j
), act as (
  select p.id, p.display_name, p.legacy_user_id,
    (select count(*) from personnel_pilot_v1.memberships m where m.person_id = p.id and m.valid_to is null) as n_mem,
    (select t.name from personnel_pilot_v1.memberships m join personnel_pilot_v1.teams t on t.id = m.team_id
     where m.person_id = p.id and m.valid_to is null order by t.name limit 1) as team,
    (select array_agg(r.role_code order by r.role_code) from personnel_pilot_v1.memberships m
     join personnel_pilot_v1.role_assignments r on r.membership_id = m.id and r.revoked_at is null
     where m.person_id = p.id and m.valid_to is null and r.role_code in ('TEAM_LEADER', 'SITE_MANAGER', 'ADMIN_DEPT')) as login_roles
  from personnel_pilot_v1.people p where p.employment_status <> 'inactive'
), act2 as (
  select act.*, case when login_roles is null then 'MEMBER' when cardinality(login_roles) > 1 then 'MULTI'
                     when login_roles[1] = 'ADMIN_DEPT' then 'ADMIN' else login_roles[1] end as role
  from act
), counts as (
  select jsonb_build_object(
    'total', (select count(*) from act2),
    'teams', (select coalesce(jsonb_object_agg(coalesce(team, '(팀 없음)'), n), '{}'::jsonb) from (select team, count(*) n from act2 group by 1) x),
    'roles', (select coalesce(jsonb_object_agg(role, n), '{}'::jsonb) from (select role, count(*) n from act2 group by 1) x),
    'unassigned', (select count(*) from act2 where team is null),
    'multi_membership', (select count(*) from act2 where n_mem > 1),
    'multi_role', (select count(*) from act2 where role = 'MULTI'),
    'inactive_with_membership', (select count(*) from personnel_pilot_v1.people p where p.employment_status = 'inactive'
        and exists (select 1 from personnel_pilot_v1.memberships m where m.person_id = p.id and m.valid_to is null)),
    'inactive_with_role', (select count(*) from personnel_pilot_v1.people p where p.employment_status = 'inactive'
        and exists (select 1 from personnel_pilot_v1.memberships m join personnel_pilot_v1.role_assignments r on r.membership_id = m.id
                    where m.person_id = p.id and r.revoked_at is null)),
    -- 명단을 넣었을 때만: 명단에 없는데 현재 인원(비활성 아님)으로 남은 사람 수
    'active_not_in_roster', (select count(*) from act2 a where exists (select 1 from roster)
        and not exists (select 1 from roster r where r.display_name = a.display_name
                        and (r.legacy_user_id is null or a.legacy_user_id = r.legacy_user_id))),
    'inactive', (select count(*) from personnel_pilot_v1.people where employment_status = 'inactive'),
    'duplicate_team_names', (select count(*) from (select name from personnel_pilot_v1.teams group by site_id, name having count(*) > 1) d)) as c
), cmp as (
  select r.display_name, r.team_name as want_team, r.role as want_role, a.team, a.role
  from roster r
  left join act2 a on a.display_name = r.display_name and (r.legacy_user_id is null or a.legacy_user_id = r.legacy_user_id)
  where a.id is null or a.team is distinct from r.team_name or a.role is distinct from r.role
)
select jsonb_pretty(jsonb_build_object(
  'ok', (c ->> 'total')::int = (e.j ->> 'total')::int
        and (c -> 'teams') = (e.j -> 'teams') and (c -> 'roles') = (e.j -> 'roles')
        and (c ->> 'unassigned')::int = 0 and (c ->> 'multi_membership')::int = 0 and (c ->> 'multi_role')::int = 0
        and (c ->> 'inactive_with_membership')::int = 0 and (c ->> 'inactive_with_role')::int = 0
        and (c ->> 'active_not_in_roster')::int = 0 and (c ->> 'duplicate_team_names')::int = 0
        and not exists (select 1 from cmp),
  'counts', c,
  'expected', e.j,
  'roster_checked', (select count(*) from roster),
  'mismatches', (select coalesce(jsonb_agg(display_name || ': 기대 ' || want_team || ' ' || want_role || ' / 현재 '
                   || coalesce(team, '없음') || ' ' || coalesce(role, '없음') order by display_name), '[]'::jsonb) from cmp),
  'teams', (select coalesce(jsonb_agg(jsonb_build_object('team', x.team, 'people', x.n, 'leaders', x.leaders) order by x.team), '[]'::jsonb) from (
      select team, count(*) n, coalesce(jsonb_agg(display_name order by display_name) filter (where role = 'TEAM_LEADER'), '[]'::jsonb) leaders
      from act2 group by team) x),
  'managers', (select coalesce(jsonb_agg(display_name || ' ' || role order by role, display_name), '[]'::jsonb) from act2 where role in ('SITE_MANAGER', 'ADMIN'))
)) as verify_roster
from counts, expected e;
