-- 현장 업무 통합 로그인 v0.2
-- 적용 대상: 기존 personnel_pilot_v1 시험 스키마
-- 명부 행은 삭제하거나 덮어쓰지 않는다.
begin;

alter table personnel_pilot_v1.people
  add column if not exists attendance_grade text not null default 'A';

do $block$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'people_attendance_grade_check'
      and conrelid = 'personnel_pilot_v1.people'::regclass
  ) then
    alter table personnel_pilot_v1.people
      add constraint people_attendance_grade_check
      check (attendance_grade in ('A','B','C'));
  end if;
end $block$;

create table if not exists personnel_pilot_v1.attendance_grade_edits (
  id bigint generated always as identity primary key,
  person_id uuid not null references personnel_pilot_v1.people(id),
  actor_id uuid not null,
  actor_login text not null,
  before_grade text not null,
  after_grade text not null,
  reason text not null check(length(trim(reason)) between 2 and 500),
  edited_at timestamptz not null default now()
);

alter table personnel_pilot_v1.attendance_grade_edits enable row level security;
revoke all on table personnel_pilot_v1.attendance_grade_edits from public, anon, authenticated;
revoke all on all sequences in schema personnel_pilot_v1 from public, anon, authenticated;

-- 운영 로그인 범위에서 자재팀 시험 계정을 제외한다.
update personnel_pilot_v1.login_profiles
set enabled = false
where app_role = 'MATERIAL' and enabled = true;

create or replace function public.pilot_roster() returns jsonb
language plpgsql security definer set search_path=''
as $fn$
declare a personnel_pilot_v1.login_profiles%rowtype; result jsonb;
begin
  select * into a
  from personnel_pilot_v1.login_profiles
  where auth_user_id = auth.uid()
    and enabled
    and app_role in ('ADMIN','MANAGER','LEADER');
  if not found then raise exception 'PILOT_ACCESS_DENIED' using errcode='42501'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'legacy_user_id',p.legacy_user_id,'display_name',p.display_name,
    'rank_title',p.rank_title,'job_title',p.job_title,'team_name',p.team_name,
    'source_site',p.source_site,'employment_status',p.employment_status,
    'attendance_grade',p.attendance_grade,
    'note',case when a.app_role in ('ADMIN','MANAGER') then p.note else '' end,
    'version',p.version,'updated_at',p.updated_at,
    'id_conflict',exists(
      select 1 from personnel_pilot_v1.people d
      where d.legacy_user_id=p.legacy_user_id and d.id<>p.id
    )
  ) order by p.source_row),'[]'::jsonb) into result
  from personnel_pilot_v1.people p
  where a.app_role in ('ADMIN','MANAGER')
     or (a.app_role='LEADER' and p.team_name=a.team_scope);

  return jsonb_build_object(
    'login_name',a.login_name,
    'app_role',a.app_role,
    'role_label',case a.app_role when 'ADMIN' then '관리자' when 'MANAGER' then '소장' else '팀장' end,
    'can_edit',a.app_role in ('ADMIN','MANAGER'),
    'can_change_grade',a.app_role in ('ADMIN','MANAGER'),
    'team_scope',a.team_scope,
    'people',result
  );
end $fn$;

create or replace function public.pilot_set_attendance_grade(
  p_id uuid,
  p_version integer,
  p_grade text,
  p_reason text
) returns jsonb
language plpgsql security definer set search_path=''
as $fn$
declare
  a personnel_pilot_v1.login_profiles%rowtype;
  before_row personnel_pilot_v1.people%rowtype;
  after_row personnel_pilot_v1.people%rowtype;
begin
  select * into a
  from personnel_pilot_v1.login_profiles
  where auth_user_id=auth.uid() and enabled;
  if not found or a.app_role not in ('ADMIN','MANAGER') then
    raise exception 'EDIT_FORBIDDEN' using errcode='42501';
  end if;
  if p_grade is null or p_grade not in ('A','B','C')
     or p_reason is null or length(trim(p_reason)) not between 2 and 500 then
    raise exception 'INVALID_INPUT' using errcode='22023';
  end if;

  select * into before_row
  from personnel_pilot_v1.people
  where id=p_id for update;
  if not found then raise exception 'PERSON_NOT_FOUND' using errcode='P0002'; end if;
  if p_version is distinct from before_row.version then
    raise exception 'VERSION_CONFLICT' using errcode='40001';
  end if;

  update personnel_pilot_v1.people
  set attendance_grade=p_grade,
      version=version+1,
      updated_at=clock_timestamp()
  where id=p_id
  returning * into after_row;

  insert into personnel_pilot_v1.attendance_grade_edits(
    person_id,actor_id,actor_login,before_grade,after_grade,reason
  ) values (
    p_id,a.auth_user_id,a.login_name,before_row.attendance_grade,after_row.attendance_grade,trim(p_reason)
  );

  return jsonb_build_object('id',after_row.id,'version',after_row.version,'attendance_grade',after_row.attendance_grade);
end $fn$;

revoke all on function public.pilot_roster() from public, anon, authenticated;
revoke all on function public.pilot_set_attendance_grade(uuid,integer,text,text) from public, anon, authenticated;
grant execute on function public.pilot_roster() to authenticated;
grant execute on function public.pilot_set_attendance_grade(uuid,integer,text,text) to authenticated;

commit;

-- 적용 확인용 읽기 전용 조회
select app_role, enabled, count(*) over () as profile_count
from personnel_pilot_v1.login_profiles
order by app_role, login_name;

select attendance_grade, count(*)
from personnel_pilot_v1.people
group by attendance_grade
order by attendance_grade;
