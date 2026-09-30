// 현장 TBM 현황 시험 화면 (tbm_manager_test v0.1: 소장·관리자 읽기 전용)
// 볼 수 있는 현장·팀은 서버(tbm_site_overview)가 정한다. 이 화면에는 저장 기능이 없다.
import { rpc, requireLogin, logout, loginUrl, describeError, escapeHtml, kstTime, kstDateLabel, signedUrls, PHOTO_BUCKET } from './tbm_api_test.mjs';

const PAGE = 'tbm_manager_test.html';
const PAGE_VERSION = '0.1';
const BLOCKING = ['AUTH_REQUIRED', 'AUTH_EXPIRED', 'SESSION_EXPIRED', 'ACCOUNT_NOT_LINKED', 'ACCOUNT_INACTIVE', 'ACCOUNT_DISABLED', 'PIN_CHANGE_REQUIRED', 'FORBIDDEN'];
const KIND_NAMES = { MORNING: '출근', AFTERNOON: '오후', EVENING: '퇴근' };
const $ = id => document.getElementById(id);

let overview = null;
let detailId = null;
let loading = false;

function tell(text, kind = '') { $('message').textContent = text; $('message').className = 'message' + (kind ? ' ' + kind : ''); }
function setLoading(on) { loading = on; $('loadingOverlay').classList.toggle('active', on); }
function showStage(id) { document.querySelectorAll('.app-stage').forEach(s => s.classList.toggle('active', s.id === id)); window.scrollTo({ top: 0 }); }
function block(text) {
  document.querySelectorAll('.app-stage').forEach(s => s.classList.remove('active'));
  $('blocked').hidden = false; $('blockedText').textContent = text; tell('');
  $('headerSub').textContent = '소장·관리자 업무계정으로 로그인해야 사용할 수 있습니다.';
}
function handleError(e) {
  if (BLOCKING.includes(e.code)) block(e.code === 'FORBIDDEN' ? '소장·관리자 계정만 사용할 수 있는 화면입니다. 업무계정(소장·관리자)으로 로그인해주세요.' : describeError(e));
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
  $('teamList').innerHTML = overview.teams.length ? overview.teams.map(teamCard).join('')
    : '<section class="card"><div class="desc" style="margin:0">볼 수 있는 팀이 없습니다. 팀장 소속·역할 등록 상태를 확인해주세요.</div></section>';
  if (!document.querySelector('.app-stage.active')) showStage('stageList');
}

function teamCard(t) {
  const r = t.report;
  const state = reportState(r);
  if (!r) return `<div class="team-card missing" data-team="${escapeHtml(t.team_name)}"><div class="team-head"><div class="team-name">${escapeHtml(t.team_name)}</div><span class="badge gray">미보고</span></div>
    <div class="team-meta">${escapeHtml(kstDateLabel(overview.date))} 작업계획이 아직 없습니다.</div></div>`;
  const photos = Object.entries(r.photo_counts || {}).filter(([, n]) => n > 0).map(([k, n]) => `${KIND_NAMES[k]} ${n}장`).join(' · ') || '없음';
  return `<div class="team-card ${r.needs_manager_check ? 'attention' : ''}" data-team="${escapeHtml(t.team_name)}">
    <div class="team-head"><div><div class="team-name">${escapeHtml(t.team_name)}</div>
      <div class="team-meta">보고자 ${escapeHtml(r.reporter_label)} · 작업 ${r.task_count}건 · 최근 ${escapeHtml(kstTime(r.updated_at))}</div></div>
      <span class="badge ${state.cls}">${state.text}</span></div>
    <div class="chips">
      <span class="badge ${r.morning_at ? 'ok' : 'gray'}">출근 ${r.morning_at ? escapeHtml(kstTime(r.morning_at)) : '전'}</span>
      ${r.needs_manager_check ? '<span class="badge danger">소장 확인 필요</span>' : ''}
      ${(r.risks || []).length ? `<span class="badge warn">위험요인 ${escapeHtml(r.risks.join(', '))}</span>` : ''}
    </div>
    ${r.issue_note ? `<div class="team-task"><strong>특이사항</strong> ${escapeHtml(r.issue_note)}</div>` : ''}
    ${(r.tasks || []).map(k => `<div class="team-task">작업 ${k.task_no} · ${escapeHtml(k.place)} — ${escapeHtml(k.content)}</div>`).join('')}
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
      <dt>출근 TBM</dt><dd>${r.morning_at ? `${escapeHtml(kstTime(r.morning_at))} 보고${r.morning_note ? ' · ' + escapeHtml(r.morning_note) : ''}` : '보고 전'}</dd></dl>
    <div class="detail-section"><h3>작업 ${r.tasks.length}건</h3><div class="plan-view">${r.tasks.map(t => `<div class="plan-view-item">
      <strong>작업 ${t.task_no} · ${escapeHtml(t.place)}${t.carried_from_task_id ? ' <span class="task-tag">이월</span>' : ''}</strong>
      <span>${escapeHtml(t.content)}</span>
      <span>인원 ${t.members.length}명: ${t.members.map(m => `${escapeHtml(m.name)}${m.role !== '작업자' ? `(${escapeHtml(m.role)})` : ''}`).join(', ') || '-'}</span></div>`).join('')}</div></div>
    <div class="detail-section"><h3>사진</h3>${photoKinds.length ? photoKinds.map(k => `<div class="photo-title">${KIND_NAMES[k]} TBM</div>
      <div class="photo-preview" style="margin-bottom:10px">${r.photos.filter(p => p.kind === k).map(p => `<a class="photo-thumb" target="_blank" rel="noopener" data-photo-link="${escapeHtml(p.path)}"><img alt="${KIND_NAMES[k]} 사진 ${escapeHtml(kstTime(p.created_at))}" data-photo-path="${escapeHtml(p.path)}"><span class="photo-state">${escapeHtml(kstTime(p.created_at))}</span></a>`).join('')}</div>`).join('') : '<div class="team-meta">올라온 사진이 없습니다.</div>'}</div>`;
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

$('pageVersion').textContent = `v${PAGE_VERSION} TEST`; $('footerVersion').textContent = `v${PAGE_VERSION} TEST`;
if (requireLogin(PAGE)) loadOverview();
