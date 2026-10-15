// 현장 TBM 현황 시험 화면 (tbm_manager_test v0.41: 현장관리·관리자(개인 로그인·업무계정) 읽기 전용 · 하루 전체 흐름 · 요약·필터·자동 새로고침·변경 이력)
// 볼 수 있는 현장·팀은 서버(tbm_site_overview)가 정한다. 이 화면에는 저장 기능이 없다.
import { rpc, requireLogin, logout, loginUrl, PROD, pageUrl, describeError, escapeHtml, kstTime, kstDateLabel, signedUrls, PHOTO_BUCKET } from './tbm_api_test.mjs?v=1.2';

const PAGE = pageUrl('tbm_manager');
const PAGE_VERSION = '0.50';
const AUTO_KEY = 'tbmManagerAutoRefresh_v1';
const HISTORY_NAMES = { SESSION_OPENED: '새 작업 열기', PLAN_SAVE: '작업계획 저장', MORNING_SUBMIT: '출근 TBM 보고', AFTERNOON_ALL_CLEAR: '오후 전체 이상 없음', TASK_NORMAL: '작업 정상', TASK_CHANGED: '작업 변경', TASK_DELAYED: '작업 지연', TASK_RISK: '작업 위험', TASK_STOPPED: '작업정지', TASK_STOP_CANCELLED: '작업정지 취소', TASK_RESULT: '퇴근 결과 입력', EVENING_CLOSE: '퇴근 TBM 마감', PHOTO_ADD: '사진 추가', PHOTO_REMOVE: '사진 빼기' };
const BLOCKING = ['AUTH_REQUIRED', 'AUTH_EXPIRED', 'SESSION_EXPIRED', 'ACCOUNT_NOT_LINKED', 'ACCOUNT_INACTIVE', 'ACCOUNT_DISABLED', 'PIN_CHANGE_REQUIRED', 'FORBIDDEN'];
const KIND_NAMES = { MORNING: '출근', AFTERNOON: '오후', EVENING: '퇴근' };
const ALERT_NAMES = { NORMAL: '정상', CHANGED: '변경', DELAYED: '지연', RISK: '위험', STOPPED: '작업정지' };
const RESULT_NAMES = { DONE: '완료', PARTIAL: '일부완료', NOT_DONE: '미완료', EXCLUDED: '제외', STOPPED: '작업정지' };
const stopText = k => `작업정지 · ${k.carry_over ? '내일 이월' : '정지로 종료'}`;
const $ = id => document.getElementById(id);

let overview = null;
let detailId = null;
let loading = false;
let filter = 'all';
let autoTimer = null;

function tell(text, kind = '') { $('message').textContent = text; $('message').className = 'message' + (kind ? ' ' + kind : ''); }
function setLoading(on) { loading = on; $('loadingOverlay').classList.toggle('active', on); }
function showStage(id) { document.querySelectorAll('.app-stage').forEach(s => s.classList.toggle('active', s.id === id)); window.scrollTo({ top: 0 }); }
function block(text) {
  document.querySelectorAll('.app-stage').forEach(s => s.classList.remove('active'));
  $('blocked').hidden = false; $('blockedText').textContent = text; tell('');
  $('headerSub').textContent = '현장관리·관리자로 로그인해야 사용할 수 있습니다.';
}
function handleError(e) {
  if (BLOCKING.includes(e.code)) block(e.code === 'FORBIDDEN' ? '현장관리·관리자 권한이 있는 사람만 사용할 수 있는 화면입니다. 본인 이름과 휴대폰 번호 뒤 4자리로 로그인해주세요.' : describeError(e));
  else tell(describeError(e), 'error');
}

function reportState(r) {
  if (!r) return { text: '미보고', cls: 'gray' };
  if (r.status === 'CONFIRMED') return { text: '소장 확인 완료', cls: 'ok' };
  if (r.evening_at) return { text: '퇴근 마감', cls: 'ok' };
  if (r.morning_at) return { text: '출근 보고', cls: '' };
  return { text: '계획만 저장', cls: 'warn' };
}

async function loadOverview({ quiet = false } = {}) {
  if (loading) return false;
  if (!quiet) setLoading(true);
  try {
    overview = await rpc('tbm_site_overview', $('dateInput').value ? { p_date: $('dateInput').value } : {});
    if (!$('dateInput').value) $('dateInput').value = overview.date;
    $('dateInput').max = overview.today;
    renderOverview();
    return true;
  } catch (e) { handleError(e); return false; }
  finally { if (!quiet) setLoading(false); }
}

function renderOverview() {
  $('blocked').hidden = true;
  const v = overview.viewer;
  document.body.classList.toggle('admin-mode', v.role_label === '관리자');
  $('headerSub').textContent = `${v.name === v.role_label ? v.name : `${v.name} ${v.role_label}`} · ${kstDateLabel(overview.date)}${overview.date === overview.today ? ' (오늘)' : ''}`;
  $('loadedAt').textContent = `최근 조회 ${kstTime(new Date().toISOString())} · 팀 ${new Set(overview.teams.map(t => t.team_id)).size}개`;
  const teams = overview.teams;
  const reported = teams.filter(t => t.report);
  const teamCount = new Set(teams.map(t => t.team_id)).size;
  const reportedTeams = new Set(reported.map(t => t.team_id)).size;
  const sum = (k) => reported.reduce((n, t) => n + Number(t.report.alerts?.[k] || 0), 0);
  const cells = [
    ['팀', teamCount, ''], ['미보고', teamCount - reportedTeams, teamCount - reportedTeams ? 'warn' : ''],
    ['출근 보고', `${reported.filter(t => t.report.morning_at).length}/${reported.length}`, ''],
    ['소장 확인 필요', reported.filter(t => t.report.needs_manager_check).length, reported.some(t => t.report.needs_manager_check) ? 'danger' : ''],
    ['위험 작업', sum('RISK'), sum('RISK') ? 'danger' : ''], ['퇴근 마감', `${reported.filter(t => t.report.evening_at).length}/${reported.length}`, ''],
    // 작업정지는 있을 때만 칸을 더한다
    ...(sum('STOPPED') ? [['작업정지', sum('STOPPED'), 'stop']] : [])];
  $('summaryGrid').innerHTML = cells.map(([label, value, cls]) => `<div class="sum ${cls}"><b>${value}</b><span>${label}</span></div>`).join('');
  // 확인 필요 → 미보고 → 나머지 순
  const rank = t => (needsAttention(t) ? 0 : !t.report ? 1 : 2);
  const shown = [...teams].sort((a, b) => rank(a) - rank(b) || a.team_name.localeCompare(b.team_name, 'ko'))
    .filter(t => filter === 'all' || (filter === 'attention' ? needsAttention(t) : !t.report));
  $('teamList').innerHTML = !teams.length ? '<section class="card"><div class="desc" style="margin:0">볼 수 있는 팀이 없습니다. 팀장 소속·역할 등록 상태를 확인해주세요.</div></section>'
    : shown.length ? shown.map(teamCard).join('') : `<section class="card"><div class="desc" style="margin:0">${filter === 'attention' ? '확인이 필요한 팀이 없습니다.' : '미보고 팀이 없습니다.'}</div></section>`;
  if (!document.querySelector('.app-stage.active')) showStage('stageList');
}

function needsAttention(t) { return !!t.report && (t.report.needs_manager_check || Number(t.report.alerts?.RISK || 0) > 0 || Number(t.report.alerts?.STOPPED || 0) > 0); }
function teamCard(t) {
  const r = t.report;
  const state = reportState(r);
  if (!r) return `<div class="team-card missing" data-team="${escapeHtml(t.team_name)}"><div class="team-head"><div class="team-name">${escapeHtml(t.team_name)}</div><span class="badge gray">미보고</span></div>
    <div class="team-meta">${escapeHtml(kstDateLabel(overview.date))} 작업계획이 아직 없습니다.</div></div>`;
  const photos = Object.entries(r.photo_counts || {}).filter(([, n]) => n > 0).map(([k, n]) => `${KIND_NAMES[k]} ${n}장`).join(' · ') || '없음';
  const alerts = r.alerts || {};
  const results = r.results || {};
  const attention = needsAttention(t);
  return `<div class="team-card ${attention ? 'attention' : ''}" data-team="${escapeHtml(t.team_name)}">
    <div class="team-head"><div><div class="team-name">${escapeHtml(t.team_name)} · 작업 ${r.session_no || 1}</div>
      <div class="team-meta">보고자 ${escapeHtml(r.reporter_label)} · 작업 ${r.task_count}건 · 최근 ${escapeHtml(kstTime(r.updated_at))}</div></div>
      <span class="badge ${state.cls}">${state.text}</span></div>
    <div class="chips">
      <span class="badge ${r.morning_at ? 'ok' : 'gray'}">출근 ${r.morning_at ? escapeHtml(kstTime(r.morning_at)) : '전'}</span>
      <span class="badge ${r.afternoon_at ? 'ok' : 'gray'}">오후 ${r.afternoon_at ? escapeHtml(kstTime(r.afternoon_at)) : '전'}</span>
      <span class="badge ${r.evening_at ? 'ok' : 'gray'}">퇴근 ${r.evening_at ? escapeHtml(kstTime(r.evening_at)) : '전'}</span>
      ${r.needs_manager_check ? '<span class="badge danger">소장 확인 필요</span>' : ''}
      ${alerts.STOPPED ? `<span class="badge stop">⛔ 작업정지 ${alerts.STOPPED}</span>` : ''}
      ${alerts.RISK ? `<span class="badge danger">위험 ${alerts.RISK}</span>` : ''}
      ${alerts.CHANGED ? `<span class="badge info">변경 ${alerts.CHANGED}</span>` : ''}
      ${alerts.DELAYED ? `<span class="badge warn">지연 ${alerts.DELAYED}</span>` : ''}
      ${results.PARTIAL ? `<span class="badge warn">일부완료 ${results.PARTIAL}</span>` : ''}
      ${results.NOT_DONE ? `<span class="badge warn">미완료 ${results.NOT_DONE}</span>` : ''}
      ${r.carry_count ? `<span class="badge">이월 ${r.carry_count}</span>` : ''}
      ${(r.risks || []).length ? `<span class="badge warn">위험요인 ${escapeHtml(r.risks.join(', '))}</span>` : ''}
    </div>
    ${r.issue_note ? `<div class="team-task"><strong>특이사항</strong> ${escapeHtml(r.issue_note)}</div>` : ''}
    ${(r.tasks || []).map(k => k.alert === 'STOPPED' ? `<div class="team-task stopped">⛔ 작업 ${k.task_no} · ${escapeHtml(k.place)} — ${escapeHtml(k.content)} <span class="badge stop">${stopText(k)}</span><br><strong>정지 사유</strong> ${escapeHtml(k.alert_note || '-')}${k.alert_at ? ` · ${escapeHtml(kstTime(k.alert_at))}` : ''}</div>`
      : `<div class="team-task">작업 ${k.task_no} · ${escapeHtml(k.place)} — ${escapeHtml(k.content)}${['CHANGED', 'DELAYED', 'RISK'].includes(k.alert) ? ` <span class="alert-line ${k.alert}">[${ALERT_NAMES[k.alert]}]</span>` : ''}${k.result ? ` <span class="badge ${k.result === 'DONE' ? 'ok' : k.result === 'EXCLUDED' ? 'gray' : 'warn'}">${RESULT_NAMES[k.result]}${k.carry_over ? '·이월' : ''}</span>` : ''}</div>`).join('')}
    <div class="team-meta">사진: ${escapeHtml(photos)}</div>
    <button class="detail-btn" type="button" data-detail="${r.id}">상세 보기</button>
  </div>`;
}

// ---------- 상세 ----------
async function openDetail(id) {
  if (loading) return;
  detailId = id;
  setLoading(true);
  try {
    const d = await rpc('tbm_report_detail', { p_report_id: id });
    renderDetail(d);
    showStage('stageDetail');
  } catch (e) { handleError(e); }
  finally { setLoading(false); }
}
function renderDetail(d) {
  const r = d.report;
  const state = reportState(r);
  $('detailTitle').textContent = `${r.team_name} · 작업 ${r.session_no || 1} · ${kstDateLabel(r.work_date)}`;
  const risks = [...(r.risks || []).filter(x => x !== '기타'), ...(r.risks?.includes('기타') ? [`기타(${r.risk_other || '-'})`] : [])].join(', ') || '없음';
  const photoKinds = ['MORNING', 'AFTERNOON', 'EVENING'].filter(k => r.photos.some(p => p.kind === k));
  $('detailBody').innerHTML = `
    <div class="section-title"><strong>${escapeHtml(r.team_name)} 보고</strong><span class="badge ${state.cls}">${state.text}</span></div>
    <dl class="kv"><dt>보고자</dt><dd>${escapeHtml(r.reporter_label)}</dd><dt>예상 종료</dt><dd>${escapeHtml(r.end_time || '-')}</dd>
      <dt>위험요인</dt><dd>${escapeHtml(risks)}</dd><dt>안전조치</dt><dd>${escapeHtml(r.safety_note || '-')}</dd>
      <dt>특이사항</dt><dd>${escapeHtml(r.issue_note || '-')}</dd><dt>소장 확인</dt><dd>${r.needs_manager_check ? '필요' : '-'}</dd>
      <dt>출근 TBM</dt><dd>${r.morning_at ? `${escapeHtml(kstTime(r.morning_at))} 보고${r.morning_note ? ' · ' + escapeHtml(r.morning_note) : ''}` : '보고 전'}</dd>
      <dt>오후 TBM</dt><dd>${r.afternoon_at ? `${escapeHtml(kstTime(r.afternoon_at))} 확인${r.afternoon_note ? ' · ' + escapeHtml(r.afternoon_note) : ''}` : '확인 전'}</dd>
      <dt>퇴근 TBM</dt><dd>${r.evening_at ? `${escapeHtml(kstTime(r.evening_at))} 마감${r.evening_note ? ' · ' + escapeHtml(r.evening_note) : ''}` : '마감 전'}</dd></dl>
    <div class="detail-section"><h3>작업 ${r.tasks.length}건</h3><div class="plan-view">${r.tasks.map(t => `<div class="plan-view-item">
      <strong>작업 ${t.task_no} · ${escapeHtml(t.place)}${t.carried_from_task_id ? ' <span class="task-tag">이월</span>' : ''}</strong>
      <span>${escapeHtml(t.content)}</span>
      <span>인원 ${t.members.length}명: ${t.members.map(m => `${escapeHtml(m.name)}${m.role !== '작업자' ? `(${escapeHtml(m.role)})` : ''}`).join(', ') || '-'}</span>
      <span>오후: ${ALERT_NAMES[t.alert] ? `<span class="alert-line ${t.alert}">${ALERT_NAMES[t.alert]}</span>` : '미확인'}${t.alert_note ? ' · ' + escapeHtml(t.alert_note) : ''}${t.alert_action ? ` · 조치: ${escapeHtml(t.alert_action)}` : ''}</span>
      ${t.alert === 'STOPPED' ? `<span class="stop-line">⛔ ${stopText(t)} · 정지 ${escapeHtml(kstTime(t.alert_at))} · 사유: ${escapeHtml(t.alert_note || '-')}${t.alert_action ? ` · 조치: ${escapeHtml(t.alert_action)}` : ''}</span>` : ''}
      <span>퇴근: ${t.result ? `<strong>${t.result === 'STOPPED' ? stopText(t) : RESULT_NAMES[t.result]}</strong>` : '미입력'}${t.result_note ? ' · ' + escapeHtml(t.result_note) : ''}${t.carry_over ? ` · 이월: ${escapeHtml(t.carry_note || '')}${t.carry_status === 'CONTINUED' ? ' (이어받음)' : t.carry_status === 'DROPPED' ? ' (이어받지 않음)' : ''}` : ''}</span></div>`).join('')}</div></div>
    <div class="detail-section"><h3>사진</h3>${photoKinds.length ? photoKinds.map(k => `<div class="photo-title">${KIND_NAMES[k]} TBM</div>
      <div class="photo-preview" style="margin-bottom:10px">${r.photos.filter(p => p.kind === k).map(p => `<a class="photo-thumb" target="_blank" rel="noopener" data-photo-link="${escapeHtml(p.path)}"><img alt="${KIND_NAMES[k]} 사진 ${escapeHtml(kstTime(p.created_at))}" data-photo-path="${escapeHtml(p.path)}"><span class="photo-state">${escapeHtml(kstTime(p.created_at))}</span></a>`).join('')}</div>`).join('') : '<div class="team-meta">올라온 사진이 없습니다.</div>'}</div>
    <div class="detail-section"><h3>자재·요청</h3><div class="team-meta">자재 요청은 다음 단계(S3)에서 이 보고와 연결됩니다.</div></div>
    <div class="detail-section"><h3>변경 이력 ${d.history.length}건</h3><ol class="history">${[...d.history].reverse().map(h => `<li><time>${escapeHtml(kstTime(h.at))}</time><strong>${escapeHtml(HISTORY_NAMES[h.action] || h.action)}</strong> · ${escapeHtml(h.actor)}${h.note ? ` — ${escapeHtml(h.note)}` : ''}</li>`).join('')}</ol></div>`;
  loadPhotos().catch(() => tell('사진 미리보기를 불러오지 못했습니다. 새로고침해주세요.', 'error'));
}
async function loadPhotos() {
  const imgs = [...document.querySelectorAll('#detailBody img[data-photo-path]')];
  if (!imgs.length) return;
  const urls = await signedUrls(PHOTO_BUCKET, imgs.map(i => i.dataset.photoPath), 600);
  imgs.forEach(img => { const url = urls[img.dataset.photoPath]; if (url) { img.src = url; img.closest('a').href = url; } });
}

// ---------- 출역 현황 (현장관리·관리자 조회, 관리자만 정정) ----------
const ATT_IN = { PRESENT: '출근', LATE: '지각', ABSENT: '결근', OFF: '휴무' };
const ATT_OUT = { LEFT: '퇴근', EARLY: '조퇴', NOT_LEFT: '미퇴근' };
const ATT_CLASS = { PRESENT: 'good', LATE: 'warn', ABSENT: 'bad', OFF: '', LEFT: 'good', EARLY: 'warn', NOT_LEFT: 'bad' };
const ROLE_NAMES = { TEAM_LEADER: '팀장', ADMIN: '관리자' };
let attData = null;
async function openAttendance() {
  if (loading) return false;
  setLoading(true);
  try {
    attData = await rpc('tbm_attendance_overview', $('dateInput').value ? { p_date: $('dateInput').value } : {});
    renderAttendance(); showStage('stageAttendance');
    return true;
  } catch (e) {
    if (e.code === 'UNKNOWN') tell('출역 현황을 아직 쓸 수 없습니다 (서버 준비 전).', 'error'); else handleError(e);
    return false;
  } finally { setLoading(false); }
}
function attLine(p, kind) {
  const code = kind === 'IN' ? p.check_in_status : p.check_out_status;
  if (!code) return kind === 'IN' ? '<span class="badge gray">출근 미확정</span>' : (['PRESENT', 'LATE'].includes(p.check_in_status) ? '<span class="badge gray">퇴근 미확정</span>' : '');
  const at = kind === 'IN' ? p.check_in_at : p.check_out_at;
  const by = kind === 'IN' ? p.check_in_by : p.check_out_by;
  const role = kind === 'IN' ? p.check_in_role : p.check_out_role;
  const name = (kind === 'IN' ? ATT_IN : ATT_OUT)[code];
  const cls = { good: 'ok', warn: 'warn', bad: 'danger' }[ATT_CLASS[code]] || 'gray';
  return `<span class="badge ${cls}">${name}</span> ${escapeHtml(kstTime(at))} · 입력 ${escapeHtml(by || '-')}${role ? `(${escapeHtml(ROLE_NAMES[role] || role)})` : ''}`;
}
function renderAttendance() {
  const d = attData;
  const all = d.teams.flatMap(t => t.people);
  const n = (k, code) => all.filter(p => p[k] === code).length;
  $('attendanceTitle').textContent = `출역 현황 · ${kstDateLabel(d.date)}`;
  const cells = [['인원', all.length, ''], ['출근', n('check_in_status', 'PRESENT'), ''], ['지각', n('check_in_status', 'LATE'), n('check_in_status', 'LATE') ? 'warn' : ''],
    ['결근', n('check_in_status', 'ABSENT'), n('check_in_status', 'ABSENT') ? 'danger' : ''], ['휴무', n('check_in_status', 'OFF'), ''],
    ['출근 미확정', all.filter(p => !p.check_in_status).length, all.some(p => !p.check_in_status) ? 'warn' : ''],
    ['퇴근', n('check_out_status', 'LEFT'), ''], ['조퇴', n('check_out_status', 'EARLY'), n('check_out_status', 'EARLY') ? 'warn' : ''], ['미퇴근', n('check_out_status', 'NOT_LEFT'), n('check_out_status', 'NOT_LEFT') ? 'danger' : '']];
  $('attendanceBody').innerHTML = `<div class="section-title"><strong>${escapeHtml(kstDateLabel(d.date))} 출역${d.date === d.today ? ' (오늘)' : ''}</strong><span class="badge">${d.can_correct ? '관리자 정정 가능' : '조회만'}</span></div>
    <div class="desc">팀장이 확정한 출근·퇴근입니다. 공식 소속 팀 기준이며, 다른 팀 작업에 투입된 인원도 원래 팀에서 처리합니다.${d.can_correct ? ' 관리자는 오늘부터 7일 전까지 정정할 수 있고, 정정은 이력에 남습니다.' : ''}</div>
    <div class="summary-grid">${cells.map(([label, value, cls]) => `<div class="sum ${cls}"><b>${value}</b><span>${label}</span></div>`).join('')}</div>
    ${d.teams.length ? d.teams.map(t => {
      const inDone = t.people.filter(p => p.check_in_status).length;
      const outs = t.people.filter(p => ['PRESENT', 'LATE'].includes(p.check_in_status));
      const outDone = outs.filter(p => p.check_out_status).length;
      return `<details class="att-team" data-att-team="${t.team_id}" ${inDone < t.people.length ? 'open' : ''}><summary><span>${escapeHtml(t.team_name)}</span><span class="badge ${inDone === t.people.length ? 'ok' : 'warn'}">출근 ${inDone}/${t.people.length} · 퇴근 ${outDone}/${outs.length}</span></summary>
        <div class="att-team-body">${t.people.map(p => `<div class="att-person" data-att-person="${p.person_id}"><strong>${escapeHtml(p.name)}</strong>${p.is_leader ? ' <span class="task-tag">팀장</span>' : ''}${p.corrections ? ` <span class="badge">수정 ${p.corrections}회</span>` : ''}
          <div>출근: ${attLine(p, 'IN')}</div>${attLine(p, 'OUT') ? `<div>퇴근: ${attLine(p, 'OUT')}</div>` : ''}
          ${d.can_correct ? `<div class="att-fix-row"><select data-fix-in aria-label="${escapeHtml(p.name)} 출근 정정"><option value="">출근 그대로</option>${Object.entries(ATT_IN).map(([c, nm]) => `<option value="${c}" ${p.check_in_status === c ? 'disabled' : ''}>${nm}(으)로</option>`).join('')}</select>
            <select data-fix-out aria-label="${escapeHtml(p.name)} 퇴근 정정"><option value="">퇴근 그대로</option>${Object.entries(ATT_OUT).map(([c, nm]) => `<option value="${c}" ${p.check_out_status === c ? 'disabled' : ''}>${nm}(으)로</option>`).join('')}</select></div>` : ''}</div>`).join('')
          || '<div class="team-meta">공식 소속 인원이 없습니다.</div>'}
          ${d.can_correct && t.people.length ? `<button class="detail-btn" type="button" data-fix-save="${t.team_id}">${escapeHtml(t.team_name)} 정정 저장</button>` : ''}</div></details>`;
    }).join('') : '<div class="team-meta">볼 수 있는 팀이 없습니다.</div>'}`;
}
// 관리자 정정: 바꾼 칸만 출근 → 퇴근 순서로 저장 (서버가 날짜·권한·출근 여부를 다시 확인)
async function saveCorrection(teamId) {
  if (loading || !attData?.can_correct) return;
  const box = document.querySelector(`[data-att-team="${teamId}"]`);
  const rows = [...box.querySelectorAll('[data-att-person]')];
  const ins = rows.map(r => ({ person_id: r.dataset.attPerson, status: r.querySelector('[data-fix-in]').value })).filter(x => x.status);
  const outs = rows.map(r => ({ person_id: r.dataset.attPerson, status: r.querySelector('[data-fix-out]').value })).filter(x => x.status);
  if (!ins.length && !outs.length) { tell('정정할 칸을 먼저 골라주세요.', 'error'); return; }
  const team = attData.teams.find(t => t.team_id === teamId);
  const name = id => team.people.find(p => p.person_id === id)?.name || '-';
  if (!confirm(`${kstDateLabel(attData.date)} ${team.team_name} 출역을 정정합니다. 이력에 남습니다.\n${[...ins.map(x => `${name(x.person_id)} 출근 → ${ATT_IN[x.status]}`), ...outs.map(x => `${name(x.person_id)} 퇴근 → ${ATT_OUT[x.status]}`)].join('\n')}`)) return;
  setLoading(true);
  try {
    const rid = () => (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random());
    if (ins.length) await rpc('tbm_attendance_save', { p_payload: { team_id: teamId, kind: 'IN', work_date: attData.date, entries: ins, request_id: rid() } });
    if (outs.length) await rpc('tbm_attendance_save', { p_payload: { team_id: teamId, kind: 'OUT', work_date: attData.date, entries: outs, request_id: rid() } });
    tell(`${team.team_name} 출역을 정정했습니다.`, 'ok');
  } catch (e) { handleError(e); }
  finally { setLoading(false); }
  await openAttendance();
}

// ---------- 이벤트 ----------
$('teamList').addEventListener('click', e => { const id = e.target.closest('[data-detail]')?.dataset.detail; if (id) openDetail(id); });
$('openAttendance').addEventListener('click', () => openAttendance());
$('attendanceRefresh').addEventListener('click', async () => { if (await openAttendance()) tell('최신 출역을 불러왔습니다.'); });
$('attendanceBody').addEventListener('click', e => { const id = e.target.closest('[data-fix-save]')?.dataset.fixSave; if (id) saveCorrection(id); });
document.addEventListener('click', e => { const go = e.target.closest('[data-go]')?.dataset.go; if (go) { showStage(go); if (go === 'stageList') loadOverview({ quiet: true }); } });
$('refreshBtn').addEventListener('click', async () => { if (await loadOverview()) tell('최신 현황을 불러왔습니다.'); });
$('detailRefresh').addEventListener('click', () => detailId && openDetail(detailId));
$('dateInput').addEventListener('change', () => loadOverview());
$('logoutBtn').addEventListener('click', async () => { if (!confirm('로그아웃할까요?')) return; await logout(); location.replace(pageUrl('login')); });
$('goLogin').addEventListener('click', async () => { await logout(); location.replace(loginUrl(PAGE)); });

$('filters').addEventListener('click', e => {
  const f = e.target.closest('[data-filter]')?.dataset.filter; if (!f || !overview) return;
  filter = f;
  document.querySelectorAll('[data-filter]').forEach(b => b.classList.toggle('selected', b.dataset.filter === f));
  renderOverview();
});
// 선택형 자동 새로고침: 목록 화면이 보이고 있을 때만 60초마다 (Realtime 사용 안 함)
function setAutoRefresh(on) {
  clearInterval(autoTimer); autoTimer = null;
  if (on) autoTimer = setInterval(() => {
    if (document.visibilityState === 'visible' && $('stageList').classList.contains('active') && !loading) loadOverview({ quiet: true });
  }, 60000);
  try { localStorage.setItem(AUTO_KEY, on ? '1' : '0'); } catch (_) {}
}
$('autoRefresh').addEventListener('change', e => setAutoRefresh(e.target.checked));
try { $('autoRefresh').checked = localStorage.getItem(AUTO_KEY) === '1'; } catch (_) {}
if ($('autoRefresh').checked) setAutoRefresh(true);

// 운영 화면에는 TEST 표시를 하지 않는다
const VERSION_LABEL = PROD ? 'v1.1' : `v${PAGE_VERSION} TEST`;
$('pageVersion').textContent = VERSION_LABEL; $('footerVersion').textContent = VERSION_LABEL;
if (requireLogin(PAGE)) loadOverview();
