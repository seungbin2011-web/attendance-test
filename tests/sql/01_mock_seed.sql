-- 가짜 시험 데이터 (실제 인원·계정 아님). 실제 DB 형태만 흉내 낸다.
insert into personnel_pilot_v1.sites (id, code, name) values
  ('a0000000-0000-0000-0000-000000000001', 'YONGIN_PILOT', '용인 현장');
insert into personnel_pilot_v1.teams (id, site_id, code, name) values
  ('b0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'CONSTRUCTION_2', '공사2팀'),
  ('b0000000-0000-0000-0000-00000000000a', 'a0000000-0000-0000-0000-000000000001', 'MATERIAL', '자재팀');

insert into personnel_pilot_v1.people (id, legacy_user_id, display_name, rank_title, job_title, team_name, source_team, source_role, source_site, source_row) values
  ('c0000000-0000-0000-0000-000000000003', 'T-0003', '시험소장', '소장', '관리', '현장소장', '현장소장', '소장', '', 3),
  ('c0000000-0000-0000-0000-000000000016', 'T-0016', '시험자재', '팀원', '자재', '자재팀', '자재팀', '팀원', '', 16),
  ('c0000000-0000-0000-0000-000000000025', 'T-0025', '시험이팀장', '팀장', '전기', '공사2팀', '공사2팀', '팀장', '용인', 25),
  ('c0000000-0000-0000-0000-000000000026', 'T-0026', '시험팀원가', '팀원', '전기', '공사2팀', '공사2팀', '팀원', '용인', 26),
  ('c0000000-0000-0000-0000-000000000027', 'T-0027', '시험팀원나', '팀원', '배관', '공사2팀', '공사2팀', '팀원', '이천', 27),
  ('c0000000-0000-0000-0000-000000000028', 'T-0028', '시험퇴사자', '팀원', '전기', '공사2팀', '공사2팀', '팀원', '', 28),
  ('c0000000-0000-0000-0000-000000000036', 'T-0036', '시험중복가', '팀원', '전기', '공사2팀', '공사2팀', '팀원', '', 36),
  ('c0000000-0000-0000-0000-000000000136', 'T-0036', '시험중복나', '팀원', '', '', '', '팀원', '', 136),
  ('c0000000-0000-0000-0000-000000000008', 'T-0008', '시험일팀장', '팀장', '전기', '공사1팀', '공사1팀', '팀장', '이천', 8),
  ('c0000000-0000-0000-0000-000000000040', 'T-0040', '시험동명', '팀원', '', '', '', '팀원', '', 40),
  ('c0000000-0000-0000-0000-000000000041', 'T-0041', '시험 동명', '팀원', '', '', '', '팀원', '', 41);
update personnel_pilot_v1.people set employment_status = 'inactive' where legacy_user_id = 'T-0028';

-- 업무계정 5개 (실제와 같은 이름·역할, 가짜 id)
insert into auth.users (id, email, email_confirmed_at, raw_app_meta_data) values
  ('d0000000-0000-0000-0000-0000000000a1', 'attendance-pilot-admin@example.com', now(), '{"attendance_pilot":"v1","login_name":"관리자"}'),
  ('d0000000-0000-0000-0000-0000000000a2', 'attendance-pilot-manager@example.com', now(), '{"attendance_pilot":"v1","login_name":"소장"}'),
  ('d0000000-0000-0000-0000-0000000000a3', 'attendance-pilot-leader1@example.com', now(), '{"attendance_pilot":"v1","login_name":"1팀장팀"}'),
  ('d0000000-0000-0000-0000-0000000000a4', 'attendance-pilot-leader2@example.com', now(), '{"attendance_pilot":"v1","login_name":"2팀장팀"}'),
  ('d0000000-0000-0000-0000-0000000000a5', 'attendance-pilot-material@example.com', now(), '{"attendance_pilot":"v1","login_name":"자재팀"}');
insert into personnel_pilot_v1.login_profiles (auth_user_id, login_name, app_role, team_scope, enabled) values
  ('d0000000-0000-0000-0000-0000000000a1', '관리자', 'ADMIN', null, true),
  ('d0000000-0000-0000-0000-0000000000a2', '소장', 'MANAGER', null, true),
  ('d0000000-0000-0000-0000-0000000000a3', '1팀장팀', 'LEADER', '공사1팀', true),
  ('d0000000-0000-0000-0000-0000000000a4', '2팀장팀', 'LEADER', '공사2팀', true),
  ('d0000000-0000-0000-0000-0000000000a5', '자재팀', 'MATERIAL', null, false);

-- 실제와 같은 형태의 소속·역할 3건
insert into personnel_pilot_v1.memberships (id, person_id, site_id, team_id) values
  ('e0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', null),
  ('e0000000-0000-0000-0000-000000000016', 'c0000000-0000-0000-0000-000000000016', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-00000000000a'),
  ('e0000000-0000-0000-0000-000000000025', 'c0000000-0000-0000-0000-000000000025', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002');
insert into personnel_pilot_v1.role_assignments (membership_id, role_code) values
  ('e0000000-0000-0000-0000-000000000003', 'SITE_MANAGER'),
  ('e0000000-0000-0000-0000-000000000016', 'MATERIAL_STAFF'),
  ('e0000000-0000-0000-0000-000000000025', 'TEAM_LEADER');

insert into public.works (work_id, work_date, work_type, status, content) values
  ('WK-20260821-001', '2026-08-21', '금일', '예정', '시험 작업');
