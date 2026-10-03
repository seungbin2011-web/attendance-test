// 관리자 화면에서 인원 추가·팀 이동·권한·로그인 번호·비활성·재투입 + 조직도 권한 e2e (로컬 흉내 게이트웨이, 가짜 데이터)
// 로그인은 Supabase 안의 번호 해시로만 확인한다 (Apps Script 없음). S4의 가짜 53명 명단 위에서 실행
import { setup, newPage, sql, step, summary, assert } from './helpers.mjs';

const env = await setup();
const NEW_NAME = '시험새인원';

async function login(page, name, secret) {
  await page.fill('#username', name);
  await page.fill('#password', secret);
  await page.click('#loginButton');
}
const msg = page => page.textContent('#message');
async function waitMsg(page, text) {
  await page.waitForFunction(t => document.querySelector('#message').textContent.includes(t), text, { timeout: 8000 });
}
async function loginTo(name, pin, url, path = 'personnel_test.html') {
  const { page, errors } = await newPage(env);
  page.on('dialog', d => d.accept());
  await page.goto(`${env.base}/${path}`);
  await login(page, name, pin);
  if (url) await page.waitForURL(url);
  return { page, errors };
}
async function adminPage() {
  const { page, errors } = await loginTo('시험관리자', '1404');
  await page.waitForSelector('#directory:not([hidden])');
  return { page, errors };
}
async function editPerson(page, fields) {
  await page.locator('#people tr', { hasText: NEW_NAME }).locator('button', { hasText: '인원 편집' }).click();
  await fillDialog(page, fields);
}
async function fillDialog(page, { name, team, role, status, login: code }) {
  await page.waitForSelector('#editDialog[open]');
  if (name !== undefined) await page.fill('#editName', name);
  if (status) await page.selectOption('#editStatus', status);
  if (team) await page.selectOption('#editTeam', { label: team });
  if (role) await page.selectOption('#editRole', role);
  if (code !== undefined) await page.fill('#editLogin', code);
  await page.click('#saveButton');
  await waitMsg(page, '변경 내용과 편집 이력을 저장했습니다');
}

try {
  await fetch(`${env.base}/__test/roster`, { method: 'POST', body: JSON.stringify({ entries: [
    { name: '시험관리자', pin: '1404', user: { userId: 'T-1404' } }, { name: '시험현장관리1', pin: '1401', user: {} },
    { name: '시험삼팀원', pin: '0051', user: { userId: 'T-0051' } }, { name: '시험일팀장', pin: '0008', user: { userId: 'T-0008' } } ] }) });

  await step('관리자 화면: 인원 추가 (이름·팀·권한·로그인 번호만, 사용자ID 없이)', async () => {
    const { page, errors } = await adminPage();
    await page.click('#addPerson');
    await page.waitForSelector('#editDialog[open]');
    assert.equal(await page.textContent('#editTitle'), '인원 추가');
    assert.match(await page.textContent('#loginState'), /새 인원은 로그인 번호가 필요/);
    await fillDialog(page, { name: NEW_NAME, team: '3팀', role: 'MEMBER', login: '4321' });
    const row = page.locator('#people tr', { hasText: NEW_NAME });
    assert.match(await row.textContent(), /3팀 · 팀원/);
    assert.match(await row.locator('td').first().textContent(), /-/);
    const stored = await sql(env, `select c.login4_hash like '$2%' as hashed, p.legacy_user_id from personnel_pilot_v1.people p
      join personnel_pilot_v1.member_pins c on c.person_id = p.id where p.display_name = $1`, [NEW_NAME]);
    assert.equal(stored[0].hashed, true); assert.equal(stored[0].legacy_user_id, null);
    assert.deepEqual(errors, []);
  });

  await step('새 인원 로그인 → 팀원 화면, 우리 팀은 3팀 (Supabase 현재 소속)', async () => {
    const { page } = await loginTo(NEW_NAME, '4321', /member_test\.html/);
    await page.waitForFunction(() => /3팀 · 총 10명/.test(document.querySelector('#notice').textContent), null, { timeout: 8000 });
  });

  await step('팀 이동 + 팀장: 관리자 화면에서 바꾸면 다음 로그인부터 1팀 팀장 TBM', async () => {
    const { page } = await adminPage();
    await editPerson(page, { team: '1팀', role: 'TEAM_LEADER' });
    assert.match(await page.locator('#people tr', { hasText: NEW_NAME }).textContent(), /1팀 · 팀장/);
    const t = await loginTo(NEW_NAME, '4321', /tbm_report_test\.html/);
    await t.page.waitForSelector('#stageHome.active');
    assert.match(await t.page.textContent('#headerSub'), new RegExp(`^1팀 · .* ${NEW_NAME} 팀장$`));
  });

  await step('팀장 → 팀원 + 로그인 번호 변경: 예전 번호 거절, 새 번호로 팀원 화면', async () => {
    const { page } = await adminPage();
    await editPerson(page, { role: 'MEMBER', login: '5678' });
    const old = await loginTo(NEW_NAME, '4321');
    await waitMsg(old.page, '일치하지 않습니다');
    await loginTo(NEW_NAME, '5678', /member_test\.html/);
  });

  await step('비활성(퇴사·현장 이탈): 로그인 차단, 행·기록 유지 → 재직으로 다시 저장하면 같은 사람으로 2팀 복귀', async () => {
    const { page } = await adminPage();
    await editPerson(page, { status: 'inactive' });
    assert.match(await page.locator('#people tr', { hasText: NEW_NAME }).textContent(), /비활성/);
    const blocked = await loginTo(NEW_NAME, '5678');
    await waitMsg(blocked.page, '로그인이 중지된 계정');
    const before = await sql(env, `select id from personnel_pilot_v1.people where display_name = $1`, [NEW_NAME]);
    await editPerson(page, { status: 'active', team: '2팀', role: 'MEMBER' });
    const after = await sql(env, `select id, (select count(*)::int from personnel_pilot_v1.memberships m where m.person_id = p.id) as memberships
      from personnel_pilot_v1.people p where display_name = $1`, [NEW_NAME]);
    assert.equal(after.length, 1); assert.equal(after[0].id, before[0].id);
    assert.ok(after[0].memberships >= 3, '이전 소속은 종료일만 남기고 보존');
    const back = await loginTo(NEW_NAME, '5678', /member_test\.html/);
    await back.page.waitForFunction(() => /2팀 · 총/.test(document.querySelector('#notice').textContent), null, { timeout: 8000 });
  });

  await step('현장관리는 인원 관리 서버 함수가 거절 (화면 버튼이 아니라 서버 기준)', async () => {
    const { page } = await loginTo('시험현장관리1', '1401', /tbm_manager_test\.html/);
    const code = await page.evaluate(async () => {
      const api = await import('./tbm_api_test.mjs');
      try { await api.rpc('pilot_admin_save_person', { p_payload: { name: '침입', team_id: null, login_code: '1111' } }); return 'NO_ERROR'; }
      catch (e) { return e.code || e.message; }
    });
    assert.match(code, /EDIT_FORBIDDEN/);
  });

  await step('조직도: 로그인 없이 열면 통합 로그인으로, 현장관리는 로그인 후 조직도 (휴대폰 번호 없음, 기기에 저장 없음)', async () => {
    const { page, errors } = await newPage(env);
    await page.goto(`${env.base}/organization.html`);
    await page.waitForURL(/personnel_test\.html\?next=organization\.html/);
    await login(page, '시험현장관리1', '1401');
    await page.waitForURL(/organization\.html/);
    await page.waitForFunction(() => document.querySelectorAll('.person').length > 40, null, { timeout: 8000 });
    const text = await page.textContent('body');
    for (const t of ['현장관리 · 관리자', '1팀', '2팀', '3팀', '자재팀']) assert.ok(text.includes(t), t);
    assert.ok(!/H\/P|010-|상시출입증/.test(text));
    await page.locator('.person', { hasText: '시험관리자' }).first().click();
    assert.ok(!/H\/P|휴대폰|출입증/.test(await page.textContent('#detailGrid')));
    assert.equal(await page.evaluate(() => Object.keys(localStorage).filter(k => k.startsWith('organization_people_cache')).length), 0);
    assert.deepEqual(errors, []);
  });

  await step('조직도: 팀원·팀장은 URL로 열어도 서버가 막음', async () => {
    for (const [name, pin, url] of [['시험삼팀원', '0051', /member_test\.html/], ['시험일팀장', '0008', /tbm_report_test\.html/]]) {
      const { page } = await loginTo(name, pin, url);
      await page.goto(`${env.base}/organization.html`);
      await page.waitForFunction(() => /현장관리·관리자만 볼 수 있는 화면/.test(document.body.textContent), null, { timeout: 8000 });
      assert.equal(await page.locator('.person').count(), 0, name);
    }
  });
} finally {
  summary('S5 admin people e2e');
  await env.close();
}
