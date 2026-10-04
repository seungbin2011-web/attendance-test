// 기존 인원 최초 로그인 자동 이관 e2e (로컬 흉내 게이트웨이, 가짜 데이터)
// 로그인 번호가 없는 현재 인원만 최초 1회 정식 인원DB(Apps Script 흉내)로 확인 → 번호 해시 저장 → 다음부터 Supabase만
import { setup, newPage, sql, step, summary, assert } from './helpers.mjs';

const env = await setup();
async function login(page, name, secret) {
  await page.fill('#username', name);
  await page.fill('#password', secret);
  await page.click('#loginButton');
}
async function waitMsg(page, text) {
  await page.waitForFunction(t => document.querySelector('#message').textContent.includes(t), text, { timeout: 8000 });
}
async function loginTo(name, pin, url) {
  const { page } = await newPage(env);
  await page.goto(`${env.base}/personnel_test.html`);
  await login(page, name, pin);
  if (url) await page.waitForURL(url);
  return page;
}
// 정식 인원DB(흉내)에만 등록 (DB 로그인 번호는 만들지 않음)
async function legacyOnly(entries) {
  await fetch(`${env.base}/__test/roster`, { method: 'POST', body: JSON.stringify({ seed: false, entries }) });
}
const calls = async () => (await (await fetch(`${env.base}/__test/roster_calls`)).json()).count;
const hasLogin = async name => (await sql(env, `select count(*)::int n from personnel_pilot_v1.people p join personnel_pilot_v1.member_pins c on c.person_id = p.id
  where p.display_name = $1 and c.login4_hash like '$2%'`, [name]))[0].n;

try {
  await legacyOnly([
    { name: '시험일반05', pin: '1505', user: { name: '시험일반05', userId: 'T-1105' } },
    { name: '시험이반02', pin: '1222', user: { name: '시험이반02', userId: 'T-1222' } },
    { name: '시험외부인', pin: '1212', user: { name: '시험외부인', userId: 'T-5555' } },
    { name: '시험지휘03', pin: '1203', user: { name: '시험지휘03', userId: 'T-1203' } },
    { name: '시험현장관리2', pin: '1402', user: { name: '시험현장관리2', userId: 'T-1402' } } ]);

  await step('번호 없는 기존 인원: 최초 1회 정식 인원DB 확인 → 번호 해시 저장 → 팀원 화면', async () => {
    assert.equal(await hasLogin('시험일반05'), 0);
    const before = await calls();
    await loginTo('시험일반05', '1505', /member_test\.html/);
    assert.equal(await calls(), before + 1);
    assert.equal(await hasLogin('시험일반05'), 1);
    const plain = await sql(env, `select count(*)::int n from personnel_pilot_v1.member_pins where login4_hash = '1505'`);
    assert.equal(plain[0].n, 0);
  });

  await step('같은 사람 두 번째 로그인: Apps Script 호출 없음', async () => {
    const before = await calls();
    await loginTo('시험일반05', '1505', /member_test\.html/);
    assert.equal(await calls(), before);
  });

  await step('틀린 번호: 정식 인원DB도 아니라고 하면 번호 저장 없음', async () => {
    const page = await loginTo('시험이반02', '9999');
    await waitMsg(page, '일치하지 않습니다');
    assert.equal(await hasLogin('시험이반02'), 0);
    assert.ok(page.url().includes('personnel_test.html'));
  });

  await step('Supabase 명단에 없는 사람: 정식 인원DB를 묻지도 않고 거절, 인원 생성 없음', async () => {
    const before = await calls();
    const page = await loginTo('시험외부인', '1212');
    await waitMsg(page, '일치하지 않습니다');
    assert.equal(await calls(), before);
    const rows = await sql(env, `select count(*)::int n from personnel_pilot_v1.people where display_name = '시험외부인'`);
    assert.equal(rows[0].n, 0);
  });

  await step('최초 로그인 후 역할별 이동: 팀장 → 팀장 TBM, 현장관리(사용자ID 없는 새 인원) → 현장 현황, 관리자 → 명부', async () => {
    const leader = await loginTo('시험지휘03', '1203', /tbm_report_test\.html/);
    await leader.waitForSelector('#stageHome.active');
    assert.match(await leader.textContent('#headerSub'), /^2팀 · .* 시험지휘03 팀장$/);
    const manager = await loginTo('시험현장관리2', '1402', /tbm_manager_test\.html/);
    await manager.waitForSelector('#stageList.active');
    await fetch(`${env.base}/__test/roster`, { method: 'POST', body: JSON.stringify({ entries: [{ name: '시험관리자', pin: '1404', user: { userId: 'T-1404' } }] }) });
    const admin = await loginTo('시험관리자', '1404');
    await admin.waitForSelector('#directory:not([hidden])');
    const [done, total] = (await admin.textContent('#loginReady')).split(' / ').map(Number);
    assert.ok(done > 0 && total >= 53 && done <= total, `로그인 번호 등록 ${done} / ${total}`);
  });
} finally {
  summary('S6 first login migration e2e');
  await env.close();
}
