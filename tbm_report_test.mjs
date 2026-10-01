// 팀장 TBM 보고 시험 화면 (tbm_report_test v0.62: 오늘 작업계획 · 출근 TBM · TBM 사진 · 오후 TBM · 퇴근 TBM · 이월 이어받기)
// 팀·날짜·보고자는 서버(tbm_today)가 정한다. 화면은 서버 저장이 성공한 뒤에만 "저장됨"을 표시한다.
import { rpc, requireLogin, logout, loginUrl, describeError, requestIdFor, escapeHtml, kstTime, kstDateLabel, kstNowHour, compressImage, sha256Hex, uploadPhoto, signedUrls, PHOTO_BUCKET } from './tbm_api_test.mjs';

const PAGE = 'tbm_report_test.html';
const PAGE_VERSION = '0.62';
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
const slots = { plan: {}, morning: {}, afternoon: {}, alert: {}, result: {}, evening: {} };
const RESULTS = { DONE: '완료', PARTIAL: '일부완료', NOT_DONE: '미완료', EXCLUDED: '제외' };
const ALERTS = { NORMAL: '정상', CHANGED: '변경', DELAYED: '지연', RISK: '위험' };
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
    drop_carry_ids: [],
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
  form = draft.form; form.drop_carry_ids = form.drop_carry_ids || []; form.tasks.forEach(t => { t.key = 't' + (++taskSeq); });
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
      block(e.code === 'FORBIDDEN' ? '팀장만 사용할 수 있는 화면입니다. 팀장 본인의 이름과 휴대폰 번호 뒤 4자리로 로그인해주세요.' : describeError(e));
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
  const flagged = (r?.tasks || []).filter(t => ['CHANGED', 'DELAYED', 'RISK'].includes(t.alert)).length;
  $('openAfternoonSub').textContent = r?.afternoon_at ? `확인 ${kstTime(r.afternoon_at)}${flagged ? ` · 이상 ${flagged}건` : ''}` : '정상 · 변경 · 지연 · 위험';
  $('openAfternoon').classList.toggle('done', !!r?.afternoon_at);
  const carried = (r?.tasks || []).filter(t => t.carry_over).length;
  $('openEveningSub').textContent = r?.evening_at ? `마감 ${kstTime(r.evening_at)}${carried ? ` · 이월 ${carried}건` : ''}` : '작업별 완료 · 이월';
  $('openEvening').classList.toggle('done', !!r?.evening_at);
  const hour = kstNowHour();
  // 시간대 추천(강조만): 출근 전 → 출근, 15시 전 → 오후, 15시 이후 → 퇴근. 모든 TBM은 언제든 열 수 있다.
  const recommended = !r ? 'openPlan' : !r.morning_at ? 'openMorning' : hour < 15 ? (r.afternoon_at ? null : 'openAfternoon') : r.evening_at ? null : 'openEvening';
  ['openPlan', 'openMorning', 'openAfternoon', 'openEvening'].forEach(id => $(id).classList.toggle('recommended', id === recommended));
  renderPlan();
  renderMorning();
  renderAfternoon();
  renderEvening();
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
  renderCarry();
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

// ---------- 이월 이어받기 (다시 입력하지 않음, 원래 작업과 연결, 한 번만) ----------
function carryCandidates() {
  const used = new Set(form.tasks.map(t => t.carried_from_task_id).filter(Boolean));
  return (today.carry_candidates || []).filter(c => !used.has(c.task_id));
}
function renderCarry() {
  const list = carryCandidates();
  const locked = !editable();
  $('carryBox').hidden = !list.length;
  $('carryCount').textContent = list.length ? `${list.length}건` : '';
  $('carryList').innerHTML = list.map(c => {
    const dropped = form.drop_carry_ids.includes(c.task_id);
    return `<div class="carry-item" data-carry="${c.task_id}">
      <strong>${escapeHtml(kstDateLabel(c.work_date))} 작업 ${c.task_no} · ${escapeHtml(c.place)}</strong>
      <span>${escapeHtml(c.carry_note || c.content)}</span>
      <span>${c.result === 'PARTIAL' ? '일부완료' : '미완료'}${c.result_note ? ' · ' + escapeHtml(c.result_note) : ''} · 인원: ${c.members.map(m => escapeHtml(m.name)).join(', ') || '-'}</span>
      <div class="carry-actions">
        <button type="button" data-carry-take="${c.task_id}" ${locked ? 'disabled' : ''}>오늘 이어서</button>
        <button type="button" class="drop ${dropped ? 'selected' : ''}" data-carry-drop="${c.task_id}" ${locked ? 'disabled' : ''}>${dropped ? '이어받지 않음 (저장 시 반영)' : '이어받지 않음'}</button>
      </div></div>`;
  }).join('');
}
function takeCarry(id) {
  const c = today.carry_candidates.find(x => x.task_id === id);
  if (!c) return;
  if (form.tasks.length >= 20) { tell('작업은 최대 20개까지 입력할 수 있습니다.', 'error'); return; }
  const lockIds = new Set((today.locks || []).map(l => l.person_id));
  const teamIds = new Set(today.members.map(m => m.person_id));
  const members = c.members.filter(m => teamIds.has(m.person_id) && !lockIds.has(m.person_id)).map(m => ({ person_id: m.person_id, role: m.role }));
  const skipped = c.members.filter(m => !members.some(x => x.person_id === m.person_id)).map(m => m.name);
  // 비어 있는 첫 작업 칸은 이월 작업으로 대신한다
  const blank = form.tasks.find(t => !t.id && !t.place.trim() && !t.content.trim() && !t.members.length);
  if (blank) form.tasks = form.tasks.filter(t => t !== blank);
  form.tasks.push({ ...emptyTask(), place: c.place, content: c.carry_note || c.content, carried_from_task_id: c.task_id, members });
  form.drop_carry_ids = form.drop_carry_ids.filter(x => x !== id);
  renderCarry(); renderTasks(); saveDraftSoon();
  tell(`이월 작업을 오늘 작업 ${form.tasks.length}(으)로 가져왔습니다. 저장해야 서버에 반영됩니다.${skipped.length ? ` 오늘 선택할 수 없는 인원은 빠졌습니다: ${skipped.join(', ')}` : ''}`);
}
$('carryList').addEventListener('click', e => {
  const take = e.target.closest('[data-carry-take]')?.dataset.carryTake;
  if (take) { takeCarry(take); return; }
  const drop = e.target.closest('[data-carry-drop]')?.dataset.carryDrop;
  if (drop) {
    form.drop_carry_ids = form.drop_carry_ids.includes(drop) ? form.drop_carry_ids.filter(x => x !== drop) : [...form.drop_carry_ids, drop];
    renderCarry(); saveDraftSoon();
  }
});

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
  renderCarry(); renderTasks(); saveDraftSoon();
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
    const carried = result.report.tasks.filter(t => t.carried_from_task_id).length;
    tell(`작업계획을 서버에 저장했습니다 (${kstTime(result.report.updated_at)}, 작업 ${result.report.tasks.length}건${carried ? `, 이월 이어받음 ${carried}건` : ''}${payload.drop_carry_ids.length ? `, 이어받지 않음 ${payload.drop_carry_ids.length}건` : ''}).`, 'ok');
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

// ---------- 오후 TBM (전체 이상 없음 한 번, 이상 있는 작업만 상세) ----------
let alertEdit = null; // 열려 있는 작업 상세 입력 { taskId, alert, note, action, place, content, members }
let afternoonNoteTouched = false;
function membersLine(members) { return members.map(m => `${escapeHtml(m.name)}${m.role !== '작업자' ? `(${escapeHtml(m.role)})` : ''}`).join(', ') || '-'; }
function alertMemberPicker(edit) {
  const lockMap = new Map((today.locks || []).map(l => [l.person_id, l]));
  return today.members.map(m => {
    const chosen = edit.members.find(x => x.person_id === m.person_id);
    const lock = lockMap.get(m.person_id);
    return `<label class="task-member ${lock && !chosen ? 'locked' : ''}"><input type="checkbox" data-amember="${m.person_id}" ${chosen ? 'checked' : ''} ${lock && !chosen ? 'disabled' : ''}>
      <span>${escapeHtml(m.name)}</span>${lock ? `<span class="task-member-assigned">${escapeHtml(lock.team_name)} 배정중</span>` : ''}
      ${chosen ? `<select class="task-role-select" data-arole="${m.person_id}" aria-label="${escapeHtml(m.name)} 역할">${ROLES.map(r => `<option ${chosen.role === r ? 'selected' : ''}>${r}</option>`).join('')}</select>` : ''}</label>`;
  }).join('');
}
function renderAfternoon() {
  const r = report();
  const ready = !!r?.morning_at && editable();
  $('afternoonBlocked').hidden = ready;
  $('afternoonBlocked').textContent = !r ? '오늘 작업계획을 먼저 저장해주세요.' : !r.morning_at ? '출근 TBM을 먼저 보고해주세요.' : !editable() ? '소장 확인이 끝난 보고라 수정할 수 없습니다.' : '';
  $('afternoonBadge').textContent = r?.afternoon_at ? `확인 ${kstTime(r.afternoon_at)}` : '확인 전';
  $('afternoonBadge').className = 'badge' + (r?.afternoon_at ? ' ok' : '');
  if (r?.afternoon_note && !afternoonNoteTouched) $('afternoonNote').value = r.afternoon_note;
  $('afternoonNote').disabled = !ready;
  const open = (r?.tasks || []).filter(t => !t.result);
  const untouched = open.filter(t => t.alert === 'NONE');
  $('afternoonAllClear').disabled = !ready || !untouched.length;
  $('afternoonAllClear').textContent = !open.length ? '확인할 작업이 없습니다' : !untouched.length ? '모든 작업 확인됨' : untouched.length === open.length ? '전체 이상 없음' : `나머지 ${untouched.length}건 이상 없음`;
  $('afternoonTasks').innerHTML = (r?.tasks || []).map(t => {
    const closed = !!t.result;
    const editing = alertEdit?.taskId === t.id ? alertEdit : null;
    const selected = editing ? editing.alert : t.alert;
    const cls = t.alert === 'RISK' ? 'is-risk' : ['CHANGED', 'DELAYED'].includes(t.alert) ? 'is-alert' : t.alert === 'NORMAL' ? 'saved' : '';
    const label = closed ? '퇴근 결과 입력됨' : ALERTS[t.alert] ? `${ALERTS[t.alert]} 저장됨` : '미확인';
    const buttons = Object.entries(ALERTS).map(([code, name]) => `<button type="button" class="task-status-btn ${code === 'NORMAL' ? 'normal' : 'danger'} ${selected === code ? 'selected' : ''}"
      data-alert="${code}" data-task-id="${t.id}" ${!ready || closed ? 'disabled' : ''}>${name}</button>`).join('');
    const editor = editing && editing.alert !== 'NORMAL' ? `<div class="task-detail-editor">
      <div class="field"><label class="label">${{ CHANGED: '변경 내용', DELAYED: '지연 사유', RISK: '위험 내용' }[editing.alert]} (필수)</label><textarea data-aedit="note" maxlength="500" placeholder="2자 이상">${escapeHtml(editing.note)}</textarea></div>
      <div class="field"><label class="label">조치 / 요청사항 (선택)</label><textarea data-aedit="action" maxlength="500" placeholder="예: 자재 추가 요청, 작업 순서 변경">${escapeHtml(editing.action)}</textarea></div>
      ${editing.alert === 'CHANGED' ? `<div class="field"><label class="label">작업 위치</label><input data-aedit="place" maxlength="120" value="${escapeHtml(editing.place)}"></div>
      <div class="field"><label class="label">작업 내용</label><textarea data-aedit="content" maxlength="500">${escapeHtml(editing.content)}</textarea></div>
      <div class="member-head"><span class="label" style="margin:0">투입 인원</span><span class="member-count">${editing.members.length}명 선택</span></div>
      <div class="task-members">${alertMemberPicker(editing)}</div>` : ''}
      <div class="btn-row" style="margin-top:10px"><button type="button" class="task-save-btn" data-alert-save="${t.id}">이 작업 저장</button><button type="button" class="task-save-btn" style="background:#EEF4FA;color:var(--navy)" data-alert-cancel>취소</button></div>
    </div>` : '';
    return `<div class="task-tbm-card ${cls}" data-afternoon-task="${t.id}">
      <div class="task-tbm-head"><div><div class="task-tbm-name">작업 ${t.task_no} · ${escapeHtml(t.place)}</div>
        <div class="task-tbm-meta">${escapeHtml(t.content)}<br>인원: ${membersLine(t.members)}</div>
        ${t.alert_note ? `<div class="task-tbm-meta"><strong>${ALERTS[t.alert] || ''}</strong> ${escapeHtml(t.alert_note)}${t.alert_action ? ` · 조치: ${escapeHtml(t.alert_action)}` : ''}</div>` : ''}</div>
        <span class="task-save-state">${label}</span></div>
      <div class="task-status-buttons">${buttons}</div>${editor}</div>`;
  }).join('');
  $('afternoonState').className = 'server-state' + (r?.afternoon_at ? ' ok' : '');
  $('afternoonState').textContent = r?.afternoon_at ? `서버 저장됨 · ${kstTime(r.afternoon_at)} 첫 확인` : '아직 오후 TBM을 저장하지 않았습니다.';
}
async function saveAlert(taskId, alert) {
  if (busy || planIsDirty()) return;
  const task = report().tasks.find(t => t.id === taskId);
  const edit = alertEdit?.taskId === taskId ? alertEdit : null;
  const note = alert === 'NORMAL' ? null : (edit?.note || '').trim();
  if (alert !== 'NORMAL' && note.length < 2) { tell('내용을 2자 이상 적어주세요.', 'error'); return; }
  let change = null;
  if (alert === 'CHANGED') {
    if (!edit.place.trim() || !edit.content.trim()) { tell('변경 후 작업 위치와 작업 내용을 입력해주세요.', 'error'); return; }
    if (!edit.members.length) { tell('투입 인원을 1명 이상 선택해주세요.', 'error'); return; }
    change = { place: edit.place.trim(), content: edit.content.trim(), members: edit.members };
  }
  const args = { p_task_id: taskId, p_alert: alert, p_note: note, p_action: alert === 'NORMAL' ? null : (edit?.action || '').trim() || null, p_change: change };
  args.p_request_id = requestIdFor(slots.alert, args);
  setBusy(true, '오후 TBM 저장 중');
  try {
    const res = await rpc('tbm_task_alert', args);
    slots.alert = {}; alertEdit = null;
    applyReport(res.report);
    tell(`작업 ${task.task_no}을(를) '${ALERTS[alert]}'(으)로 저장했습니다.`, 'ok');
  } catch (e) { await handleActionError(e); }
  finally { setBusy(false); }
}
async function afternoonAllClear() {
  const r = report();
  if (busy || !r || planIsDirty()) return;
  const note = $('afternoonNote').value.trim();
  const count = r.tasks.filter(t => !t.result && t.alert === 'NONE').length;
  const request_id = requestIdFor(slots.afternoon, { id: r.id, note });
  setBusy(true, '오후 TBM 저장 중');
  try {
    const res = await rpc('tbm_afternoon_all_clear', { p_report_id: r.id, p_note: note || null, p_request_id: request_id });
    slots.afternoon = {}; afternoonNoteTouched = false; alertEdit = null;
    applyReport(res.report);
    tell(`오후 TBM을 저장했습니다. 확인 안 한 작업 ${count}건을 정상으로 표시했습니다.`, 'ok');
  } catch (e) { await handleActionError(e); }
  finally { setBusy(false); }
}
$('afternoonAllClear').addEventListener('click', afternoonAllClear);
$('afternoonNote').addEventListener('input', () => { afternoonNoteTouched = true; });
$('afternoonTasks').addEventListener('click', e => {
  const btn = e.target.closest('button'); if (!btn || busy) return;
  if (btn.dataset.alert) {
    const t = report().tasks.find(x => x.id === btn.dataset.taskId);
    if (btn.dataset.alert === 'NORMAL') { if (alertEdit?.taskId === t.id) alertEdit = null; saveAlert(t.id, 'NORMAL'); return; }
    alertEdit = { taskId: t.id, alert: btn.dataset.alert, note: t.alert === btn.dataset.alert ? t.alert_note || '' : '', action: t.alert === btn.dataset.alert ? t.alert_action || '' : '',
      place: t.place, content: t.content, members: t.members.map(m => ({ person_id: m.person_id, role: m.role })) };
    renderAfternoon();
    document.querySelector(`[data-afternoon-task="${t.id}"] [data-aedit=note]`)?.focus();
  } else if (btn.dataset.alertSave) saveAlert(btn.dataset.alertSave, alertEdit.alert);
  else if (btn.hasAttribute('data-alert-cancel')) { alertEdit = null; renderAfternoon(); }
});
$('afternoonTasks').addEventListener('input', e => { const f = e.target.dataset.aedit; if (f && alertEdit) alertEdit[f] = e.target.value; });
$('afternoonTasks').addEventListener('change', e => {
  if (!alertEdit) return;
  const id = e.target.dataset.amember;
  if (id) {
    if (e.target.checked) alertEdit.members.push({ person_id: id, role: '작업자' });
    else alertEdit.members = alertEdit.members.filter(m => m.person_id !== id);
    renderAfternoon(); return;
  }
  const rid = e.target.dataset.arole;
  if (rid) { const m = alertEdit.members.find(x => x.person_id === rid); if (m) m.role = e.target.value; }
});
$('openAfternoon').addEventListener('click', async () => {
  if (!dirty) await load({ quiet: true });
  if (!report()) { tell('오늘 작업계획을 먼저 저장해주세요.', 'error'); showStage('stagePlan'); return; }
  showStage('stageAfternoon');
});

// ---------- 퇴근 TBM (완료는 한 번에, 일부완료·미완료만 사유·이월) ----------
let resultEdit = null; // { taskId, result, note, carry, carryNote }
let eveningNoteTouched = false;
function renderEvening() {
  const r = report();
  const ready = !!r?.morning_at && editable();
  $('eveningBlocked').hidden = ready;
  $('eveningBlocked').textContent = !r ? '오늘 작업계획을 먼저 저장해주세요.' : !r.morning_at ? '출근 TBM을 먼저 보고해주세요.' : !editable() ? '소장 확인이 끝난 보고라 수정할 수 없습니다.' : '';
  $('eveningBadge').textContent = r?.evening_at ? `마감 ${kstTime(r.evening_at)}` : '마감 전';
  $('eveningBadge').className = 'badge' + (r?.evening_at ? ' ok' : '');
  if (r?.evening_note && !eveningNoteTouched) $('eveningNote').value = r.evening_note;
  $('eveningNote').disabled = !ready;
  const open = (r?.tasks || []).filter(t => !t.result);
  $('eveningClose').disabled = !ready;
  $('eveningClose').textContent = r?.evening_at ? (open.length ? `나머지 ${open.length}건 완료로 다시 마감` : '퇴근 마감 내용 다시 저장') : open.length ? `나머지 ${open.length}건 완료로 하고 퇴근 마감` : '퇴근 TBM 마감';
  $('eveningTasks').innerHTML = (r?.tasks || []).map(t => {
    const editing = resultEdit?.taskId === t.id ? resultEdit : null;
    const selected = editing ? editing.result : t.result;
    const cls = t.result === 'DONE' ? 'saved' : ['PARTIAL', 'NOT_DONE'].includes(t.result) ? 'is-alert' : '';
    const label = t.result ? `${RESULTS[t.result]}${t.carry_over ? ' · 이월' : ''} 저장됨` : '미입력';
    const buttons = Object.entries(RESULTS).map(([code, name]) => `<button type="button" class="task-status-btn ${code === 'DONE' ? 'normal' : code === 'EXCLUDED' ? '' : 'danger'} ${selected === code ? 'selected' : ''}"
      data-result="${code}" data-task-id="${t.id}" ${!ready ? 'disabled' : ''}>${name}</button>`).join('');
    const partial = editing && ['PARTIAL', 'NOT_DONE'].includes(editing.result);
    const editor = editing && editing.result !== 'DONE' ? `<div class="task-detail-editor">
      <div class="field"><label class="label">${partial ? '사유 (필수)' : '제외 사유 (선택)'}</label><textarea data-redit="note" maxlength="500" placeholder="${partial ? '예: 자재 미입고, 타 공정 간섭' : '예: 작업 취소'}">${escapeHtml(editing.note)}</textarea></div>
      ${partial ? `<label class="check-line plain field"><input type="checkbox" data-redit-carry ${editing.carry ? 'checked' : ''}>내일로 이월 (다음 날 작업계획에서 이어받기)</label>
      ${editing.carry ? `<div class="field"><label class="label">내일 이어서 할 내용</label><textarea data-redit="carryNote" maxlength="500">${escapeHtml(editing.carryNote)}</textarea></div>` : ''}` : ''}
      <div class="btn-row"><button type="button" class="task-save-btn" data-result-save="${t.id}">이 작업 저장</button><button type="button" class="task-save-btn" style="background:#EEF4FA;color:var(--navy)" data-result-cancel>취소</button></div>
    </div>` : '';
    return `<div class="task-tbm-card ${cls}" data-evening-task="${t.id}">
      <div class="task-tbm-head"><div><div class="task-tbm-name">작업 ${t.task_no} · ${escapeHtml(t.place)}</div>
        <div class="task-tbm-meta">${escapeHtml(t.content)}<br>인원: ${membersLine(t.members)}${ALERTS[t.alert] && t.alert !== 'NORMAL' ? `<br>오후: ${ALERTS[t.alert]} · ${escapeHtml(t.alert_note || '')}` : ''}</div>
        ${t.result_note || t.carry_over ? `<div class="task-tbm-meta">${t.result_note ? escapeHtml(t.result_note) : ''}${t.carry_over ? `${t.result_note ? ' · ' : ''}이월: ${escapeHtml(t.carry_note || '')}` : ''}</div>` : ''}</div>
        <span class="task-save-state">${label}</span></div>
      <div class="task-status-buttons">${buttons}</div>${editor}</div>`;
  }).join('');
  $('eveningState').className = 'server-state' + (r?.evening_at ? ' ok' : '');
  $('eveningState').textContent = r?.evening_at ? `서버 저장됨 · ${kstTime(r.evening_at)} 마감` : open.length ? `결과를 입력하지 않은 작업 ${open.length}건` : '모든 작업 결과가 입력됐습니다. 마감을 눌러주세요.';
}
async function saveResult(taskId, result) {
  if (busy || planIsDirty()) return;
  const task = report().tasks.find(t => t.id === taskId);
  const edit = resultEdit?.taskId === taskId ? resultEdit : null;
  const partial = ['PARTIAL', 'NOT_DONE'].includes(result);
  const note = result === 'DONE' ? '' : (edit?.note || '').trim();
  if (partial && note.length < 2) { tell('일부완료·미완료는 사유를 2자 이상 적어주세요.', 'error'); return; }
  const args = { p_task_id: taskId, p_result: result, p_carry: partial ? !!edit.carry : null,
    p_carry_note: partial && edit.carry ? (edit.carryNote || '').trim() || null : null, p_note: note || null };
  args.p_request_id = requestIdFor(slots.result, args);
  setBusy(true, '퇴근 TBM 저장 중');
  try {
    const res = await rpc('tbm_task_result', args);
    slots.result = {}; resultEdit = null;
    applyReport(res.report);
    tell(`작업 ${task.task_no}을(를) '${RESULTS[result]}'${partial && args.p_carry ? '·이월' : ''}(으)로 저장했습니다.`, 'ok');
  } catch (e) { await handleActionError(e); }
  finally { setBusy(false); }
}
async function eveningClose() {
  const r = report();
  if (busy || !r || planIsDirty()) return;
  const open = r.tasks.filter(t => !t.result);
  if (open.length && !confirm(`결과를 입력하지 않은 작업 ${open.length}건을 '완료'로 저장하고 마감할까요?\n${open.map(t => `작업 ${t.task_no} · ${t.place}`).join('\n')}`)) return;
  const note = $('eveningNote').value.trim();
  const request_id = requestIdFor(slots.evening, { id: r.id, note, rest: open.map(t => t.id) });
  setBusy(true, '퇴근 TBM 마감 중');
  try {
    const res = await rpc('tbm_evening_close', { p_report_id: r.id, p_note: note || null, p_complete_rest: open.length > 0, p_request_id: request_id });
    slots.evening = {}; eveningNoteTouched = false; resultEdit = null;
    applyReport(res.report);
    const carried = res.report.tasks.filter(t => t.carry_over).length;
    tell(`퇴근 TBM을 마감했습니다 (${kstTime(res.report.evening_at)}).${carried ? ` 내일 이월 ${carried}건은 다음 날 작업계획에서 이어받을 수 있습니다.` : ''}`, 'ok');
  } catch (e) { await handleActionError(e); }
  finally { setBusy(false); }
}
$('eveningClose').addEventListener('click', eveningClose);
$('eveningNote').addEventListener('input', () => { eveningNoteTouched = true; });
$('eveningTasks').addEventListener('click', e => {
  const btn = e.target.closest('button'); if (!btn || busy) return;
  if (btn.dataset.result) {
    const t = report().tasks.find(x => x.id === btn.dataset.taskId);
    if (btn.dataset.result === 'DONE') { if (resultEdit?.taskId === t.id) resultEdit = null; saveResult(t.id, 'DONE'); return; }
    const same = t.result === btn.dataset.result;
    resultEdit = { taskId: t.id, result: btn.dataset.result, note: same ? t.result_note || '' : '', carry: same && t.result !== 'EXCLUDED' ? !!t.carry_over : true,
      carryNote: same && t.carry_note ? t.carry_note : t.content };
    renderEvening();
    document.querySelector(`[data-evening-task="${t.id}"] [data-redit=note]`)?.focus();
  } else if (btn.dataset.resultSave) saveResult(btn.dataset.resultSave, resultEdit.result);
  else if (btn.hasAttribute('data-result-cancel')) { resultEdit = null; renderEvening(); }
});
$('eveningTasks').addEventListener('input', e => { const f = e.target.dataset.redit; if (f && resultEdit) resultEdit[f] = e.target.value; });
$('eveningTasks').addEventListener('change', e => { if (e.target.hasAttribute('data-redit-carry') && resultEdit) { resultEdit.carry = e.target.checked; renderEvening(); } });
$('openEvening').addEventListener('click', async () => {
  if (!dirty) await load({ quiet: true }); // 오후 변경 사항을 최신으로
  if (!report()) { tell('오늘 작업계획을 먼저 저장해주세요.', 'error'); showStage('stagePlan'); return; }
  showStage('stageEvening');
});

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
// 로그아웃하면 이 기기의 작업계획 임시저장(인원 이름 포함)도 지운다 (공용 기기 대비)
$('logoutBtn').addEventListener('click', async () => {
  if (!confirm(dirty ? '서버에 저장하지 않은 작업계획 변경이 있습니다. 로그아웃하면 이 기기의 임시저장도 지워집니다. 로그아웃할까요?' : '로그아웃할까요?')) return;
  dirty = false; clearDraft();
  await logout(); location.replace('personnel_test.html');
});
$('goLogin').addEventListener('click', async () => { await logout(); location.replace(loginUrl(PAGE)); });
window.addEventListener('beforeunload', e => { if (dirty) { e.preventDefault(); e.returnValue = ''; } });

$('pageVersion').textContent = `v${PAGE_VERSION} TEST`; $('footerVersion').textContent = `v${PAGE_VERSION} TEST`;
if (requireLogin(PAGE)) load();
