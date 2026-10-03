-- personnel_auth v0.11 롤백 · v0.10 명부 함수로 되돌리고 v0.11 함수를 지운다
-- 적용 방법: Supabase SQL Editor에서 이 파일만 단독 실행. Edge Function member-login을 v0.2로 되돌린 뒤 실행
-- 행은 지우지 않는다. 로그인 번호 해시 칸(login4_hash·login4_set_at)은 남겨 두고 쓰지 않는다.
-- 기존 사용자ID NOT NULL은 사용자ID 없는 인원이 없을 때만 되돌린다 (있으면 안내만).
begin;

create or replace function public.pilot_roster() returns jsonb
language plpgsql security definer set search_path=''
as $fn$
declare a personnel_pilot_v1.login_profiles%rowtype; result jsonb;
begin
  a := personnel_pilot_v1.roster_actor();
  if a.auth_user_id is null or a.app_role not in ('ADMIN','MANAGER','LEADER') then
    raise exception 'PILOT_ACCESS_DENIED' using errcode='42501';
  end if;

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

create or replace function public.pilot_update_person(p_id uuid, p_version integer, p_name text, p_team text, p_rank text, p_job text, p_status text, p_note text)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare a personnel_pilot_v1.login_profiles%rowtype; before_row personnel_pilot_v1.people%rowtype; after_row personnel_pilot_v1.people%rowtype;
begin
 a := personnel_pilot_v1.roster_actor();
 if a.auth_user_id is null or a.app_role not in ('ADMIN','MANAGER') then
  raise exception 'EDIT_FORBIDDEN' using errcode='42501';
 end if;
 if p_name is null or length(trim(p_name)) not between 1 and 80
 or p_team is null or (p_team not in ('','용인사무실','현장소장','자재팀','공사1팀','공사2팀','공사3팀','공사4팀')
                       and not exists (select 1 from personnel_pilot_v1.teams t where t.name = p_team))
 or p_rank is null or length(p_rank)>40 or p_job is null or length(p_job)>80
 or p_status is null or p_status not in ('unknown','active','inactive')
 or p_note is null or length(p_note)>1000 then
  raise exception 'INVALID_INPUT' using errcode='22023';
 end if;
 select * into before_row from personnel_pilot_v1.people where id=p_id for update;
 if not found then raise exception 'PERSON_NOT_FOUND' using errcode='P0002'; end if;
 if p_version is distinct from before_row.version then raise exception 'VERSION_CONFLICT' using errcode='40001'; end if;
 update personnel_pilot_v1.people set display_name=trim(p_name),team_name=p_team,
 rank_title=trim(p_rank),job_title=trim(p_job),employment_status=p_status,note=p_note,
 version=version+1,updated_at=clock_timestamp()
 where id=p_id returning * into after_row;
 insert into personnel_pilot_v1.person_edits(person_id,actor_id,actor_login,before_data,after_data)
 values(p_id,a.auth_user_id,a.login_name,to_jsonb(before_row),to_jsonb(after_row));
 return jsonb_build_object('id',after_row.id,'version',after_row.version);
end $function$;

drop function if exists public.pilot_member_login4(text, text, text);
drop function if exists public.pilot_admin_save_person(jsonb);
drop function if exists public.pilot_org_chart();
drop function if exists personnel_pilot_v1.set_login4(uuid, text, text);
drop function if exists personnel_pilot_v1.assign_current(uuid, uuid, text);
drop function if exists personnel_pilot_v1.end_current(uuid);

do $nn$
begin
  if exists (select 1 from personnel_pilot_v1.people where legacy_user_id is null) then
    raise notice '사용자ID 없는 인원이 있어 legacy_user_id NOT NULL은 되돌리지 않음';
  else
    alter table personnel_pilot_v1.people alter column legacy_user_id set not null;
  end if;
end $nn$;

commit;
