-- 로컬 시험용 Supabase 흉내 구조 (실제 DB 아님, 가짜 데이터 전용)
-- 2026-09-29 실제 work-status-test 조회 결과(personnel_auth_v08_inspect_readonly.sql)를 기준으로 재현한다.
-- 실행: tests/run_sql_tests.sh (빈 로컬 DB에서만 사용)

-- 역할
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;

create schema extensions;
create extension pgcrypto schema extensions;
grant usage on schema extensions to anon, authenticated, service_role;

-- auth
create schema auth;
grant usage on schema auth to anon, authenticated, service_role;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  phone text,
  email_confirmed_at timestamptz,
  last_sign_in_at timestamptz,
  raw_app_meta_data jsonb default '{}'::jsonb,
  raw_user_meta_data jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);
create table auth.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz default now(),
  updated_at timestamptz,
  not_after timestamptz
);
create function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim', true), ''),
                  nullif(current_setting('request.jwt.claims', true), ''))::jsonb $$;
create function auth.role() returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'))::text $$;
grant execute on all functions in schema auth to anon, authenticated, service_role;

-- storage (필요한 열만)
create schema storage;
grant usage on schema storage to anon, authenticated, service_role;
create table storage.buckets (
  id text primary key,
  name text not null,
  owner uuid,
  public boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid,
  owner_id text,
  metadata jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;
alter table storage.buckets enable row level security;
grant all on storage.objects, storage.buckets to anon, authenticated, service_role;
create function storage.foldername(name text) returns text[] language sql immutable as $$
  select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1] $$;
grant execute on function storage.foldername(text) to anon, authenticated, service_role;

-- public 기본 권한 (Supabase 기본값과 동일하게 anon/authenticated에 자동 허용)
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

-- personnel_pilot_v1 (실제 구조와 동일한 열·제약)
create schema personnel_pilot_v1;
create table personnel_pilot_v1.people (
  id uuid primary key default gen_random_uuid(),
  legacy_user_id text not null,
  display_name text not null check (length(trim(display_name)) > 0),
  rank_title text,
  job_title text,
  employment_status text not null default 'unknown' check (employment_status in ('unknown', 'active', 'inactive')),
  source_system text not null default 'spreadsheet_personnel_api',
  created_at timestamptz not null default now(),
  source_row integer unique,
  source_team text not null default '',
  source_site text not null default '',
  source_role text not null default '',
  team_name text not null default '',
  note text not null default '',
  version integer not null default 1,
  updated_at timestamptz not null default now()
);
create index people_legacy_id_idx on personnel_pilot_v1.people (legacy_user_id);

create table personnel_pilot_v1.login_profiles (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  login_name text not null unique,
  app_role text not null check (app_role in ('ADMIN', 'MANAGER', 'MATERIAL', 'LEADER')),
  team_scope text,
  enabled boolean not null default true,
  check ((app_role = 'LEADER' and team_scope in ('공사1팀', '공사2팀')) or (app_role <> 'LEADER' and team_scope is null))
);

create table personnel_pilot_v1.sites (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  is_active boolean not null default true
);
create table personnel_pilot_v1.teams (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references personnel_pilot_v1.sites(id),
  code text not null,
  name text not null,
  unique (site_id, code),
  unique (id, site_id)
);
create table personnel_pilot_v1.memberships (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references personnel_pilot_v1.people(id),
  site_id uuid not null references personnel_pilot_v1.sites(id),
  team_id uuid,
  valid_from timestamptz not null default now(),
  valid_to timestamptz,
  check (valid_to is null or valid_to > valid_from),
  foreign key (team_id, site_id) references personnel_pilot_v1.teams(id, site_id)
);
create unique index memberships_team_active_uq on personnel_pilot_v1.memberships (person_id, site_id, team_id)
  where valid_to is null and team_id is not null;
create unique index memberships_site_active_uq on personnel_pilot_v1.memberships (person_id, site_id)
  where valid_to is null and team_id is null;
create table personnel_pilot_v1.role_assignments (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null references personnel_pilot_v1.memberships(id),
  role_code text not null check (role_code in ('SITE_MANAGER', 'TEAM_LEADER', 'MATERIAL_STAFF', 'ADMIN_DEPT')),
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  check (revoked_at is null or revoked_at >= granted_at)
);
create unique index roles_active_uq on personnel_pilot_v1.role_assignments (membership_id, role_code) where revoked_at is null;
create table personnel_pilot_v1.account_links (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  person_id uuid not null unique references personnel_pilot_v1.people(id),
  enabled boolean not null default false
);
create table personnel_pilot_v1.person_edits (
  id bigint generated always as identity primary key,
  person_id uuid not null references personnel_pilot_v1.people(id),
  actor_id uuid not null,
  actor_login text not null,
  before_data jsonb not null,
  after_data jsonb not null,
  edited_at timestamptz not null default now()
);
alter table personnel_pilot_v1.people enable row level security;
alter table personnel_pilot_v1.login_profiles enable row level security;
alter table personnel_pilot_v1.sites enable row level security;
alter table personnel_pilot_v1.teams enable row level security;
alter table personnel_pilot_v1.memberships enable row level security;
alter table personnel_pilot_v1.role_assignments enable row level security;
alter table personnel_pilot_v1.account_links enable row level security;
alter table personnel_pilot_v1.person_edits enable row level security;

-- 실제 DB의 pilot 함수 (저장소에 원본 SQL이 없는 2개는 조회 결과를 그대로 옮김)
create function public.pilot_update_person(p_id uuid, p_version integer, p_name text, p_team text, p_rank text, p_job text, p_status text, p_note text)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare a personnel_pilot_v1.login_profiles%rowtype; before_row personnel_pilot_v1.people%rowtype; after_row personnel_pilot_v1.people%rowtype;
begin
 select * into a from personnel_pilot_v1.login_profiles where auth_user_id=auth.uid() and enabled;
 if not found or a.app_role not in ('ADMIN','MANAGER') then
  raise exception 'EDIT_FORBIDDEN' using errcode='42501';
 end if;
 if p_name is null or length(trim(p_name)) not between 1 and 80
 or p_team is null or p_team not in ('','용인사무실','현장소장','자재팀','공사1팀','공사2팀','공사3팀','공사4팀')
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

create function public.pilot_bind_account(p_auth_user_id uuid, p_login_name text)
returns void language plpgsql security definer set search_path = ''
as $function$
declare user_row auth.users%rowtype; target_role text; target_team text; expected_email text;
begin
 case p_login_name
 when '관리자' then target_role:='ADMIN'; expected_email:='attendance-pilot-admin@example.com';
 when '소장' then target_role:='MANAGER'; expected_email:='attendance-pilot-manager@example.com';
 when '자재팀' then target_role:='MATERIAL'; expected_email:='attendance-pilot-material@example.com';
 when '1팀장팀' then target_role:='LEADER'; target_team:='공사1팀'; expected_email:='attendance-pilot-leader1@example.com';
 when '2팀장팀' then target_role:='LEADER'; target_team:='공사2팀'; expected_email:='attendance-pilot-leader2@example.com';
 else raise exception 'UNKNOWN_LOGIN';
 end case;
 select * into user_row from auth.users where id=p_auth_user_id;
 if not found or user_row.email is distinct from expected_email
 or user_row.raw_app_meta_data->>'attendance_pilot' is distinct from 'v1'
 or user_row.raw_app_meta_data->>'login_name' is distinct from p_login_name
 or user_row.email_confirmed_at is null then raise exception 'ACCOUNT_IDENTITY_MISMATCH'; end if;
 insert into personnel_pilot_v1.login_profiles(auth_user_id,login_name,app_role,team_scope)
 values(p_auth_user_id,p_login_name,target_role,target_team)
 on conflict(auth_user_id) do update set login_name=excluded.login_name,app_role=excluded.app_role,team_scope=excluded.team_scope,enabled=true;
end $function$;
revoke all on function public.pilot_update_person(uuid,integer,text,text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.pilot_update_person(uuid,integer,text,text,text,text,text,text) to authenticated;
revoke all on function public.pilot_bind_account(uuid,text) from public, anon, authenticated;
grant execute on function public.pilot_bind_account(uuid,text) to service_role;

-- public.works (실제 권한·정책과 동일)
create table public.works (
  work_id text primary key,
  work_date date not null,
  work_type text, team text, leader text, workers text, headcount integer,
  building text, floor text, place text, trade text, content text,
  planned_qty numeric, unit text, status text default '예정', note text,
  is_active boolean default true,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
alter table public.works enable row level security;
revoke all on public.works from anon;
grant select, truncate on public.works to anon;
grant insert (work_id, work_date, work_type, team, leader, workers, headcount, building, floor, place, trade, content, planned_qty, unit, status, note, is_active, updated_at) on public.works to anon;
grant update (work_date, work_type, team, leader, workers, headcount, building, floor, place, trade, content, planned_qty, unit, status, note, is_active, updated_at) on public.works to anon;
create policy "anon can insert works" on public.works for insert to anon with check (is_active is true);
create policy "anon can update active works" on public.works for update to anon using (is_active is true) with check (is_active = any (array[true, false]));
create policy "public can read active works" on public.works for select to anon using (is_active = true);
