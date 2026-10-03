-- 인원 역할·소속 전체 점검 (읽기 전용: SELECT만, 아무것도 바꾸지 않음)
-- SQL 버전: personnel_auth v0.10 부속 / 작성 2026-10-03
-- 실행: Supabase SQL Editor 새 탭에서 이 파일만 실행 → 결과(check_roles) 전체를 복사해서 전달
--
-- 기준
--   * 로그인 역할은 서버 표만 본다: 현재 소속(memberships, valid_to 없음) + 현재 역할(role_assignments, revoked_at 없음)
--     ADMIN_DEPT → ADMIN(관리자), SITE_MANAGER → MANAGER(현장 TBM 현황), TEAM_LEADER → LEADER(팀장 TBM), 그 외 MEMBER(팀원 화면)  ※ v0.10 기준
--   * 명부 표시(직급·직책·명부 역할 글자)는 권한과 별개다. 글자와 시스템 역할이 다르면 notes(참고)로만 보여 준다.
--     (예: 직급 '팀장'인 팀원, 직책은 그대로인 현장관리 권한자) 문제(issues)는 소속·역할 구조 문제만 센다.
--   * 휴대폰 번호는 Supabase에 없으므로 결과에도 나오지 않는다.
with person_m as (
  select p.id,
    coalesce(jsonb_agg(coalesce(t.name, '(현장 소속·팀 없음)') order by t.name) filter (where m.id is not null), '[]'::jsonb) as memberships,
    count(m.id) filter (where m.team_id is not null) as team_count,
    coalesce(array_agg(t.name) filter (where t.name is not null), '{}') as team_names
  from personnel_pilot_v1.people p
  left join personnel_pilot_v1.memberships m on m.person_id = p.id and m.valid_to is null
  left join personnel_pilot_v1.teams t on t.id = m.team_id
  group by p.id
), person_r as (
  select m.person_id,
    array_agg(distinct r.role_code order by r.role_code) as roles,
    bool_or(r.role_code = 'TEAM_LEADER' and m.team_id is null) as leader_without_team
  from personnel_pilot_v1.memberships m
  join personnel_pilot_v1.role_assignments r on r.membership_id = m.id and r.revoked_at is null
  where m.valid_to is null
  group by m.person_id
), base as (
  select p.display_name, p.legacy_user_id, p.team_name, p.rank_title, p.job_title, p.source_role, p.employment_status,
    pm.memberships, pm.team_count, pm.team_names,
    coalesce(pr.roles, '{}') as roles,
    coalesce('TEAM_LEADER' = any (pr.roles), false) as team_leader,
    coalesce('SITE_MANAGER' = any (pr.roles), false) as site_manager,
    coalesce('ADMIN_DEPT' = any (pr.roles), false) as admin,
    coalesce(pr.leader_without_team, false) as leader_without_team,
    concat_ws(' ', p.rank_title, p.job_title, p.source_role) like '%팀장%' as roster_leader,
    concat_ws(' ', p.rank_title, p.job_title, p.source_role) like '%소장%' as roster_manager,
    (select count(*) from personnel_pilot_v1.people d where d.legacy_user_id = p.legacy_user_id) > 1 as dup_id,
    exists (select 1 from personnel_pilot_v1.teams t where t.name = p.team_name) as roster_team_exists
  from personnel_pilot_v1.people p
  join person_m pm on pm.id = p.id
  left join person_r pr on pr.person_id = p.id
), checked as (
  select b.*,
    case when employment_status = 'inactive' then '로그인 불가(비활성)'
         when admin then 'ADMIN' when site_manager then 'MANAGER' when team_leader then 'LEADER' else 'MEMBER' end as expected_app_role,
    array_remove(array[
      case when roster_leader and not team_leader then '명부 팀장 · 팀장 역할 없음' end,
      case when team_leader and not roster_leader then '팀장 역할 · 명부 표시는 팀장 아님' end,
      case when roster_manager and not site_manager then '명부 소장 · 소장 역할 없음' end,
      case when site_manager and not roster_manager then '소장 역할 · 명부 표시는 소장 아님' end
    ], null) as notes,
    array_remove(array[
      case when leader_without_team then '팀장 역할 · 팀 없는 소속에 연결' end,
      case when employment_status <> 'inactive' and team_count = 0 and not site_manager and not admin then '현재 팀 없음' end,
      case when team_count > 1 then '현재 팀 여러 개' end,
      case when nullif(team_name, '') is not null and team_count > 0 and not (team_name = any (team_names)) then '명부팀과 현재 소속 다름' end,
      case when nullif(team_name, '') is null and team_count > 0 then '명부팀 비어 있음 · 현재 소속 있음' end,
      case when employment_status <> 'inactive' and nullif(team_name, '') is not null and not roster_team_exists and not site_manager then '명부팀이 팀 목록(teams)에 없음' end,
      case when dup_id then '사용자ID 중복' end,
      case when employment_status = 'inactive' and cardinality(roles) > 0 then '비활성 · 역할 남음' end
    ], null) as issues
  from base b
)
select jsonb_pretty(jsonb_build_object(
  'summary', jsonb_build_object(
    'people', (select count(*) from checked),
    'inactive', (select count(*) from checked where employment_status = 'inactive'),
    'people_with_issues', (select count(*) from checked where cardinality(issues) > 0),
    'expected_app_role', (select jsonb_object_agg(expected_app_role, n) from (
        select expected_app_role, count(*) n from checked group by 1) x),
    'issue_counts', (select coalesce(jsonb_object_agg(issue, n), '{}'::jsonb) from (
        select issue, count(*) n from checked, unnest(issues) issue group by 1) x)),
  'teams', (select coalesce(jsonb_agg(jsonb_build_object(
      'site', s.code, 'code', t.code, 'name', t.name,
      'members_now', (select count(*) from personnel_pilot_v1.memberships m where m.team_id = t.id and m.valid_to is null),
      'leaders_now', (select coalesce(jsonb_agg(p.display_name order by p.display_name), '[]'::jsonb)
                      from personnel_pilot_v1.memberships m
                      join personnel_pilot_v1.role_assignments r on r.membership_id = m.id and r.revoked_at is null and r.role_code = 'TEAM_LEADER'
                      join personnel_pilot_v1.people p on p.id = m.person_id
                      where m.team_id = t.id and m.valid_to is null)) order by s.code, t.name), '[]'::jsonb)
    from personnel_pilot_v1.teams t join personnel_pilot_v1.sites s on s.id = t.site_id),
  'problems', (select coalesce(jsonb_agg(jsonb_build_object(
      'name', display_name, 'user_id', legacy_user_id, 'roster_team', team_name,
      'rank', rank_title, 'job', job_title, 'roster_role', source_role, 'status', employment_status,
      'memberships_now', memberships, 'roles_now', to_jsonb(roles),
      'team_leader', team_leader, 'site_manager', site_manager,
      'expected_app_role', expected_app_role, 'issues', to_jsonb(issues), 'notes', to_jsonb(notes))
      order by cardinality(issues) desc, team_name, display_name), '[]'::jsonb)
    from checked where cardinality(issues) > 0),
  'notes', (select coalesce(jsonb_agg(display_name || ' ' || legacy_user_id || ': ' || array_to_string(notes, ', ') order by display_name), '[]'::jsonb)
    from checked where cardinality(notes) > 0 and employment_status <> 'inactive'),
  'ok', (select coalesce(jsonb_agg(display_name || ' ' || legacy_user_id || ' · ' || coalesce(nullif(team_name, ''), '팀 없음')
           || ' · ' || coalesce(nullif(rank_title, ''), '-') || ' → ' || expected_app_role
           order by team_name, display_name), '[]'::jsonb)
    from checked where cardinality(issues) = 0)
)) as check_roles;
