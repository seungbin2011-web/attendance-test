// TBM v1.2 현장 UX 보정 화면 시험 (흉내 DB + Chromium, 실제 Supabase에 연결하지 않음)
// 전일 이월 접힘·이월 취소 · 저장 성공 → 홈 / 실패 → 화면 유지 · 로그인 뒤로가기 · 소장 PC 화면 · 휴대폰 폭
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
process.env.KEEP_DB='1';
const {db,root,rpc,as}=await import('./sql.mjs');
const {chromium}=await import('playwright');
const file=async f=>db.exec(await fs.readFile(path.join(root,f),'utf8'));
for(const v of ['04','05']){assert.ok((await file(`field_sql_v${v}_check.sql`))[0].rows[0].ready);await file(`field_sql_v${v}.sql`);assert.ok((await file(`field_sql_v${v}_verify.sql`))[0].rows[0].ok);}
await fs.mkdir('artifacts',{recursive:true});
const P=n=>'c0000000-0000-0000-0000-000000000'+n;
const TEAM2='b0000000-0000-0000-0000-000000000002';

// 준비: 오늘(작업 3)을 이월 3건과 함께 마감한 뒤 날짜를 하루 앞으로 → 오늘은 '다음 날'
let r=(await rpc('tbm_today')).report;
r=(await rpc('tbm_save_plan',{p_payload:{request_id:'v12-prev',report_id:r.id,version:r.version,end_time:'17:00',risks:[],tasks:[
  {id:r.tasks[0].id,place:'플레넘 TPS 2',content:'삽장 구성\n2구간 마무리',members:[{person_id:P('026'),role:'작업자'},{person_id:P('027'),role:'작업자'}]},
  {place:'B동 지하',content:'배관 작업',members:[{person_id:P('036'),role:'작업자'}]},
  {place:'옥상',content:'잘못 이월될 작업',members:[]}]}})).report;
for(const [k,res] of [[0,'NOT_DONE'],[1,'PARTIAL'],[2,'NOT_DONE']]) await rpc('tbm_task_result',{p_task_id:r.tasks[k].id,p_result:res,p_carry:true,p_note:'시간 부족'});
await rpc('tbm_evening_close',{p_report_id:r.id});
await db.query("update field_pilot_v1.daily_reports set work_date=work_date-1 where team_id=$1 and work_date=field_pilot_v1.kst_today()",[TEAM2]);
const [y1,y2,y3]=r.tasks;

const browser=await chromium.launch({channel:process.env.TEST_BROWSER_CHANNEL||'chrome',headless:true});
const context=await browser.newContext({viewport:{width:390,height:844},deviceScaleFactor:1});
const origin='https://seungbin2011-web.github.io/attendance-test/';
let errors=[];const fail=new Set();
await context.route('**/*',async route=>{
 const req=route.request(),u=new URL(req.url());
 if(u.hostname==='cgeciwdibirvdsucgrnz.supabase.co'){
  const role=(req.headers().authorization||'').replace('Bearer ','');
  try{
   let value;
   if(u.pathname.startsWith('/rest/v1/rpc/')){const name=u.pathname.split('/').pop();if(fail.has(name))return route.abort();value=await rpc(name,req.postDataJSON()||{},role);}
   else if(u.pathname==='/functions/v1/member-login')value={ok:true,access_token:'other',refresh_token:'other',expires_in:3600};
   else if(u.pathname.startsWith('/storage/v1/object/sign/'))value=[];
   else if(u.pathname==='/auth/v1/logout')value={};
   else throw new Error('Unexpected API '+u.pathname);
   return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(value)});
  }catch(e){return route.fulfill({status:400,contentType:'application/json',body:JSON.stringify({message:e.message})});}
 }
 if(req.url().startsWith(origin)){try{const name=decodeURIComponent(u.pathname.slice('/attendance-test/'.length))||'index.html';const f=path.resolve(root,name);assert.ok(f.startsWith(root+path.sep));const body=await fs.readFile(f);return route.fulfill({status:200,body,contentType:name.endsWith('.html')?'text/html; charset=utf-8':name.endsWith('.mjs')?'text/javascript':name.endsWith('.css')?'text/css':name.endsWith('.pdf')?'application/pdf':'application/octet-stream'});}catch(e){return route.fulfill({status:404,body:'not found'});}}
 return route.abort();
});
const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
async function login(role,f){if(page.url().startsWith(origin))await page.evaluate(()=>sessionStorage.clear());await page.goto(origin+'index.html');await page.evaluate(({role})=>{sessionStorage.setItem('personnelPilotSessionV2',JSON.stringify({access_token:role,refresh_token:role,expiresAt:Date.now()+3600000}));sessionStorage.setItem('attendanceAuthUser',JSON.stringify({name:'시험팀원가',personId:'c0000000-0000-0000-0000-000000000026',userId:'T-0026',authSource:'supabase-pin'}));},{role});await page.goto(origin+f);}
async function idle(){await page.locator('#loadingOverlay.active').waitFor({state:'hidden'});}
async function noHScroll(label){assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'no horizontal scroll: '+label);}
const msg=async re=>{await page.locator('#message').filter({hasText:re}).waitFor();};
// 성공 표시 → 홈: 성공 카드 문구를 확인하고 홈이 열릴 때까지 기다린다
async function doneThenHome(title,sub){
  await page.locator('#doneOverlay.active').waitFor();
  assert.match(await page.locator('#doneTitle').innerText(),title);
  if(sub)assert.match(await page.locator('#doneSub').innerText(),sub);
  await page.locator('#doneOverlay.active').waitFor({state:'detached'}).catch(()=>{});
  await page.locator('#doneOverlay').waitFor({state:'hidden'});
  await page.locator('#stageHome.active').waitFor();
}
const step=async label=>{const s=await page.locator('#homeSteps').innerText();assert.match(s,new RegExp(label+'\\s*✓'),label+' ✓ on home');};
let passed=0;const ok=label=>{passed++;console.log('PASS',label);};

// ---- 1. 전일 이월: 기본 접힘 · 펼치기 · 이월 취소(후보) ----
await login('leader','tbm_report.html');await page.locator('#stageHome.active').waitFor();await idle();
await page.locator('#openPlan').click();await page.locator('#stagePlan.active').waitFor();await idle();
assert.equal(await page.locator('#carryBox').isVisible(),true);
assert.equal(await page.locator('#carryBox').getAttribute('open'),null,'carry candidates folded by default');
assert.match(await page.locator('#carryBox summary').innerText(),/전일 이월[\s\S]*3건/);
assert.equal(await page.locator('#carryBox summary .fold-hint').evaluate(el=>getComputedStyle(el,'::before').content),'"펼치기 ▼"');
assert.equal(await page.locator('#carryList .carry-item').first().isVisible(),false);
ok('carry candidates folded by default');
await page.locator('#carryBox summary').click();
const cand=id=>page.locator(`#carryList [data-carry="${id}"]`);
assert.match(await cand(y1.id).innerText(),/플레넘 TPS 2[\s\S]*전일 미완료[\s\S]*인원 2명/);
assert.doesNotMatch(await cand(y1.id).innerText(),/시험팀원가/,'names hidden, count only');
ok('expand shows task, summary, 전일 미완료, 인원 N명');
await cand(y3.id).locator('[data-carry-cancel]').click();
assert.equal(await cand(y3.id).locator('[data-cancel-reason]').inputValue(),'잘못 이월 처리함');
await cand(y3.id).locator('[data-cancel-confirm]').click();await msg(/이월을 취소했습니다/);await idle();
assert.equal(await cand(y3.id).count(),0);
const h=(await db.query("select note,actor_label from field_pilot_v1.workflow_history where entity_id=$1 and action='CARRY_CANCELLED'",[y3.id])).rows;
assert.ok(h.length===1&&h[0].note==='잘못 이월 처리함'&&h[0].actor_label);
assert.equal((await db.query('select carry_status,result from field_pilot_v1.report_tasks where id=$1',[y3.id])).rows[0].carry_status,'DROPPED');
ok('candidate 이월 취소: reason + history, yesterday record kept (DROPPED)');

// ---- 2. 오늘 이어서 → 접힌 이월 카드 · 오늘 신규와 구분 · 인원 문구 ----
await cand(y1.id).locator('[data-carry-take]').click();
const carried=page.locator('#carriedList .carried-task').first();
assert.equal(await carried.getAttribute('open'),null,'taken carry folded');
assert.match(await carried.locator('summary').innerText(),/전일 이월[\s\S]*플레넘 TPS 2[\s\S]*삽장 구성[\s\S]*전일 미완료 · 인원 2명/);
assert.equal(await carried.locator('.chosen-list').isVisible(),false);
assert.match(await page.locator('#taskList').innerText(),/오늘 신규 작업이 없습니다/);
await page.locator('#addTask').click();
await page.locator('#taskList .task-card').first().locator('[data-tfield=place]').fill('A동 1층');
await page.locator('#taskList .task-card').first().locator('[data-tfield=content]').fill('조명 설치');
await page.locator('#taskList .task-card').first().locator('[data-member-pool] .task-member',{hasText:'시험팀원가'}).locator('input').click();
assert.match(await page.locator('#taskList .task-card').first().innerText(),/작업 1[\s\S]*오늘 신규/);
assert.match(await page.locator('#taskList .task-card').first().locator('.chosen-list').innerText(),/이월1에도 투입/);
assert.doesNotMatch(await page.locator('#stagePlan').innerText(),/(작업|이월)\d[^\n]* 중복/);
await carried.locator('summary').click();
assert.equal(await carried.locator('.chosen-list').isVisible(),true);
assert.match(await carried.locator('.chosen-list').innerText(),/시험팀원가[\s\S]*작업1에도 투입/);
await noHScroll('plan with carry 390');
await page.screenshot({path:'artifacts/v12-plan-carry-390.png',fullPage:true});
ok('taken carry: folded card, 전일 이월 vs 오늘 신규, "작업1에도 투입" wording');

// ---- 3. 저장 실패 → 화면 유지 · 입력 보존 / 성공 → 성공 표시 → 홈 ----
fail.add('tbm_save_plan');
await page.locator('#savePlan').click();
await page.locator('#errorSheet').waitFor();
assert.match(await page.locator('#errorSheet').innerText(),/저장되지 않았습니다[\s\S]*입력한 내용은 그대로/);
assert.equal(await page.locator('#stagePlan.active').count(),1,'stays on plan');
assert.equal(await page.locator('#taskList .task-card').first().locator('[data-tfield=place]').inputValue(),'A동 1층');
await page.screenshot({path:'artifacts/v12-save-fail-390.png'});
fail.delete('tbm_save_plan');
ok('save failure: no home, inputs kept, big error');
await page.locator('#errorSheetRetry').click();
await doneThenHome(/작업계획 저장 완료/,/작업 2건 · 전일 이월 1건/);
await step('계획');
assert.match(await page.locator('#message').innerText(),/서버에 저장했습니다/);
ok('plan save → ✓ 작업계획 저장 완료 → home → 계획 ✓');

// ---- 4. 저장된 이월 작업 정정(이월 취소) ----
await page.locator('#openPlan').click();await page.locator('#stagePlan.active').waitFor();await idle();
const saved=page.locator('#carriedList .carried-task').first();
assert.equal(await saved.getAttribute('open'),null);
await saved.locator('summary').click();
await saved.locator('[data-carried-cancel]').click();
await page.locator('#carriedList [data-cancel-reason]').fill('전일 작업 이미 끝남');
await page.locator('#carriedList [data-cancel-confirm]').click();await msg(/이월을 취소했습니다/);await idle();
assert.equal(await page.locator('#carriedList .carried-task').count(),0);
const todayRep=(await rpc('tbm_today')).report;
assert.ok(todayRep.tasks.length===1&&todayRep.tasks[0].place==='A동 1층');
assert.equal((await db.query('select carry_status from field_pilot_v1.report_tasks where id=$1',[y1.id])).rows[0].carry_status,'DROPPED');
assert.equal((await db.query("select count(*)::int as n from field_pilot_v1.workflow_history where action='CARRY_CANCELLED' and note='전일 작업 이미 끝남'")).rows[0].n,2);
ok('saved carry 이월 취소: removed from today, original kept as DROPPED, history on both days');
// 남은 후보(y2)를 이어받아 저장 (이후 단계에서 작업정지 대상)
await page.locator('#carryBox summary').click().catch(()=>{});
if(!(await page.locator('#carryBox').getAttribute('open')))await page.locator('#carryBox summary').click();
await cand(y2.id).locator('[data-carry-take]').click();
await page.locator('#savePlan').click();await doneThenHome(/작업계획 저장 완료/);

// ---- 5. 출근 → 오후(작업정지·전체 이상 없음) → 퇴근, 단계마다 성공 → 홈 ----
await page.locator('#openMorning').click();await page.locator('#stageMorning.active').waitFor();await idle();
await page.fill('#morningNote','장비 점검');
fail.add('tbm_submit_morning');
await page.locator('#submitMorning').click();await page.locator('#errorSheet').waitFor();
assert.equal(await page.locator('#stageMorning.active').count(),1);assert.equal(await page.inputValue('#morningNote'),'장비 점검');
fail.delete('tbm_submit_morning');await page.locator('#errorSheetClose').click();
await page.locator('#submitMorning').click();await doneThenHome(/출근 TBM 보고 완료/);await step('출근');
ok('morning: failure stays with note kept; success → home → 출근 ✓');
const rep=(await rpc('tbm_today')).report;const stopTask=rep.tasks.find(t=>t.carried_from_task_id===y2.id);
await page.locator('#openAfternoon').click();await page.locator('#stageAfternoon.active').waitFor();await idle();
const card=page.locator(`[data-afternoon-task="${stopTask.id}"]`);
await card.locator('[data-alert=STOPPED]').click();await card.locator('[data-aedit=note]').fill('자재 미입고');
await card.locator('[data-stop-disp=CARRY]').click();await card.locator('[data-stop-save]').click();
await doneThenHome(/작업정지 저장 완료/,/내일 이월/);
assert.match(await page.locator('#homeNotes').innerText(),/⛔ 작업정지 · 내일 이월[\s\S]*B동 지하 — 자재 미입고/);
await page.screenshot({path:'artifacts/v12-home-stop-390.png',fullPage:true});
ok('stop → ✓ 작업정지 저장 완료 · 내일 이월 → home shows ⛔ 작업정지 · 내일 이월');
await page.locator('#openAfternoon').click();await page.locator('#stageAfternoon.active').waitFor();await idle();
await page.locator('#afternoonAllClear').click();await doneThenHome(/오후 TBM 저장 완료/);await step('오후');
ok('afternoon all-clear → home → 오후 ✓');
await page.locator('#openEvening').click();await page.locator('#stageEvening.active').waitFor();await idle();
await page.locator('#eveningClose').click();await doneThenHome(/퇴근 TBM 마감 완료/,/내일 이월 1건/);await step('퇴근');
ok('evening close → home → 퇴근 ✓');

// ---- 6. 로그인 뒤로가기: 로그인 폼이 다시 나오지 않음, 로그아웃만 세션 종료 ----
await page.evaluate(()=>sessionStorage.clear());
await page.goto('about:blank');
await page.goto(origin+'index.html');await page.locator('#loginPanel:not([hidden])').waitFor();
await page.fill('#username','시험삼팀장');await page.fill('#password','1234');await page.click('#loginButton');
await page.waitForURL(origin+'tbm_report.html');await page.locator('#stageHome.active').waitFor();await idle();
const len=await page.evaluate(()=>history.length);
await page.goBack();await page.waitForURL(u=>!String(u).includes('tbm_report'));
assert.ok(!page.url().includes('index.html'),'back does not show the login page: '+page.url());
await page.goForward();await page.waitForURL(origin+'tbm_report.html');await page.locator('#stageHome.active').waitFor();
ok(`login → leader page → back does not return to login form (history ${len})`);
await page.goto(origin+'index.html');await page.waitForURL(origin+'tbm_report.html');
ok('opening index with a live session goes straight to the role page');
// 뒤로가기 캐시 복원(pageshow persisted) 흉내: 로그아웃 상태 화면에 세션이 생기면 역할 화면으로
await page.evaluate(()=>sessionStorage.clear());await page.goto(origin+'index.html');await page.locator('#loginPanel:not([hidden])').waitFor();
await page.evaluate(()=>{sessionStorage.setItem('personnelPilotSessionV2',JSON.stringify({access_token:'other',refresh_token:'other',expiresAt:Date.now()+3600000,kind:'member'}));window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));});
await page.waitForURL(origin+'tbm_report.html');await page.locator('#stageHome.active').waitFor();await idle();
ok('BFCache restore of login page with a live session → role page');
await page.locator('#logoutBtn').click();await page.waitForURL(origin+'index.html');await page.locator('#loginPanel:not([hidden])').waitFor();
assert.equal(await page.evaluate(()=>sessionStorage.getItem('personnelPilotSessionV2')),null);
await page.goBack().catch(()=>{});
assert.ok(!(await page.locator('#stageHome.active').count())||!page.url().includes('tbm_report'),'back after logout does not show leader page');
ok('logout clears session; back does not reopen the leader page');

// ---- 7. 소장 PC 화면 (1024 / 1440) · 휴대폰 ----
for(const w of [1024,1440]){
  await page.setViewportSize({width:w,height:900});
  await login('manager','tbm_manager.html');await page.locator('#loadedAt').filter({hasText:'최근 조회'}).waitFor();await idle();
  const wrap=await page.locator('main.wrap').boundingBox();
  const cols=await page.locator('#teamList').evaluate(el=>getComputedStyle(el).gridTemplateColumns.split(' ').length);
  const cards=await page.locator('#teamList .team-card').evaluateAll(els=>els.slice(0,2).map(e=>Math.round(e.getBoundingClientRect().top)));
  assert.ok(wrap.width>=Math.min(1100,w-48)&&wrap.width<=1180,`wide container at ${w}: ${wrap.width}`);
  assert.equal(cols,2,'team cards in 2 columns');assert.equal(cards[0],cards[1],'first two cards side by side');
  const fs1=await page.locator('.team-name').first().evaluate(el=>parseFloat(getComputedStyle(el).fontSize));
  assert.ok(fs1>=18,'font not smaller on PC');
  await noHScroll('manager '+w);
  await page.screenshot({path:`artifacts/v12-manager-${w}.png`,fullPage:true});
  await page.locator('#openAttendance').click();await page.locator('#stageAttendance.active').waitFor();await idle();
  await page.screenshot({path:`artifacts/v12-manager-attendance-${w}.png`,fullPage:true});
}
ok('site manager PC: wide container, 2-column team cards, summary uses width, fonts kept');
for(const w of [320,360,390]){
  await page.setViewportSize({width:w,height:760});
  await login('manager','tbm_manager.html');await page.locator('#loadedAt').filter({hasText:'최근 조회'}).waitFor();await idle();
  assert.equal(await page.locator('#teamList').evaluate(el=>getComputedStyle(el).display),'flex','mobile keeps single column');
  await noHScroll('manager '+w);
  await login('leader','tbm_report.html');await page.locator('#stageHome.active').waitFor();await idle();
  await noHScroll('leader home '+w);await page.screenshot({path:`artifacts/v12-leader-home-${w}.png`,fullPage:true});
  await page.locator('#openAttendance').click();await page.locator('#stageAttendance.active').waitFor();await idle();await noHScroll('leader attendance '+w);
}
ok('phones 320/360/390: no horizontal scroll, manager single column');
assert.deepEqual(errors,[]);
console.log('UI V12 PASSED',passed);
await browser.close();await db.close();
