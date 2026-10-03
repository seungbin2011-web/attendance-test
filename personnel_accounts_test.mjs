export const accounts = [
  { login: '관리자', email: 'attendance-pilot-admin@example.com', role: 'ADMIN' },
  { login: '소장', email: 'attendance-pilot-manager@example.com', role: 'MANAGER' },
  { login: '1팀장팀', email: 'attendance-pilot-leader1@example.com', role: 'LEADER', team: '공사1팀' },
  { login: '2팀장팀', email: 'attendance-pilot-leader2@example.com', role: 'LEADER', team: '공사2팀' }
];
export const endpoint = 'https://cgeciwdibirvdsucgrnz.supabase.co';
export const publishableKey = 'sb_publishable_Ui2gOfJoBOvtN4mWwN5Paw_tjvSdxJs';
// 운영 화면(파일 이름에 _test 없음, 루트 포함)은 운영 화면끼리, 시험 화면은 시험 화면끼리 연결한다.
export const PROD = typeof location === 'undefined' || !/_test\.html$/.test(location.pathname);
const PAGES = { login: ['index.html', 'personnel_test.html'], member: ['member.html', 'member_test.html'], tbm_report: ['tbm_report.html', 'tbm_report_test.html'], tbm_manager: ['tbm_manager.html', 'tbm_manager_test.html'] };
export function pageUrl(name) { return PAGES[name][PROD ? 0 : 1]; }
