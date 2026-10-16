// field v0.4 화면 시험 (흉내 DB + Chromium, 실제 Supabase에 연결하지 않음)
// 작업정지(오후 TBM) → 퇴근 TBM 재입력 없음 → 소장 현황 · 팀원 화면 표시
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
process.env.KEEP_DB='1';
const {db,root,rpc,as}=await import('./sql.mjs');
const {chromium}=await import('playwright');
const file=async f=>db.exec(await fs.readFile(path.join(root,f),'utf8'));
assert.ok((await file('field_sql_v04_check.sql'))[0].rows[0].ready);
await file('field_sql_v04.sql');
assert.ok((await file('field_sql_v04_verify.sql'))[0].rows[0].ok);
await fs.mkdir('artifacts',{recursive:true});
const browser=await chromium.launch({channel:process.env.TEST_BROWSER_CHANNEL||'chrome',headless:true});
const context=await browser.newContext({viewport:{width:360,height:780},deviceScaleFactor:1});
const origin='https://seungbin2011-web.github.io/attendance-test/';
const P=n=>'c0000000-0000-0000-0000-000000000'+n;
let errors=[];let calls=[];
await context.route('**/*',async route=>{
 const req=route.request(),u=new URL(req.url());
 if(u.hostname==='cgeciwdibirvdsucgrnz.supabase.co'){
  const role=(req.headers().authorization||'').replace('Bearer ','');
  try{
   let value;
   if(u.pathname.startsWith('/rest/v1/rpc/')){const name=u.pathname.split('/').pop();calls.push(name);value=await rpc(name,req.postDataJSON()||{},role);}
   else if(u.pathname.startsWith('/storage/v1/object/sign/')){const p=req.postDataJSON();value=[];for(const name of p.paths){const allowed=await as(role,'select field_pilot_v1.storage_can_read($1) as ok',[name]);assert.ok(allowed[0].ok);value.push({path:name,signedURL:'/object/fake.jpg'});}}
   else if(u.pathname==='/storage/v1/object/fake.jpg')return route.fulfill({status:200,contentType:'image/svg+xml',body:'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10" fill="navy"/></svg>'});
   else if(u.pathname==='/auth/v1/logout')value={};
   else throw new Error('Unexpected API '+u.pathname);
   return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(value)});
  }catch(e){return route.fulfill({status:400,contentType:'application/json',body:JSON.stringify({message:e.message})});}
 }
 if(req.url().startsWith(origin)){try{const name=decodeURIComponent(u.pathname.slice('/attendance-test/'.length))||'index.html';const f=path.resolve(root,name);assert.ok(f.startsWith(root+path.sep));const body=await fs.readFile(f);return route.fulfill({status:200,body,contentType:name.endsWith('.html')?'text/html; charset=utf-8':name.endsWith('.mjs')?'text/javascript':name.endsWith('.css')?'text/css':'application/octet-stream'});}catch(e){return route.fulfill({status:404,body:'not found'});}}
 return route.abort();
});
const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
async function login(role,f){if(page.url().startsWith(origin))await page.evaluate(()=>sessionStorage.clear());await page.goto(origin+'index.html');await page.evaluate(({role})=>{sessionStorage.setItem('personnelPilotSessionV2',JSON.stringify({access_token:role,refresh_token:role,expiresAt:Date.now()+3600000}));sessionStorage.setItem('attendanceAuthUser',JSON.stringify({name:'시험팀원가',personId:'c0000000-0000-0000-0000-000000000026',userId:'T-0026',authSource:'supabase-pin'}));},{role});await page.goto(origin+f);}
async function idle(){await page.locator('#loadingOverlay.active').waitFor({state:'hidden'});}
async function noHScroll(label){assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'no horizontal scroll: '+label);}
const poolNamesOf=async c=>(await c.locator('[data-member-pool] .task-member > span:nth-of-type(1)').allTextContents());
const msg=async re=>{await page.locator('#message').filter({hasText:re}).waitFor();};
let passed=0;const ok=(label)=>{passed++;console.log('PASS',label);};

// 준비: 작업 3(출근 보고 완료)에 작업 2개를 더한다
let r=(await rpc('tbm_today')).report;
r=(await rpc('tbm_save_plan',{p_payload:{request_id:'ui-v04-plan',report_id:r.id,version:r.version,end_time:'17:00',risks:['전기'],safety_note:'안전',
  tasks:[{id:r.tasks[0].id,place:r.tasks[0].place,content:r.tasks[0].content,members:[{person_id:P('026'),role:'작업자'}]},
    {place:'B동 지하',content:'배관 작업',members:[{person_id:P('027'),role:'작업자'}]},{place:'옥상',content:'정리',members:[]}]}})).report;
const [t1,t2,t3]=r.tasks;

// ---- 작업정지 (오후 TBM) ----
await login('leader','tbm_report.html');await page.locator('#homeTitle').filter({hasText:'작업 3'}).waitFor();await idle();
await page.locator('#openAfternoon').click();await page.locator('#stageAfternoon.active').waitFor();await idle();
const card=id=>page.locator(`[data-afternoon-task="${id}"]`);
await card(t1.id).locator('[data-alert=STOPPED]').click();
await card(t1.id).locator('[data-stop-save]').click();await msg(/정지 사유를 2자 이상/);
await card(t1.id).locator('[data-aedit=note]').fill('자재 미입고');
await card(t1.id).locator('[data-stop-save]').click();await msg(/처리 방향/);
assert.equal(calls.filter(c=>c==='tbm_task_stop').length,0,'no server call before reason and disposition');
ok('stop needs reason and disposition before saving');
await card(t1.id).locator('[data-stop-disp=CARRY]').click();
await card(t1.id).locator('[data-aedit=action]').fill('내일 오전 재개');
await page.screenshot({path:'artifacts/v04-stop-editor-360.png',fullPage:true});
await card(t1.id).locator('[data-stop-save]').click();await msg(/작업정지\(내일 이월\)로 저장/);await idle();
// v1.2: 작업정지 저장은 단계 완료 → 홈. 오후 TBM을 다시 연다
await page.locator('#stageHome.active').waitFor();await page.locator('#openAfternoon').click();await page.locator('#stageAfternoon.active').waitFor();await idle();
assert.match(await card(t1.id).getAttribute('class'),/is-stopped/);
assert.match(await card(t1.id).locator('.task-save-state').innerText(),/작업정지 · 내일 이월/);
assert.match(await card(t1.id).innerText(),/정지 사유 자재 미입고 · 조치: 내일 오전 재개/);
let k=(await rpc('tbm_today')).report.tasks[0];assert.ok(k.alert==='STOPPED'&&k.carry_over&&k.carry_status==='PENDING');
ok('stop CARRY saved with reason, action and carryover');
await card(t2.id).locator('[data-alert=STOPPED]').click();await card(t2.id).locator('[data-aedit=note]').fill('우천');
await card(t2.id).locator('[data-stop-disp=END]').click();await card(t2.id).locator('[data-stop-save]').click();await msg(/오늘 정지로 종료/);await idle();
// v1.2: 작업정지 저장은 단계 완료 → 홈. 오후 TBM을 다시 연다
await page.locator('#stageHome.active').waitFor();await page.locator('#openAfternoon').click();await page.locator('#stageAfternoon.active').waitFor();await idle();
await card(t2.id).locator('[data-alert=STOPPED]').click();
assert.equal(await card(t2.id).locator('[data-aedit=note]').inputValue(),'우천');
assert.match(await card(t2.id).locator('[data-stop-disp=END]').getAttribute('class'),/selected/);
await card(t2.id).locator('[data-stop-cancel]').click();await msg(/작업정지를 취소/);await idle();
assert.doesNotMatch(await card(t2.id).getAttribute('class'),/is-stopped/);
ok('reopen stop editor keeps values; cancel stop returns task to unchecked');
await card(t2.id).locator('[data-alert=STOPPED]').click();await card(t2.id).locator('[data-aedit=note]').fill('우천 지속');
await card(t2.id).locator('[data-stop-disp=END]').click();await card(t2.id).locator('[data-stop-save]').click();await msg(/오늘 정지로 종료/);await idle();
// v1.2: 작업정지 저장은 단계 완료 → 홈. 오후 TBM을 다시 연다
await page.locator('#stageHome.active').waitFor();await page.locator('#openAfternoon').click();await page.locator('#stageAfternoon.active').waitFor();await idle();
assert.equal(await card(t1.id).locator('[data-alert=NORMAL]').isDisabled(),true,'other status buttons locked on stopped task');
assert.equal(await page.locator('#afternoonAllClear').innerText(),'전체 이상 없음');
await page.locator('#afternoonAllClear').click();await msg(/오후 TBM을 저장/);await idle();
await page.locator('#stageHome.active').waitFor();await page.locator('#openAfternoon').click();await page.locator('#stageAfternoon.active').waitFor();await idle();
assert.match(await card(t1.id).locator('.task-save-state').innerText(),/작업정지/);
await noHScroll('afternoon 360');
await page.screenshot({path:'artifacts/v04-afternoon-360.png',fullPage:true});
ok('all-clear keeps stopped tasks');

// ---- 퇴근 TBM: 작업정지는 다시 입력하지 않음 ----
await page.locator('#stageAfternoon [data-go="stageHome"]').click();await page.locator('#openEvening').click();await page.locator('#stageEvening.active').waitFor();await idle();
const ev=id=>page.locator(`[data-evening-task="${id}"]`);
assert.equal(await ev(t1.id).locator('[data-result]').count(),0);
assert.match(await ev(t1.id).locator('.stop-note').innerText(),/퇴근 결과 입력 필요 없음/);
assert.match(await ev(t2.id).locator('.task-save-state').innerText(),/작업정지 · 정지로 종료/);
assert.equal(await page.locator('#eveningClose').innerText(),'나머지 1건 완료로 하고 퇴근 마감');
await page.screenshot({path:'artifacts/v04-evening-360.png',fullPage:true});
await page.locator('#eveningClose').click();await msg(/퇴근 TBM을 마감했습니다.*내일 이월 1건/);await idle();await page.locator('#stageHome.active').waitFor();
const closed=(await rpc('tbm_report_detail',{p_report_id:r.id},'manager')).report;
assert.deepEqual(closed.tasks.map(t=>t.result),['STOPPED','STOPPED','DONE']);
assert.ok(closed.evening_at&&closed.tasks[0].alert_note==='자재 미입고'&&closed.tasks[1].alert_note==='우천 지속');
ok('evening close without re-entry; only the open task becomes DONE');

// ---- 소장 현황 ----
await login('manager','tbm_manager.html');await page.locator('#loadedAt').filter({hasText:'최근 조회'}).waitFor();await idle();
const team=page.locator('.team-card[data-team="공사2팀"]').filter({hasText:'작업 3'});
assert.match(await team.locator('.chips').innerText(),/작업정지 2/);
assert.equal(await team.locator('.team-task.stopped').count(),2);
assert.match(await team.innerText(),/정지 사유 자재 미입고/);
assert.match(await page.locator('#summaryGrid').innerText(),/2\s*작업정지/);
await page.screenshot({path:'artifacts/v04-manager-360.png',fullPage:true});
await team.locator('[data-detail]').click();await page.locator('#stageDetail.active').waitFor();await idle();
const det=await page.locator('#detailBody').innerText();
assert.match(det,/작업정지 · 내일 이월 · 정지 .* 사유: 자재 미입고 · 조치: 내일 오전 재개/);
assert.match(det,/작업정지 · 정지로 종료/);
assert.match(det,/작업정지 취소/);
await noHScroll('manager detail 360');
ok('manager card count, stopped task lines and detail reason/disposition/history');

// ---- 팀원 화면 ----
await login('member','member.html');await page.locator('#myTasks details').first().waitFor();
const stoppedRow=page.locator('#myTasks details').filter({hasText:'작업 3'}).first();
assert.match(await stoppedRow.locator('summary').innerText(),/⛔ 작업 3[\s\S]*작업정지/);
await stoppedRow.locator('summary').click();
assert.match(await stoppedRow.innerText(),/오후 TBM: 작업정지[\s\S]*퇴근 TBM: 작업정지 · 내일 이월/);
await noHScroll('member 360');
ok('member screen shows 작업정지 · 내일 이월');

// ---- 작업계획 인원: 검색 · 타 팀원 · 선택된 인원 ----
await page.setViewportSize({width:320,height:720});
await login('leader','tbm_report.html');await page.locator('#homeTitle').filter({hasText:'작업 3'}).waitFor();await idle();
await page.locator('#openNextSession').click();await page.locator('#stagePlan.active').waitFor();await idle();
const plan=page.locator('.task-card').first();
const poolNames=async()=>(await plan.locator('[data-member-pool] .task-member > span:nth-of-type(1)').allTextContents()).sort();
assert.deepEqual(await poolNames(),['시험이팀장','시험중복가','시험팀원가','시험팀원나'].sort(),'default list = own team');
assert.match(await plan.locator('.member-count').innerText(),/선택된 인원 0명/);
await plan.locator('[data-msearch]').fill('시험3');
assert.deepEqual(await poolNames(),['시험삼팀원','시험삼팀장'].sort());
assert.equal(await plan.locator('[data-member-pool] .other-team-badge').count(),2);
assert.match(await plan.locator('[data-member-pool]').innerText(),/타 팀원 · 시험3팀/);
await plan.locator('[data-msearch]').fill('퇴사');
assert.match(await plan.locator('[data-member-pool]').innerText(),/검색 결과가 없습니다/);
ok('search: own team by default, other teams by name/team, inactive never shown');
await plan.locator('[data-msearch]').fill('삼팀원');
await plan.locator('[data-member-pool] .task-member',{hasText:'시험삼팀원'}).locator('input').click();
await page.locator('.task-card').first().locator('[data-msearch]').fill('');
await page.locator('.task-card').first().locator('[data-member-pool] .task-member',{hasText:'시험팀원가'}).locator('input').click();
const plan2=page.locator('.task-card').first();
assert.match(await plan2.locator('.member-count').innerText(),/선택된 인원 2명/);
assert.deepEqual((await plan2.locator('.chosen-list .chip-name').allTextContents()),['시험삼팀원','시험팀원가']);
assert.match(await plan2.locator('.chosen-list .task-member',{hasText:'시험삼팀원'}).innerText(),/타 팀원 · 시험3팀/);
assert.ok(!(await poolNamesOf(plan2)).includes('시험팀원가'),'chosen person leaves the list');
await plan2.locator('.chosen-list .task-member',{hasText:'시험팀원가'}).locator('.chip-x').click();
assert.ok((await poolNamesOf(page.locator('.task-card').first())).includes('시험팀원가'),'× returns person to the list');
await page.locator('.task-card').first().locator('[data-member-pool] .task-member',{hasText:'시험팀원가'}).locator('input').click();
await page.locator('.task-card').first().locator('.chosen-list .task-member',{hasText:'시험삼팀원'}).locator('select').selectOption('신호수');
ok('chosen chips with ×, role select, other-team badge');
await page.locator('.task-card').first().locator('[data-tfield=place]').fill('지원 구역');
await page.locator('.task-card').first().locator('[data-tfield=content]').fill('타 팀 지원 작업');
await noHScroll('plan 320');
await page.screenshot({path:'artifacts/v04-plan-320.png',fullPage:true});
await page.locator('#savePlan').click();await msg(/서버에 저장했습니다/);await idle();await page.locator('#stageHome.active').waitFor();
const four=(await rpc('tbm_today')).report;
const m51=four.tasks[0].members.find(m=>m.name==='시험삼팀원');
assert.ok(four.session_no===4&&m51.other_team&&m51.home_team_name==='시험3팀'&&m51.role==='신호수');
assert.equal((await db.query("select team_id from personnel_pilot_v1.memberships where person_id=$1 and valid_to is null",[P('051')])).rows[0].team_id,'b0000000-0000-0000-0000-000000000003');
await page.locator('#openMorning').click();await page.locator('#stageMorning.active').waitFor();
assert.match(await page.locator('#morningTasks').innerText(),/시험삼팀원\(신호수\)\s*타 팀원 · 시험3팀/);
ok('saved with other-team member; official team unchanged; morning view shows badge');

// ---- 출역 관리 (팀장) ----
const recCount=async()=>(await db.query('select count(*)::int as n from field_pilot_v1.attendance_records')).rows[0].n;
const rec=async n=>(await db.query('select r.*,(select count(*)::int from field_pilot_v1.attendance_history h where h.attendance_id=r.id) as hist from field_pilot_v1.attendance_records r where person_id=$1',[P(n)])).rows[0];
await page.locator('#stageMorning [data-go="stageHome"]').click();await page.locator('#stageHome.active').waitFor();
await page.locator('#openAttendance').click();await page.locator('#stageAttendance.active').waitFor();await idle();
assert.equal(await page.locator('.att-row').count(),4);
assert.equal(await recCount(),0,'opening attendance writes nothing');
assert.equal(await page.locator('#attendanceConfirm').isDisabled(),true);
await page.locator('#attendanceAll').click();
assert.equal(await page.locator('#attendanceConfirm').innerText(),'출근 확정 (4명)');
const row=name=>page.locator('.att-row',{hasText:name});
await row('시험팀원나').locator('[data-att-status=ABSENT]').click();
await row('시험중복가').locator('[data-att-status=ABSENT]').click();
await row('시험중복가').locator('[data-att-status=OFF]').click();
assert.equal(await recCount(),0,'choices are not saved before confirm');
await page.screenshot({path:'artifacts/v04-attendance-in-320.png',fullPage:true});
await noHScroll('attendance 320');
await page.locator('#attendanceConfirm').click();await msg(/출근 4명을 확정했습니다/);await idle();
assert.equal(await recCount(),4);
assert.deepEqual([(await rec('025')).check_in_status,(await rec('027')).check_in_status,(await rec('036')).check_in_status],['PRESENT','ABSENT','OFF']);
assert.equal((await rec('026')).check_in_by_role,'TEAM_LEADER');
assert.match(await row('시험팀원가').locator('.att-state').innerText(),/출근 확정 · .* · 2팀장팀/);
ok('check-in: all present → exceptions → confirm; nothing saved before confirm');
await row('시험팀원나').locator('[data-att-status=LATE]').click();
assert.equal(await page.locator('#attendanceConfirm').innerText(),'출근 확정 (1명 · 수정 1명)');
await page.locator('#attendanceConfirm').click();await msg(/수정 1명, 이력 남음/);await idle();
const r27=await rec('027');assert.ok(r27.check_in_status==='LATE'&&r27.hist===2);
assert.match(await row('시험팀원나').innerText(),/수정 1회/);
ok('correction keeps history and shows count');
await page.locator('[data-att-tab=OUT]').click();
assert.equal(await page.locator('.att-row.locked').count(),1);
assert.match(await row('시험중복가').innerText(),/휴무 · 퇴근 처리 없음/);
assert.equal(await page.locator('#attendanceAll').innerText(),'전체 퇴근 (3명)');
await page.locator('#attendanceAll').click();
await row('시험팀원가').locator('[data-att-status=EARLY]').click();
await page.setViewportSize({width:390,height:844});
await page.screenshot({path:'artifacts/v04-attendance-out-390.png',fullPage:true});
await page.locator('#attendanceConfirm').click();await msg(/퇴근 3명을 확정했습니다/);await idle();
assert.deepEqual([(await rec('025')).check_out_status,(await rec('026')).check_out_status,(await rec('027')).check_out_status,(await rec('036')).check_out_status],['LEFT','EARLY','LEFT',null]);
await page.locator('[data-go="stageHome"]').first().click();
assert.match(await page.locator('#openAttendanceSub').innerText(),/출근 4\/4 확정 · 퇴근 3\/3/);
ok('check-out only for present/late; home shows attendance progress');

// ---- 출역 현황 (현장관리 조회 · 관리자 정정) ----
await login('manager','tbm_manager.html');await page.locator('#loadedAt').filter({hasText:'최근 조회'}).waitFor();await idle();
await page.locator('#openAttendance').click();await page.locator('#stageAttendance.active').waitFor();await idle();
const team2=page.locator('[data-att-team="b0000000-0000-0000-0000-000000000002"]');
assert.match(await team2.locator('summary').innerText(),/출근 4\/4 · 퇴근 3\/3/);
await team2.locator('summary').click().catch(()=>{});
assert.match(await page.locator('#attendanceBody').innerText(),/조회만/);
assert.equal(await page.locator('[data-fix-in]').count(),0,'site manager cannot correct');
assert.match(await page.locator('#attendanceBody').textContent(),/입력 2팀장팀\(팀장\)/);
await noHScroll('manager attendance');
await page.screenshot({path:'artifacts/v04-manager-attendance.png',fullPage:true});
ok('site manager sees all teams read-only with who entered');
await login('admin','tbm_manager.html');await page.locator('#loadedAt').filter({hasText:'최근 조회'}).waitFor();await idle();
await page.locator('#openAttendance').click();await page.locator('#stageAttendance.active').waitFor();await idle();
const adminTeam=page.locator('[data-att-team="b0000000-0000-0000-0000-000000000002"]');
if(!(await adminTeam.getAttribute('open')))await adminTeam.locator('summary').click();
await adminTeam.locator('[data-att-person="'+P('026')+'"] [data-fix-out]').selectOption('LEFT');
await adminTeam.locator('[data-fix-save]').click();await page.locator('#message').filter({hasText:'출역을 정정했습니다'}).waitFor();await idle();
const r26=await rec('026');assert.ok(r26.check_out_status==='LEFT'&&r26.check_out_by_role==='ADMIN');
assert.match(await page.locator('[data-att-team="b0000000-0000-0000-0000-000000000002"]').textContent(),/수정 1회/);
ok('admin correction saved with ADMIN role and history');

// ---- 휴대폰 폭 320 / 360 / 390 + 데스크톱: 가로 스크롤 없음 ----
const shot=async (w,name)=>{await noHScroll(`${name} ${w}`);if(w!==360)await page.screenshot({path:`artifacts/w${w}-${name}.png`,fullPage:true});};
for(const w of [320,360,390,1280]){
  await page.setViewportSize({width:w,height:w>1000?900:760});
  await login('leader','tbm_report.html');await page.locator('#homeTitle').filter({hasText:'작업 4'}).waitFor();await idle();
  await shot(w,'leader-home');
  if(w>1000){assert.ok((await page.locator('main.wrap').boundingBox()).width<=620,'desktop keeps phone-width column');continue;}
  await page.locator('#openPlan').click();await page.locator('#stagePlan.active').waitFor();await idle();await shot(w,'leader-plan');
  await page.locator('#stagePlan [data-go="stageHome"]').click();
  await page.locator('#openAfternoon').click();await page.locator('#stageAfternoon.active').waitFor();await idle();await shot(w,'leader-afternoon');
  await page.locator('#stageAfternoon [data-go="stageHome"]').click();
  await page.locator('#openAttendance').click();await page.locator('#stageAttendance.active').waitFor();await idle();await shot(w,'leader-attendance');
  await login('manager','tbm_manager.html');await page.locator('#loadedAt').filter({hasText:'최근 조회'}).waitFor();await idle();await shot(w,'manager-list');
  await page.locator('.team-card').filter({hasText:'작업정지'}).locator('[data-detail]').click();await page.locator('#stageDetail.active').waitFor();await idle();await shot(w,'manager-detail');
  await page.locator('#stageDetail [data-go="stageList"]').click();await idle();
  await page.locator('#openAttendance').click();await page.locator('#stageAttendance.active').waitFor();await idle();await shot(w,'manager-attendance');
  await login('member','member.html');await page.locator('#myTasks details').first().waitFor();await shot(w,'member');
}
ok('no horizontal scroll at 320/360/390 on leader home·plan·afternoon·attendance, manager list·detail·attendance, member; desktop column kept');

assert.deepEqual(errors,[]);
console.log('UI V04 PASSED',passed);
await browser.close();await db.close();
