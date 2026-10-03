// 2026-10 확정 명단(가짜 53명)으로 인원·소속·권한을 맞춘 뒤 역할별 화면 e2e (로컬 흉내 게이트웨이, 가짜 데이터)
// 역할 변경은 실제 동기화 파일(personnel_roster_v10_sync.sql)의 "명단" 자리에 가짜 명단만 넣어 실행한다.
import { readFileSync } from 'node:fs';
import { setup, newPage, sql, step, summary, assert } from './helpers.mjs';

const env = await setup();
const SYNC = readFileSync(new URL('../../personnel_roster_v10_sync.sql', import.meta.url), 'utf8');
const VERIFY = readFileSync(new URL('../../personnel_roster_v10_verify.sql', import.meta.url), 'utf8');
const ROWS = readFileSync(new URL('../sql/fixture_roster_2026_10_fake.rows', import.meta.url), 'utf8');
const fill = text => text.replace(/^(.*-- ▼ 명단.*)$/m, `$1\n${ROWS}`);

async function login(page, name, secret) {
  await page.fill('#username', name);
  await page.fill('#password', secret);
  await page.click('#loginButton');
}
async function loginTo(name, pin, url) {
  const { page, errors } = await newPage(env);
  page.on('dialog', d => d.accept());
  await page.goto(`${env.base}/personnel_test.html`);
  await login(page, name, pin);
  if (url) await page.waitForURL(url);
  return { page, errors };
}
const person = (name, userId, team, rank = '팀원') => ({ name, pin: userId.slice(-4), user: { name, userId, team, rank, role: rank, job: '' } });

try {
  await step('실제 동기화 SQL에 가짜 명단 53명을 넣어 실행 → 검증 SQL ok (53 / 15·23·9·1·5 / 13·35·4·1)', async () => {
    const r = await fetch(`${env.base}/__test/sql`, { method: 'POST', body: JSON.stringify({ sql: fill(SYNC), params: [] }) });
    assert.equal(r.status, 200, `동기화 실패: ${await r.text()}`);
    const v = (await sql(env, fill(VERIFY).replace(/;\s*$/, '')))[0].verify_roster;
    const j = JSON.parse(v);
    assert.equal(j.ok, true, JSON.stringify(j.mismatches));
    assert.deepEqual(j.counts.teams, { '1팀': 15, '2팀': 23, '3팀': 9, '자재팀': 1, '현장·관리': 5 });
    assert.deepEqual(j.counts.roles, { ADMIN: 1, MEMBER: 35, TEAM_LEADER: 13, SITE_MANAGER: 4 });
    await fetch(`${env.base}/__test/roster`, { method: 'POST', body: JSON.stringify({ entries: [
      person('시험관리자', 'T-1404', '현장·관리'), person('시험현장관리1', 'T-1401', '현장·관리', '부장'),
      person('시험일팀장', 'T-0008', '2팀', '팀장'), person('시험팀원가', 'T-0026', '2팀'), person('시험자재', 'T-0016', '자재팀'),
      person('시험삼팀원', 'T-0051', '2팀', '팀장'), person('시험삼반장', 'T-1301', '3팀') ] }) });
  });

  await step('관리자(서버 역할): 이름 + 뒤 4자리 → 기존 관리자 화면(명부·편집) + TBM 현황', async () => {
    const { page, errors } = await loginTo('시험관리자', '1404');
    await page.waitForSelector('#directory:not([hidden])');
    assert.ok(await page.evaluate(() => document.body.classList.contains('admin-mode')));
    assert.match(await page.textContent('#identity'), /시험관리자 · 편집 가능/);
    assert.ok(await page.locator('#people tr').count() > 50);
    await page.click('#workHome');
    await page.waitForURL(/tbm_manager_test\.html/);
    await page.waitForSelector('#stageList.active');
    assert.ok(await page.evaluate(() => document.body.classList.contains('admin-mode')));
    assert.deepEqual(errors, []);
  });

  await step('현장관리 권한(직책은 그대로): 현장 TBM 현황, 작업팀만 표시, 명부 편집은 없음', async () => {
    const { page, errors } = await loginTo('시험현장관리1', '1401', /tbm_manager_test\.html/);
    await page.waitForSelector('#stageList.active .team-card');
    assert.match(await page.textContent('#headerSub'), /^시험현장관리1 현장관리 · /);
    const list = await page.textContent('#stageList');
    for (const t of ['1팀', '2팀', '3팀', '자재팀']) assert.ok(list.includes(t), t);
    assert.ok(!list.includes('현장·관리'));
    assert.deepEqual(errors, []);
  });

  await step('같은 팀 팀장 여러 명: 둘 다 2팀 TBM, 3팀 팀장은 3팀, 자재팀 팀장은 팀원 0명이어도 정상', async () => {
    for (const [name, pin, team] of [['시험일팀장', '0008', '2팀'], ['시험팀원가', '0026', '2팀'], ['시험삼반장', '1301', '3팀'], ['시험자재', '0016', '자재팀']]) {
      const { page, errors } = await loginTo(name, pin, /tbm_report_test\.html/);
      await page.waitForSelector('#stageHome.active');
      assert.match(await page.textContent('#headerSub'), new RegExp(`^${team} · .* ${name} 팀장$`));
      if (team === '자재팀') {
        await page.click('#openPlan');
        await page.waitForSelector('#stagePlan.active');
      }
      assert.deepEqual(errors, [], name);
    }
  });

  await step('팀원: 우리 팀장·팀원이 현재 소속(2팀) 기준, 직급 글자가 "팀장"이어도 팀원 화면', async () => {
    const { page } = await loginTo('시험삼팀원', '0051', /member_test\.html/);
    await page.waitForFunction(() => /2팀 · 총 23명/.test(document.querySelector('#notice').textContent), null, { timeout: 8000 });
    assert.equal(await page.textContent('#leaderCount'), '10명');
    assert.equal(await page.textContent('#memberCount'), '13명');
    assert.equal(await page.locator('#members .badge.me').count(), 1);
    assert.match(await page.textContent('#myMeta'), /2팀/);
  });

  await step('팀원이 브라우저 값을 관리자로 바꿔도 서버 역할대로 팀원 화면', async () => {
    const { page } = await loginTo('시험삼팀원', '0051', /member_test\.html/);
    await page.evaluate(() => {
      for (const key of ['attendanceAuthUser', 'tbmAuthUser']) {
        const u = JSON.parse(sessionStorage.getItem(key)); u.appRole = 'ADMIN'; u.role = '관리자';
        sessionStorage.setItem(key, JSON.stringify(u));
      }
    });
    await page.goto(`${env.base}/personnel_test.html`);
    await page.waitForURL(/member_test\.html/);
    assert.equal(await page.evaluate(() => document.querySelector('#directory')), null);
  });

  await step('팀원 화면 로그아웃: 서버 세션 종료 후 통합 로그인, 다시 열어도 자동 로그인 안 됨', async () => {
    const { page } = await loginTo('시험삼팀원', '0051', /member_test\.html/);
    await page.click('text=로그아웃');
    await page.waitForURL(/personnel_test\.html/);
    await page.goto(`${env.base}/personnel_test.html`);
    await page.waitForSelector('#loginPanel:not([hidden])');
    assert.equal(await page.evaluate(() => sessionStorage.getItem('personnelPilotSessionV2')), null);
  });

  await step('명단에서 빠진 인원은 로그인 차단 (기록은 유지)', async () => {
    const { page } = await loginTo('시험중복나', '1360');
    await page.waitForFunction(() => document.querySelector('#message').textContent.includes('로그인이 중지된 계정'));
    const rows = await sql(env, `select employment_status from personnel_pilot_v1.people where display_name = '시험중복나'`);
    assert.equal(rows[0].employment_status, 'inactive');
  });
} finally {
  summary('S4 2026-10 roster e2e');
  await env.close();
}
