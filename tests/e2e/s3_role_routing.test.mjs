// Season 2 현장 사용 준비: 서버 역할(소속·역할 표)대로 화면 이동 e2e (로컬 흉내 게이트웨이, 가짜 데이터)
// 이름·팀으로 역할을 정하지 않는다. 역할 변경은 실제 변경 템플릿 파일(personnel_roles_v10_change_template.sql)로만 한다.
import { readFileSync } from 'node:fs';
import { setup, newPage, sql, step, summary, assert } from './helpers.mjs';

const env = await setup();
const TEMPLATE = readFileSync(new URL('../../personnel_roles_v10_change_template.sql', import.meta.url), 'utf8');

async function login(page, name, secret) {
  await page.fill('#username', name);
  await page.fill('#password', secret);
  await page.click('#loginButton');
}
async function rosterAdd(entries) {
  await fetch(`${env.base}/__test/roster`, { method: 'POST', body: JSON.stringify({ entries }) });
}
// 관리자가 SQL Editor에서 하는 일과 같다: 템플릿의 "변경 대상" 자리에 명단만 넣어 실행
async function applyTargets(rows) {
  const text = TEMPLATE.replace(/^(-- ▼ 변경 대상.*)$/m, `$1\ninsert into role_targets values ${rows};`);
  const r = await fetch(`${env.base}/__test/sql`, { method: 'POST', body: JSON.stringify({ sql: text, params: [] }) });
  assert.equal(r.status, 200, `템플릿 실행 실패: ${await r.text()}`);
}
async function loginTo(name, pin, url, next = '') {
  const { page, errors } = await newPage(env);
  page.on('dialog', d => d.accept());
  await page.goto(`${env.base}/personnel_test.html${next ? `?next=${next}` : ''}`);
  await login(page, name, pin);
  await page.waitForURL(url);
  return { page, errors };
}

try {
  await rosterAdd([
    { name: '시험일팀장', pin: '0808', user: { name: '시험일팀장', userId: 'T-0008', team: '공사1팀', rank: '팀장', role: '팀장', job: '전기' } },
    { name: '시험소장', pin: '0303', user: { name: '시험소장', userId: 'T-0003', team: '현장소장', rank: '소장', role: '소장', job: '관리' } },
  ]);

  await step('명부상 팀장이어도 서버에 팀장 역할이 없으면 팀원 화면 (현장 사례 재현, 이름으로 판단하지 않음)', async () => {
    const { page } = await loginTo('시험일팀장', '0808', /member_test\.html/);
    const u = await page.evaluate(() => JSON.parse(sessionStorage.getItem('attendanceAuthUser')));
    assert.equal(u.appRole, 'MEMBER');
  });

  await step('변경 템플릿으로 소속·팀장 역할만 넣으면 코드 수정 없이 팀장 TBM (새 팀도 자동 표시)', async () => {
    await applyTargets(`('T-0008','시험일팀장','CONSTRUCTION_1','공사1팀','TEAM_LEADER')`);
    const { page, errors } = await loginTo('시험일팀장', '0808', /tbm_report_test\.html/);
    await page.waitForSelector('#stageHome.active');
    assert.match(await page.textContent('#headerSub'), /^공사1팀 · .* 시험일팀장 팀장$/);
    assert.deepEqual(errors, []);
  });

  await step('소장: 이름 + 뒤 4자리 → 소장 TBM 현황 (서버 SITE_MANAGER 기준), 새 팀도 목록에 보임', async () => {
    const { page, errors } = await loginTo('시험소장', '0303', /tbm_manager_test\.html/);
    await page.waitForSelector('#stageList.active .team-card');
    assert.match(await page.textContent('#headerSub'), /^시험소장 현장관리 · /);
    assert.match(await page.textContent('#stageList'), /공사1팀/);
    assert.match(await page.textContent('#stageList'), /공사2팀/);
    const u = await page.evaluate(() => JSON.parse(sessionStorage.getItem('attendanceAuthUser')));
    assert.equal(u.appRole, 'MANAGER');
    await page.goto(`${env.base}/tbm_report_test.html`);
    await page.waitForSelector('#blocked:not([hidden])');
    assert.match(await page.textContent('#blockedText'), /팀장만 사용할 수 있는 화면/);
    assert.deepEqual(errors, []);
  });

  await step('개인 로그인 소장은 업무계정 전용 화면(인원 편집)으로 보내지 않음', async () => {
    const { page } = await loginTo('시험소장', '0303', /tbm_manager_test\.html/, 'admin_test.html');
    await page.waitForSelector('#stageList.active');
  });

  await step('팀원이 브라우저 값(appRole)을 바꿔도 소장 화면은 서버가 막음', async () => {
    const { page } = await loginTo('시험중복가', '3636', /member_test\.html/);
    await page.evaluate(() => {
      for (const key of ['attendanceAuthUser', 'tbmAuthUser']) {
        const u = JSON.parse(sessionStorage.getItem(key)); u.appRole = 'MANAGER'; u.role = '소장';
        sessionStorage.setItem(key, JSON.stringify(u));
      }
    });
    await page.goto(`${env.base}/tbm_manager_test.html`);
    await page.waitForSelector('#blocked:not([hidden])');
    assert.match(await page.textContent('#blockedText'), /현장관리·관리자 권한이 있는 사람만/);
    assert.equal(await page.locator('#stageList .team-card').count(), 0);
  });

  await step('소장 교체: 템플릿으로 소장 역할을 빼면 다음 로그인부터 팀원 화면, 다시 넣으면 소장 현황', async () => {
    await applyTargets(`('T-0003','시험소장',null,null,'MEMBER')`);
    await loginTo('시험소장', '0303', /member_test\.html/);
    await applyTargets(`('T-0003','시험소장',null,null,'SITE_MANAGER')`);
    await loginTo('시험소장', '0303', /tbm_manager_test\.html/);
  });

  await step('팀장 교체·팀 이동은 서버 기록만 바뀌고 지난 보고는 그대로', async () => {
    const before = await sql(env, `select count(*)::int n from field_pilot_v1.task_assignments`);
    await applyTargets(`('T-0008','시험일팀장','CONSTRUCTION_1','공사1팀','MEMBER'), ('T-0036','시험중복가','CONSTRUCTION_1','공사1팀','TEAM_LEADER')`);
    await loginTo('시험일팀장', '0808', /member_test\.html/);
    const after = await sql(env, `select count(*)::int n from field_pilot_v1.task_assignments`);
    assert.equal(after[0].n, before[0].n);
    const ended = await sql(env, `select count(*)::int n from personnel_pilot_v1.memberships m join personnel_pilot_v1.people p on p.id = m.person_id
      where p.display_name = '시험중복가' and m.valid_to is not null`);
    assert.equal(ended[0].n, 1, '이전 팀 소속은 지우지 않고 종료');
    const { page } = await loginTo('시험중복가', '3636', /tbm_report_test\.html/);
    await page.waitForSelector('#stageHome.active');
    assert.match(await page.textContent('#headerSub'), /^공사1팀 · /);
  });
} finally {
  summary('S3 role routing e2e');
  await env.close();
}
