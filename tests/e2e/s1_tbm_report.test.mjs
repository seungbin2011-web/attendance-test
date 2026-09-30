// S1 팀장 TBM 보고 화면 e2e 시험 (로컬 흉내 게이트웨이, 가짜 데이터)
import { setup, newPage, issuePin, sql, noHorizontalScroll, step, summary, assert } from './helpers.mjs';

const env = await setup();
const PASS = 'pilot-test-pass';
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
    assert.equal(await page.textContent('#pageVersion'), 'v0.1 TEST');
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
    await page.click('[data-go=stageHome]');
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
    await p2.click('[data-go=stageHome]');
    await p2.click('#openPlan');
    const locked = p2.locator('.task-card').first().locator('.task-member', { hasText: '시험삼팀원' });
    assert.match(await locked.textContent(), /시험3팀 배정중/);
    assert.ok(await locked.locator('input').isDisabled());
    const direct = await rpcFromPage(p2, 'tbm_save_plan', { p_payload: { version: 4, tasks: [{ place: 'x', content: 'y', members: [{ person_id: P(51) }] }] } });
    assert.equal(direct.code, 'MEMBER_ASSIGNED_ELSEWHERE'); assert.match(direct.message, /시험삼팀원 \(시험3팀\)/);
  });

  await step('팀 공용 팀장계정(2팀장팀)도 같은 보고를 이어서 봄', async () => {
    const { page } = await loginWork('2팀장팀');
    await page.waitForURL(/tbm_report_test\.html/);
    await page.waitForSelector('#stageHome.active');
    assert.match(await page.textContent('#homeSub'), /보고자 시험이팀장 · 작업 2건/);
  });

  await step('역할이 맞지 않으면 차단: 소장 업무계정·일반 팀원 PIN', async () => {
    const mgr = await loginWork('소장', 'tbm_report_test.html');
    await mgr.page.waitForURL(/admin_test\.html/);
    await mgr.page.goto(`${env.base}/tbm_report_test.html`);
    await mgr.page.waitForSelector('#blocked:not([hidden])');
    assert.match(await mgr.page.textContent('#blockedText'), /팀장 계정만/);
    const member = await loginPin('T-0026', '시험팀원가', '482915');
    await member.page.waitForURL(/member_test\.html/);
    await member.page.goto(`${env.base}/tbm_report_test.html`);
    await member.page.waitForSelector('#blocked:not([hidden])');
    const r = await rpcFromPage(member.page, 'tbm_save_plan', { p_payload: { tasks: [{ place: 'x', content: 'y', members: [] }] } });
    assert.equal(r.code, 'FORBIDDEN');
  });

  await step('모바일 폭: 홈·작업계획 가로 스크롤 없음', async () => {
    const { page, errors } = await loginPin('T-0025', '시험이팀장', '507319', { mobile: true });
    await page.waitForSelector('#stageHome.active');
    assert.ok(await noHorizontalScroll(page));
    await page.screenshot({ path: 'artifacts/s1_report_home_mobile.png', fullPage: true });
    await page.click('#openPlan');
    assert.ok(await noHorizontalScroll(page));
    await page.screenshot({ path: 'artifacts/s1_report_plan_mobile.png', fullPage: true });
    assert.deepEqual(errors, []);
  });
} finally {
  summary('S1 tbm report e2e');
  await env.close();
}
