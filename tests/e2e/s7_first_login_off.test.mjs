// 최초 로그인 이관 끄기 (MEMBER_LOGIN_FIRST_LOGIN_FALLBACK=off) e2e: Apps Script를 전혀 부르지 않는다
process.env.MEMBER_LOGIN_FIRST_LOGIN_FALLBACK = 'off';
const { setup, newPage, sql, step, summary, assert } = await import('./helpers.mjs');

const env = await setup();
async function loginTo(name, pin) {
  const { page } = await newPage(env);
  await page.goto(`${env.base}/personnel_test.html`);
  await page.fill('#username', name); await page.fill('#password', pin); await page.click('#loginButton');
  return page;
}
const calls = async () => (await (await fetch(`${env.base}/__test/roster_calls`)).json()).count;

try {
  await step('끈 상태: 번호 없는 사람은 정식 인원DB를 묻지 않고 거절, 번호 있는 사람은 그대로 로그인', async () => {
    await fetch(`${env.base}/__test/roster`, { method: 'POST', body: JSON.stringify({ seed: false, entries: [
      { name: '시험이반04', pin: '1224', user: { name: '시험이반04', userId: 'T-1224' } }] }) });
    const page = await loginTo('시험이반04', '1224');
    await page.waitForFunction(() => document.querySelector('#message').textContent.includes('일치하지 않습니다'), null, { timeout: 8000 });
    const n = await sql(env, `select count(*)::int n from personnel_pilot_v1.people p join personnel_pilot_v1.member_pins c on c.person_id = p.id
      where p.display_name = '시험이반04' and c.login4_hash is not null`);
    assert.equal(n[0].n, 0);
    await fetch(`${env.base}/__test/roster`, { method: 'POST', body: JSON.stringify({ entries: [{ name: '시험관리자', pin: '1404', user: { userId: 'T-1404' } }] }) });
    const admin = await loginTo('시험관리자', '1404');
    await admin.waitForSelector('#directory:not([hidden])');
    assert.equal(await calls(), 0);
  });
} finally {
  summary('S7 first login off e2e');
  await env.close();
}
