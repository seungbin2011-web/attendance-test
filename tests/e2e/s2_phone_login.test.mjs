// Season 2 현장 시연: 이름 + 휴대폰 번호 뒤 4자리 로그인과 화면 이동 e2e (로컬 흉내 게이트웨이, 가짜 데이터)
import { setup, newPage, sql, noHorizontalScroll, step, summary, assert } from './helpers.mjs';

const env = await setup();
const PASS = 'pilot-test-pass';

async function login(page, name, secret) {
  await page.fill('#username', name);
  await page.fill('#password', secret);
  await page.click('#loginButton');
}
const msg = page => page.textContent('#message');
async function waitMsg(page, text) {
  await page.waitForFunction(t => document.querySelector('#message').textContent.includes(t), text, { timeout: 8000 });
}

try {
  await step('로그인 화면: 이름 + 휴대폰 번호 뒤 4자리 안내, 업무 계정 이름이면 비밀번호 칸으로 바뀜', async () => {
    const { page, errors } = await newPage(env);
    await page.goto(`${env.base}/personnel_test.html`);
    assert.match(await page.textContent('.login-heading'), /이름과 휴대폰 번호 뒤 4자리/);
    assert.equal(await page.textContent('[data-secret-label]'), '휴대폰 번호 뒤 4자리');
    assert.equal(await page.getAttribute('#password', 'inputmode'), 'numeric');
    await page.fill('#username', '소장');
    assert.equal(await page.textContent('[data-secret-label]'), '업무 계정 비밀번호');
    assert.equal(await page.evaluate(() => document.querySelector('#password').inputMode), 'text');
    assert.deepEqual(errors, []);
  });

  await step('팀장: 이름 + 뒤 4자리 → PIN 변경 없이 바로 팀장 TBM 보고(tbm_report_test), 팀·사람은 서버 기준', async () => {
    const { page, errors } = await newPage(env);
    await page.goto(`${env.base}/personnel_test.html`);
    await login(page, '시험이팀장', '2525');
    await page.waitForURL(/tbm_report_test\.html/);
    await page.waitForSelector('#stageHome.active');
    assert.match(await page.textContent('#headerSub'), /공사2팀 · 용인 현장 · .* · 시험이팀장 팀장/);
    const stored = await page.evaluate(() => Object.values({ ...sessionStorage, ...localStorage }).join('|'));
    assert.ok(!stored.includes('2525'), '번호가 브라우저 저장소에 남지 않음');
    assert.deepEqual(errors, []);
  });

  await step('팀장 화면 이동: 작업계획·출근·오후·퇴근·홈 버튼, 로그아웃 후 다시 로그인하면 같은 화면', async () => {
    const { page, errors } = await newPage(env);
    page.on('dialog', d => d.accept());
    await page.goto(`${env.base}/personnel_test.html`);
    await login(page, '시험이팀장', '2525');
    await page.waitForSelector('#stageHome.active');
    for (const [btn, stage] of [['#openPlan', '#stagePlan'], ['#openMorning', '#stageMorning'], ['#openAfternoon', '#stageAfternoon'], ['#openEvening', '#stageEvening']]) {
      await page.click(btn);
      await page.waitForSelector(`${stage}.active, #stagePlan.active`);
      await page.click('.app-stage.active [data-go=stageHome]');
      await page.waitForSelector('#stageHome.active');
    }
    await page.click('#logoutBtn');
    await page.waitForURL(/personnel_test\.html/);
    await login(page, '시험이팀장', '2525');
    await page.waitForURL(/tbm_report_test\.html/);
    assert.deepEqual(errors, []);
  });

  await step('팀원: 이름 + 뒤 4자리 → 팀원 화면, 기존 ID 중복(T-0036)은 이름으로 본인 구분', async () => {
    const a = await newPage(env);
    await a.page.goto(`${env.base}/personnel_test.html`);
    await login(a.page, '시험중복가', '3636');
    await a.page.waitForURL(/member_test\.html/);
    const ua = await a.page.evaluate(() => JSON.parse(sessionStorage.getItem('attendanceAuthUser')));
    assert.equal(ua.authSource, 'supabase-pin'); assert.equal(ua.appRole, 'MEMBER');
    assert.equal(ua.personId, 'c0000000-0000-0000-0000-000000000036');
    const b = await newPage(env);
    await b.page.goto(`${env.base}/personnel_test.html`);
    await login(b.page, '시험중복나', '1360');
    await b.page.waitForURL(/member_test\.html/);
    const ub = await b.page.evaluate(() => JSON.parse(sessionStorage.getItem('attendanceAuthUser')));
    assert.equal(ub.personId, 'c0000000-0000-0000-0000-000000000136');
  });

  await step('번호가 틀리거나 명부에 없거나 퇴사면 이해할 수 있는 안내, 성공 이동 없음', async () => {
    const { page } = await newPage(env);
    await page.goto(`${env.base}/personnel_test.html`);
    await login(page, '시험이팀장', '9999');
    await waitMsg(page, '휴대폰 번호 뒤 4자리가 일치하지 않습니다');
    assert.ok(page.url().includes('personnel_test.html'));
    await login(page, '시험퇴사자', '2828');
    await waitMsg(page, '로그인이 중지된 계정');
    await login(page, '시험이팀장', '25');
    await waitMsg(page, '휴대폰 번호 뒤 4자리를 입력해주세요');
    assert.ok((await page.getAttribute('#message', 'class')).includes('error'));
  });

  await step('같은 이름 연속 5회 실패 → 30분 잠금', async () => {
    await fetch(`${env.base}/__test/roster`, { method: 'POST', body: JSON.stringify({ entries: [{ name: '시험삼팀원', pin: '5151', user: { name: '시험삼팀원', userId: 'T-0051', team: '시험3팀', rank: '팀원', role: '팀원', job: '' } }] }) });
    const { page } = await newPage(env);
    await page.goto(`${env.base}/personnel_test.html`);
    for (let i = 0; i < 5; i++) {
      await login(page, '시험삼팀원', '0000');
      await waitMsg(page, '일치하지 않습니다');
      await page.evaluate(() => { document.querySelector('#message').textContent = ''; });
    }
    await login(page, '시험삼팀원', '5151');
    await waitMsg(page, '30분');
    await sql(env, `insert into personnel_pilot_v1.member_login_attempts(name_key, outcome) select personnel_pilot_v1.name_key('시험삼팀원'), 'ADMIN_UNLOCK'`);
    await login(page, '시험삼팀원', '5151');
    await page.waitForURL(/member_test\.html/);
  });

  await step('업무 계정: 소장 → TBM 현황, 관리자 → 명부 화면의 "TBM 현황 열기" 링크', async () => {
    const m = await newPage(env);
    await m.page.goto(`${env.base}/personnel_test.html`);
    await login(m.page, '소장', PASS);
    await m.page.waitForURL(/tbm_manager_test\.html/);
    await m.page.waitForSelector('#stageList.active');
    await m.page.click('#logoutBtn').catch(() => {});
    const a = await newPage(env);
    await a.page.goto(`${env.base}/personnel_test.html`);
    await login(a.page, '관리자', PASS);
    await a.page.waitForSelector('#directory:not([hidden])');
    assert.equal(await a.page.getAttribute('#workHome', 'href'), 'tbm_manager_test.html');
    assert.equal(await a.page.textContent('#workHome'), 'TBM 현황 열기');
    await a.page.click('#workHome');
    await a.page.waitForURL(/tbm_manager_test\.html/);
    await a.page.waitForSelector('#stageList.active');
  });

  await step('기존 개인 PIN 6자리 로그인도 그대로 동작', async () => {
    const temp = (await (await fetch(`${env.base}/__test/issue_pin?legacy=T-0050&name=${encodeURIComponent('시험삼팀장')}`)).json()).pin;
    const { page } = await newPage(env);
    await page.goto(`${env.base}/personnel_test.html`);
    await login(page, '시험삼팀장', temp);
    await page.waitForSelector('#pinPanel:not([hidden])');
    await page.fill('#pinNew', '613845'); await page.fill('#pinConfirm', '613845'); await page.click('#pinButton');
    await page.waitForURL(/tbm_report_test\.html/);
  });

  await step('관리자 전용 SQL 화면은 4자리 로그인을 받지 않음', async () => {
    const { page } = await newPage(env);
    await page.goto(`${env.base}/admin_sql_test.html`);
    await login(page, '시험이팀장', '2525');
    await waitMsg(page, '업무 계정만');
    assert.ok(page.url().includes('admin_sql_test.html'));
  });

  await step('모바일 폭: 로그인 화면 가로 스크롤 없음', async () => {
    const { page } = await newPage(env, { mobile: true });
    await page.goto(`${env.base}/personnel_test.html`);
    assert.ok(await noHorizontalScroll(page));
    await page.screenshot({ path: 'artifacts/s2_login_mobile.png', fullPage: true });
  });
} finally {
  summary('S2 phone login e2e');
  await env.close();
}
