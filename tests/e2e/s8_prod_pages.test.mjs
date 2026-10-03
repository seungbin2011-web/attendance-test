// 운영 화면 e2e: 루트(index.html) 하나로 로그인 → 역할별 운영 화면 (TEST·시험 화면 표시 없음, 시험 화면으로 새지 않음)
// 운영 화면은 tests/make_prod_pages.py가 시험 화면에서 만든다. 같은 모듈을 쓰고 파일 이름으로 운영/시험을 구분한다.
import { setup, newPage, step, summary, assert } from './helpers.mjs';

const env = await setup();
const PASS = 'pilot-test-pass';
// 팀원 화면의 '오늘 작업'은 아직 기존 TBM DB(Apps Script)를 본다 → 흉내 응답
const appsScript = q => q.action === 'memberTodayTasks' ? { success: true, tasks: [], tbm: [] } : { success: false, message: '시험 환경' };
async function rootLogin(name, secret, url) {
  const ctx = await newPage(env, { appsScript });
  ctx.page.on('dialog', d => d.accept());
  await ctx.page.goto(`${env.base}/`);
  await ctx.page.fill('#username', name); await ctx.page.fill('#password', secret); await ctx.page.click('#loginButton');
  if (url) await ctx.page.waitForURL(url, { timeout: 10000 }).catch(async e => {
    throw new Error(`${ctx.page.url()} · ${await ctx.page.textContent('#message').catch(() => '')} · ${e.message.split('\n')[0]}`);
  });
  return ctx;
}
// 화면에 보이는 글자에 시험 표시가 없어야 한다 (시험용 가짜 이름의 '시험'은 제외)
async function noTestMarks(page) {
  const text = await page.evaluate(() => document.title + '\n' + document.body.innerText);
  assert.ok(!/TEST|시험 화면|v0\.\d+/.test(text), `시험 표시가 남음: ${text.match(/.{0,20}(TEST|시험 화면|v0\.\d+).{0,20}/)?.[0]}`);
  assert.ok(!/_test\.html/.test(page.url()), page.url());
}

try {
  // 정식 인원DB(흉내)는 시험 파일마다 새로 시작하므로 최초 로그인할 사람을 다시 등록 (DB 로그인 번호는 만들지 않음)
  await fetch(`${env.base}/__test/roster`, { method: 'POST', body: JSON.stringify({ seed: false, entries: [
    { name: '시험이반02', pin: '1222', user: { name: '시험이반02', userId: 'T-1222' } }] }) });

  await step('루트 주소 = 운영 로그인 화면 (TEST 표시 없음, v1.0)', async () => {
    const { page, errors } = await newPage(env);
    await page.goto(`${env.base}/`);
    await page.waitForSelector('#loginPanel:not([hidden])');
    assert.equal(await page.title(), '현장 업무 통합 로그인');
    assert.equal(await page.textContent('.login .version'), 'v1.0');
    await noTestMarks(page);
    assert.deepEqual(errors, []);
  });

  await step('로그인 없이 운영 화면을 열면 운영 로그인(index.html)으로', async () => {
    const { page } = await newPage(env);
    for (const name of ['tbm_report', 'tbm_manager']) {
      await page.goto(`${env.base}/${name}.html`);
      await page.waitForURL(new RegExp(`/index\\.html\\?next=${name}\\.html$`));
    }
  });

  await step('번호 없는 기존 인원 최초 로그인(루트) → 운영 팀원 화면, 출결 등록은 기존 운영 출퇴근 화면, 로그아웃은 루트 로그인', async () => {
    const { page, errors } = await rootLogin('시험이반02', '1222', /\/member\.html$/);
    await page.waitForFunction(() => /총 \d+명/.test(document.getElementById('notice').textContent), null, { timeout: 8000 });
    await noTestMarks(page);
    await page.click('text=출결 등록');
    await page.waitForURL(/\/index_season1\.html$/);
    assert.equal(await page.title(), '현장 출퇴근 확인');
    await page.goBack(); await page.waitForURL(/\/member\.html$/);
    await page.click('text=로그아웃');
    await page.waitForURL(/\/index\.html$/);
    await page.waitForSelector('#loginPanel:not([hidden])');
    assert.deepEqual(errors, []);
  });

  await step('팀장 → 운영 팀장 TBM (v1.0), 로그아웃 → 루트 로그인', async () => {
    const { page, errors } = await rootLogin('시험지휘03', '1203', /\/tbm_report\.html$/);
    await page.waitForSelector('#stageHome.active');
    assert.equal(await page.textContent('#pageVersion'), 'v1.0');
    await noTestMarks(page);
    await page.click('#logoutBtn');
    await page.waitForURL(/\/index\.html$/);
    assert.deepEqual(errors, []);
  });

  await step('현장관리 → 운영 현장 TBM 현황 (v1.0), 로그아웃 → 루트 로그인', async () => {
    const { page, errors } = await rootLogin('시험현장관리2', '1402', /\/tbm_manager\.html$/);
    await page.waitForSelector('#stageList.active');
    assert.equal(await page.textContent('#pageVersion'), 'v1.0');
    await noTestMarks(page);
    await page.click('#logoutBtn');
    await page.waitForURL(/\/index\.html$/);
    assert.deepEqual(errors, []);
  });

  await step('관리자 → 루트에서 관리자 명부 (로그인 번호 등록 현황 표시, 시험 문구 없음)', async () => {
    const { page, errors } = await rootLogin('시험관리자', '1404');
    await page.waitForSelector('#directory:not([hidden])');
    assert.match(await page.textContent('#loginReady'), /^\d+ \/ \d+$/);
    assert.equal(await page.textContent('#scopeTitle'), '전체 인원');
    assert.ok(!/_test\.html/.test(page.url()));
    assert.deepEqual(errors, []);
  });

  await step('시범 업무계정(팀장)도 운영에서는 운영 팀장 TBM 화면으로 (시험 화면 leader_test로 가지 않음)', async () => {
    // (시범 업무계정의 팀 연결은 명단 재구성 시험(S4)에서 끝났으므로 여기서는 이동 경로만 본다)
    const { page } = await rootLogin('1팀장팀', PASS, /\/tbm_report\.html$/);
    await page.waitForSelector('#stageHome.active, #blocked:not([hidden])');
    await noTestMarks(page);
  });
} finally {
  summary('S8 production pages e2e');
  await env.close();
}
