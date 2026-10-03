// 현장 TBM 현황 시험 화면 (tbm_manager_test v0.41: 현장관리·관리자(개인 로그인·업무계정) 읽기 전용 · 하루 전체 흐름 · 요약·필터·자동 새로고침·변경 이력)
// 볼 수 있는 현장·팀은 서버(tbm_site_overview)가 정한다. 이 화면에는 저장 기능이 없다.
import { rpc, requireLogin, logout, loginUrl, describeError, escapeHtml, kstTime, kstDateLabel, signedUrls, PHOTO_BUCKET } from './tbm_api_test.mjs';

const PAGE = 'tbm_manager_test.html';
const PAGE_VERSION = '0.41';
const AUTO_KEY = 'tbmManagerAutoRefresh_v1';
const HISTORY_NAMES = { PLAN_SAVE: '작업계획 저장', MORNING_SUBMIT: '출근 TBM 보고', AFTERNOON_ALL_CLEAR: '오후 전체 이상 없음', TASK_NORMAL: '작업 정상', TASK_CHANGED: '작업 변경', TASK_DELAYED: '작업 지연', TASK_RISK: '작업 위험', TASK_RESULT: '퇴근 결과 입력', EVENING_CLOSE: '퇴근 TBM 마감', PHOTO_ADD: '사진 추가', PHOTO_REMOVE: '사진 빼기' };
const BLOCKING = ['AUTH_REQUIRED', 'AUTH_EXPIRED', 'SESSION_EXPIRED', 'ACCOUNT_NOT_LINKED', 'ACCOUNT_INACTIVE', 'ACCOUNT_DISABLED', 'PIN_CHANGE_REQUIRED', 'FORBIDDEN'];
const KIND_NAMES = { MORNING: '출근', AFTERNOON: '오후', EVENING: '퇴근' };
const ALERT_NAMES = { NORMAL: '정상', CHANGED: '변경', DELAYED: '지연', RISK: '위험' };
const RESULT_NAMES = { DONE: '완료', PARTIAL: '일부완료', NOT_DONE: '미완료', EXCLUDED: '제외' };
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
  $('loadedAt').textContent = `최근 조회 ${kstTime(new Date().toISOString())} · 팀 ${overview.teams.length}개`;
  const teams = overview.teams;
  const reported = teams.filter(t => t.report);
  const sum = (k) => reported.reduce((n, t) => n + Number(t.report.alerts?.[k] || 0), 0);
  const cells = [
    ['팀', teams.length, ''], ['미보고', teams.length - reported.length, teams.length - reported.length ? 'warn' : ''],
    ['출근 보고', `${reported.filter(t => t.report.morning_at).length}/${teams.length}`, ''],
    ['소장 확인 필요', reported.filter(t => t.report.needs_manager_check).length, reported.some(t => t.report.needs_manager_check) ? 'danger' : ''],
    ['위험 작업', sum('RISK'), sum('RISK') ? 'danger' : ''], ['퇴근 마감', `${reported.filter(t => t.report.evening_at).length}/${teams.length}`, '']];
  $('summaryGrid').innerHTML = cells.map(([label, value, cls]) => `<div class="sum ${cls}"><b>${value}</b><span>${label}</span></div>`).join('');
  // 확인 필요 → 미보고 → 나머지 순
  const rank = t => (needsAttention(t) ? 0 : !t.report ? 1 : 2);
  const shown = [...teams].sort((a, b) => rank(a) - rank(b) || a.team_name.localeCompare(b.team_name, 'ko'))
    .filter(t => filter === 'all' || (filter === 'attention' ? needsAttention(t) : !t.report));
  $('teamList').innerHTML = !teams.length ? '<section class="card"><div class="desc" style="margin:0">볼 수 있는 팀이 없습니다. 팀장 소속·역할 등록 상태를 확인해주세요.</div></section>'
    : shown.length ? shown.map(teamCard).join('') : `<section class="card"><div class="desc" style="margin:0">${filter === 'attention' ? '확인이 필요한 팀이 없습니다.' : '미보고 팀이 없습니다.'}</div></section>`;
  if (!document.querySelector('.app-stage.active')) showStage('stageList');
}

function needsAttention(t) { return !!t.report && (t.report.needs_manager_check || Number(t.report.alerts?.RISK || 0) > 0); }
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
    <div class="team-head"><div><div class="team-name">${escapeHtml(t.team_name)}</div>
      <div class="team-meta">보고자 ${escapeHtml(r.reporter_label)} · 작업 ${r.task_count}건 · 최근 ${escapeHtml(kstTime(r.updated_at))}</div></div>
      <span class="badge ${state.cls}">${state.text}</span></div>
    <div class="chips">
      <span class="badge ${r.morning_at ? 'ok' : 'gray'}">출근 ${r.morning_at ? escapeHtml(kstTime(r.morning_at)) : '전'}</span>
      <span class="badge ${r.afternoon_at ? 'ok' : 'gray'}">오후 ${r.afternoon_at ? escapeHtml(kstTime(r.afternoon_at)) : '전'}</span>
      <span class="badge ${r.evening_at ? 'ok' : 'gray'}">퇴근 ${r.evening_at ? escapeHtml(kstTime(r.evening_at)) : '전'}</span>
      ${r.needs_manager_check ? '<span class="badge danger">소장 확인 필요</span>' : ''}
      ${alerts.RISK ? `<span class="badge danger">위험 ${alerts.RISK}</span>` : ''}
      ${alerts.CHANGED ? `<span class="badge warn">변경 ${alerts.CHANGED}</span>` : ''}
      ${alerts.DELAYED ? `<span class="badge warn">지연 ${alerts.DELAYED}</span>` : ''}
      ${results.PARTIAL ? `<span class="badge warn">일부완료 ${results.PARTIAL}</span>` : ''}
      ${results.NOT_DONE ? `<span class="badge warn">미완료 ${results.NOT_DONE}</span>` : ''}
      ${r.carry_count ? `<span class="badge">이월 ${r.carry_count}</span>` : ''}
      ${(r.risks || []).length ? `<span class="badge warn">위험요인 ${escapeHtml(r.risks.join(', '))}</span>` : ''}
    </div>
    ${r.issue_note ? `<div class="team-task"><strong>특이사항</strong> ${escapeHtml(r.issue_note)}</div>` : ''}
    ${(r.tasks || []).map(k => `<div class="team-task">작업 ${k.task_no} · ${escapeHtml(k.place)} — ${escapeHtml(k.content)}${['CHANGED', 'DELAYED', 'RISK'].includes(k.alert) ? ` <span class="alert-line ${k.alert}">[${ALERT_NAMES[k.alert]}]</span>` : ''}${k.result ? ` <span class="badge ${k.result === 'DONE' ? 'ok' : k.result === 'EXCLUDED' ? 'gray' : 'warn'}">${RESULT_NAMES[k.result]}${k.carry_over ? '·이월' : ''}</span>` : ''}</div>`).join('')}
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
  $('detailTitle').textContent = `${r.team_name} · ${kstDateLabel(r.work_date)}`;
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
      <span>퇴근: ${t.result ? `<strong>${RESULT_NAMES[t.result]}</strong>` : '미입력'}${t.result_note ? ' · ' + escapeHtml(t.result_note) : ''}${t.carry_over ? ` · 이월: ${escapeHtml(t.carry_note || '')}${t.carry_status === 'CONTINUED' ? ' (이어받음)' : t.carry_status === 'DROPPED' ? ' (이어받지 않음)' : ''}` : ''}</span></div>`).join('')}</div></div>
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

// ---------- 이벤트 ----------
$('teamList').addEventListener('click', e => { const id = e.target.closest('[data-detail]')?.dataset.detail; if (id) openDetail(id); });
document.addEventListener('click', e => { const go = e.target.closest('[data-go]')?.dataset.go; if (go) { showStage(go); if (go === 'stageList') loadOverview({ quiet: true }); } });
$('refreshBtn').addEventListener('click', async () => { if (await loadOverview()) tell('최신 현황을 불러왔습니다.'); });
$('detailRefresh').addEventListener('click', () => detailId && openDetail(detailId));
$('dateInput').addEventListener('change', () => loadOverview());
$('logoutBtn').addEventListener('click', async () => { if (!confirm('로그아웃할까요?')) return; await logout(); location.replace('personnel_test.html'); });
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

$('pageVersion').textContent = `v${PAGE_VERSION} TEST`; $('footerVersion').textContent = `v${PAGE_VERSION} TEST`;
if (requireLogin(PAGE)) loadOverview();
