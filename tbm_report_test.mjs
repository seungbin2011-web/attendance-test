// 팀장 TBM 보고 시험 화면 (tbm_report_test v0.70: 오늘 작업계획 · 출근 TBM · TBM 사진 · 오후 TBM(작업정지 포함) · 퇴근 TBM · 이월 이어받기 · 출역 관리)
// 팀·날짜·보고자는 서버(tbm_today)가 정한다. 화면은 서버 저장이 성공한 뒤에만 "저장됨"을 표시한다.
import { rpc, requireLogin, guardBackForward, logout, loginUrl, PROD, pageUrl, describeError, requestIdFor, escapeHtml, kstTime, kstDateLabel, kstNowHour, compressImage, sha256Hex, uploadPhoto, signedUrls, PHOTO_BUCKET } from './tbm_api_test.mjs?v=1.3';

const PAGE = pageUrl('tbm_report');
const PAGE_VERSION = '0.80';
const DRAFT_KEY = 'tbmReportDraft_v1';
const RISKS = ['고소작업', '전기', '중량물', '화기', '장비사용', '기타'];
const ROLES = ['작업자', '작업지휘자', '신호수', '화기감시자', '유도원', '기타'];
const BLOCKING = ['AUTH_REQUIRED', 'AUTH_EXPIRED', 'SESSION_EXPIRED', 'ACCOUNT_NOT_LINKED', 'ACCOUNT_INACTIVE', 'ACCOUNT_DISABLED', 'PIN_CHANGE_REQUIRED', 'FORBIDDEN', 'TEAM_NOT_READY', 'TEAM_REQUIRED'];
const $ = id => document.getElementById(id);

let today = null;      // tbm_today 결과
let sitePeople = null; // tbm_site_people 결과(같은 현장 현재 인원). 서버에 v0.4가 없으면 null → 우리 팀만
const memberQuery = new Map(); // 작업별 인원 검색어 (화면에만)
const openCarried = new Set(); // 펼쳐 둔 전일 이월 작업 (화면에만, 기본은 접힘)
let cancelEdit = null;         // 이월 취소 사유 입력 { target: 후보 task_id 또는 오늘 작업 key, reason }
let form = null;       // 작업계획 입력 상태
let dirty = false;     // 서버에 저장되지 않은 변경
let busy = false;      // 저장 중 (중복 전송 방지)
let draftTimer = null;
let taskSeq = 0;
const slots = { plan: {}, morning: {}, afternoon: {}, alert: {}, stop: {}, result: {}, evening: {}, attendance: {}, carry: {} };
const RESULTS = { DONE: '완료', PARTIAL: '일부완료', NOT_DONE: '미완료', EXCLUDED: '제외' };
const ALERTS = { NORMAL: '정상', CHANGED: '변경', DELAYED: '지연', RISK: '위험' };
// 작업정지(STOPPED)는 버튼 목록과 따로 둔다: 오후 TBM에서 사유·처리 방향과 함께 저장하고, 퇴근 결과도 함께 확정된다
const RESULT_LABELS = { ...RESULTS, STOPPED: '작업정지' };
const ALERT_LABELS = { ...ALERTS, STOPPED: '작업정지' };
const STOP_DISPOSITIONS = { CARRY: '내일 이월', END: '오늘 정지로 종료' };
const stopLabel = t => `작업정지 · ${t.carry_over ? '내일 이월' : '정지로 종료'}`;
const RELOAD_CODES = ['VERSION_CONFLICT', 'REPORT_NOT_EDITABLE', 'REPORT_NOT_FOUND', 'TASK_NOT_FOUND', 'TASK_CLOSED', 'TASK_STOPPED', 'CARRY_ALREADY_TAKEN', 'CARRY_NOT_AVAILABLE'];

function tell(text, kind = '') { $('message').textContent = text; $('message').className = 'message' + (kind ? ' ' + kind : ''); }
// 저장 중에는 화면 전체를 덮어 추가 입력·중복 전송을 막는다 (busy 플래그로 한 번 더 확인)
function setBusy(on, title = '저장 중입니다') {
  busy = on;
  if (on) hideSaveError();
  $('loadingTitle').textContent = title;
  $('loadingOverlay').classList.toggle('active', on);
  $('loadingOverlay').setAttribute('aria-hidden', on ? 'false' : 'true');
}
// 업무 단계 완료(계획 저장·출근 보고·오후 저장·작업정지·퇴근 마감)는 서버 성공을 확인한 뒤
// 큰 성공 표시를 잠깐 보여 주고 홈으로 돌아간다. 홈으로 돌아오면 저장 완료 (홈의 단계 ✓로 한 번 더 확인)
const DONE_MS = 1200;
function finishStep(title, sub = '') {
  $('loadingOverlay').classList.remove('active'); $('loadingOverlay').setAttribute('aria-hidden', 'true');
  $('doneTitle').textContent = title; $('doneSub').textContent = sub; $('doneSub').hidden = !sub;
  $('doneOverlay').classList.add('active'); $('doneOverlay').setAttribute('aria-hidden', 'false');
  return new Promise(resolve => setTimeout(() => {
    $('doneOverlay').classList.remove('active'); $('doneOverlay').setAttribute('aria-hidden', 'true');
    showStage('stageHome'); resolve();
  }, DONE_MS));
}
// 저장 실패: 홈으로 가지 않고, 누른 버튼 바로 위에 크게 알린다 (입력 내용은 그대로, 다른 버튼을 가리지 않음).
// 「다시 저장」은 같은 단계를 다시 보낸다 (같은 요청번호라 한 번만 저장)
let retryStep = null;
const STEP_ANCHORS = { stagePlan: 'savePlan', stageMorning: 'submitMorning', stageAfternoon: 'afternoonTasks', stageEvening: 'eveningClose' };
function showSaveError(text, retry = null) {
  retryStep = retry;
  const stage = document.querySelector('.app-stage.active')?.id;
  const anchor = $(STEP_ANCHORS[stage]);
  if (anchor) anchor.before($('errorSheet'));
  $('errorSheetText').textContent = text; $('errorSheetRetry').hidden = !retry; $('errorSheet').hidden = false;
  $('errorSheet').scrollIntoView({ block: 'nearest' });
}
function hideSaveError() { $('errorSheet').hidden = true; }
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
const editable = () => !report() || (!report().evening_at && report().status !== 'CONFIRMED');

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
function draftOwner() { return today ? `${today.team.id}|${today.today}|${report()?.id || 'new'}|${today.actor.person_id || today.actor.name}` : ''; }
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
  if (!editable()) { clearDraft(); return false; }
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
    const previousId = report()?.id;
    today = await rpc('tbm_today', {});
    if (previousId !== report()?.id) {
      alertEdit = null; resultEdit = null; afternoonNoteTouched = false; eveningNoteTouched = false;
      for (const id of ['morningNote', 'afternoonNote', 'eveningNote']) $(id).value = '';
      for (const key of Object.keys(slots)) slots[key] = {};
    }
    if (editable() && (!quiet || sitePeople === null)) {
      // 다른 팀 인원 검색용. 실패해도 우리 팀 인원으로 계속 쓸 수 있게 한다
      sitePeople = await rpc('tbm_site_people', { p_team_id: today.team.id }).then(x => x.people || null, () => null);
    }
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
  for (const [stage, label] of [['stagePlan','작업계획'],['stageMorning','출근 TBM'],['stageAfternoon','오후 TBM'],['stageEvening','퇴근 TBM']]) {
    document.querySelector(`#${stage} .stage-title`).textContent = `작업 ${r?.session_no || 1} · ${label}`;
  }
  $('homeTitle').textContent = `${kstDateLabel(today.today)} ${today.team.name} · 작업 ${r?.session_no || 1}${r?.evening_at ? ' · 완료' : ' · 진행 중'}`;
  $('homeSub').textContent = r ? `보고자 ${r.reporter_label} · 작업 ${r.tasks.length}건 · 최근 저장 ${kstTime(r.updated_at)}` : '아직 오늘 작업계획이 없습니다. 작업계획부터 저장해주세요.';
  $('homeStatus').textContent = !r?.tasks?.length ? '계획 작성 전' : r.status === 'CONFIRMED' ? '소장 확인 완료' : r.evening_at ? '퇴근 마감' : r.morning_at ? '출근 보고 완료' : '계획 저장';
  $('homeStatus').className = 'badge' + (!r ? ' gray' : r.status === 'CONFIRMED' || r.evening_at ? ' ok' : '');
  const steps = [['계획', !!r?.tasks?.length], ['출근', !!r?.morning_at], ['오후', !!r?.afternoon_at], ['퇴근', !!r?.evening_at]];
  const now = steps.findIndex(s => !s[1]);
  $('homeSteps').innerHTML = steps.map(([label, done], i) => `<div class="step ${done ? 'done' : i === now ? 'now' : ''}">${label}${done ? ' ✓' : ''}</div>`).join('');
  // 작업정지는 홈에서도 바로 보이게 (처리 방향 포함)
  const stoppedTasks = (r?.tasks || []).filter(t => t.alert === 'STOPPED');
  $('homeNotes').hidden = !stoppedTasks.length;
  $('homeNotes').innerHTML = stoppedTasks.map(t => `<div class="home-stop"><b>⛔ 작업정지 · ${t.carry_over ? '내일 이월' : '정지로 종료'}</b><span>작업 ${t.task_no} · ${escapeHtml(t.place)}${t.alert_note ? ' — ' + escapeHtml(t.alert_note) : ''}</span></div>`).join('');
  $('openPlanSub').textContent = r?.evening_at ? '내용 보기' : r ? '보기 · 수정' : '먼저 작성';
  $('currentActions').hidden = !!r?.evening_at;
  $('openNextSession').hidden = !r?.evening_at;
  renderSessions();
  $('openMorningSub').textContent = r?.morning_at ? `보고 완료 ${kstTime(r.morning_at)}` : '작업계획 공유';
  $('openMorning').classList.toggle('done', !!r?.morning_at);
  const flagged = (r?.tasks || []).filter(t => ['CHANGED', 'DELAYED', 'RISK'].includes(t.alert)).length;
  const stoppedCount = (r?.tasks || []).filter(t => t.alert === 'STOPPED').length;
  $('openAfternoonSub').textContent = r?.afternoon_at ? `확인 ${kstTime(r.afternoon_at)}${flagged ? ` · 이상 ${flagged}건` : ''}${stoppedCount ? ` · 작업정지 ${stoppedCount}건` : ''}` : '정상 · 변경 · 지연 · 위험 · 정지';
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

// 인원 정보: 우리 팀 → 같은 현장 인원 → 저장된 배정 순으로 찾는다. other = 다른 팀 공식 소속(타 팀원)
function personInfo(personId) {
  const mine = today.members.find(m => m.person_id === personId);
  if (mine) return { name: mine.name, team: today.team.name, other: false, sub: [mine.rank, mine.job].filter(Boolean).join(' · ') || (mine.is_leader ? '팀장' : '팀원') };
  const site = (sitePeople || []).find(m => m.person_id === personId);
  if (site) return { name: site.name, team: site.team_name, other: site.team_id !== today.team.id, sub: site.team_name };
  const saved = (today.reports || [today.report]).filter(Boolean).flatMap(r => r.tasks).flatMap(t => t.members).find(m => m.person_id === personId);
  if (saved) return { name: saved.name, team: saved.home_team_name || '', other: saved.other_team !== false, sub: saved.home_team_name || '' };
  return { name: '(팀 외 인원)', team: '', other: true, sub: '' };
}
function memberName(personId) { return personInfo(personId).name; }
const otherBadge = info => info.other ? `<span class="other-team-badge">타 팀원${info.team ? ' · ' + escapeHtml(info.team) : ''}</span>` : '';
function renderPlan() {
  const locked = !editable();
  $('planLocked').hidden = !locked;
  $('planLocked').textContent = locked ? '완료된 작업은 내용 보기만 가능합니다.' : '';
  $('endTime').value = form.end_time;
  $('riskGrid').innerHTML = RISKS.map(r => `<label class="risk"><input type="checkbox" value="${r}" ${form.risks.includes(r) ? 'checked' : ''}>${r}</label>`).join('');
  $('riskOtherField').hidden = !form.risks.includes('기타');
  $('riskOther').value = form.risk_other; $('safetyNote').value = form.safety_note; $('issueNote').value = form.issue_note;
  $('needsCheck').checked = form.needs_manager_check;
  document.querySelectorAll('#stagePlan input, #stagePlan textarea, #stagePlan select').forEach(el => { el.disabled = locked; });
  renderCarry();
  renderTasks();
  document.querySelectorAll('#stagePlan input, #stagePlan textarea, #stagePlan select').forEach(el => { if (locked) el.disabled = true; });
  $('addTask').disabled = locked; $('savePlan').disabled = locked;
  $('addTask').hidden = locked; $('savePlan').hidden = locked; $('draftClear').hidden = locked;
  renderServerState();
}
// 화면 번호: 전일 이월은 '이월 N', 오늘 신규는 '작업 N' (서버 작업 번호와 별개, 작업계획 화면 안에서만)
function taskLabel(task) {
  const group = form.tasks.filter(t => !!t.carried_from_task_id === !!task.carried_from_task_id);
  return (task.carried_from_task_id ? '이월 ' : '작업 ') + (group.indexOf(task) + 1);
}
function otherTaskNos(task, personId) {
  return form.tasks.filter(t => t !== task && t.members.some(m => m.person_id === personId)).map(t => taskLabel(t).replace(' ', ''));
}
// 같은 사람이 여러 작업에 들어가는 것은 허용된다 (서버는 한 작업 안 중복만 막음). 오류처럼 보이지 않게 '에도 투입'으로 표시
const alsoIn = others => others.length ? `<span class="task-member-also">${others.join('·')}에도 투입</span>` : '';
// 고를 수 있는 인원 목록: 검색어가 없으면 우리 팀, 있으면 같은 현장 전체(이름·팀). 이미 고른 인원은 위 '선택된 인원'으로 옮긴다
function memberPool(task) {
  const q = (memberQuery.get(task.key) || '').trim().toLowerCase();
  const chosen = new Set(task.members.map(m => m.person_id));
  const own = today.members.map(m => ({ person_id: m.person_id, name: m.name, team_name: today.team.name, team_id: today.team.id }));
  const source = q ? (sitePeople || own) : own;
  return source.filter(p => !chosen.has(p.person_id) && (!q || p.name.toLowerCase().includes(q) || (p.team_name || '').toLowerCase().includes(q))).slice(0, 40);
}
function renderPool(task) {
  const lockMap = new Map((today.locks || []).map(l => [l.person_id, l]));
  const q = (memberQuery.get(task.key) || '').trim();
  const list = memberPool(task);
  if (!list.length) return `<div class="task-member-empty">${q ? `'${escapeHtml(q)}' 검색 결과가 없습니다. 퇴사·비활성 인원은 나오지 않습니다.` : today.members.length ? '우리 팀 인원을 모두 골랐습니다. 다른 팀 인원은 위에서 검색하세요.' : '서버에 등록된 우리 팀 인원이 없습니다. 위에서 이름으로 검색하거나 관리자에게 팀 소속 등록을 요청해주세요.'}</div>`;
  return list.map(p => {
    const info = personInfo(p.person_id);
    const lock = lockMap.get(p.person_id);
    const others = otherTaskNos(task, p.person_id);
    return `<label class="task-member ${lock ? 'locked' : ''} ${info.other ? 'other-team' : ''}">
      <input type="checkbox" data-member="${p.person_id}" ${task.closed || lock ? 'disabled' : ''}>
      <span>${escapeHtml(info.name)}</span>${otherBadge(info)}
      ${lock ? `<span class="task-member-assigned">${escapeHtml(lock.team_name)} 배정중</span>` : ''}
      ${alsoIn(others)}
      ${info.other ? '' : `<span class="member-sub">${escapeHtml(info.sub)}</span>`}
    </label>`;
  }).join('');
}
function renderChosen(task) {
  if (!task.members.length) return '<div class="chosen-empty">아직 고른 인원이 없습니다. 아래 목록에서 눌러 고르세요.</div>';
  return task.members.map(m => {
    const info = personInfo(m.person_id);
    const others = otherTaskNos(task, m.person_id);
    return `<div class="task-member chosen ${info.other ? 'other-team' : ''}">
      <div class="chip-head"><span class="chip-name">${escapeHtml(info.name)}</span>${otherBadge(info)}
      ${alsoIn(others)}</div>
      <select class="task-role-select" data-role="${m.person_id}" ${task.closed ? 'disabled' : ''} aria-label="${escapeHtml(info.name)} 역할">
        ${ROLES.map(r => `<option ${m.role === r ? 'selected' : ''}>${r}</option>`).join('')}
      </select>
      ${task.closed ? '' : `<label class="chip-x" title="빼기" aria-label="${escapeHtml(info.name)} 빼기"><input type="checkbox" class="sr-only" data-member="${m.person_id}" checked>×</label>`}
    </div>`;
  }).join('');
}
function taskBody(task) {
  const label = taskLabel(task);
  return `<div class="field"><label class="label">작업 위치</label><input data-tfield="place" maxlength="120" placeholder="예: 3층 MDF실 / A구역" value="${escapeHtml(task.place)}" ${task.closed ? 'disabled' : ''}></div>
      <div class="field"><label class="label">작업 내용</label><textarea data-tfield="content" maxlength="500" placeholder="예: 배선 작업 / 관로 작업" ${task.closed ? 'disabled' : ''}>${escapeHtml(task.content)}</textarea></div>
      <div class="member-head"><span class="label" style="margin:0">투입 인원</span><span class="member-count">선택된 인원 ${task.members.length}명</span></div>
      <div class="chosen-list">${renderChosen(task)}</div>
      ${task.closed ? '' : `<input type="search" class="member-search" data-msearch="${task.key}" value="${escapeHtml(memberQuery.get(task.key) || '')}" placeholder="이름·팀으로 검색" aria-label="${label} 인원 검색" enterkeyhint="search" autocomplete="off">
      <div class="task-members" data-member-pool="${task.key}">${renderPool(task)}</div>`}`;
}
const CARRY_RESULT = { PARTIAL: '전일 일부완료', NOT_DONE: '전일 미완료', STOPPED: '전일 작업정지' };
function cancelEditor(target) {
  if (cancelEdit?.target !== target) return '';
  return `<div class="cancel-editor">
    <label class="label" for="cancelReason">이월 취소 사유</label>
    <input id="cancelReason" data-cancel-reason maxlength="200" value="${escapeHtml(cancelEdit.reason)}">
    <div class="btn-row" style="margin-top:8px"><button type="button" class="task-save-btn cancel-confirm" data-cancel-confirm="${escapeHtml(target)}">이월 취소</button><button type="button" class="task-save-btn" style="background:#EEF4FA;color:var(--navy)" data-cancel-close>닫기</button></div>
    <p class="stage-note">어제 기록은 지우지 않습니다. 누가·언제·사유가 이력에 남습니다.</p></div>`;
}
// 오늘 계획에 들어온 전일 이월 작업: 기본 접힘 (요약만), 누르면 내용·인원과 「이월 취소」
function carriedCard(task) {
  const label = taskLabel(task);
  const summary = (task.content || '').split('\n')[0];
  const source = CARRY_RESULT[task.carry_info?.result] || '전일 작업에서 이어받음';
  const action = task.closed || !editable() ? '' : `<button class="task-remove carry-cancel-btn" type="button" data-carried-cancel="${task.key}">이월 취소</button>`;
  return `<details class="carried-task task-card ${task.closed ? 'closed' : ''}" data-task="${task.key}" ${openCarried.has(task.key) ? 'open' : ''}>
    <summary class="carried-summary">
      <span class="carried-main"><span class="carried-title"><span class="carry-badge">전일 이월</span> ${escapeHtml(task.place || '(위치 없음)')}</span>
        <span class="carried-text">${escapeHtml(summary || '-')}</span>
        <span class="carried-meta">${escapeHtml(label)} · ${escapeHtml(source)} · 인원 ${task.members.length}명${task.closed ? ' · 결과 입력됨' : task.id ? '' : ' · 저장 전'}</span></span>
      <span class="fold-hint" aria-hidden="true"></span>
    </summary>
    <div class="carried-body">${taskBody(task)}
      <div class="carried-actions">${action}</div>${cancelEditor(task.key)}</div>
  </details>`;
}
function renderTasks() {
  if (!form.tasks.length) form.tasks.push(emptyTask());
  const carried = form.tasks.filter(t => t.carried_from_task_id);
  const fresh = form.tasks.filter(t => !t.carried_from_task_id);
  $('carriedBox').hidden = !carried.length;
  $('carriedCount').textContent = carried.length ? `${carried.length}건` : '';
  $('carriedList').innerHTML = carried.map(carriedCard).join('');
  const split = carried.length > 0 || carryCandidates().length > 0;
  $('newTasksHead').hidden = !split;
  $('taskList').innerHTML = fresh.map(task => `<div class="task-card ${task.closed ? 'closed' : ''}" data-task="${task.key}">
      <div class="task-head">
        <div class="task-title">${taskLabel(task)}${split ? '<span class="new-badge">오늘 신규</span>' : ''}${task.closed ? '<span class="task-tag">결과 입력됨</span>' : ''}</div>
        ${task.closed || !editable() ? '' : `<button class="task-remove" type="button" data-remove="${task.key}">삭제</button>`}
      </div>
      ${taskBody(task)}
    </div>`).join('') || '<div class="task-member-empty">오늘 신규 작업이 없습니다. 필요하면 「＋ 작업 추가」를 누르세요.</div>';
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
  $('carryList').innerHTML = list.map(c => `<div class="carry-item" data-carry="${c.task_id}">
      <div class="carried-title"><span class="carry-badge">전일 이월</span> ${escapeHtml(c.place)}</div>
      <span>${escapeHtml(c.carry_note || c.content)}</span>
      <span>${escapeHtml(kstDateLabel(c.work_date))} · ${CARRY_RESULT[c.result] || '전일 미완료'}${c.result_note ? ' · ' + escapeHtml(c.result_note) : ''} · 인원 ${c.members.length}명</span>
      <div class="carry-actions">
        <button type="button" data-carry-take="${c.task_id}" ${locked ? 'disabled' : ''}>오늘 이어서</button>
        <button type="button" class="drop" data-carry-cancel="${c.task_id}" ${locked ? 'disabled' : ''}>이월 취소</button>
      </div>${cancelEditor(c.task_id)}</div>`).join('');
}
function takeCarry(id) {
  const c = today.carry_candidates.find(x => x.task_id === id);
  if (!c) return;
  if (form.tasks.length >= 20) { tell('작업은 최대 20개까지 입력할 수 있습니다.', 'error'); return; }
  const lockIds = new Set((today.locks || []).map(l => l.person_id));
  const teamIds = new Set([...today.members, ...(sitePeople || [])].map(m => m.person_id));
  const members = c.members.filter(m => teamIds.has(m.person_id) && !lockIds.has(m.person_id)).map(m => ({ person_id: m.person_id, role: m.role }));
  const skipped = c.members.filter(m => !members.some(x => x.person_id === m.person_id)).map(m => m.name);
  // 비어 있는 첫 작업 칸은 이월 작업으로 대신한다
  const blank = form.tasks.find(t => !t.id && !t.place.trim() && !t.content.trim() && !t.members.length);
  if (blank) form.tasks = form.tasks.filter(t => t !== blank);
  const task = { ...emptyTask(), place: c.place, content: c.carry_note || c.content, carried_from_task_id: c.task_id, members, carry_info: { result: c.result, work_date: c.work_date } };
  form.tasks.push(task);
  form.drop_carry_ids = form.drop_carry_ids.filter(x => x !== id);
  if (cancelEdit?.target === id) cancelEdit = null;
  renderCarry(); renderTasks(); saveDraftSoon();
  tell(`이월 작업을 「${taskLabel(task)}」(으)로 가져왔습니다 (접혀 있음). 저장해야 서버에 반영됩니다.${skipped.length ? ` 오늘 선택할 수 없는 인원은 빠졌습니다: ${skipped.join(', ')}` : ''}`);
}
// 이월 취소: 서버에 이유를 남긴다 (어제 기록은 그대로, 이월 상태만 '이어받지 않음'). 오늘 계획에 저장된 이월이면 오늘 작업에서도 뺀다
async function cancelCarry(taskId, reason, todayTask) {
  if (busy) return;
  if ((reason || '').trim().length < 2) { tell('이월 취소 사유를 2자 이상 적어주세요.', 'error'); return; }
  if (todayTask && planIsDirty()) return;
  const args = { p_task_id: taskId, p_reason: reason.trim() };
  args.p_request_id = requestIdFor(slots.carry, args);
  setBusy(true, '이월 취소 중');
  try {
    const res = await rpc('tbm_carry_cancel', args);
    slots.carry = {}; cancelEdit = null;
    if (res.mode === 'TODAY') await load({ quiet: true });
    else { today.carry_candidates = (today.carry_candidates || []).filter(c => c.task_id !== taskId); renderCarry(); renderTasks(); }
    tell('이월을 취소했습니다. 어제 기록은 그대로이고, 취소 사유가 이력에 남았습니다.', 'ok');
  } catch (e) {
    if (e.code === 'UNKNOWN') tell('이월 취소는 서버 준비(DB v0.5) 뒤에 쓸 수 있습니다. 관리자에게 알려주세요.', 'error');
    else await handleActionError(e);
  } finally { setBusy(false); }
}
function onCancelEditor(e) {
  if (e.target.closest('[data-cancel-close]')) { cancelEdit = null; renderCarry(); renderTasks(); return true; }
  const target = e.target.closest('[data-cancel-confirm]')?.dataset.cancelConfirm;
  if (!target) return false;
  const task = form.tasks.find(t => t.key === target);
  cancelCarry(task ? task.id : target, cancelEdit?.reason || '', !!task);
  return true;
}
$('carryList').addEventListener('click', e => {
  if (busy || onCancelEditor(e)) return;
  const take = e.target.closest('[data-carry-take]')?.dataset.carryTake;
  if (take) { takeCarry(take); return; }
  const cancel = e.target.closest('[data-carry-cancel]')?.dataset.carryCancel;
  if (cancel) { cancelEdit = { target: cancel, reason: '잘못 이월 처리함' }; renderCarry(); document.querySelector('#carryList [data-cancel-reason]')?.focus(); }
});
$('carriedList').addEventListener('click', e => {
  if (busy || onCancelEditor(e)) return;
  const key = e.target.closest('[data-carried-cancel]')?.dataset.carriedCancel;
  if (!key) return;
  const task = form.tasks.find(t => t.key === key);
  if (!task.id) {
    // 아직 서버에 저장하지 않은 이어받기는 목록에서만 빼면 된다 (후보로 돌아감, 서버 기록 없음)
    if (!confirm('아직 저장하지 않은 이월 작업입니다. 오늘 작업에서 뺄까요?')) return;
    form.tasks = form.tasks.filter(t => t !== task); openCarried.delete(key);
    renderCarry(); renderTasks(); saveDraftSoon();
    tell('이월 작업을 오늘 작업에서 뺐습니다 (저장 전이라 서버 기록 없음). 다시 이어받을 수 있습니다.', 'ok');
    return;
  }
  cancelEdit = { target: key, reason: '잘못 이월 처리함' }; renderTasks();
  document.querySelector('#carriedList [data-cancel-reason]')?.focus();
});
$('stagePlan').addEventListener('toggle', e => {
  const key = e.target.matches?.('.carried-task') ? e.target.dataset.task : null;
  if (key) { if (e.target.open) openCarried.add(key); else openCarried.delete(key); }
}, true);

// ---------- 입력 ----------
function taskOf(el) { const key = el.closest('[data-task]')?.dataset.task; return form.tasks.find(t => t.key === key); }
$('stagePlan').addEventListener('input', e => {
  const el = e.target;
  if (el.hasAttribute('data-cancel-reason')) { if (cancelEdit) cancelEdit.reason = el.value; return; }
  if (el.dataset.msearch) {
    // 검색은 서버 저장·임시저장과 무관. 목록만 다시 그린다 (입력칸 포커스 유지)
    memberQuery.set(el.dataset.msearch, el.value);
    const task = form.tasks.find(t => t.key === el.dataset.msearch);
    const pool = document.querySelector(`[data-member-pool="${el.dataset.msearch}"]`);
    if (task && pool) pool.innerHTML = renderPool(task);
    return;
  }
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
    report_id: report()?.id || null,
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
  if (busy || !editable()) return;
  const problem = validatePlan();
  if (problem) { tell(problem, 'error'); return; }
  const dup = [...new Set(form.tasks.flatMap(t => t.members.map(m => m.person_id)).filter((id, i, all) => all.indexOf(id) !== i))];
  if (dup.length && !confirm(`같은 인원이 여러 작업에 들어 있습니다.\n${dup.map(memberName).join(', ')}\n\n이대로 저장할까요?`)) return;
  const payload = buildPayload();
  const request_id = requestIdFor(slots.plan, payload);
  setBusy(true, '작업계획 저장 중');
  try {
    const result = await rpc('tbm_save_plan', { p_payload: { ...payload, request_id } });
    slots.plan = {};
    today.reports = [result.report, ...(today.reports || []).filter(x => x.id !== result.report.id)];
    today.report = result.report; form = formFromReport(result.report); dirty = false; clearDraft();
    renderAll();
    const carried = result.report.tasks.filter(t => t.carried_from_task_id).length;
    tell(`작업계획을 서버에 저장했습니다 (${kstTime(result.report.updated_at)}, 작업 ${result.report.tasks.length}건${carried ? `, 이월 이어받음 ${carried}건` : ''}${payload.drop_carry_ids.length ? `, 이어받지 않음 ${payload.drop_carry_ids.length}건` : ''}).`, 'ok');
    await finishStep('작업계획 저장 완료', `작업 ${result.report.tasks.length}건${carried ? ` · 전일 이월 ${carried}건` : ''}`);
  } catch (e) {
    if (e.code === 'VERSION_CONFLICT' || e.code === 'CARRY_NOT_AVAILABLE' || e.code === 'TASK_NOT_FOUND') {
      slots.plan = {}; clearDraft();
      await load({ quiet: true });
      tell(describeError(e) + ' 확인 후 필요한 내용을 다시 입력해주세요.', 'error');
    } else if (e.code === 'REPORT_NOT_EDITABLE') {
      slots.plan = {}; await load({ quiet: true }); tell(describeError(e), 'error');
    } else tell(describeError(e) + (e.code === 'NETWORK' || e.code === 'TIMEOUT' ? '' : ' (서버에 저장되지 않았습니다)'), 'error');
    if (!BLOCKING.includes(e.code)) showSaveError(saveErrorText(e), ['VERSION_CONFLICT', 'CARRY_NOT_AVAILABLE', 'TASK_NOT_FOUND', 'REPORT_NOT_EDITABLE'].includes(e.code) ? null : savePlan);
  } finally { setBusy(false); }
}
$('savePlan').addEventListener('click', savePlan);

// ---------- 출근 TBM ----------
function risksText(r) { return [...(r.risks || []).filter(x => x !== '기타'), ...(r.risks?.includes('기타') ? [`기타(${r.risk_other || '-'})`] : [])].join(', ') || '없음'; }
function tasksHtml(r) {
  return r.tasks.map(t => `<div class="plan-view-item"><strong>작업 ${t.task_no} · ${escapeHtml(t.place)}</strong>
    <span>${escapeHtml(t.content)}</span>
    <span>인원: ${membersLine(t.members)}</span></div>`).join('');
}
function renderMorning() {
  const r = report();
  const done = !!r?.morning_at;
  $('morningBadge').textContent = done ? `보고 완료 ${kstTime(r.morning_at)}` : '보고 전';
  $('morningBadge').className = 'badge' + (done ? ' ok' : '');
  if (!r?.tasks?.length) {
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
  today.reports = [r, ...(today.reports || []).filter(x => x.id !== r.id)];
  if (!dirty) form = formFromReport(r);
  renderAll();
}
async function handleActionError(e) {
  if (RELOAD_CODES.includes(e.code)) { await load({ quiet: true }); tell(describeError(e), 'error'); }
  else if (BLOCKING.includes(e.code)) block(describeError(e));
  else tell(describeError(e) + (e.code === 'NETWORK' || e.code === 'TIMEOUT' ? '' : ' (서버에 저장되지 않았습니다)'), 'error');
}
function saveErrorText(e) {
  if (e.code === 'NETWORK' || e.code === 'TIMEOUT') return '저장됐는지 확인되지 않았습니다. 입력한 내용은 그대로 있습니다. 다시 눌러주세요 (같은 요청은 한 번만 저장됩니다).';
  if (RELOAD_CODES.includes(e.code)) return `${describeError(e)} 최신 내용을 다시 불러왔습니다. 확인한 뒤 다시 저장해주세요.`;
  return `${describeError(e)} 입력한 내용은 그대로 있습니다. 다시 저장해주세요.`;
}
// 업무 단계 완료 버튼의 실패: 지금 화면에 그대로 남는다
async function stepFailed(e, retry = null) {
  await handleActionError(e);
  if (!BLOCKING.includes(e.code)) showSaveError(saveErrorText(e), RELOAD_CODES.includes(e.code) ? null : retry);
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
    await finishStep('출근 TBM 보고 완료', kstTime(res.report.morning_at));
  } catch (e) { await stepFailed(e, submitMorning); }
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
function membersLine(members) { return members.map(m => `${escapeHtml(m.name)}${m.role !== '작업자' ? `(${escapeHtml(m.role)})` : ''}${m.other_team ? ` <span class="other-team-badge">타 팀원${m.home_team_name ? ' · ' + escapeHtml(m.home_team_name) : ''}</span>` : ''}`).join(', ') || '-'; }
function alertMemberPicker(edit) {
  const lockMap = new Map((today.locks || []).map(l => [l.person_id, l]));
  // 우리 팀 + 이 작업에 이미 들어간 다른 팀 인원(뺄 수 있도록)
  const ids = [...new Set([...today.members.map(m => m.person_id), ...edit.members.map(m => m.person_id)])];
  return ids.map(id => {
    const m = { person_id: id, name: memberName(id) };
    const info = personInfo(id);
    const chosen = edit.members.find(x => x.person_id === m.person_id);
    const lock = lockMap.get(m.person_id);
    return `<label class="task-member ${lock && !chosen ? 'locked' : ''}"><input type="checkbox" data-amember="${m.person_id}" ${chosen ? 'checked' : ''} ${lock && !chosen ? 'disabled' : ''}>
      <span>${escapeHtml(m.name)}</span>${otherBadge(info)}${lock ? `<span class="task-member-assigned">${escapeHtml(lock.team_name)} 배정중</span>` : ''}
      ${chosen ? `<select class="task-role-select" data-arole="${m.person_id}" aria-label="${escapeHtml(m.name)} 역할">${ROLES.map(r => `<option ${chosen.role === r ? 'selected' : ''}>${r}</option>`).join('')}</select>` : ''}</label>`;
  }).join('');
}
function renderAfternoon() {
  const r = report();
  const ready = !!r?.morning_at && editable();
  $('afternoonBlocked').hidden = ready;
  $('afternoonBlocked').textContent = !r ? '오늘 작업계획을 먼저 저장해주세요.' : !r.morning_at ? '출근 TBM을 먼저 보고해주세요.' : !editable() ? '완료된 작업은 내용 보기만 가능합니다.' : '';
  $('afternoonBadge').textContent = r?.afternoon_at ? `확인 ${kstTime(r.afternoon_at)}` : '확인 전';
  $('afternoonBadge').className = 'badge' + (r?.afternoon_at ? ' ok' : '');
  if (r?.afternoon_note && !afternoonNoteTouched) $('afternoonNote').value = r.afternoon_note;
  $('afternoonNote').disabled = !ready;
  const open = (r?.tasks || []).filter(t => !t.result);
  const untouched = open.filter(t => t.alert === 'NONE');
  $('afternoonAllClear').disabled = !ready || !untouched.length;
  $('afternoonAllClear').textContent = !open.length ? '확인할 작업이 없습니다' : !untouched.length ? '모든 작업 확인됨' : untouched.length === open.length ? '전체 이상 없음' : `나머지 ${untouched.length}건 이상 없음`;
  $('afternoonTasks').innerHTML = (r?.tasks || []).map(t => {
    const stopped = t.alert === 'STOPPED';
    const closed = !!t.result && !stopped;
    const editing = alertEdit?.taskId === t.id ? alertEdit : null;
    const selected = editing ? editing.alert : t.alert;
    const cls = stopped ? 'is-stopped' : t.alert === 'RISK' ? 'is-risk' : t.alert === 'DELAYED' ? 'is-alert' : t.alert === 'CHANGED' ? 'is-changed' : t.alert === 'NORMAL' ? 'saved' : '';
    const label = stopped ? `⛔ ${stopLabel(t)}` : closed ? '퇴근 결과 입력됨' : ALERTS[t.alert] ? `${ALERTS[t.alert]} 저장됨` : '미확인';
    const buttons = Object.entries(ALERTS).map(([code, name]) => `<button type="button" class="task-status-btn ${code === 'NORMAL' ? 'normal' : code.toLowerCase()} ${selected === code ? 'selected' : ''}"
      data-alert="${code}" data-task-id="${t.id}" ${!ready || closed || stopped ? 'disabled' : ''}>${name}</button>`).join('')
      + `<button type="button" class="task-status-btn stop ${selected === 'STOPPED' ? 'selected' : ''}" data-alert="STOPPED" data-task-id="${t.id}" ${!ready || closed ? 'disabled' : ''}>⛔ ${stopped ? '작업정지 내용 고치기' : '작업정지'}</button>`;
    const editor = editing && editing.alert === 'STOPPED' ? `<div class="task-detail-editor stop-editor">
      <div class="field"><label class="label">정지 사유 (필수)</label><textarea data-aedit="note" maxlength="500" placeholder="예: 자재 미입고, 우천, 안전 문제">${escapeHtml(editing.note)}</textarea></div>
      <div class="field"><span class="label">처리 방향 (필수)</span><div class="choice-row">
        <button type="button" class="choice-btn ${editing.disposition === 'CARRY' ? 'selected' : ''}" data-stop-disp="CARRY">내일 이월<small>다음 날 작업계획에서 이어받기</small></button>
        <button type="button" class="choice-btn ${editing.disposition === 'END' ? 'selected' : ''}" data-stop-disp="END">오늘 정지로 종료<small>이월 없음 · 완료 아님</small></button></div></div>
      <div class="field"><label class="label">조치 / 요청사항 (선택)</label><textarea data-aedit="action" maxlength="500" placeholder="예: 자재 입고 요청, 내일 오전 재개">${escapeHtml(editing.action)}</textarea></div>
      <p class="stage-note">저장하면 퇴근 TBM 결과도 '작업정지'로 함께 정해집니다. 퇴근 때 다시 입력하지 않습니다.</p>
      <div class="btn-row" style="margin-top:10px"><button type="button" class="task-save-btn stop-save" data-stop-save="${t.id}">작업정지 저장</button><button type="button" class="task-save-btn" style="background:#EEF4FA;color:var(--navy)" data-alert-cancel>취소</button></div>
      ${stopped ? `<button type="button" class="link-btn" data-stop-cancel="${t.id}">작업정지 취소 (잘못 누른 경우)</button>` : ''}
    </div>` : editing && editing.alert !== 'NORMAL' ? `<div class="task-detail-editor">
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
        ${t.alert_note ? `<div class="task-tbm-meta"><strong>${stopped ? '정지 사유' : ALERTS[t.alert] || ''}</strong> ${escapeHtml(t.alert_note)}${t.alert_action ? ` · 조치: ${escapeHtml(t.alert_action)}` : ''}${stopped ? ` · ${kstTime(t.alert_at)} 정지` : ''}</div>` : ''}</div>
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
    await finishStep('오후 TBM 저장 완료', count ? `정상 ${count}건` : '');
  } catch (e) { await stepFailed(e, afternoonAllClear); }
  finally { setBusy(false); }
}
// 작업정지: 사유와 처리 방향(내일 이월 / 오늘 정지로 종료)을 함께 저장. CANCEL은 잘못 누른 정지를 되돌린다
async function saveStop(taskId, disposition) {
  if (busy || planIsDirty()) return;
  const task = report().tasks.find(t => t.id === taskId);
  const edit = alertEdit?.taskId === taskId ? alertEdit : null;
  let args;
  if (disposition === 'CANCEL') {
    if (!confirm(`작업 ${task.task_no}의 작업정지를 취소할까요?\n취소하면 이 작업의 오후 상태를 다시 입력해야 합니다.`)) return;
    args = { p_task_id: taskId, p_reason: null, p_disposition: 'CANCEL', p_action: null };
  } else {
    const note = (edit?.note || '').trim();
    if (note.length < 2) { tell('정지 사유를 2자 이상 적어주세요.', 'error'); return; }
    if (!edit.disposition) { tell('처리 방향(내일 이월 / 오늘 정지로 종료)을 골라주세요.', 'error'); return; }
    args = { p_task_id: taskId, p_reason: note, p_disposition: edit.disposition, p_action: (edit.action || '').trim() || null };
  }
  args.p_request_id = requestIdFor(slots.stop, args);
  setBusy(true, '작업정지 저장 중');
  try {
    const res = await rpc('tbm_task_stop', args);
    slots.stop = {}; alertEdit = null;
    applyReport(res.report);
    tell(disposition === 'CANCEL' ? `작업 ${task.task_no}의 작업정지를 취소했습니다. 오후 상태를 다시 입력해주세요.`
      : `작업 ${task.task_no}을(를) 작업정지(${STOP_DISPOSITIONS[args.p_disposition]})로 저장했습니다.`, 'ok');
    // 정지 취소는 고치는 중이라 화면에 남고, 작업정지 저장은 단계 완료로 홈에 간다
    if (disposition !== 'CANCEL') await finishStep('작업정지 저장 완료', `작업 ${task.task_no} · ${STOP_DISPOSITIONS[args.p_disposition]}`);
  } catch (e) { if (disposition === 'CANCEL') await handleActionError(e); else await stepFailed(e, () => saveStop(taskId, disposition)); }
  finally { setBusy(false); }
}
$('afternoonAllClear').addEventListener('click', afternoonAllClear);
$('afternoonNote').addEventListener('input', () => { afternoonNoteTouched = true; });
$('afternoonTasks').addEventListener('click', e => {
  const btn = e.target.closest('button'); if (!btn || busy) return;
  if (btn.dataset.alert) {
    const t = report().tasks.find(x => x.id === btn.dataset.taskId);
    if (btn.dataset.alert === 'NORMAL') { if (alertEdit?.taskId === t.id) alertEdit = null; saveAlert(t.id, 'NORMAL'); return; }
    if (btn.dataset.alert === 'STOPPED') {
      const stopped = t.alert === 'STOPPED';
      alertEdit = { taskId: t.id, alert: 'STOPPED', note: stopped ? t.alert_note || '' : '', action: stopped ? t.alert_action || '' : '',
        disposition: stopped ? (t.carry_over ? 'CARRY' : 'END') : null };
      renderAfternoon();
      document.querySelector(`[data-afternoon-task="${t.id}"] [data-aedit=note]`)?.focus();
      return;
    }
    alertEdit = { taskId: t.id, alert: btn.dataset.alert, note: t.alert === btn.dataset.alert ? t.alert_note || '' : '', action: t.alert === btn.dataset.alert ? t.alert_action || '' : '',
      place: t.place, content: t.content, members: t.members.map(m => ({ person_id: m.person_id, role: m.role })) };
    renderAfternoon();
    document.querySelector(`[data-afternoon-task="${t.id}"] [data-aedit=note]`)?.focus();
  } else if (btn.dataset.alertSave) saveAlert(btn.dataset.alertSave, alertEdit.alert);
  else if (btn.dataset.stopDisp && alertEdit) { alertEdit.disposition = btn.dataset.stopDisp; renderAfternoon(); }
  else if (btn.dataset.stopSave) saveStop(btn.dataset.stopSave, alertEdit?.disposition);
  else if (btn.dataset.stopCancel) saveStop(btn.dataset.stopCancel, 'CANCEL');
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
  $('eveningBlocked').textContent = !r ? '오늘 작업계획을 먼저 저장해주세요.' : !r.morning_at ? '출근 TBM을 먼저 보고해주세요.' : !editable() ? '완료된 작업은 내용 보기만 가능합니다.' : '';
  $('eveningBadge').textContent = r?.evening_at ? `마감 ${kstTime(r.evening_at)}` : '마감 전';
  $('eveningBadge').className = 'badge' + (r?.evening_at ? ' ok' : '');
  if (r?.evening_note && !eveningNoteTouched) $('eveningNote').value = r.evening_note;
  $('eveningNote').disabled = !ready;
  const open = (r?.tasks || []).filter(t => !t.result);
  $('eveningClose').disabled = !ready;
  $('eveningClose').hidden = !!r?.evening_at;
  $('eveningClose').textContent = r?.evening_at ? '퇴근 마감 완료' : open.length ? `나머지 ${open.length}건 완료로 하고 퇴근 마감` : '퇴근 TBM 마감';
  $('eveningTasks').innerHTML = (r?.tasks || []).map(t => {
    const stopped = t.result === 'STOPPED';
    const editing = resultEdit?.taskId === t.id ? resultEdit : null;
    const selected = editing ? editing.result : t.result;
    const cls = stopped ? 'is-stopped' : t.result === 'DONE' ? 'saved' : ['PARTIAL', 'NOT_DONE'].includes(t.result) ? 'is-alert' : '';
    const label = stopped ? `⛔ ${stopLabel(t)}` : t.result ? `${RESULTS[t.result]}${t.carry_over ? ' · 이월' : ''} 저장됨` : '미입력';
    // 작업정지는 오후 TBM에서 결과까지 정해졌으므로 다시 입력하지 않는다 (고치기는 오후 TBM에서)
    const buttons = stopped ? '' : Object.entries(RESULTS).map(([code, name]) => `<button type="button" class="task-status-btn ${code === 'DONE' ? 'normal' : code === 'EXCLUDED' ? '' : 'danger'} ${selected === code ? 'selected' : ''}"
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
        <div class="task-tbm-meta">${escapeHtml(t.content)}<br>인원: ${membersLine(t.members)}${ALERT_LABELS[t.alert] && t.alert !== 'NORMAL' ? `<br>오후: ${ALERT_LABELS[t.alert]} · ${escapeHtml(t.alert_note || '')}` : ''}</div>
        ${t.result_note || t.carry_over ? `<div class="task-tbm-meta">${t.result_note ? escapeHtml(t.result_note) : ''}${t.carry_over ? `${t.result_note ? ' · ' : ''}이월: ${escapeHtml(t.carry_note || '')}` : ''}</div>` : ''}</div>
        <span class="task-save-state">${label}</span></div>
      ${stopped ? `<div class="stop-note">오후 TBM에서 작업정지로 처리됨 · 퇴근 결과 입력 필요 없음${ready ? ' <button type="button" class="link-btn" data-go="stageAfternoon">오후 TBM에서 고치기</button>' : ''}</div>` : `<div class="task-status-buttons">${buttons}</div>`}${editor}</div>`;
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
    await finishStep('퇴근 TBM 마감 완료', carried ? `내일 이월 ${carried}건` : kstTime(res.report.evening_at));
  } catch (e) { await stepFailed(e, eveningClose); }
  finally { setBusy(false); }
}
$('eveningClose').addEventListener('click', eveningClose);
$('errorSheetClose').addEventListener('click', hideSaveError);
$('errorSheetRetry').addEventListener('click', () => { const retry = retryStep; hideSaveError(); if (retry && !busy) retry(); });
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


// ---------- 출역 관리 (오늘 · 우리 팀 공식 소속 인원) ----------
// 순서: 전체 출근(또는 전체 퇴근) → 다른 사람만 바꾸기 → 확정. 확정 전 선택은 이 화면에만 있고 서버에 저장되지 않는다.
const ATT_IN = { PRESENT: '출근', LATE: '지각', ABSENT: '결근', OFF: '휴무' };
const ATT_OUT = { LEFT: '퇴근', EARLY: '조퇴', NOT_LEFT: '미퇴근' };
const ATT_CLASS = { PRESENT: 'good', LATE: 'warn', ABSENT: 'bad', OFF: 'gray', LEFT: 'good', EARLY: 'warn', NOT_LEFT: 'bad' };
let att = null;        // tbm_attendance_today 결과
let attTab = 'IN';
const attDraft = { IN: new Map(), OUT: new Map() };
const attServer = (p, kind) => kind === 'IN' ? p.check_in_status : p.check_out_status;
const attCanOut = p => ['PRESENT', 'LATE'].includes(p.check_in_status);
const attTargets = kind => !att ? [] : kind === 'IN' ? att.people : att.people.filter(attCanOut);
function attPending(kind) {
  return attTargets(kind).filter(p => attDraft[kind].has(p.person_id) && attDraft[kind].get(p.person_id) !== attServer(p, kind));
}
function renderAttendanceHome() {
  if (!att) return;
  const inDone = att.people.filter(p => p.check_in_status).length;
  const outs = attTargets('OUT');
  const outDone = outs.filter(p => p.check_out_status).length;
  $('openAttendanceSub').textContent = !inDone ? `출근 확정 전 · ${att.people.length}명` : `출근 ${inDone}/${att.people.length} 확정 · 퇴근 ${outDone}/${outs.length}`;
  $('openAttendance').classList.toggle('done', att.people.length > 0 && inDone === att.people.length && outs.length === outDone);
}
function renderAttendance() {
  if (!att) return;
  const kind = attTab;
  const names = kind === 'IN' ? ATT_IN : ATT_OUT;
  const label = kind === 'IN' ? '출근' : '퇴근';
  const targets = attTargets(kind);
  const done = targets.filter(p => attServer(p, kind)).length;
  $('attendanceTitle').textContent = `출역 관리 · ${att.team.name}`;
  $('attendanceHead').textContent = `${kstDateLabel(att.date)} · ${att.team.name} ${att.people.length}명`;
  document.querySelectorAll('[data-att-tab]').forEach(b => { b.classList.toggle('selected', b.dataset.attTab === kind); b.setAttribute('aria-selected', String(b.dataset.attTab === kind)); });
  $('attendanceBadge').textContent = `${label} 확정 ${done}/${targets.length}`;
  $('attendanceBadge').className = 'badge' + (targets.length && done === targets.length ? ' ok' : '');
  $('attendanceSummary').innerHTML = Object.entries(names).map(([code, name]) => `<span class="att-count ${ATT_CLASS[code]}">${name} <b>${targets.filter(p => attServer(p, kind) === code).length}</b></span>`).join('')
    + `<span class="att-count">미확정 <b>${targets.length - done}</b></span>`
    + (kind === 'OUT' && targets.length < att.people.length ? `<div class="att-note">퇴근은 출근·지각으로 확정된 ${targets.length}명만 처리합니다.</div>` : '');
  const blank = targets.filter(p => !attServer(p, kind) && !attDraft[kind].has(p.person_id));
  $('attendanceAll').textContent = blank.length ? `전체 ${label} (${blank.length}명)` : `전체 ${label} 선택됨`;
  $('attendanceAll').disabled = !blank.length;
  const pending = attPending(kind);
  const fixes = pending.filter(p => attServer(p, kind)).length;
  $('attendanceConfirm').textContent = pending.length ? `${label} 확정 (${pending.length}명${fixes ? ` · 수정 ${fixes}명` : ''})` : `${label} 확정할 선택 없음`;
  $('attendanceConfirm').disabled = !pending.length;
  $('attendanceList').innerHTML = att.people.map(p => {
    const server = attServer(p, kind);
    const draft = attDraft[kind].get(p.person_id);
    const chosen = draft ?? server;
    const locked = kind === 'OUT' && !attCanOut(p);
    const at = kind === 'IN' ? p.check_in_at : p.check_out_at;
    const by = kind === 'IN' ? p.check_in_by : p.check_out_by;
    const state = locked ? (p.check_in_status ? `${ATT_IN[p.check_in_status]} · 퇴근 처리 없음` : '출근 확정 전')
      : server ? `${names[server]} 확정 · ${kstTime(at)} · ${by || '-'}${draft && draft !== server ? ` → ${names[draft]}(으)로 수정 예정` : ''}`
      : draft ? `${names[draft]} 선택됨 · 아직 확정 전` : '미확정';
    return `<div class="att-row ${locked ? 'locked' : ''} ${draft && draft !== server ? 'pending' : ''} ${chosen ? 'is-' + ATT_CLASS[chosen] : ''}" data-att-person="${p.person_id}">
      <div class="att-head"><span class="att-name">${escapeHtml(p.name)}</span>${p.is_leader ? '<span class="task-tag">팀장</span>' : ''}${p.corrections ? `<span class="att-fix">수정 ${p.corrections}회</span>` : ''}</div>
      <div class="att-state">${escapeHtml(state)}</div>
      ${locked ? '' : `<div class="att-buttons n${Object.keys(names).length}">${Object.entries(names).map(([code, name]) => `<button type="button" class="att-btn ${ATT_CLASS[code]} ${chosen === code ? 'selected' : ''}" data-att-status="${code}" aria-pressed="${chosen === code}">${name}</button>`).join('')}</div>`}
    </div>`;
  }).join('') || '<div class="task-member-empty">우리 팀 공식 소속 인원이 없습니다. 관리자에게 팀 소속 등록을 요청해주세요.</div>';
  $('attendanceState').className = 'server-state' + (pending.length ? ' dirty' : ' ok');
  $('attendanceState').textContent = pending.length ? `확정하지 않은 선택 ${pending.length}명 (아직 서버에 저장되지 않음)` : '화면의 확정 상태는 모두 서버에 저장된 내용입니다.';
}
async function loadAttendance({ quiet = false } = {}) {
  if (!quiet) setBusy(true, '출역 불러오는 중');
  try {
    att = await rpc('tbm_attendance_today', { p_team_id: today?.team?.id || null });
    renderAttendance(); renderAttendanceHome();
    return true;
  } catch (e) {
    tell(e.code === 'UNKNOWN' ? '출역 관리를 아직 쓸 수 없습니다 (서버 준비 전). 관리자에게 문의해주세요.' : describeError(e), 'error');
    return false;
  } finally { if (!quiet) setBusy(false); }
}
async function confirmAttendance() {
  if (busy || !att) return;
  const kind = attTab;
  const names = kind === 'IN' ? ATT_IN : ATT_OUT;
  const label = kind === 'IN' ? '출근' : '퇴근';
  const pending = attPending(kind);
  if (!pending.length) return;
  const fixes = pending.filter(p => attServer(p, kind));
  if (fixes.length && !confirm(`이미 확정된 ${fixes.length}명의 ${label} 상태를 바꿉니다. 수정 이력이 남습니다.\n${fixes.map(p => `${p.name}: ${names[attServer(p, kind)]} → ${names[attDraft[kind].get(p.person_id)]}`).join('\n')}`)) return;
  const unset = attTargets(kind).filter(p => !attServer(p, kind) && !attDraft[kind].has(p.person_id));
  if (unset.length && !confirm(`아직 고르지 않은 ${unset.length}명은 이번에 확정하지 않습니다.\n${unset.map(p => p.name).join(', ')}\n\n고른 ${pending.length}명만 확정할까요?`)) return;
  const payload = { team_id: att.team.id, kind, work_date: att.date, entries: pending.map(p => ({ person_id: p.person_id, status: attDraft[kind].get(p.person_id) })) };
  payload.request_id = requestIdFor(slots.attendance, payload);
  setBusy(true, `${label} 확정 중`);
  try {
    const res = await rpc('tbm_attendance_save', { p_payload: payload });
    slots.attendance = {};
    attDraft[kind].clear();
    att = { ...att, people: res.people };
    for (const id of [...attDraft.OUT.keys()]) if (!attCanOut(att.people.find(p => p.person_id === id) || {})) attDraft.OUT.delete(id);
    renderAttendance(); renderAttendanceHome();
    tell(`${label} ${pending.length}명을 확정했습니다${fixes.length ? ` (수정 ${fixes.length}명, 이력 남음)` : ''}.`, 'ok');
  } catch (e) {
    tell(describeError(e) + (e.code === 'NETWORK' || e.code === 'TIMEOUT' ? '' : ' (저장되지 않았습니다)'), 'error');
    if (['MEMBER_NOT_IN_TEAM', 'ATTENDANCE_NOT_CHECKED_IN', 'ATTENDANCE_DATE_LOCKED'].includes(e.code)) { slots.attendance = {}; await loadAttendance({ quiet: true }); }
  } finally { setBusy(false); }
}
$('openAttendance').addEventListener('click', async () => { if (busy) return; tell(''); if (await loadAttendance()) showStage('stageAttendance'); });
$('attendanceRefresh').addEventListener('click', async () => { if (await loadAttendance()) tell('최신 출역을 불러왔습니다. 확정하지 않은 선택은 그대로 둡니다.'); });
$('attendanceConfirm').addEventListener('click', confirmAttendance);
$('attendanceAll').addEventListener('click', () => {
  const code = attTab === 'IN' ? 'PRESENT' : 'LEFT';
  for (const p of attTargets(attTab)) if (!attServer(p, attTab) && !attDraft[attTab].has(p.person_id)) attDraft[attTab].set(p.person_id, code);
  renderAttendance();
});
document.querySelector('#stageAttendance .seg').addEventListener('click', e => {
  const tab = e.target.closest('[data-att-tab]')?.dataset.attTab; if (!tab) return;
  attTab = tab; renderAttendance();
});
$('attendanceList').addEventListener('click', e => {
  const btn = e.target.closest('[data-att-status]'); if (!btn || busy || !att) return;
  const id = btn.closest('[data-att-person]').dataset.attPerson;
  const p = att.people.find(x => x.person_id === id);
  if (btn.dataset.attStatus === attServer(p, attTab)) attDraft[attTab].delete(id); else attDraft[attTab].set(id, btn.dataset.attStatus);
  renderAttendance();
});

// Same-day sessions. Completed sessions are shown in a separate read-only view.
function renderSessions() {
  const completed = (today.reports || []).filter(r => r.evening_at);
  $('completedSessions').hidden = !completed.length;
  $('sessionList').innerHTML = completed.map(r => `<div class="session-row">
    <div><strong>작업 ${r.session_no} · 완료</strong><div class="team-meta">${r.tasks.map(t => escapeHtml(t.place)).join(' · ') || '작업계획'} · ${kstTime(r.evening_at)} 마감</div></div>
    <button class="stage-small-btn" type="button" data-session-view="${r.id}">내용 보기</button></div>`).join('');
}
async function openCompleted(id) {
  if (busy) return;
  setBusy(true, '완료 작업 불러오는 중');
  try {
    const d = await rpc('tbm_report_detail', { p_report_id: id });
    const r = d.report;
    $('sessionDetailTitle').textContent = `작업 ${r.session_no} · ${r.evening_at ? '완료' : '내용'}`;
    $('sessionDetailBody').innerHTML = `<p class="notice">완료된 기록은 읽기 전용입니다.</p>
      <dl class="kv"><dt>보고자</dt><dd>${escapeHtml(r.reporter_label)}</dd>
      <dt>저장</dt><dd>${kstTime(r.updated_at)}</dd><dt>예상 종료</dt><dd>${escapeHtml(r.end_time || '-')}</dd>
      <dt>위험요인</dt><dd>${escapeHtml(risksText(r))}</dd><dt>안전조치</dt><dd>${escapeHtml(r.safety_note || '-')}</dd>
      <dt>특이사항</dt><dd>${escapeHtml(r.issue_note || '-')}</dd>
      <dt>소장 확인 필요</dt><dd>${r.needs_manager_check ? '필요' : '-'}</dd>
      ${[['출근',r.morning_at,r.morning_note],['오후',r.afternoon_at,r.afternoon_note],['퇴근 마감',r.evening_at,r.evening_note]].map(([label,at,note]) => `<dt>${label}</dt><dd>${at ? kstTime(at) : '-'} ${escapeHtml(note || '')}</dd>`).join('')}</dl>
      <div class="plan-view">${r.tasks.map(t => `<div class="plan-view-item"><strong>세부 작업 ${t.task_no} · ${escapeHtml(t.place)}</strong><span>${escapeHtml(t.content)}</span>
        <span>인원: ${membersLine(t.members)}</span><span>오후: ${ALERT_LABELS[t.alert] || '미확인'} · ${escapeHtml(t.alert_note || '')} ${escapeHtml(t.alert_action || '')}</span>
        <span>퇴근: ${t.result === 'STOPPED' ? stopLabel(t) : RESULTS[t.result] || '미입력'} · ${escapeHtml(t.result_note || '')}</span>${t.carry_over ? `<span>이월: ${escapeHtml(t.carry_note || '')}</span>` : ''}</div>`).join('')}</div>
      ${['MORNING','AFTERNOON','EVENING'].map((kind,i) => `<h3>${['출근','오후','퇴근'][i]} 사진</h3><div class="photo-preview">${r.photos.filter(p => p.kind===kind).map(p => `<div class="photo-thumb"><img alt="${['출근','오후','퇴근'][i]} 사진" data-photo-path="${escapeHtml(p.path)}"><span class="photo-state">${kstTime(p.created_at)}</span></div>`).join('') || '사진 없음'}</div>`).join('')}
      <h3>저장 이력</h3><ul>${d.history.map(h => `<li>${kstTime(h.at)} · ${escapeHtml(h.actor)} · ${escapeHtml(({SESSION_OPENED:'새 작업 열기',PLAN_SAVE:'계획 저장',MORNING_SUBMIT:'출근 TBM',AFTERNOON_ALL_CLEAR:'오후 TBM',EVENING_CLOSE:'퇴근 마감',PHOTO_ADD:'사진 추가',PHOTO_REMOVE:'사진 숨김',TASK_RESULT:'작업 결과',TASK_NORMAL:'정상',TASK_CHANGED:'변경',TASK_DELAYED:'지연',TASK_RISK:'위험',TASK_STOPPED:'작업정지',TASK_STOP_CANCELLED:'작업정지 취소',CARRY_CANCELLED:'이월 취소'})[h.action] || '작업 기록')} ${escapeHtml(h.note || '')}</li>`).join('')}</ul>`;
    await loadPhotoUrls(); showStage('stageSessionDetail');
  } catch(e) { tell(describeError(e),'error'); } finally { setBusy(false); }
}
$('sessionList').addEventListener('click', e => { const id=e.target.closest('[data-session-view]')?.dataset.sessionView; if(id) openCompleted(id); });
$('openNextSession').addEventListener('click', async () => {
  if(busy || !report()?.evening_at) return;
  const previous=report().id;
  setBusy(true,'새 작업 여는 중');
  try {
    await rpc('tbm_open_next',{p_previous_report_id:previous});
    dirty=false; clearDraft(); alertEdit=null; resultEdit=null; afternoonNoteTouched=false; eveningNoteTouched=false;
    for(const id of ['morningNote','afternoonNote','eveningNote']) $(id).value='';
    for(const key of Object.keys(slots)) slots[key]={};
    if(await load({quiet:true})) { showStage('stagePlan'); tell(`작업 ${report().session_no}을 열었습니다. 새 작업계획을 작성해주세요.`,'ok'); }
  } catch(e) { await handleActionError(e); } finally {setBusy(false);}
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
  await logout(); location.replace(pageUrl('login'));
});
$('goLogin').addEventListener('click', async () => { await logout(); location.replace(loginUrl(PAGE)); });
window.addEventListener('beforeunload', e => { if (dirty || attPending('IN').length || attPending('OUT').length) { e.preventDefault(); e.returnValue = ''; } });

// 운영 화면에는 TEST 표시를 하지 않는다
const VERSION_LABEL = PROD ? 'v1.2' : `v${PAGE_VERSION} TEST`;
$('pageVersion').textContent = VERSION_LABEL; $('footerVersion').textContent = VERSION_LABEL;
guardBackForward(PAGE);
if (requireLogin(PAGE)) load();
