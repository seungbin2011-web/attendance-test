// S1 하루 흐름 e2e 시험: 팀장 TBM 보고 → 소장·관리자 현황 (로컬 흉내 게이트웨이, 가짜 데이터)
import { setup, newPage, issuePin, sql, noHorizontalScroll, step, summary, assert } from './helpers.mjs';

const env = await setup();
const PASS = 'pilot-test-pass';
const REPORT_VERSION = 'v0.62 TEST';
const MANAGER_VERSION = 'v0.41 TEST';
const TEAM2 = 'b0000000-0000-0000-0000-000000000002';
const TEAM3 = 'b0000000-0000-0000-0000-000000000003';
const P = n => `c0000000-0000-0000-0000-0000000000${n}`;

async function loginPin(legacy, name, newPin, opts = {}) {
  const temp = await issuePin(env, legacy, name);
  const ctx = await newPage(env, opts);
  const { page } = ctx;
  page.on('dialog', d => d.accept());
  await page.goto(`${env.base}/personnel_test.html?next=tbm_report_test.html`);
  await page.fill('#username', name); await page.fill('#password', temp); await page.click('#loginButton');
  await page.waitForSelector('#pinPanel:not([hidden])');
  await page.fill('#pinNew', newPin); await page.fill('#pinConfirm', newPin); await page.click('#pinButton');
  return ctx;
}
async function loginWork(name, next = 'tbm_report_test.html', opts = {}) {
  const ctx = await newPage(env, opts);
  ctx.page.on('dialog', d => d.accept());
  await ctx.page.goto(`${env.base}/personnel_test.html?next=${next}`);
  await ctx.page.fill('#username', name); await ctx.page.fill('#password', PASS); await ctx.page.click('#loginButton');
  return ctx;
}
const msg = page => page.textContent('#message');
const clearMsg = page => page.evaluate(() => { document.querySelector('#message').textContent = ''; });
async function waitMsg(page, text) {
  await page.waitForFunction(t => document.querySelector('#message').textContent.includes(t), text, { timeout: 8000 });
}
// 작업 카드 입력: 위치·내용·인원(이름 → 역할)
async function fillTask(page, index, place, content, members) {
  const card = page.locator('.task-card').nth(index);
  await card.locator('[data-tfield=place]').fill(place);
  await card.locator('[data-tfield=content]').fill(content);
  for (const [name, role] of Object.entries(members)) {
    const label = page.locator('.task-card').nth(index).locator('.task-member', { hasText: name });
    await label.locator('input[type=checkbox]').check();
    if (role) await page.locator('.task-card').nth(index).locator('.task-member', { hasText: name }).locator('select').selectOption(role);
  }
}
// 브라우저 캔버스로 서로 다른 가짜 JPEG 만들기 (1600x900, 줄이기 확인용)
async function makeJpegs(page, colors) {
  const arrays = await page.evaluate(async colors => Promise.all(colors.map(c => new Promise(res => {
    const cv = document.createElement('canvas'); cv.width = 1600; cv.height = 900;
    const g = cv.getContext('2d'); g.fillStyle = c; g.fillRect(0, 0, 1600, 900); g.fillStyle = '#fff'; g.font = '60px sans-serif'; g.fillText(c, 40, 120);
    cv.toBlob(b => b.arrayBuffer().then(a => res(Array.from(new Uint8Array(a)))), 'image/jpeg', 0.9);
  }))), colors);
  return arrays.map((a, i) => ({ name: `photo${i}.jpg`, mimeType: 'image/jpeg', buffer: Buffer.from(a) }));
}
async function thumbsLoaded(page, kind) {
  await page.waitForFunction(k => [...document.querySelectorAll(`[data-photo-preview=${k}] img`)].every(i => i.complete && i.naturalWidth > 0), kind, { timeout: 8000 });
  return page.locator(`[data-photo-preview=${kind}] .photo-thumb`).count();
}
async function rpcFromPage(page, name, args) {
  return page.evaluate(async ([name, args]) => {
    const api = await import('/tbm_api_test.mjs');
    try { return { ok: true, result: await api.rpc(name, args) }; } catch (e) { return { ok: false, code: e.code, message: e.message }; }
  }, [name, args]);
}

let leader;
try {
  await step('로그인 없이 열면 통합 로그인으로 이동 (next 유지)', async () => {
    const { page } = await newPage(env);
    await page.goto(`${env.base}/tbm_report_test.html`);
    await page.waitForURL(/personnel_test\.html\?next=tbm_report_test\.html/);
  });

  await step('팀장 PIN 로그인 → 팀장 TBM 보고 화면, 팀·날짜·보고자는 서버 기준', async () => {
    leader = await loginPin('T-0025', '시험이팀장', '507318');
    const { page, errors } = leader;
    await page.waitForURL(/tbm_report_test\.html/);
    await page.waitForSelector('#stageHome.active');
    assert.match(await page.textContent('#headerSub'), /공사2팀 · 용인 현장 · .* · 시험이팀장 팀장/);
    assert.equal(await page.textContent('#homeStatus'), '미작성');
    assert.equal(await page.textContent('#pageVersion'), REPORT_VERSION);
    assert.match(await page.textContent('#footerVersion'), new RegExp(REPORT_VERSION));
    assert.deepEqual(errors, []);
  });

  await step('작업계획: 우리 팀 소속만 후보 (다른 팀·퇴사자 제외)', async () => {
    const { page } = leader;
    await page.click('#openPlan');
    await page.waitForSelector('#stagePlan.active');
    const names = await page.locator('.task-card').first().locator('.task-member > span:nth-of-type(1)').allTextContents();
    assert.deepEqual(names.sort(), ['시험이팀장', '시험중복가', '시험팀원가', '시험팀원나'].sort());
  });

  await step('빈 입력·인원 없음·기타 내용 없음은 저장 요청 없이 안내', async () => {
    const { page } = leader;
    let calls = 0; const count = r => { if (r.url().includes('tbm_save_plan')) calls++; };
    page.on('request', count);
    await page.click('#savePlan');
    await waitMsg(page, '작업 위치와 작업 내용');
    await page.locator('.task-card').first().locator('[data-tfield=place]').fill('3층 MDF실');
    await page.locator('.task-card').first().locator('[data-tfield=content]').fill('배선 작업');
    await page.click('#savePlan');
    await waitMsg(page, '인원을 1명 이상');
    await page.locator('.task-card').first().locator('.task-member', { hasText: '시험팀원가' }).locator('input').check();
    await page.locator('#riskGrid input[value=기타]').check();
    await page.click('#savePlan');
    await waitMsg(page, '기타 위험요인 내용');
    page.off('request', count);
    assert.equal(calls, 0);
    assert.ok((await page.getAttribute('#message', 'class')).includes('error'));
  });

  await step('저장: 서버 확인 후에만 저장 완료 표시, 두 번 눌러도 한 번만 저장', async () => {
    const { page } = leader;
    await page.fill('#riskOther', '협소 공간');
    await page.locator('#riskGrid input[value=전기]').check();
    await page.locator('.task-card').first().locator('.task-member', { hasText: '시험팀원가' }).locator('select').selectOption('작업지휘자');
    await page.locator('.task-card').first().locator('.task-member', { hasText: '시험팀원나' }).locator('input').check();
    await page.click('#addTask');
    await fillTask(page, 1, 'B동 옥상', '관로 작업', { '시험중복가': '신호수' });
    await page.fill('#endTime', '17:30');
    await page.fill('#safetyNote', '안전대 착용');
    await page.fill('#issueNote', '자재 반입 지연 가능');
    await page.check('#needsCheck');
    assert.match(await page.textContent('#serverState'), /아직 서버에 저장되지/);
    let calls = 0; page.on('request', r => { if (r.url().includes('tbm_save_plan')) calls++; });
    await page.dblclick('#savePlan');
    await waitMsg(page, '서버에 저장했습니다');
    assert.equal(calls, 1);
    assert.match(await page.textContent('#serverState'), /서버 저장됨 .* 버전 2/);
    const rows = await sql(env, `select r.version, r.risks, r.risk_other, r.needs_manager_check, to_char(r.end_time,'HH24:MI') as end_time, r.reporter_label,
      (select json_agg(json_build_object('no', k.task_no, 'place', k.place, 'members', (select json_agg(a.work_role || ':' || a.legacy_user_id order by a.legacy_user_id) from field_pilot_v1.task_assignments a where a.task_id = k.id)) order by k.task_no)
       from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active) as tasks
      from field_pilot_v1.daily_reports r where r.team_id = $1`, [TEAM2]);
    assert.equal(rows.length, 1);
    const r = rows[0];
    assert.equal(r.version, 2); assert.deepEqual(r.risks.sort(), ['기타', '전기'].sort()); assert.equal(r.risk_other, '협소 공간');
    assert.equal(r.needs_manager_check, true); assert.equal(r.end_time, '17:30'); assert.equal(r.reporter_label, '시험이팀장');
    assert.deepEqual(r.tasks, [{ no: 1, place: '3층 MDF실', members: ['작업지휘자:T-0026', '작업자:T-0027'] }, { no: 2, place: 'B동 옥상', members: ['신호수:T-0036'] }]);
    await page.click('.app-stage.active [data-go=stageHome]');
    assert.equal(await page.textContent('#homeStatus'), '계획 저장');
  });

  await step('이 기기 임시저장: 새로고침 후 복원, 서버 저장과 구분 표시, 삭제하면 서버 내용', async () => {
    const { page } = leader;
    await page.click('#openPlan');
    await page.fill('#safetyNote', '안전대 착용 + 추락방지망 확인');
    await page.waitForTimeout(700);
    await page.reload();
    await page.waitForSelector('#stageHome.active');
    await waitMsg(page, '임시저장된 작업계획을 불러왔습니다');
    await page.click('#openPlan');
    assert.equal(await page.inputValue('#safetyNote'), '안전대 착용 + 추락방지망 확인');
    assert.match(await page.textContent('#serverState'), /아직 서버에 저장되지/);
    await page.click('#draftClear');
    assert.equal(await page.inputValue('#safetyNote'), '안전대 착용');
    const stored = await page.evaluate(() => localStorage.getItem('tbmReportDraft_v1'));
    assert.equal(stored, null);
  });

  await step('연결 실패: 성공 표시 없음, 다시 누르면 같은 요청번호로 한 번만 반영', async () => {
    const { page } = leader;
    await page.fill('#safetyNote', '안전대 착용, 공구 낙하 주의');
    const ids = [];
    page.on('request', r => { if (r.url().includes('tbm_save_plan')) ids.push(JSON.parse(r.postData()).p_payload.request_id); });
    await page.route('**/rest/v1/rpc/tbm_save_plan', route => route.abort());
    await page.click('#savePlan');
    await waitMsg(page, '서버에 연결하지 못했습니다');
    assert.ok(!(await msg(page)).includes('저장했습니다'));
    assert.match(await page.textContent('#serverState'), /아직 서버에 저장되지/);
    await page.unroute('**/rest/v1/rpc/tbm_save_plan');
    await page.click('#savePlan');
    await waitMsg(page, '서버에 저장했습니다');
    assert.equal(ids.length, 2); assert.equal(ids[0], ids[1]);
    const v = await sql(env, `select version, safety_note from field_pilot_v1.daily_reports where team_id = $1`, [TEAM2]);
    assert.equal(v[0].version, 3); assert.equal(v[0].safety_note, '안전대 착용, 공구 낙하 주의');
  });

  await step('다른 화면이 먼저 저장하면 충돌 안내 후 최신 내용으로 다시 불러옴', async () => {
    const { page } = leader;
    await sql(env, `update field_pilot_v1.daily_reports set version = version + 1, safety_note = '다른 화면에서 수정' where team_id = $1`, [TEAM2]);
    await page.fill('#safetyNote', '이 화면의 수정');
    await page.click('#savePlan');
    await waitMsg(page, '다른 화면에서 먼저 저장됐습니다');
    assert.equal(await page.inputValue('#safetyNote'), '다른 화면에서 수정');
    assert.match(await page.textContent('#serverState'), /버전 4/);
  });

  await step('다른 팀: 시험3팀장은 자기 팀 인원만 보이고, 공사2팀 저장·인원 배정은 서버가 거절', async () => {
    const other = await loginPin('T-0050', '시험삼팀장', '613842');
    const { page } = other;
    await page.waitForURL(/tbm_report_test\.html/);
    await page.waitForSelector('#stageHome.active');
    await page.click('#openPlan');
    const names = await page.locator('.task-card').first().locator('.task-member > span:nth-of-type(1)').allTextContents();
    assert.deepEqual(names.sort(), ['시험삼팀원', '시험삼팀장'].sort());
    const forbidden = await rpcFromPage(page, 'tbm_save_plan', { p_payload: { team_id: TEAM2, tasks: [{ place: 'x', content: 'y', members: [] }] } });
    assert.equal(forbidden.code, 'TEAM_FORBIDDEN');
    const notMine = await rpcFromPage(page, 'tbm_save_plan', { p_payload: { tasks: [{ place: 'x', content: 'y', members: [{ person_id: P(26) }] }] } });
    assert.equal(notMine.code, 'MEMBER_NOT_IN_TEAM'); assert.match(notMine.message, /시험팀원가/);
    const detail = await rpcFromPage(page, 'tbm_today', { p_team_id: TEAM2 });
    assert.equal(detail.code, 'TEAM_FORBIDDEN');
  });

  await step('두 팀 소속 인원: 다른 팀이 먼저 배정하면 우리 화면에서 잠김 표시', async () => {
    await sql(env, `insert into personnel_pilot_v1.memberships (person_id, site_id, team_id) values ($1, 'a0000000-0000-0000-0000-000000000001', $2)`, [P(51), TEAM2]);
    const other = await loginPin('T-0050', '시험삼팀장', '613843');
    const { page } = other;
    await page.waitForSelector('#stageHome.active');
    await page.click('#openPlan');
    await fillTask(page, 0, '시험3 구역', '지원 작업', { '시험삼팀원': '' });
    await page.click('#savePlan');
    await waitMsg(page, '서버에 저장했습니다');
    const { page: p2 } = leader;
    await p2.click('.app-stage.active [data-go=stageHome]');
    await p2.click('#openPlan');
    const locked = p2.locator('.task-card').first().locator('.task-member', { hasText: '시험삼팀원' });
    assert.match(await locked.textContent(), /시험3팀 배정중/);
    assert.ok(await locked.locator('input').isDisabled());
    const direct = await rpcFromPage(p2, 'tbm_save_plan', { p_payload: { version: 4, tasks: [{ place: 'x', content: 'y', members: [{ person_id: P(51) }] }] } });
    assert.equal(direct.code, 'MEMBER_ASSIGNED_ELSEWHERE'); assert.match(direct.message, /시험삼팀원 \(시험3팀\)/);
  });

  await step('출근 TBM: 저장 안 한 계획 변경이 있으면 보고를 막음', async () => {
    const { page } = leader;
    await page.fill('#safetyNote', '저장 안 한 변경');
    await page.click('.app-stage.active [data-open=openMorning]');
    await page.waitForSelector('#stageMorning.active');
    await page.click('#submitMorning');
    await waitMsg(page, '작업계획에 저장하지 않은 변경');
    const rows = await sql(env, `select morning_at from field_pilot_v1.daily_reports where team_id = $1`, [TEAM2]);
    assert.equal(rows[0].morning_at, null);
    await page.click('.app-stage.active [data-go=stagePlan]');
    await page.click('#draftClear');
  });

  await step('출근 TBM: 계획 요약 표시, 연결 실패 시 성공 표시 없음, 재시도 후 보고 완료', async () => {
    const { page } = leader;
    await page.click('.app-stage.active [data-open=openMorning]');
    await page.waitForSelector('#stageMorning.active');
    const tasks = await page.textContent('#morningTasks');
    assert.match(tasks, /작업 1 · 3층 MDF실/); assert.match(tasks, /시험팀원가\(작업지휘자\)/); assert.match(tasks, /시험중복가\(신호수\)/);
    assert.match(await page.textContent('#morningSummary'), /기타\(협소 공간\)/);
    await page.fill('#morningNote', '장비 점검 후 작업 시작');
    await page.route('**/rest/v1/rpc/tbm_submit_morning', route => route.abort());
    await page.click('#submitMorning');
    await waitMsg(page, '서버에 연결하지 못했습니다');
    assert.equal(await page.textContent('#morningBadge'), '보고 전');
    await page.unroute('**/rest/v1/rpc/tbm_submit_morning');
    await page.click('#submitMorning');
    await waitMsg(page, '출근 TBM을 보고했습니다');
    assert.match(await page.textContent('#morningBadge'), /보고 완료/);
    assert.ok(await page.isDisabled('#submitMorning'));
    const rows = await sql(env, `select status, morning_note, morning_at is not null as done from field_pilot_v1.daily_reports where team_id = $1`, [TEAM2]);
    assert.deepEqual(rows[0], { status: 'SUBMITTED', morning_note: '장비 점검 후 작업 시작', done: true });
    const hist = await sql(env, `select count(*)::int as n from field_pilot_v1.workflow_history h join field_pilot_v1.daily_reports r on r.id = h.report_id where r.team_id = $1 and h.action = 'MORNING_SUBMIT'`, [TEAM2]);
    assert.equal(hist[0].n, 1);
    await page.click('.app-stage.active [data-go=stageHome]');
    assert.equal(await page.textContent('#homeStatus'), '출근 보고 완료');
  });

  let photoFiles;
  await step('출근 사진: 4장 고르면 3장만 저장·4번째 안내, 비공개 서명 링크로 미리보기, 입력 잠김', async () => {
    const { page } = leader;
    await page.click('#openMorning');
    await page.waitForSelector('#stageMorning.active');
    photoFiles = await makeJpegs(page, ['#c0392b', '#27ae60', '#2980b9', '#8e44ad', '#d35400']);
    await page.setInputFiles('[data-photo-input=MORNING]', photoFiles.slice(0, 4));
    await waitMsg(page, '사진 3장을 서버에 저장했습니다');
    assert.match(await msg(page), /1장은 올리지 않았습니다/);
    assert.equal(await thumbsLoaded(page, 'MORNING'), 3);
    assert.match(await page.textContent('[data-photo-count=MORNING]'), /사진 3장 \/ 최대 3장/);
    assert.ok(await page.isDisabled('[data-photo-input=MORNING]'));
    const src = await page.getAttribute('[data-photo-preview=MORNING] img', 'src');
    assert.match(src, /\/storage\/v1\/object\/sign\/tbm-photos\/.+\?token=/);
    const rows = await sql(env, `select a.status, a.size_bytes, a.kind, o.name is not null as uploaded from field_pilot_v1.attachments a
      join field_pilot_v1.daily_reports r on r.id = a.report_id left join storage.objects o on o.bucket_id = 'tbm-photos' and o.name = a.object_path
      where r.team_id = $1 and r.work_date = (now() at time zone 'Asia/Seoul')::date`, [TEAM2]);
    assert.equal(rows.length, 3);
    assert.ok(rows.every(r => r.status === 'READY' && r.kind === 'MORNING' && r.uploaded && r.size_bytes <= 2097152));
    const dims = await page.evaluate(() => { const i = document.querySelector('[data-photo-preview=MORNING] img'); return Math.max(i.naturalWidth, i.naturalHeight); });
    assert.equal(dims, 1280);
  });

  await step('사진 빼기 → 같은 사진은 건너뜀, 연결 실패는 성공 표시 없음, 재시도는 같은 자리로 저장', async () => {
    const { page } = leader;
    await page.locator('[data-photo-preview=MORNING] [data-photo-remove]').first().click();
    await waitMsg(page, '사진을 뺐습니다');
    assert.equal(await page.locator('[data-photo-preview=MORNING] .photo-thumb').count(), 2);
    await page.setInputFiles('[data-photo-input=MORNING]', [photoFiles[1]]);
    await waitMsg(page, '이미 올라가 있어 건너뛰었습니다');
    await page.route('**/storage/v1/object/tbm-photos/**', route => route.abort());
    await page.setInputFiles('[data-photo-input=MORNING]', [photoFiles[4]]);
    await waitMsg(page, '서버에 연결하지 못했습니다');
    assert.ok(!(await msg(page)).includes('저장했습니다'));
    assert.equal(await page.locator('[data-photo-preview=MORNING] .photo-thumb').count(), 2);
    await page.unroute('**/storage/v1/object/tbm-photos/**');
    await page.setInputFiles('[data-photo-input=MORNING]', [photoFiles[4]]);
    await waitMsg(page, '사진 1장을 서버에 저장했습니다');
    assert.equal(await thumbsLoaded(page, 'MORNING'), 3);
    const rows = await sql(env, `select a.status, count(*)::int as n from field_pilot_v1.attachments a join field_pilot_v1.daily_reports r on r.id = a.report_id
      where r.team_id = $1 and r.work_date = (now() at time zone 'Asia/Seoul')::date group by a.status order by a.status`, [TEAM2]);
    assert.deepEqual(rows, [{ status: 'DELETED', n: 1 }, { status: 'READY', n: 3 }]);
  });

  await step('다른 팀장은 우리 팀 사진을 올리거나 볼 수 없음 (Storage 정책)', async () => {
    const other = await loginPin('T-0050', '시험삼팀장', '613844');
    const { page } = other;
    await page.waitForSelector('#stageHome.active');
    const [path] = (await sql(env, `select a.object_path from field_pilot_v1.attachments a join field_pilot_v1.daily_reports r on r.id = a.report_id
      where r.team_id = $1 and a.status = 'READY' limit 1`, [TEAM2])).map(r => r.object_path);
    const result = await page.evaluate(async path => {
      const api = await import('/tbm_api_test.mjs');
      const blob = new Blob([new Uint8Array([255, 216, 255, 217])], { type: 'image/jpeg' });
      let upload = 'ok';
      try { await api.uploadPhoto('tbm-photos', path.replace(/[^/]+$/, 'intruder.jpg'), blob); } catch (e) { upload = e.code; }
      const urls = await api.signedUrls('tbm-photos', [path]);
      return { upload, urls: Object.keys(urls).length };
    }, path);
    assert.deepEqual(result, { upload: 'UPLOAD_FAILED', urls: 0 });
  });

  let manager;
  await step('소장 업무계정: 현황 화면으로 이동, 팀별 상태·소장 확인 필요 표시 (읽기 전용)', async () => {
    manager = await loginWork('소장', 'tbm_manager_test.html');
    const { page, errors } = manager;
    await page.waitForURL(/tbm_manager_test\.html/);
    await page.waitForSelector('#stageList.active .team-card');
    assert.equal(await page.textContent('#pageVersion'), MANAGER_VERSION);
    assert.match(await page.textContent('#headerSub'), /^소장 · .*\(오늘\)/);
    const team2 = page.locator('.team-card[data-team=공사2팀]');
    assert.match(await team2.textContent(), /출근 보고/);
    assert.match(await team2.textContent(), /소장 확인 필요/);
    assert.match(await team2.textContent(), /자재 반입 지연 가능/);
    assert.match(await team2.textContent(), /출근 3장/);
    assert.ok((await team2.getAttribute('class')).includes('attention'));
    assert.match(await page.locator('.team-card[data-team=시험3팀]').textContent(), /계획만 저장/);
    assert.equal(await page.locator('#stageList button:has-text("승인")').count(), 0);
    assert.ok(!(await page.evaluate(() => document.body.classList.contains('admin-mode'))));
    assert.deepEqual(errors, []);
  });

  await step('보고 상세: 작업·인원·출근 전달사항·비공개 사진(서명 링크) 표시, 조회 RPC만 호출', async () => {
    const { page } = manager;
    const called = new Set();
    page.on('request', r => { const m = r.url().match(/\/rest\/v1\/rpc\/(\w+)/); if (m) called.add(m[1]); });
    await page.click('.team-card[data-team=공사2팀] [data-detail]');
    await page.waitForSelector('#stageDetail.active');
    const body = await page.textContent('#detailBody');
    assert.match(body, /작업 1 · 3층 MDF실/); assert.match(body, /시험팀원가\(작업지휘자\)/); assert.match(body, /장비 점검 후 작업 시작/);
    await page.waitForFunction(() => [...document.querySelectorAll('#detailBody img')].length === 3 && [...document.querySelectorAll('#detailBody img')].every(i => i.complete && i.naturalWidth > 0));
    await page.click('#detailRefresh');
    await page.click('.app-stage.active [data-go=stageList]');
    await page.waitForSelector('#stageList.active');
    assert.deepEqual([...called].sort(), ['tbm_report_detail', 'tbm_site_overview']);
    const forbidden = await rpcFromPage(page, 'tbm_submit_morning', { p_report_id: (await sql(env, `select id from field_pilot_v1.daily_reports where team_id = $1`, [TEAM2]))[0].id });
    assert.equal(forbidden.code, 'FORBIDDEN');
  });

  await step('지난 날짜 조회: 보고 없는 팀은 미보고', async () => {
    const { page } = manager;
    const yesterday = await page.evaluate(() => { const d = new Date(document.querySelector('#dateInput').value + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() - 1); return d.toISOString().slice(0, 10); });
    await page.fill('#dateInput', yesterday);
    await page.dispatchEvent('#dateInput', 'change');
    await page.waitForFunction(() => !document.querySelector('#headerSub').textContent.includes('(오늘)'));
    assert.match(await page.locator('.team-card[data-team=공사2팀]').textContent(), /미보고/);
  });

  await step('관리자 업무계정은 초록 화면, 팀장·팀원은 현황 화면 차단', async () => {
    const admin = await loginWork('관리자', 'tbm_manager_test.html');
    await admin.page.waitForURL(/tbm_manager_test\.html/);
    await admin.page.waitForSelector('#stageList.active .team-card');
    assert.ok(await admin.page.evaluate(() => document.body.classList.contains('admin-mode')));
    const { page } = leader;
    await page.goto(`${env.base}/tbm_manager_test.html`);
    await page.waitForSelector('#blocked:not([hidden])');
    assert.match(await page.textContent('#blockedText'), /소장·관리자만 사용할 수 있는 화면/);
    await page.goto(`${env.base}/tbm_report_test.html`);
    await page.waitForSelector('#stageHome.active');
  });

  await step('오후 TBM: "전체 이상 없음" 한 번으로 저장 (연결 실패 시 성공 표시 없음, 두 번 눌러도 한 번)', async () => {
    const { page } = leader;
    await page.click('#openAfternoon');
    await page.waitForSelector('#stageAfternoon.active');
    assert.equal(await page.textContent('#afternoonAllClear'), '전체 이상 없음');
    assert.equal(await page.textContent('#afternoonBadge'), '확인 전');
    await page.fill('#afternoonNote', '오후 작업 순서 공유');
    await page.route('**/rest/v1/rpc/tbm_afternoon_all_clear', route => route.abort());
    await page.click('#afternoonAllClear');
    await waitMsg(page, '서버에 연결하지 못했습니다');
    assert.equal(await page.textContent('#afternoonBadge'), '확인 전');
    await page.unroute('**/rest/v1/rpc/tbm_afternoon_all_clear');
    let calls = 0; const count = r => { if (r.url().includes('tbm_afternoon_all_clear')) calls++; };
    page.on('request', count);
    await page.dblclick('#afternoonAllClear');
    await waitMsg(page, '오후 TBM을 저장했습니다');
    page.off('request', count);
    assert.equal(calls, 1);
    assert.match(await msg(page), /2건을 정상/);
    assert.match(await page.textContent('#afternoonBadge'), /확인 \d\d:\d\d/);
    assert.equal(await page.textContent('#afternoonAllClear'), '모든 작업 확인됨');
    assert.equal(await page.locator('.task-tbm-card.saved').count(), 2);
    const rows = await sql(env, `select afternoon_note, (select string_agg(alert, ',' order by task_no) from field_pilot_v1.report_tasks k where k.report_id = r.id and k.is_active) as alerts
      from field_pilot_v1.daily_reports r where team_id = $1 and work_date = (now() at time zone 'Asia/Seoul')::date`, [TEAM2]);
    assert.deepEqual(rows[0], { afternoon_note: '오후 작업 순서 공유', alerts: 'NORMAL,NORMAL' });
  });

  await step('오후 TBM: 위험은 내용 없이 저장 안 됨, 내용·조치 적으면 작업별 저장', async () => {
    const { page } = leader;
    let calls = 0; const count = r => { if (r.url().includes('tbm_task_alert')) calls++; };
    page.on('request', count);
    const card2 = page.locator('.task-tbm-card').nth(1);
    await card2.locator('[data-alert=RISK]').click();
    await card2.locator('[data-alert-save]').click();
    await waitMsg(page, '2자 이상');
    assert.equal(calls, 0);
    await card2.locator('[data-aedit=note]').fill('옥상 끝단 추락 위험');
    await card2.locator('[data-aedit=action]').fill('안전난간 추가 설치 요청');
    await card2.locator('[data-alert-save]').click();
    await waitMsg(page, "작업 2을(를) '위험'(으)로 저장했습니다");
    page.off('request', count);
    assert.equal(calls, 1);
    assert.ok((await page.locator('.task-tbm-card').nth(1).getAttribute('class')).includes('is-risk'));
    assert.match(await page.locator('.task-tbm-card').nth(1).textContent(), /옥상 끝단 추락 위험 · 조치: 안전난간 추가 설치 요청/);
  });

  await step('오후 TBM: 변경은 위치·인원까지 바꿔 저장, 다른 팀 배정 인원은 잠김, 이력에 전후 기록', async () => {
    const { page } = leader;
    const card1 = page.locator('.task-tbm-card').nth(0);
    await card1.locator('[data-alert=CHANGED]').click();
    const locked = page.locator('.task-tbm-card').nth(0).locator('.task-member', { hasText: '시험삼팀원' });
    assert.ok(await locked.locator('input').isDisabled());
    await page.locator('.task-tbm-card').nth(0).locator('[data-aedit=note]').fill('MDF실 선행공정 지연으로 위치 변경');
    await page.locator('.task-tbm-card').nth(0).locator('[data-aedit=place]').fill('4층 EPS실');
    await page.locator('.task-tbm-card').nth(0).locator('.task-member', { hasText: '시험팀원나' }).locator('input').uncheck();
    await page.locator('.task-tbm-card').nth(0).locator('.task-member', { hasText: '시험이팀장' }).locator('input').check();
    await page.locator('.task-tbm-card').nth(0).locator('.task-member', { hasText: '시험이팀장' }).locator('select').selectOption('작업지휘자');
    await page.locator('.task-tbm-card').nth(0).locator('.task-member', { hasText: '시험팀원가' }).locator('select').selectOption('작업자');
    await page.locator('.task-tbm-card').nth(0).locator('[data-alert-save]').click();
    await waitMsg(page, "작업 1을(를) '변경'(으)로 저장했습니다");
    const t = await sql(env, `select k.place, k.alert, (select string_agg(a.work_role || ':' || a.legacy_user_id, ',' order by a.legacy_user_id) from field_pilot_v1.task_assignments a where a.task_id = k.id) as members,
      (select count(*)::int from field_pilot_v1.workflow_history h where h.entity_id = k.id and h.action = 'TASK_CHANGED' and h.before_data ->> 'place' = '3층 MDF실' and h.after_data ->> 'place' = '4층 EPS실') as hist
      from field_pilot_v1.report_tasks k join field_pilot_v1.daily_reports r on r.id = k.report_id where r.team_id = $1 and k.task_no = 1 and k.is_active and r.work_date = (now() at time zone 'Asia/Seoul')::date`, [TEAM2]);
    assert.deepEqual(t[0], { place: '4층 EPS실', alert: 'CHANGED', members: '작업지휘자:T-0025,작업자:T-0026', hist: 1 });
    await page.click('.app-stage.active [data-go=stageHome]');
    assert.match(await page.textContent('#openAfternoonSub'), /이상 2건/);
  });

  await step('소장 현황 v0.2: 오후 확인 시각, 위험·변경 수, 작업별 오후 내용', async () => {
    const { page } = manager;
    await page.fill('#dateInput', await page.evaluate(() => document.querySelector('#dateInput').max));
    await page.dispatchEvent('#dateInput', 'change');
    await page.waitForFunction(() => document.querySelector('#headerSub').textContent.includes('(오늘)'));
    await clearMsg(page);
    await page.click('#refreshBtn');
    await waitMsg(page, '최신 현황');
    const team2 = await page.locator('.team-card[data-team=공사2팀]').textContent();
    assert.match(team2, /오후 \d\d:\d\d/); assert.match(team2, /위험 1/); assert.match(team2, /변경 1/);
    assert.match(team2, /4층 EPS실/); assert.match(team2, /\[위험\]/);
    await page.click('.team-card[data-team=공사2팀] [data-detail]');
    await page.waitForSelector('#stageDetail.active');
    const body = await page.textContent('#detailBody');
    assert.match(body, /오후 작업 순서 공유/);
    assert.match(body, /위험 · 옥상 끝단 추락 위험 · 조치: 안전난간 추가 설치 요청/);
    assert.match(body, /변경 · MDF실 선행공정 지연으로 위치 변경/);
    await page.click('.app-stage.active [data-go=stageList]');
  });

  const todayTask = no => sql(env, `select k.result, k.result_note, k.carry_over, k.carry_note, k.carry_status from field_pilot_v1.report_tasks k join field_pilot_v1.daily_reports r on r.id = k.report_id
    where r.team_id = $1 and k.task_no = $2 and k.is_active and r.work_date = (now() at time zone 'Asia/Seoul')::date`, [TEAM2, no]).then(r => r[0]);

  await step('퇴근 TBM: 미완료는 사유 없이 저장 안 됨, 사유·내일 이월 내용과 함께 저장', async () => {
    const { page } = leader;
    await page.click('#openEvening');
    await page.waitForSelector('#stageEvening.active');
    assert.equal(await page.textContent('#eveningClose'), '나머지 2건 완료로 하고 퇴근 마감');
    const card2 = page.locator('.task-tbm-card[data-evening-task]').nth(1);
    await card2.locator('[data-result=NOT_DONE]').click();
    await card2.locator('[data-result-save]').click();
    await waitMsg(page, '사유를 2자 이상');
    assert.equal((await todayTask(2)).result, null);
    await page.locator('.task-tbm-card[data-evening-task]').nth(1).locator('[data-redit=note]').fill('안전난간 미설치로 중단');
    assert.ok(await page.locator('.task-tbm-card[data-evening-task]').nth(1).locator('[data-redit-carry]').isChecked());
    await page.locator('.task-tbm-card[data-evening-task]').nth(1).locator('[data-redit=carryNote]').fill('옥상 관로 나머지 구간');
    await page.locator('.task-tbm-card[data-evening-task]').nth(1).locator('[data-result-save]').click();
    await waitMsg(page, "작업 2을(를) '미완료'·이월(으)로 저장했습니다");
    assert.deepEqual(await todayTask(2), { result: 'NOT_DONE', result_note: '안전난간 미설치로 중단', carry_over: true, carry_note: '옥상 관로 나머지 구간', carry_status: 'PENDING' });
    assert.equal(await page.textContent('#eveningClose'), '나머지 1건 완료로 하고 퇴근 마감');
  });

  await step('퇴근 TBM: 나머지는 완료로 한 번에 마감 (확인창), 연결 실패 시 성공 표시 없음', async () => {
    const { page } = leader;
    await page.fill('#eveningNote', '공구 정리 완료, 내일 안전난간 먼저 설치');
    await page.route('**/rest/v1/rpc/tbm_evening_close', route => route.abort());
    await page.click('#eveningClose');
    await waitMsg(page, '서버에 연결하지 못했습니다');
    assert.equal(await page.textContent('#eveningBadge'), '마감 전');
    await page.unroute('**/rest/v1/rpc/tbm_evening_close');
    await page.click('#eveningClose');
    await waitMsg(page, '퇴근 TBM을 마감했습니다');
    assert.match(await msg(page), /이월 1건/);
    assert.match(await page.textContent('#eveningBadge'), /마감 \d\d:\d\d/);
    assert.equal((await todayTask(1)).result, 'DONE');
    const r = await sql(env, `select evening_note, evening_at is not null as closed from field_pilot_v1.daily_reports where team_id = $1 and work_date = (now() at time zone 'Asia/Seoul')::date`, [TEAM2]);
    assert.deepEqual(r[0], { evening_note: '공구 정리 완료, 내일 안전난간 먼저 설치', closed: true });
    assert.ok(await page.isDisabled('.task-tbm-card[data-afternoon-task] [data-alert=RISK]'), '결과가 난 작업은 오후 상태 변경 불가');
  });

  await step('퇴근 TBM: 마감 후에도 결과 수정 가능 (일부완료 + 이월 안 함)', async () => {
    const { page } = leader;
    const card1 = page.locator('.task-tbm-card[data-evening-task]').nth(0);
    await card1.locator('[data-result=PARTIAL]').click();
    await page.locator('.task-tbm-card[data-evening-task]').nth(0).locator('[data-redit=note]').fill('배선 90% 완료, 나머지는 타 팀 인계');
    await page.locator('.task-tbm-card[data-evening-task]').nth(0).locator('[data-redit-carry]').uncheck();
    assert.equal(await page.locator('.task-tbm-card[data-evening-task]').nth(0).locator('[data-redit=carryNote]').count(), 0);
    await page.locator('.task-tbm-card[data-evening-task]').nth(0).locator('[data-result-save]').click();
    await waitMsg(page, "작업 1을(를) '일부완료'(으)로 저장했습니다");
    assert.deepEqual(await todayTask(1), { result: 'PARTIAL', result_note: '배선 90% 완료, 나머지는 타 팀 인계', carry_over: false, carry_note: null, carry_status: null });
    await page.click('.app-stage.active [data-go=stageHome]');
    assert.equal(await page.textContent('#homeStatus'), '퇴근 마감');
    assert.match(await page.textContent('#openEveningSub'), /마감 \d\d:\d\d · 이월 1건/);
  });

  await step('소장 현황 v0.3: 퇴근 마감 시각, 일부완료·미완료·이월 수, 작업별 결과', async () => {
    const { page } = manager;
    await clearMsg(page);
    await page.click('#refreshBtn');
    await waitMsg(page, '최신 현황');
    const team2 = await page.locator('.team-card[data-team=공사2팀]').textContent();
    assert.match(team2, /퇴근 마감/); assert.match(team2, /퇴근 \d\d:\d\d/);
    assert.match(team2, /일부완료 1/); assert.match(team2, /미완료 1/); assert.match(team2, /이월 1/); assert.match(team2, /미완료·이월/);
    await page.click('.team-card[data-team=공사2팀] [data-detail]');
    await page.waitForSelector('#stageDetail.active');
    const body = await page.textContent('#detailBody');
    assert.match(body, /퇴근: 미완료 · 안전난간 미설치로 중단 · 이월: 옥상 관로 나머지 구간/);
    assert.match(body, /공구 정리 완료, 내일 안전난간 먼저 설치/);
    await page.click('.app-stage.active [data-go=stageList]');
  });

  await step('소장 현황 v0.4: 요약 수치, 확인 필요 우선 정렬, 필터, 상세 변경 이력', async () => {
    const { page } = manager;
    const sums = await page.locator('#summaryGrid .sum').allTextContents();
    assert.deepEqual(sums.map(x => x.trim()), ['2팀', '0미보고', '1/2출근 보고', '1소장 확인 필요', '1위험 작업', '1/2퇴근 마감']);
    assert.equal(await page.locator('.team-card').first().getAttribute('data-team'), '공사2팀');
    await page.click('[data-filter=attention]');
    assert.deepEqual(await page.locator('.team-card').evaluateAll(els => els.map(e => e.dataset.team)), ['공사2팀']);
    await page.click('[data-filter=missing]');
    assert.match(await page.textContent('#teamList'), /미보고 팀이 없습니다/);
    await page.click('[data-filter=all]');
    assert.equal(await page.locator('.team-card').count(), 2);
    await page.click('.team-card[data-team=공사2팀] [data-detail]');
    await page.waitForSelector('#stageDetail.active');
    const hist = await page.textContent('#detailBody .history');
    for (const label of ['작업계획 저장', '출근 TBM 보고', '사진 추가', '사진 빼기', '오후 전체 이상 없음', '작업 위험', '작업 변경', '퇴근 결과 입력', '퇴근 TBM 마감']) assert.ok(hist.includes(label), label);
    assert.match(hist, /시험이팀장 — 옥상 끝단 추락 위험/);
    assert.match(await page.textContent('#detailBody'), /자재 요청은 다음 단계/);
    await page.click('.app-stage.active [data-go=stageList]');
  });

  await step('소장 현황 v0.4: 자동 새로고침은 선택했을 때만 60초마다 (설정은 이 기기에 저장)', async () => {
    const m = await newPage(env);
    await m.page.clock.install();
    await m.page.goto(`${env.base}/personnel_test.html?next=tbm_manager_test.html`);
    await m.page.fill('#username', '소장'); await m.page.fill('#password', PASS); await m.page.click('#loginButton');
    await m.page.waitForSelector('#stageList.active .team-card');
    let calls = 0; m.page.on('request', r => { if (r.url().includes('tbm_site_overview')) calls++; });
    await m.page.clock.runFor(61000);
    await m.page.waitForTimeout(300);
    assert.equal(calls, 0, '꺼져 있으면 자동 조회 없음');
    await m.page.check('#autoRefresh');
    await m.page.clock.runFor(61000);
    for (let i = 0; i < 20 && calls === 0; i++) await m.page.waitForTimeout(100);
    assert.equal(calls, 1, '켜면 60초마다 1번');
    await m.page.reload();
    await m.page.waitForSelector('#stageList.active .team-card');
    assert.ok(await m.page.isChecked('#autoRefresh'));
  });

  await step('팀 공용 팀장계정(2팀장팀)도 같은 보고를 이어서 봄', async () => {
    const { page } = await loginWork('2팀장팀');
    await page.waitForURL(/tbm_report_test\.html/);
    await page.waitForSelector('#stageHome.active');
    assert.match(await page.textContent('#homeSub'), /보고자 시험이팀장 · 작업 2건/);
  });

  await step('역할이 맞지 않으면 차단: 소장 업무계정·일반 팀원 PIN', async () => {
    const mgr = await loginWork('소장', 'tbm_report_test.html');
    await mgr.page.waitForURL(/tbm_manager_test\.html/);
    await mgr.page.goto(`${env.base}/tbm_report_test.html`);
    await mgr.page.waitForSelector('#blocked:not([hidden])');
    assert.match(await mgr.page.textContent('#blockedText'), /팀장만 사용할 수 있는/);
    const member = await loginPin('T-0026', '시험팀원가', '482915');
    await member.page.waitForURL(/member_test\.html/);
    await member.page.goto(`${env.base}/tbm_report_test.html`);
    await member.page.waitForSelector('#blocked:not([hidden])');
    const r = await rpcFromPage(member.page, 'tbm_save_plan', { p_payload: { tasks: [{ place: 'x', content: 'y', members: [] }] } });
    assert.equal(r.code, 'FORBIDDEN');
  });

  await step('모바일 폭: 팀장 홈·작업계획·출근, 소장 목록·상세 가로 스크롤 없음', async () => {
    const { page, errors } = await loginPin('T-0025', '시험이팀장', '507319', { mobile: true });
    await page.waitForSelector('#stageHome.active');
    assert.ok(await noHorizontalScroll(page));
    await page.screenshot({ path: 'artifacts/s1_report_home_mobile.png', fullPage: true });
    await page.click('#openPlan');
    assert.ok(await noHorizontalScroll(page));
    await page.screenshot({ path: 'artifacts/s1_report_plan_mobile.png', fullPage: true });
    await page.click('.app-stage.active [data-open=openMorning]');
    await page.waitForSelector('#stageMorning.active');
    await thumbsLoaded(page, 'MORNING');
    assert.ok(await noHorizontalScroll(page));
    await page.screenshot({ path: 'artifacts/s1_report_morning_mobile.png', fullPage: true });
    await page.click('.app-stage.active [data-open=openAfternoon]');
    await page.waitForSelector('#stageAfternoon.active');
    assert.ok(await noHorizontalScroll(page));
    const riskButtons = await page.locator('.task-tbm-card.is-risk .task-status-buttons').boundingBox();
    assert.ok(riskButtons.width > 280, `위험 카드 버튼 줄이 좁음: ${riskButtons.width}`);
    await page.screenshot({ path: 'artifacts/s1_report_afternoon_mobile.png', fullPage: true });
    await page.click('.app-stage.active [data-open=openEvening]');
    await page.waitForSelector('#stageEvening.active');
    await page.locator('.task-tbm-card[data-evening-task]').nth(1).locator('[data-result=NOT_DONE]').click();
    assert.ok(await noHorizontalScroll(page));
    await page.screenshot({ path: 'artifacts/s1_report_evening_mobile.png', fullPage: true });
    await page.locator('.task-tbm-card[data-evening-task]').nth(1).locator('[data-result-cancel]').click();
    assert.deepEqual(errors, []);
    const m = await loginWork('소장', 'tbm_manager_test.html', { mobile: true });
    await m.page.waitForSelector('#stageList.active .team-card');
    assert.ok(await noHorizontalScroll(m.page));
    await m.page.screenshot({ path: 'artifacts/s1_manager_list_mobile.png', fullPage: true });
    await m.page.click('.team-card[data-team=공사2팀] [data-detail]');
    await m.page.waitForSelector('#stageDetail.active');
    assert.ok(await noHorizontalScroll(m.page));
    await m.page.screenshot({ path: 'artifacts/s1_manager_detail_mobile.png', fullPage: true });
    assert.deepEqual(m.errors, []);
  });

  // ---------- 다음 날 (보고 날짜를 하루 앞으로 옮겨 흉내) ----------
  let sourceTaskId;
  await step('다음 날: 이월 후보만 표시(이월 안 함은 제외), "오늘 이어서"로 다시 입력 없이 가져와 저장', async () => {
    sourceTaskId = (await sql(env, `select k.id from field_pilot_v1.report_tasks k join field_pilot_v1.daily_reports r on r.id = k.report_id
      where r.team_id = $1 and k.task_no = 2 and k.is_active and r.work_date = (now() at time zone 'Asia/Seoul')::date`, [TEAM2]))[0].id;
    await sql(env, `update field_pilot_v1.daily_reports set work_date = work_date - 1 where work_date = (now() at time zone 'Asia/Seoul')::date`);
    const { page } = leader;
    await page.goto(`${env.base}/tbm_report_test.html`);
    await page.waitForSelector('#stageHome.active');
    assert.equal(await page.textContent('#homeStatus'), '미작성');
    await page.click('#openPlan');
    await page.waitForSelector('#carryBox:not([hidden])');
    assert.equal(await page.textContent('#carryCount'), '1건');
    const item = await page.textContent('#carryList');
    assert.match(item, /작업 2 · B동 옥상/); assert.match(item, /옥상 관로 나머지 구간/); assert.match(item, /미완료 · 안전난간 미설치로 중단/);
    await page.click(`[data-carry-take="${sourceTaskId}"]`);
    assert.ok(await page.isHidden('#carryBox'));
    const card = page.locator('.task-card').first();
    assert.match(await card.locator('.task-title').textContent(), /작업 1이월/);
    assert.equal(await card.locator('[data-tfield=place]').inputValue(), 'B동 옥상');
    assert.equal(await card.locator('[data-tfield=content]').inputValue(), '옥상 관로 나머지 구간');
    assert.equal(await card.locator('.task-member', { hasText: '시험중복가' }).locator('select').inputValue(), '신호수');
    await page.click('#addTask');
    await fillTask(page, 1, '5층 전기실', '분전반 설치', { '시험팀원나': '' });
    await page.click('#savePlan');
    await waitMsg(page, '이월 이어받음 1건');
    const rows = await sql(env, `select k.carried_from_task_id, (select carry_status from field_pilot_v1.report_tasks s where s.id = k.carried_from_task_id) as source_status
      from field_pilot_v1.report_tasks k join field_pilot_v1.daily_reports r on r.id = k.report_id
      where r.team_id = $1 and k.is_active and r.work_date = (now() at time zone 'Asia/Seoul')::date and k.carried_from_task_id is not null`, [TEAM2]);
    assert.deepEqual(rows, [{ carried_from_task_id: sourceTaskId, source_status: 'CONTINUED' }]);
  });

  await step('이월은 한 번만: 같은 작업을 다시 이어받으면 서버가 거절', async () => {
    const { page } = leader;
    const version = (await sql(env, `select version from field_pilot_v1.daily_reports where team_id = $1 and work_date = (now() at time zone 'Asia/Seoul')::date`, [TEAM2]))[0].version;
    const again = await rpcFromPage(page, 'tbm_save_plan', { p_payload: { version, tasks: [{ place: 'B동 옥상', content: '또 이어받기', carried_from_task_id: sourceTaskId, members: [{ person_id: P(36) }] }] } });
    assert.equal(again.code, 'CARRY_NOT_AVAILABLE');
  });

  await step('이어받은 작업을 빼면 다시 후보, "이어받지 않음"은 저장할 때 정리', async () => {
    const { page } = leader;
    await page.locator('.task-card').first().locator('.task-remove').click();
    await page.waitForSelector('#carryBox:not([hidden])');
    await page.click(`[data-carry-drop="${sourceTaskId}"]`);
    assert.match(await page.textContent(`[data-carry-drop="${sourceTaskId}"]`), /저장 시 반영/);
    await page.click('#savePlan');
    await waitMsg(page, '이어받지 않음 1건');
    const src = await sql(env, `select carry_status from field_pilot_v1.report_tasks where id = $1`, [sourceTaskId]);
    assert.equal(src[0].carry_status, 'DROPPED');
    const active = await sql(env, `select count(*)::int as n from field_pilot_v1.report_tasks k join field_pilot_v1.daily_reports r on r.id = k.report_id
      where r.team_id = $1 and k.is_active and r.work_date = (now() at time zone 'Asia/Seoul')::date`, [TEAM2]);
    assert.equal(active[0].n, 1);
    await page.reload();
    await page.waitForSelector('#stageHome.active');
    await page.click('#openPlan');
    assert.ok(await page.isHidden('#carryBox'));
  });

  await step('로그아웃: 서버 세션 종료 + 이 기기 임시저장 삭제, 이후 화면은 로그인 요구', async () => {
    const { page } = leader;
    await page.click('.app-stage.active [data-go=stageHome]').catch(() => {});
    await page.click('#openPlan');
    await page.fill('#safetyNote', '로그아웃 전 임시 입력');
    await page.waitForTimeout(700);
    assert.ok(await page.evaluate(() => !!localStorage.getItem('tbmReportDraft_v1')));
    await page.click('.app-stage.active [data-go=stageHome]');
    await page.click('#logoutBtn');
    await page.waitForURL(/personnel_test\.html/);
    assert.equal(await page.evaluate(() => localStorage.getItem('tbmReportDraft_v1')), null);
    assert.equal(await page.evaluate(() => sessionStorage.getItem('personnelPilotSessionV2')), null);
    await page.goto(`${env.base}/tbm_report_test.html`);
    await page.waitForURL(/personnel_test\.html\?next=tbm_report_test\.html/);
  });
} finally {
  summary('S1 tbm day flow e2e');
  await env.close();
}
