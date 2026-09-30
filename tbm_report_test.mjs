// 팀장 TBM 보고 시험 화면 (tbm_report_test v0.3: 오늘 작업계획 · 출근 TBM · TBM 사진)
// 팀·날짜·보고자는 서버(tbm_today)가 정한다. 화면은 서버 저장이 성공한 뒤에만 "저장됨"을 표시한다.
import { rpc, requireLogin, logout, loginUrl, describeError, requestIdFor, escapeHtml, kstTime, kstDateLabel, kstNowHour, compressImage, sha256Hex, uploadPhoto, signedUrls, PHOTO_BUCKET } from './tbm_api_test.mjs';

const PAGE = 'tbm_report_test.html';
const PAGE_VERSION = '0.3';
const DRAFT_KEY = 'tbmReportDraft_v1';
const RISKS = ['고소작업', '전기', '중량물', '화기', '장비사용', '기타'];
const ROLES = ['작업자', '작업지휘자', '신호수', '화기감시자', '유도원', '기타'];
const BLOCKING = ['AUTH_REQUIRED', 'AUTH_EXPIRED', 'SESSION_EXPIRED', 'ACCOUNT_NOT_LINKED', 'ACCOUNT_INACTIVE', 'ACCOUNT_DISABLED', 'PIN_CHANGE_REQUIRED', 'FORBIDDEN', 'TEAM_NOT_READY', 'TEAM_REQUIRED'];
const $ = id => document.getElementById(id);

let today = null;      // tbm_today 결과
let form = null;       // 작업계획 입력 상태
let dirty = false;     // 서버에 저장되지 않은 변경
let busy = false;      // 저장 중 (중복 전송 방지)
let draftTimer = null;
let taskSeq = 0;
const slots = { plan: {}, morning: {} };
const RELOAD_CODES = ['VERSION_CONFLICT', 'REPORT_NOT_EDITABLE', 'REPORT_NOT_FOUND', 'TASK_NOT_FOUND', 'TASK_CLOSED', 'CARRY_NOT_AVAILABLE'];

function tell(text, kind = '') { $('message').textContent = text; $('message').className = 'message' + (kind ? ' ' + kind : ''); }
// 저장 중에는 화면 전체를 덮어 추가 입력·중복 전송을 막는다 (busy 플래그로 한 번 더 확인)
function setBusy(on, title = '저장 중입니다') {
  busy = on;
  $('loadingTitle').textContent = title;
  $('loadingOverlay').classList.toggle('active', on);
  $('loadingOverlay').setAttribute('aria-hidden', on ? 'false' : 'true');
}
function showStage(id) {
  document.querySelectorAll('.app-stage').forEach(s => s.classList.toggle('active', s.id === id));
  window.scrollTo({ top: 0 });
}
function block(text) {
  document.querySelectorAll('.app-stage').forEach(s => s.classList.remove('active'));
  $('blocked').hidden = false; $('blockedText').textContent = text; tell('');
  $('headerSub').textContent = '팀장 계정으로 로그인해야 사용할 수 있습니다.';
}
const report = () => today?.report || null;
const editable = () => !report() || report().status !== 'CONFIRMED';

// ---------- 서버 → 입력 상태 ----------
function formFromReport(r) {
  return {
    base_version: r ? r.version : null,
    end_time: r?.end_time || '',
    risks: [...(r?.risks || [])],
    risk_other: r?.risk_other || '',
    safety_note: r?.safety_note || '',
    issue_note: r?.issue_note || '',
    needs_manager_check: !!r?.needs_manager_check,
    tasks: (r?.tasks || []).map(t => ({
      key: 't' + (++taskSeq), id: t.id, task_no: t.task_no, place: t.place, content: t.content,
      closed: !!t.result, carried_from_task_id: t.carried_from_task_id || null,
      members: t.members.map(m => ({ person_id: m.person_id, role: m.role })),
    })),
  };
}
function emptyTask() { return { key: 't' + (++taskSeq), id: null, task_no: null, place: '', content: '', closed: false, carried_from_task_id: null, members: [] }; }

// ---------- 이 기기 임시저장 (서버 저장과 구분) ----------
function draftOwner() { return today ? `${today.team.id}|${today.today}|${today.actor.person_id || today.actor.name}` : ''; }
function saveDraftSoon() {
  dirty = true; renderServerState();
  clearTimeout(draftTimer);
  draftTimer = setTimeout(() => {
    try {
      localStorage.setItem(DRAFT_KEY, JSON.stringify({ owner: draftOwner(), base_version: form.base_version, saved_at: Date.now(), form }));
      $('draftStatus').innerHTML = `<strong>임시저장:</strong> 이 기기에 ${escapeHtml(kstTime(new Date().toISOString()))} 저장 (서버 저장 전)`;
    } catch (_) { $('draftStatus').innerHTML = '<strong>임시저장:</strong> 이 기기에 저장하지 못했습니다'; }
  }, 500);
}
function clearDraft() {
  clearTimeout(draftTimer);
  try { localStorage.removeItem(DRAFT_KEY); } catch (_) {}
  $('draftStatus').innerHTML = '<strong>임시저장:</strong> 없음';
}
function restoreDraft() {
  let draft = null;
  try { draft = JSON.parse(localStorage.getItem(DRAFT_KEY) || 'null'); } catch (_) {}
  if (!draft || draft.owner !== draftOwner()) { if (draft) clearDraft(); return false; }
  if (draft.base_version !== (report()?.version ?? null)) {
    clearDraft();
    tell('서버의 작업계획이 이 기기의 임시저장보다 최신이라 서버 내용을 표시합니다.');
    return false;
  }
  form = draft.form; form.tasks.forEach(t => { t.key = 't' + (++taskSeq); });
  dirty = true;
  $('draftStatus').innerHTML = `<strong>임시저장:</strong> 이 기기의 ${escapeHtml(kstTime(new Date(draft.saved_at).toISOString()))} 내용을 불러옴 (서버 저장 전)`;
  return true;
}

// ---------- 불러오기 ----------
async function load({ quiet = false } = {}) {
  if (!quiet) setBusy(true, '불러오는 중입니다');
  try {
    today = await rpc('tbm_today', {});
    form = formFromReport(report()); dirty = false;
    const restored = restoreDraft();
    renderAll();
    if (restored) tell('이 기기에 임시저장된 작업계획을 불러왔습니다. 아직 서버에는 저장되지 않았습니다.');
    return true;
  } catch (e) {
    if (BLOCKING.includes(e.code)) {
      block(e.code === 'FORBIDDEN' ? '팀장 계정만 사용할 수 있는 화면입니다. 팀장 개인 PIN 또는 팀 공용 팀장계정으로 로그인해주세요.' : describeError(e));
    } else tell(describeError(e), 'error');
    return false;
  } finally { if (!quiet) setBusy(false); }
}

// ---------- 화면 그리기 ----------
function renderAll() {
  $('blocked').hidden = true;
  const r = report();
  $('headerSub').textContent = `${today.team.name} · ${today.site.name || today.site.code} · ${kstDateLabel(today.today)} · ${today.actor.name} ${today.actor.role_label || ''}`.trim();
  $('homeTitle').textContent = `${kstDateLabel(today.today)} ${today.team.name}`;
  $('homeSub').textContent = r ? `보고자 ${r.reporter_label} · 작업 ${r.tasks.length}건 · 최근 저장 ${kstTime(r.updated_at)}` : '아직 오늘 작업계획이 없습니다. 작업계획부터 저장해주세요.';
  $('homeStatus').textContent = !r ? '미작성' : r.status === 'CONFIRMED' ? '소장 확인 완료' : r.evening_at ? '퇴근 마감' : r.morning_at ? '출근 보고 완료' : '계획 저장';
  $('homeStatus').className = 'badge' + (!r ? ' gray' : r.status === 'CONFIRMED' || r.evening_at ? ' ok' : '');
  const steps = [['계획', !!r], ['출근', !!r?.morning_at], ['오후', !!r?.afternoon_at], ['퇴근', !!r?.evening_at]];
  const now = steps.findIndex(s => !s[1]);
  $('homeSteps').innerHTML = steps.map(([label, done], i) => `<div class="step ${done ? 'done' : i === now ? 'now' : ''}">${label}${done ? ' ✓' : ''}</div>`).join('');
  $('openPlanSub').textContent = r ? '보기 · 수정' : '먼저 작성';
  $('openMorningSub').textContent = r?.morning_at ? `보고 완료 ${kstTime(r.morning_at)}` : '작업계획 공유';
  $('openMorning').classList.toggle('done', !!r?.morning_at);
  const hour = kstNowHour();
  const recommended = !r ? 'openPlan' : !r.morning_at || hour < 11 ? 'openMorning' : null;
  ['openPlan', 'openMorning'].forEach(id => $(id).classList.toggle('recommended', id === recommended));
  renderPlan();
  renderMorning();
  renderPhotos();
  if (!document.querySelector('.app-stage.active')) showStage('stageHome');
}

function memberName(personId) { return today.members.find(m => m.person_id === personId)?.name || today.report?.tasks.flatMap(t => t.members).find(m => m.person_id === personId)?.name || '(팀 외 인원)'; }
function renderPlan() {
  const locked = !editable();
  $('planLocked').hidden = !locked;
  $('planLocked').textContent = locked ? '소장 확인이 끝난 보고라 수정할 수 없습니다.' : '';
  $('endTime').value = form.end_time;
  $('riskGrid').innerHTML = RISKS.map(r => `<label class="risk"><input type="checkbox" value="${r}" ${form.risks.includes(r) ? 'checked' : ''}>${r}</label>`).join('');
  $('riskOtherField').hidden = !form.risks.includes('기타');
  $('riskOther').value = form.risk_other; $('safetyNote').value = form.safety_note; $('issueNote').value = form.issue_note;
  $('needsCheck').checked = form.needs_manager_check;
  renderTasks();
  document.querySelectorAll('#stagePlan input, #stagePlan textarea, #stagePlan select').forEach(el => { if (locked) el.disabled = true; });
  $('addTask').disabled = locked; $('savePlan').disabled = locked;
  renderServerState();
}
function otherTaskNos(task, personId) {
  return form.tasks.filter(t => t !== task && t.members.some(m => m.person_id === personId)).map(t => '작업' + (form.tasks.indexOf(t) + 1));
}
function renderTasks() {
  if (!form.tasks.length) form.tasks.push(emptyTask());
  const lockMap = new Map((today.locks || []).map(l => [l.person_id, l]));
  $('taskList').innerHTML = form.tasks.map((task, i) => {
    const members = today.members.length ? today.members.map(m => {
      const chosen = task.members.find(x => x.person_id === m.person_id);
      const lock = lockMap.get(m.person_id);
      const disabled = task.closed || (!!lock && !chosen);
      const others = otherTaskNos(task, m.person_id);
      return `<label class="task-member ${lock && !chosen ? 'locked' : ''}">
        <input type="checkbox" data-member="${m.person_id}" ${chosen ? 'checked' : ''} ${disabled ? 'disabled' : ''}>
        <span>${escapeHtml(m.name)}</span>
        ${lock ? `<span class="task-member-assigned">${escapeHtml(lock.team_name)} 배정중</span>` : ''}
        ${others.length ? `<span class="task-member-assigned">${others.join('·')} 중복</span>` : ''}
        <span class="member-sub">${escapeHtml([m.rank, m.job].filter(Boolean).join(' · ') || (m.is_leader ? '팀장' : '팀원'))}</span>
        ${chosen ? `<select class="task-role-select" data-role="${m.person_id}" ${disabled ? 'disabled' : ''} aria-label="${escapeHtml(m.name)} 역할">
          ${ROLES.map(r => `<option ${chosen.role === r ? 'selected' : ''}>${r}</option>`).join('')}
        </select>` : ''}
      </label>`;
    }).join('') : '<div class="task-member-empty">서버에 등록된 우리 팀 인원이 없습니다. 관리자에게 팀 소속 등록을 요청해주세요.</div>';
    return `<div class="task-card ${task.closed ? 'closed' : ''}" data-task="${task.key}">
      <div class="task-head">
        <div class="task-title">작업 ${i + 1}${task.carried_from_task_id ? '<span class="task-tag">이월</span>' : ''}${task.closed ? '<span class="task-tag">결과 입력됨</span>' : ''}</div>
        ${task.closed ? '' : `<button class="task-remove" type="button" data-remove="${task.key}">삭제</button>`}
      </div>
      <div class="field"><label class="label">작업 위치</label><input data-tfield="place" maxlength="120" placeholder="예: 3층 MDF실 / A구역" value="${escapeHtml(task.place)}" ${task.closed ? 'disabled' : ''}></div>
      <div class="field"><label class="label">작업 내용</label><textarea data-tfield="content" maxlength="500" placeholder="예: 배선 작업 / 관로 작업" ${task.closed ? 'disabled' : ''}>${escapeHtml(task.content)}</textarea></div>
      <div class="member-head"><span class="label" style="margin:0">투입 인원</span><span class="member-count">${task.members.length}명 선택</span></div>
      <div class="task-members">${members}</div>
    </div>`;
  }).join('');
}
function renderServerState() {
  const r = report();
  const el = $('serverState');
  if (dirty) { el.className = 'server-state dirty'; el.textContent = '변경 내용이 아직 서버에 저장되지 않았습니다.'; }
  else if (r) { el.className = 'server-state ok'; el.textContent = `서버 저장됨 · ${kstTime(r.updated_at)} · 버전 ${r.version}`; }
  else { el.className = 'server-state'; el.textContent = '아직 서버에 저장된 작업계획이 없습니다.'; }
}

// ---------- 입력 ----------
function taskOf(el) { const key = el.closest('[data-task]')?.dataset.task; return form.tasks.find(t => t.key === key); }
$('stagePlan').addEventListener('input', e => {
  const el = e.target;
  if (el.dataset.field && el.type !== 'checkbox') { form[el.dataset.field] = el.value; saveDraftSoon(); return; }
  if (el.dataset.tfield) { const t = taskOf(el); if (t) { t[el.dataset.tfield] = el.value; saveDraftSoon(); } }
});
$('stagePlan').addEventListener('change', e => {
  const el = e.target;
  if (el.id === 'needsCheck') { form.needs_manager_check = el.checked; saveDraftSoon(); return; }
  if (el.closest('#riskGrid')) {
    form.risks = [...document.querySelectorAll('#riskGrid input:checked')].map(x => x.value);
    $('riskOtherField').hidden = !form.risks.includes('기타'); saveDraftSoon(); return;
  }
  const task = taskOf(el); if (!task) return;
  if (el.dataset.member) {
    if (el.checked) task.members.push({ person_id: el.dataset.member, role: '작업자' });
    else task.members = task.members.filter(m => m.person_id !== el.dataset.member);
    renderTasks(); saveDraftSoon(); return;
  }
  if (el.dataset.role) { const m = task.members.find(x => x.person_id === el.dataset.role); if (m) m.role = el.value; saveDraftSoon(); }
});
$('taskList').addEventListener('click', e => {
  const key = e.target.dataset?.remove; if (!key) return;
  const task = form.tasks.find(t => t.key === key);
  if ((task.place || task.content || task.members.length) && !confirm('이 작업을 목록에서 뺄까요? 저장해야 서버에 반영됩니다.')) return;
  form.tasks = form.tasks.filter(t => t.key !== key);
  renderTasks(); saveDraftSoon();
});
$('addTask').addEventListener('click', () => {
  if (form.tasks.length >= 20) { tell('작업은 최대 20개까지 입력할 수 있습니다.', 'error'); return; }
  form.tasks.push(emptyTask()); renderTasks(); saveDraftSoon();
  $('taskList').lastElementChild?.querySelector('input')?.focus();
});
$('draftClear').addEventListener('click', () => {
  if (!confirm('이 기기의 임시저장을 지우고 서버에 저장된 내용으로 되돌릴까요?')) return;
  clearDraft(); form = formFromReport(report()); dirty = false; renderPlan(); tell('서버에 저장된 내용으로 되돌렸습니다.');
});

// ---------- 저장 ----------
function validatePlan() {
  if (!form.tasks.length) return '작업을 1개 이상 입력해주세요.';
  for (const [i, t] of form.tasks.entries()) {
    if (t.closed) continue;
    if (!t.place.trim() || !t.content.trim()) return `작업 ${i + 1}의 작업 위치와 작업 내용을 입력해주세요.`;
    if (!t.members.length) return `작업 ${i + 1}에 투입할 인원을 1명 이상 선택해주세요.`;
  }
  if (form.risks.includes('기타') && !form.risk_other.trim()) return '기타 위험요인 내용을 적어주세요.';
  return '';
}
function buildPayload() {
  return {
    team_id: today.team.id,
    version: form.base_version,
    end_time: form.end_time || null,
    risks: form.risks, risk_other: form.risks.includes('기타') ? form.risk_other.trim() : '',
    safety_note: form.safety_note.trim(), issue_note: form.issue_note.trim(),
    needs_manager_check: form.needs_manager_check,
    tasks: form.tasks.map(t => ({ id: t.id || null, place: t.place.trim(), content: t.content.trim(), carried_from_task_id: t.carried_from_task_id || null, members: t.members })),
    drop_carry_ids: form.drop_carry_ids || [],
  };
}
async function savePlan() {
  if (busy) return;
  const problem = validatePlan();
  if (problem) { tell(problem, 'error'); return; }
  const dup = [...new Set(form.tasks.flatMap(t => t.members.map(m => m.person_id)).filter((id, i, all) => all.indexOf(id) !== i))];
  if (dup.length && !confirm(`다음 인원이 여러 작업에 중복 배정되어 있습니다.\n${dup.map(memberName).join(', ')}\n\n그래도 저장할까요?`)) return;
  const payload = buildPayload();
  const request_id = requestIdFor(slots.plan, payload);
  setBusy(true, '작업계획 저장 중');
  try {
    const result = await rpc('tbm_save_plan', { p_payload: { ...payload, request_id } });
    slots.plan = {};
    today.report = result.report; form = formFromReport(result.report); dirty = false; clearDraft();
    renderAll();
    tell(`작업계획을 서버에 저장했습니다 (${kstTime(result.report.updated_at)}, 작업 ${result.report.tasks.length}건).`, 'ok');
  } catch (e) {
    if (e.code === 'VERSION_CONFLICT' || e.code === 'CARRY_NOT_AVAILABLE' || e.code === 'TASK_NOT_FOUND') {
      slots.plan = {}; clearDraft();
      await load({ quiet: true });
      tell(describeError(e) + ' 확인 후 필요한 내용을 다시 입력해주세요.', 'error');
    } else if (e.code === 'REPORT_NOT_EDITABLE') {
      slots.plan = {}; await load({ quiet: true }); tell(describeError(e), 'error');
    } else tell(describeError(e) + (e.code === 'NETWORK' || e.code === 'TIMEOUT' ? '' : ' (서버에 저장되지 않았습니다)'), 'error');
  } finally { setBusy(false); }
}
$('savePlan').addEventListener('click', savePlan);

// ---------- 출근 TBM ----------
function risksText(r) { return [...(r.risks || []).filter(x => x !== '기타'), ...(r.risks?.includes('기타') ? [`기타(${r.risk_other || '-'})`] : [])].join(', ') || '없음'; }
function tasksHtml(r) {
  return r.tasks.map(t => `<div class="plan-view-item"><strong>작업 ${t.task_no} · ${escapeHtml(t.place)}</strong>
    <span>${escapeHtml(t.content)}</span>
    <span>인원: ${t.members.map(m => `${escapeHtml(m.name)}${m.role !== '작업자' ? `(${escapeHtml(m.role)})` : ''}`).join(', ') || '-'}</span></div>`).join('');
}
function renderMorning() {
  const r = report();
  const done = !!r?.morning_at;
  $('morningBadge').textContent = done ? `보고 완료 ${kstTime(r.morning_at)}` : '보고 전';
  $('morningBadge').className = 'badge' + (done ? ' ok' : '');
  if (!r) {
    $('morningSummary').textContent = '오늘 작업계획이 아직 없습니다. 작업계획을 먼저 저장해주세요.';
    $('morningTasks').innerHTML = ''; $('submitMorning').disabled = true; $('morningState').textContent = ''; return;
  }
  $('morningSummary').innerHTML = `<dl class="kv"><dt>예상 종료</dt><dd>${escapeHtml(r.end_time || '-')}</dd>
    <dt>위험요인</dt><dd>${escapeHtml(risksText(r))}</dd><dt>안전조치</dt><dd>${escapeHtml(r.safety_note || '-')}</dd>
    ${r.issue_note ? `<dt>특이사항</dt><dd>${escapeHtml(r.issue_note)}</dd>` : ''}${r.needs_manager_check ? '<dt>소장 확인</dt><dd>필요</dd>' : ''}</dl>`;
  $('morningTasks').innerHTML = tasksHtml(r);
  if (done) { $('morningNote').value = r.morning_note || ''; }
  $('morningNote').disabled = done || !editable();
  $('submitMorning').disabled = done || !editable();
  $('submitMorning').textContent = done ? '출근 TBM 보고 완료' : '출근 TBM 보고';
  $('morningState').className = 'server-state' + (done ? ' ok' : '');
  $('morningState').textContent = done ? `서버 저장됨 · ${kstTime(r.morning_at)} 보고` : '아직 보고하지 않았습니다.';
}
// 작업계획에 저장하지 않은 변경이 있으면 다른 보고를 막는다 (서버 최신 버전과 어긋나지 않게)
function planIsDirty() {
  if (!dirty) return false;
  tell('작업계획에 저장하지 않은 변경이 있습니다. 작업계획을 먼저 저장하거나 임시저장을 삭제해주세요.', 'error');
  return true;
}
function applyReport(r) {
  today.report = r;
  if (!dirty) form = formFromReport(r);
  renderAll();
}
async function handleActionError(e) {
  if (RELOAD_CODES.includes(e.code)) { await load({ quiet: true }); tell(describeError(e), 'error'); }
  else if (BLOCKING.includes(e.code)) block(describeError(e));
  else tell(describeError(e) + (e.code === 'NETWORK' || e.code === 'TIMEOUT' ? '' : ' (서버에 저장되지 않았습니다)'), 'error');
}
async function submitMorning() {
  const r = report();
  if (busy || !r || r.morning_at || planIsDirty()) return;
  const note = $('morningNote').value.trim();
  const request_id = requestIdFor(slots.morning, { id: r.id, note });
  setBusy(true, '출근 TBM 보고 중');
  try {
    const res = await rpc('tbm_submit_morning', { p_report_id: r.id, p_note: note || null, p_request_id: request_id });
    slots.morning = {};
    applyReport(res.report);
    tell(`출근 TBM을 보고했습니다 (${kstTime(res.report.morning_at)}).`, 'ok');
  } catch (e) { await handleActionError(e); }
  finally { setBusy(false); }
}
$('submitMorning').addEventListener('click', submitMorning);
$('openMorning').addEventListener('click', async () => {
  if (!dirty) await load({ quiet: true });
  if (!report()) { tell('오늘 작업계획을 먼저 저장해주세요.', 'error'); showStage('stagePlan'); return; }
  showStage('stageMorning');
});

// ---------- TBM 사진 (회차마다 최대 3장, 비공개 버킷) ----------
const PHOTO_LIMIT = 3;
const signedCache = new Map(); // path -> { url, until }
function photosOf(kind) { return (report()?.photos || []).filter(p => p.kind === kind); }
function renderPhotos() {
  document.querySelectorAll('[data-photo-kind]').forEach(box => {
    const kind = box.dataset.photoKind;
    const photos = photosOf(kind);
    const canEdit = !!report() && editable();
    const input = box.querySelector('[data-photo-input]');
    input.disabled = !canEdit || photos.length >= PHOTO_LIMIT;
    box.querySelector('[data-photo-count]').textContent = !report() ? '작업계획을 저장한 뒤 사진을 올릴 수 있습니다.'
      : `사진 ${photos.length}장 / 최대 ${PHOTO_LIMIT}장${photos.length >= PHOTO_LIMIT ? ' · 더 올리려면 한 장을 빼주세요' : ''}`;
    box.querySelector('[data-photo-preview]').innerHTML = photos.map(p => `<div class="photo-thumb" data-photo-id="${p.id}">
      <img alt="${escapeHtml(kstTime(p.created_at))} 사진" data-photo-path="${escapeHtml(p.path)}">
      <span class="photo-state">${escapeHtml(kstTime(p.created_at))}</span>
      ${canEdit ? `<button class="photo-remove" type="button" data-photo-remove="${p.id}" aria-label="사진 빼기">×</button>` : ''}</div>`).join('');
  });
  loadPhotoUrls().catch(() => {});
}
async function loadPhotoUrls() {
  const imgs = [...document.querySelectorAll('img[data-photo-path]')];
  const now = Date.now();
  const need = [...new Set(imgs.map(i => i.dataset.photoPath).filter(p => !(signedCache.get(p)?.until > now)))];
  if (need.length) {
    const urls = await signedUrls(PHOTO_BUCKET, need, 600);
    for (const [path, url] of Object.entries(urls)) signedCache.set(path, { url, until: now + 540000 });
  }
  imgs.forEach(img => { const hit = signedCache.get(img.dataset.photoPath); if (hit && img.src !== hit.url) img.src = hit.url; });
}
async function addPhotos(kind, input) {
  const r = report();
  const files = [...(input.files || [])];
  input.value = '';
  if (busy || !r || !files.length) return;
  const left = PHOTO_LIMIT - photosOf(kind).length;
  if (left <= 0) { tell(`사진은 회차마다 최대 ${PHOTO_LIMIT}장입니다.`, 'error'); return; }
  const list = files.slice(0, left);
  let added = 0, duplicate = 0;
  setBusy(true, '사진 올리는 중');
  try {
    for (const [i, file] of list.entries()) {
      $('loadingTitle').textContent = `사진 올리는 중 (${i + 1}/${list.length})`;
      const blob = await compressImage(file);
      const sha = await sha256Hex(blob);
      const slot = await rpc('tbm_photo_prepare', { p_report_id: r.id, p_kind: kind, p_size: blob.size, p_sha256: sha });
      if (slot.duplicate) { duplicate++; continue; }
      await uploadPhoto(slot.bucket, slot.path, blob);
      const res = await rpc('tbm_photo_confirm', { p_attachment_id: slot.attachment_id });
      today.report = res.report; added++;
    }
    const notes = [];
    if (added) notes.push(`사진 ${added}장을 서버에 저장했습니다.`);
    if (duplicate) notes.push(`같은 사진 ${duplicate}장은 이미 올라가 있어 건너뛰었습니다.`);
    if (files.length > list.length) notes.push(`사진은 회차마다 최대 ${PHOTO_LIMIT}장이라 ${files.length - list.length}장은 올리지 않았습니다.`);
    tell(notes.join(' '), files.length > list.length ? 'error' : 'ok');
  } catch (e) {
    tell(describeError(e) + (added ? ` (앞의 ${added}장은 저장됐습니다)` : ''), 'error');
    if (RELOAD_CODES.includes(e.code)) await load({ quiet: true });
  } finally {
    setBusy(false);
    applyReport(today.report);
  }
}
async function removePhoto(id) {
  if (busy || !confirm('이 사진을 뺄까요? 보고에서 보이지 않게 됩니다.')) return;
  setBusy(true, '사진 빼는 중');
  try {
    const res = await rpc('tbm_photo_remove', { p_attachment_id: id });
    applyReport(res.report);
    tell('사진을 뺐습니다.', 'ok');
  } catch (e) { await handleActionError(e); }
  finally { setBusy(false); }
}
document.addEventListener('change', e => { const kind = e.target.dataset?.photoInput; if (kind) addPhotos(kind, e.target); });
document.addEventListener('click', e => { const id = e.target.closest('[data-photo-remove]')?.dataset.photoRemove; if (id) removePhoto(id); });

// ---------- 이동·기타 ----------
document.addEventListener('click', e => {
  const go = e.target.closest('[data-go]')?.dataset.go; if (go) showStage(go);
  const open = e.target.closest('[data-open]')?.dataset.open; if (open) $(open).click();
});
$('openPlan').addEventListener('click', async () => {
  if (!dirty) await load({ quiet: true }); // 다른 팀 배정 현황을 최신으로
  showStage('stagePlan');
});
$('refreshBtn').addEventListener('click', async () => {
  if (dirty && !confirm('서버에 저장하지 않은 작업계획 변경이 있습니다. 새로고침해도 이 기기의 임시저장은 남습니다. 계속할까요?')) return;
  if (await load()) tell('최신 내용을 불러왔습니다.');
});
$('logoutBtn').addEventListener('click', async () => {
  if (!confirm('로그아웃할까요?')) return;
  await logout(); location.replace('personnel_test.html');
});
$('goLogin').addEventListener('click', async () => { await logout(); location.replace(loginUrl(PAGE)); });
window.addEventListener('beforeunload', e => { if (dirty) { e.preventDefault(); e.returnValue = ''; } });

$('pageVersion').textContent = `v${PAGE_VERSION} TEST`; $('footerVersion').textContent = `v${PAGE_VERSION} TEST`;
if (requireLogin(PAGE)) load();
