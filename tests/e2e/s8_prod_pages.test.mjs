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

// 역할별 「사용 가이드」: 상단 작은 버튼 줄에 있고, 자기 역할 PDF를 새 탭으로 연다. PDF는 고정 정적 경로에서 바로 받아진다.
async function checkGuide(page, pdf) {
  const link = page.locator('.app-stage.active .stage-actions #guideBtn');
  assert.equal((await link.textContent()).trim(), '사용 가이드');
  assert.equal(await link.getAttribute('href'), `guides/${pdf}`);
  assert.equal(await link.getAttribute('target'), '_blank');
  const res = await page.request.get(new URL(`guides/${pdf}`, page.url()).href);
  assert.equal(res.status(), 200);
  assert.match(res.headers()['content-type'], /application\/pdf/);
  assert.equal((await res.body()).subarray(0, 5).toString(), '%PDF-');
  // 새 탭이 열리고 그 탭이 PDF를 요청한다 (헤드리스 Chromium은 PDF 뷰어가 없어 주소창 대신 요청으로 확인)
  const [tab, req] = await Promise.all([
    page.context().waitForEvent('page'),
    page.context().waitForEvent('request', r => r.url().endsWith(`/guides/${pdf}`)),
    link.click(),
  ]);
  assert.notEqual(tab, page);
  assert.equal(req.frame()?.page() ?? tab, tab);
  await tab.close();
  // 휴대폰 폭: 버튼이 한 줄에 있고 글자가 두 줄로 꺾이거나 화면 밖으로 나가지 않는다
  for (const width of [360, 320]) {
    await page.setViewportSize({ width, height: 740 });
    const boxes = await page.$$eval('.app-stage.active .stage-actions > *', els => els.map(e => {
      const r = e.getBoundingClientRect(); return { top: Math.round(r.top), h: Math.round(r.height), right: Math.round(r.right), text: e.textContent.trim() };
    }));
    assert.ok(boxes.every(b => b.top === boxes[0].top), `${width}px 버튼 줄바꿈: ${JSON.stringify(boxes)}`);
    assert.ok(boxes.every(b => b.h <= 40 && b.right <= width), `${width}px 버튼 깨짐: ${JSON.stringify(boxes)}`);
    await page.screenshot({ path: `artifacts/s8_guide_${pdf.split('-')[0]}_${width}.png` });
  }
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

  await step('역할별 사용 가이드: 팀장 → 팀장 PDF, 현장관리 → 소장 PDF (새 탭, 휴대폰 폭 버튼 한 줄)', async () => {
    const leader = await rootLogin('시험삼반장', '1301', /\/tbm_report\.html$/);
    await leader.page.waitForSelector('#stageHome.active');
    await checkGuide(leader.page, 'team-leader-tbm-guide.pdf');
    assert.deepEqual(await leader.page.$$eval('#stageHome .stage-actions > *', els => els.map(e => e.textContent.trim())), ['새로고침', '사용 가이드', '로그아웃']);
    assert.deepEqual(leader.errors, []);
    const manager = await rootLogin('시험현장관리1', '1401', /\/tbm_manager\.html$/);
    await manager.page.waitForSelector('#stageList.active');
    await checkGuide(manager.page, 'site-manager-tbm-guide.pdf');
    assert.deepEqual(await manager.page.$$eval('#stageList .stage-actions > *', els => els.map(e => e.textContent.trim())), ['사용 가이드', '로그아웃']);
    assert.deepEqual(manager.errors, []);
    // 관리자가 여는 같은 현황 화면(관리자 모드)에는 가이드 버튼을 보이지 않는다 (이번 범위는 팀장·소장만)
    const admin = await rootLogin('시험관리자', '1404');
    await admin.page.waitForSelector('#directory:not([hidden])');
    await admin.page.goto(`${env.base}/tbm_manager.html`);
    await admin.page.waitForSelector('body.admin-mode #stageList.active');
    assert.equal(await admin.page.isVisible('#guideBtn'), false);
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
