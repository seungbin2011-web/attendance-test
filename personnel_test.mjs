import { accounts, endpoint, publishableKey } from './personnel_accounts_test.mjs';
const $ = id => document.getElementById(id);
const SESSION_KEY = 'personnelPilotSessionV2';
const roleNames = { ADMIN: '관리자', MANAGER: '소장', LEADER: '팀장' };
let session = null, roster = null, editing = null, gradeEditing = null, generation = 0;
const statusNames = { unknown: '미확인', active: '재직', inactive: '비활성' };
const messages = { EDIT_FORBIDDEN: '이 계정에는 인원 편집 권한이 없습니다.', PILOT_ACCESS_DENIED: '시험 계정 연결이 아직 준비되지 않았습니다.', VERSION_CONFLICT: '다른 사용자가 먼저 수정했습니다. 목록을 새로고침한 뒤 다시 편집하세요.', INVALID_INPUT: '입력값을 확인해주세요.', PERSON_NOT_FOUND: '인원을 찾을 수 없습니다.' };
function tell(text, error = false) { $('message').textContent = text; $('message').classList.toggle('error', error); }
function saveSession() {
  if (session) sessionStorage.setItem(SESSION_KEY, JSON.stringify(session));
}
function restoreSession() {
  try {
    const value = JSON.parse(sessionStorage.getItem(SESSION_KEY) || 'null');
    if (value?.access_token && value?.refresh_token) session = value;
  } catch (_) { sessionStorage.removeItem(SESSION_KEY); }
}
async function call(path, body, token) {
  const headers = { apikey: publishableKey, 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(endpoint + path, { method: 'POST', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(20000) });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    const known = Object.keys(messages).find(code => String(result.message || '').includes(code));
    throw new Error(known ? messages[known] : path.includes('/auth/') ? '로그인 정보를 확인해주세요. 계정이 아직 생성되지 않았거나 비밀번호가 다를 수 있습니다.' : `요청에 실패했습니다 (${response.status}). 연결 또는 계정 준비 상태를 확인해주세요.`);
  }
  return result;
}
async function rpc(name, body = {}) {
  if (!session) throw new Error('로그인이 필요합니다.');
  if (Date.now() > session.expiresAt - 30000) {
    try {
      const renewed = await call('/auth/v1/token?grant_type=refresh_token', { refresh_token: session.refresh_token });
      session = { ...renewed, expiresAt: Date.now() + renewed.expires_in * 1000 }; saveSession();
    } catch (e) { clearSession(); throw new Error('로그인이 만료됐습니다. 다시 로그인해주세요.'); }
  }
  return call('/rest/v1/rpc/' + name, body, session.access_token);
}
function clearSession() {
  generation++; session = null; roster = null; editing = null; gradeEditing = null;
  document.body.classList.remove('directory-mode');
  sessionStorage.removeItem(SESSION_KEY);
  sessionStorage.removeItem('attendanceAuthUser'); sessionStorage.removeItem('tbmAuthUser');
  $('people').replaceChildren(); $('identity').textContent = '';
  if ($('editDialog').open) $('editDialog').close();
  if ($('gradeDialog').open) $('gradeDialog').close();
  $('directory').hidden = true; $('loginPanel').hidden = false; $('password').value = '';
}
function syncRoleSession(result) {
  const role = roleNames[result.app_role];
  const user = { name: result.login_name, userId: `SUPA-${result.app_role}`, team: result.team_scope || '현장소장', rank: role, role, appRole: result.app_role, authSource: 'supabase-v2' };
  sessionStorage.setItem('attendanceAuthUser', JSON.stringify(user));
  sessionStorage.setItem('tbmAuthUser', JSON.stringify(user));
  $('roleLabel').textContent = role;
  $('roleScope').textContent = result.team_scope || '용인 현장 전체';
  $('workHome').href = result.app_role === 'LEADER' ? 'leader_test.html' : 'admin_test.html';
  $('workHome').textContent = result.app_role === 'LEADER' ? '팀장 TBM 열기' : '관리자 현황 열기';
}
async function loadRoster() {
  const ticket = generation; const started = performance.now(); $('refresh').disabled = true;
  try {
    const result = await rpc('pilot_roster');
    if (ticket !== generation) return;
    if (document.body.dataset.adminOnly === 'true' && !result.can_edit) {
      throw new Error('이 페이지는 관리자 또는 소장 계정만 사용할 수 있습니다.');
    }
    if (!roleNames[result.app_role]) throw new Error('팀장·소장·관리자 계정만 사용할 수 있습니다.');
    roster = result;
    syncRoleSession(result);
    $('identity').textContent = result.login_name + (result.can_edit ? ' · 편집 가능' : ' · 조회 전용');
    $('scopeTitle').textContent = result.team_scope || '전체 시험 인원';
    $('count').textContent = result.people.length;
    $('unassigned').textContent = result.people.filter(p => !p.team_name).length;
    $('conflicts').textContent = result.people.filter(p => p.id_conflict).length;
    const previous = $('teamFilter').value;
    $('teamFilter').replaceChildren(new Option('전체', ''));
    [...new Set(result.people.map(p => p.team_name || '미지정'))].sort().forEach(team => $('teamFilter').add(new Option(team, team)));
    if ([...$('teamFilter').options].some(o => o.value === previous)) $('teamFilter').value = previous;
    $('timing').textContent = `최근 조회 ${Math.round(performance.now() - started)}ms`;
    document.body.classList.add('directory-mode');
    $('loginPanel').hidden = true; $('directory').hidden = false; render();
  } finally { $('refresh').disabled = false; }
}
function render() {
  if (!roster) return;
  const q = $('search').value.trim().toLowerCase(), team = $('teamFilter').value;
  const people = roster.people.filter(p => (!q || `${p.display_name} ${p.legacy_user_id}`.toLowerCase().includes(q)) && (!team || (p.team_name || '미지정') === team));
  $('people').replaceChildren(); $('empty').hidden = people.length !== 0;
  for (const person of people) {
    const row = document.createElement('tr');
    function cell(text) { const el = document.createElement('td'); el.textContent = text; row.append(el); return el; }
    const name = cell(person.display_name); const id = document.createElement('small'); id.textContent = person.legacy_user_id; name.append(id);
    if (person.id_conflict) { const flag = document.createElement('small'); flag.textContent = '기존 ID 중복 · 별도 인원으로 보존'; flag.className = 'conflict'; name.append(flag); }
    cell(person.team_name || '미지정'); cell(`${person.rank_title || '-'} / ${person.job_title || '-'}`);
    const grade = cell(''); const gradePill = document.createElement('span'); gradePill.className = 'grade-pill'; gradePill.textContent = person.attendance_grade || 'A'; grade.append(gradePill);
    cell(statusNames[person.employment_status] || '미확인');
    const action = cell('');
    if (roster.can_edit) {
      const buttons = document.createElement('div'); buttons.className = 'action-buttons';
      const btn = document.createElement('button'); btn.className = 'secondary'; btn.textContent = '인원 편집'; btn.addEventListener('click', () => openEdit(person));
      const gradeBtn = document.createElement('button'); gradeBtn.className = 'secondary'; gradeBtn.textContent = '등급 변경'; gradeBtn.addEventListener('click', () => openGrade(person));
      buttons.append(btn, gradeBtn); action.append(buttons);
    }
    else action.textContent = '조회 전용';
    $('people').append(row);
  }
}
function openGrade(person) {
  gradeEditing = person;
  $('gradePerson').textContent = `${person.display_name} · ${person.legacy_user_id} · 현재 ${person.attendance_grade || 'A'}등급`;
  $('attendanceGrade').value = person.attendance_grade || 'A';
  $('gradeReason').value = ''; $('gradeMessage').textContent = ''; $('gradeDialog').showModal();
}
function openEdit(person) {
  editing = person;
  $('editingId').textContent = person.legacy_user_id + ' · 변경 이력이 저장됩니다';
  $('editName').value = person.display_name; $('editTeam').value = person.team_name;
  $('editRank').value = person.rank_title || ''; $('editJob').value = person.job_title || '';
  $('editStatus').value = person.employment_status; $('editNote').value = person.note || '';
  $('editMessage').textContent = ''; $('editDialog').showModal();
}
$('loginForm').addEventListener('submit', async event => {
  event.preventDefault(); $('loginButton').disabled = true; tell('로그인 확인 중…');
  try {
    const account = accounts.find(a => a.login === $('username').value.trim());
    if (!account) throw new Error('등록된 시험 아이디를 입력해주세요.');
    const password = $('password').value;
    const auth = await call('/auth/v1/token?grant_type=password', { email: account.email, password });
    $('password').value = ''; session = { ...auth, expiresAt: Date.now() + auth.expires_in * 1000 }; saveSession(); generation++;
    await loadRoster(); tell('');
  } catch (e) { clearSession(); tell(e.message, true); }
  finally { $('loginButton').disabled = false; }
});
$('refresh').addEventListener('click', async () => { try { await loadRoster(); tell('최신 정보로 갱신했습니다.'); } catch(e) { tell(e.message, true); } });
$('logout').addEventListener('click', async () => {
  const token = session?.access_token; clearSession(); tell('로그아웃했습니다.');
  if (token) await call('/auth/v1/logout', {}, token).catch(() => tell('이 화면에서는 로그아웃했습니다. 서버 세션 종료는 연결 문제로 확인하지 못했습니다.', true));
});
$('search').addEventListener('input', render); $('teamFilter').addEventListener('change', render);
$('cancel').addEventListener('click', () => $('editDialog').close());
$('gradeCancel').addEventListener('click', () => $('gradeDialog').close());
$('editForm').addEventListener('submit', async event => {
  event.preventDefault(); if (!editing) return; $('saveButton').disabled = true; $('cancel').disabled = true; $('editMessage').textContent = '';
  let saved = false;
  try {
    await rpc('pilot_update_person', { p_id: editing.id, p_version: editing.version, p_name: $('editName').value.trim(), p_team: $('editTeam').value, p_rank: $('editRank').value, p_job: $('editJob').value, p_status: $('editStatus').value, p_note: $('editNote').value });
    saved = true; $('editDialog').close(); editing = null;
    await loadRoster(); tell('변경 내용과 편집 이력을 저장했습니다.');
  } catch(e) {
    if (saved) tell('저장은 완료됐지만 목록 갱신에 실패했습니다. 새로고침해주세요.', true);
    else { $('editMessage').textContent = e.message; $('editMessage').className = 'error'; }
  } finally { $('saveButton').disabled = false; $('cancel').disabled = false; }
});
$('gradeForm').addEventListener('submit', async event => {
  event.preventDefault(); if (!gradeEditing) return;
  const reason = $('gradeReason').value.trim();
  if (reason.length < 2) { $('gradeMessage').textContent = '변경 사유를 2자 이상 입력해주세요.'; $('gradeMessage').className = 'error'; return; }
  $('gradeSave').disabled = true; $('gradeCancel').disabled = true; $('gradeMessage').textContent = '';
  let saved = false;
  try {
    await rpc('pilot_set_attendance_grade', { p_id: gradeEditing.id, p_version: gradeEditing.version, p_grade: $('attendanceGrade').value, p_reason: reason });
    saved = true; $('gradeDialog').close(); gradeEditing = null;
    await loadRoster(); tell('출결등급과 변경 이력을 저장했습니다.');
  } catch (e) {
    if (saved) tell('등급은 저장됐지만 목록 갱신에 실패했습니다. 새로고침해주세요.', true);
    else { $('gradeMessage').textContent = e.message; $('gradeMessage').className = 'error'; }
  } finally { $('gradeSave').disabled = false; $('gradeCancel').disabled = false; }
});

restoreSession();
if (session) loadRoster().then(() => tell('로그인 상태를 복원했습니다.')).catch(e => { clearSession(); tell(e.message, true); });
