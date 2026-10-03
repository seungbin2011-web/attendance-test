-- 2026-10 명단 동기화 시험 준비: 동기화 전 상태 지문 (로컬 시험 DB 전용)
create or replace function test_util.roster_fp() returns text language sql as $$
  select md5(concat_ws('|',
    (select string_agg(id::text || ':' || coalesce(team_id::text, '-') || ':' || coalesce(valid_to::text, 'open'), ',' order by id) from personnel_pilot_v1.memberships),
    (select string_agg(id::text || ':' || role_code || ':' || coalesce(revoked_at::text, 'open'), ',' order by id) from personnel_pilot_v1.role_assignments),
    (select string_agg(id::text || ':' || employment_status || ':' || team_name || ':' || version, ',' order by id) from personnel_pilot_v1.people),
    (select string_agg(id::text || ':' || code || ':' || name, ',' order by id) from personnel_pilot_v1.teams),
    (select count(*)::text from personnel_pilot_v1.person_edits)))
$$;
-- 되돌리기 비교용: 현재 소속·역할·재직·명부 팀 (동기화가 만든 새 인원·새 팀 제외)
drop table if exists test_util.teams_before;
create table test_util.teams_before as select id, name from personnel_pilot_v1.teams;
create or replace function test_util.roster_state_fp() returns text language sql as $$
  select md5(concat_ws('|',
    (select string_agg(m.id::text || ':' || m.person_id || ':' || coalesce(m.team_id::text, '-'), ',' order by m.id) from personnel_pilot_v1.memberships m where m.valid_to is null),
    (select string_agg(r.id::text, ',' order by r.id) from personnel_pilot_v1.role_assignments r where r.revoked_at is null),
    (select string_agg(p.id::text || ':' || p.employment_status || ':' || p.team_name, ',' order by p.id) from personnel_pilot_v1.people p where p.source_system <> 'roster_sync_2026_10'),
    (select string_agg(t.id::text || ':' || t.name, ',' order by t.id) from personnel_pilot_v1.teams t where t.id in (select id from test_util.teams_before))))
$$;
insert into test_util.snapshot values
  ('roster_fp_before', test_util.roster_fp()),
  ('roster_state_before', test_util.roster_state_fp()),
  ('tbm_rows_before', (select count(*) || '/' || (select count(*) from field_pilot_v1.task_assignments) || '/' || (select count(*) from field_pilot_v1.attachments)
                       from field_pilot_v1.daily_reports))
on conflict (key) do update set value = excluded.value;
