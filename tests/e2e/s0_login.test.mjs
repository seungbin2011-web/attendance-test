// S0 로그인·역할 이동 e2e 시험 (로컬 흉내 게이트웨이, 가짜 데이터)
import { setup, newPage, issuePin, sql, noHorizontalScroll, step, summary, assert } from './helpers.mjs';

const env = await setup();
const PASS = 'pilot-test-pass';

async function login(page, name, password) {
  await page.fill('#username', name);
  await page.fill('#password', password);
  await page.click('#loginButton');
}
async function stays(page, file, ms = 1200) {
  await page.waitForTimeout(ms);
  assert.ok(page.url().includes(file), `expected to stay on ${file}, now ${page.url()}`);
}

try {
  await step('관리자 업무계정: 통합 로그인 화면에 머물고 초록 관리 화면', async () => {
    const { page, errors } = await newPage(env);
    await page.goto(`${env.base}/personnel_test.html`);
    assert.equal(await page.textContent('.login .version'), 'TEST v0.92');
    await login(page, '관리자', PASS);
    await page.waitForSelector('#directory:not([hidden])');
    assert.equal(await page.textContent('#roleLabel'), '관리자');
    assert.ok(await page.evaluate(() => document.body.classList.contains('admin-mode')));
    assert.deepEqual(errors, []);
  });

  await step('소장 업무계정: TBM 현황(tbm_manager_test)으로 이동하고 유지', async () => {
    const { page } = await newPage(env);
    await page.goto(`${env.base}/personnel_test.html`);
    await login(page, '소장', PASS);
    await page.waitForURL(/tbm_manager_test\.html/);
    await stays(page, 'tbm_manager_test.html');
  });

  await step('팀 공용 팀장계정(2팀장팀): leader_test로 이동하고 유지', async () => {
    const { page } = await newPage(env);
    await page.goto(`${env.base}/personnel_test.html`);
    await login(page, '2팀장팀', PASS);
    await page.waitForURL(/leader_test\.html/);
    await stays(page, 'leader_test.html');
    assert.match(await page.textContent('.footer'), /v0\.42 TEST/);
  });

  let memberPin;
  await step('일반 인원 첫 로그인: 임시 PIN → PIN 변경 화면 → 팀원 화면', async () => {
    const temp = await issuePin(env, 'T-0026', '시험팀원가');
    const { page, errors } = await newPage(env);
    await page.goto(`${env.base}/personnel_test.html`);
    await login(page, '시험팀원가', temp);
    await page.waitForSelector('#pinPanel:not([hidden])');
    assert.equal(await page.inputValue('#pinCurrent'), temp, '현재 PIN은 방금 입력한 값으로 채워짐(메모리만)');
    await page.fill('#pinNew', '123456'); await page.fill('#pinConfirm', '123456'); await page.click('#pinButton');
    await page.waitForFunction(() => document.querySelector('#message').textContent.includes('사용할 수 없는 PIN'));
    memberPin = '482915';
    await page.fill('#pinNew', memberPin); await page.fill('#pinConfirm', memberPin); await page.click('#pinButton');
    await page.waitForURL(/member_test\.html/);
    const user = await page.evaluate(() => JSON.parse(sessionStorage.getItem('attendanceAuthUser')));
    assert.equal(user.authSource, 'supabase-pin');
    assert.equal(user.appRole, 'MEMBER');
    assert.equal(user.userId, 'T-0026');
    assert.equal(user.personId, 'c0000000-0000-0000-0000-000000000026');
    const stored = await page.evaluate(() => Object.values({ ...sessionStorage, ...localStorage }).join('|'));
    assert.ok(!stored.includes(temp) && !stored.includes(memberPin), 'PIN이 브라우저 저장소에 남지 않음');
    assert.deepEqual(errors.filter(e => !e.includes('시험 환경')), []);
  });

  await step('일반 인원 재로그인: 개인 PIN으로 바로 팀원 화면', async () => {
    const { page } = await newPage(env);
    await page.goto(`${env.base}/personnel_test.html`);
    await login(page, '시험팀원가', memberPin);
    await page.waitForURL(/member_test\.html/);
  });

  await step('팀장 PIN 로그인(TEAM_LEADER): 팀장 TBM 보고(tbm_report_test)로 이동하고 유지', async () => {
    const temp = await issuePin(env, 'T-0025', '시험이팀장');
    const { page } = await newPage(env);
    await page.goto(`${env.base}/personnel_test.html`);
    await login(page, '시험이팀장', temp);
    await page.waitForSelector('#pinPanel:not([hidden])');
    await page.fill('#pinNew', '507318'); await page.fill('#pinConfirm', '507318'); await page.click('#pinButton');
    await page.waitForURL(/tbm_report_test\.html/);
    await stays(page, 'tbm_report_test.html');
    const user = await page.evaluate(() => JSON.parse(sessionStorage.getItem('tbmAuthUser')));
    assert.equal(user.appRole, 'LEADER'); assert.equal(user.role, '팀장'); assert.equal(user.team, '공사2팀');
  });

  await step('소장 인원 개인 로그인(v0.10): 소장 현황으로, 인원 편집(업무계정 전용) 화면은 아님', async () => {
    const temp = await issuePin(env, 'T-0003', '시험소장');
    const { page } = await newPage(env);
    await page.goto(`${env.base}/personnel_test.html?next=admin_test.html`);
    await login(page, '시험소장', temp);
    await page.waitForSelector('#pinPanel:not([hidden])');
    await page.fill('#pinNew', '640271'); await page.fill('#pinConfirm', '640271'); await page.click('#pinButton');
    await page.waitForURL(/tbm_manager_test\.html/);
  });

  await step('next= 허용 목록: 팀장은 leader_test, 허용 안 된 조합은 기본 화면', async () => {
    const { page } = await newPage(env);
    await page.goto(`${env.base}/personnel_test.html?next=leader_test.html`);
    await login(page, '시험이팀장', '507318');
    await page.waitForURL(/leader_test\.html/);
    const second = await newPage(env);
    await second.page.goto(`${env.base}/personnel_test.html?next=https://evil.example/x.html`);
    await login(second.page, '시험팀원가', memberPin);
    await second.page.waitForURL(/member_test\.html/);
  });

  await step('틀린 PIN: 안내 문구, 연속 5회 후 30분 잠금', async () => {
    const { page } = await newPage(env);
    await page.goto(`${env.base}/personnel_test.html`);
    for (let i = 0; i < 5; i++) {
      await login(page, '시험팀원나', '918273');
      await page.waitForFunction(() => document.querySelector('#message').textContent.includes('일치하지 않습니다'));
      await page.evaluate(() => { document.querySelector('#message').textContent = ''; });
    }
    await login(page, '시험팀원나', '918273');
    await page.waitForFunction(() => document.querySelector('#message').textContent.includes('30분'));
    assert.ok(await page.evaluate(() => document.querySelector('#message').classList.contains('error')));
  });

  await step('관리자 전용 SQL 화면은 개인 PIN 로그인을 받지 않음', async () => {
    const { page } = await newPage(env);
    await page.goto(`${env.base}/admin_sql_test.html`);
    await login(page, '시험팀원가', memberPin);
    await page.waitForFunction(() => document.querySelector('#message').textContent.includes('업무 계정만'));
    assert.ok(page.url().includes('admin_sql_test.html'));
  });

  await step('새 시스템 명부에 없는 인원: 외부 명부(Apps Script)를 묻지 않고 일치하지 않음 안내만', async () => {
    const { page } = await newPage(env, { appsScript: q => q.action === 'attendanceLogin' && q.pin === '1234'
      ? { success: true, user: { name: '레거시인원', userId: 'T-9999', team: '공사2팀', rank: '소장', role: '소장', job: '' } }
      : { success: false, message: '시험 환경' } });
    await page.goto(`${env.base}/personnel_test.html`);
    await login(page, '레거시인원', '1234');
    await page.waitForFunction(() => document.querySelector('#message').textContent.includes('휴대폰 번호 뒤 4자리가 일치하지 않습니다'));
    assert.ok(page.url().includes('personnel_test.html'));
    assert.equal(await page.evaluate(() => sessionStorage.getItem('attendanceAuthUser')), null);
  });

  await step('16시간이 지난 개인 세션은 다시 로그인 요구', async () => {
    const { page } = await newPage(env);
    await page.goto(`${env.base}/personnel_test.html`);
    await page.evaluate(() => { sessionStorage.clear(); });
    await login(page, '시험팀원가', memberPin);
    await page.waitForURL(/member_test\.html/);
    await sql(env, `update auth.sessions set created_at = now() - interval '17 hours' where user_id in (select auth_user_id from personnel_pilot_v1.account_links where person_id = 'c0000000-0000-0000-0000-000000000026')`);
    await page.goto(`${env.base}/personnel_test.html`);
    await page.waitForFunction(() => document.querySelector('#message').textContent.includes('16시간'));
    assert.ok(!(await page.isHidden('#loginPanel')));
  });

  await step('모바일 폭: 로그인·PIN 변경 화면 가로 스크롤 없음', async () => {
    const temp = await issuePin(env, 'T-0027', '시험팀원나');
    const { page } = await newPage(env, { mobile: true });
    await page.goto(`${env.base}/personnel_test.html`);
    assert.ok(await noHorizontalScroll(page));
    await sql(env, `insert into personnel_pilot_v1.member_login_attempts(name_key, outcome) select personnel_pilot_v1.name_key('시험팀원나'), 'ADMIN_UNLOCK'`);
    await login(page, '시험팀원나', temp);
    await page.waitForSelector('#pinPanel:not([hidden])');
    assert.ok(await noHorizontalScroll(page));
    await page.screenshot({ path: 'artifacts/s0_pin_change_mobile.png', fullPage: true });
  });

  await step('DB: 평문 PIN 없음, 개인 계정 연결은 서버 함수로만 생성', async () => {
    const rows = await sql(env, `select count(*)::int as links, (select count(*)::int from personnel_pilot_v1.member_pins where pin_hash !~ '^\\$2') as plain from personnel_pilot_v1.account_links`);
    assert.equal(rows[0].plain, 0);
    assert.ok(rows[0].links >= 4);
  });
} finally {
  summary('S0 login e2e');
  await env.close();
}
