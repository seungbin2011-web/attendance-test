// 사용 가이드 v1.2 그림 만들기 (전일 이월 접힘·이월 취소·저장 후 홈) (흉내 DB + Chromium). 실제 Supabase·실제 인원을 쓰지 않는다.
// 가짜 시험 인원 이름을 예시 이름(홍길동·김철수·이영희 등)으로 바꾼 뒤 찍어 guides/source/img/에 저장한다.
//   cd tests/sessions && node guide_shots_v12.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
process.env.KEEP_DB='1';
const {db,root,rpc,as}=await import('./sql.mjs');
const {chromium}=await import('playwright');
const file=async f=>db.exec(await fs.readFile(path.join(root,f),'utf8'));
assert.ok((await file('field_sql_v04_check.sql'))[0].rows[0].ready);
await file('field_sql_v04.sql');
await file('field_sql_v05.sql');
const P=n=>'c0000000-0000-0000-0000-000000000'+n;
// 예시 이름 (실제 인원 아님)
for(const [n,name] of [['025','김민수'],['026','홍길동'],['027','이영희'],['036','박철수'],['050','최현우'],['051','김철수'],['016','윤서준'],['003','정소장']])
  await db.query('update personnel_pilot_v1.people set display_name=$2 where id=$1',[P(n),name]);
await db.query("update personnel_pilot_v1.teams set name='공사3팀' where id='b0000000-0000-0000-0000-000000000003'");
await db.query("update personnel_pilot_v1.login_profiles set login_name='김민수' where auth_user_id='d0000000-0000-0000-0000-0000000000a4'");
await db.query("update personnel_pilot_v1.login_profiles set login_name='정소장' where auth_user_id='d0000000-0000-0000-0000-0000000000a2'");
const out=path.join(root,'guides/source/img');
const browser=await chromium.launch({channel:process.env.TEST_BROWSER_CHANNEL||'chrome',headless:true});
const context=await browser.newContext({viewport:{width:390,height:844},deviceScaleFactor:2});
const origin='https://seungbin2011-web.github.io/attendance-test/';
await context.route('**/*',async route=>{
 const req=route.request(),u=new URL(req.url());
 if(u.hostname==='cgeciwdibirvdsucgrnz.supabase.co'){
  const role=(req.headers().authorization||'').replace('Bearer ','');
  try{
   let value;
   if(u.pathname.startsWith('/rest/v1/rpc/'))value=await rpc(u.pathname.split('/').pop(),req.postDataJSON()||{},role);
   else if(u.pathname==='/auth/v1/logout')value={};
   else if(u.pathname.startsWith('/storage/v1/object/sign/'))value=[];
   else throw new Error('Unexpected API '+u.pathname);
   return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(value)});
  }catch(e){return route.fulfill({status:400,contentType:'application/json',body:JSON.stringify({message:e.message})});}
 }
 if(req.url().startsWith(origin)){try{const name=decodeURIComponent(u.pathname.slice('/attendance-test/'.length))||'index.html';const f=path.resolve(root,name);const body=await fs.readFile(f);return route.fulfill({status:200,body,contentType:name.endsWith('.html')?'text/html; charset=utf-8':name.endsWith('.mjs')?'text/javascript':name.endsWith('.css')?'text/css':'application/octet-stream'});}catch(e){return route.fulfill({status:404,body:'not found'});}}
 return route.abort();
});
const page=await context.newPage();page.on('dialog',d=>d.accept());
async function login(role,f){if(page.url().startsWith(origin))await page.evaluate(()=>sessionStorage.clear());await page.goto(origin+'index.html');await page.evaluate(({role})=>{sessionStorage.setItem('personnelPilotSessionV2',JSON.stringify({access_token:role,refresh_token:role,expiresAt:Date.now()+3600000}));},{role});await page.goto(origin+f);}
async function idle(){await page.locator('#loadingOverlay.active').waitFor({state:'hidden'});}
const shot=async(locator,name)=>{await locator.screenshot({path:path.join(out,name),type:'jpeg',quality:82});console.log('img/'+name);};
// 화면 시각을 보기 좋은 현장 시각으로 (그림용)
const at=hhmm=>`(field_pilot_v1.kst_today() + time '${hhmm}') at time zone 'Asia/Seoul'`;
const TEAM2='b0000000-0000-0000-0000-000000000002';
// 어제 작업(이월 3건)을 만든 뒤 날짜를 하루 앞으로 → 오늘은 '다음 날'
let r=(await rpc('tbm_today')).report;
r=(await rpc('tbm_save_plan',{p_payload:{request_id:'g12-prev',report_id:r.id,version:r.version,end_time:'17:00',risks:[],tasks:[
  {id:r.tasks[0].id,place:'플레넘 TPS 2',content:'삽장 구성',members:[{person_id:P('026'),role:'작업자'},{person_id:P('027'),role:'작업자'}]},
  {place:'B동 지하',content:'배관 작업',members:[{person_id:P('036'),role:'작업자'}]},
  {place:'옥상',content:'자재 정리',members:[{person_id:P('025'),role:'작업자'}]}]}})).report;
for(const [k,res] of [[0,'NOT_DONE'],[1,'PARTIAL'],[2,'NOT_DONE']]) await rpc('tbm_task_result',{p_task_id:r.tasks[k].id,p_result:res,p_carry:true,p_note:'시간 부족'});
await rpc('tbm_evening_close',{p_report_id:r.id});
await db.query("update field_pilot_v1.daily_reports set work_date=work_date-1 where team_id=$1 and work_date=field_pilot_v1.kst_today()",[TEAM2]);

await login('leader','tbm_report.html');await page.locator('#stageHome.active').waitFor();await idle();
await page.locator('#openPlan').click();await page.locator('#stagePlan.active').waitFor();await idle();
// 접힌 이월 후보 + 오늘 이어받은 작업(접힘) + 오늘 신규
await page.locator('#carryBox summary').click();
await page.locator('#carryList [data-carry-take]').first().click();
await page.locator('#carryBox summary').click();
await page.locator('#addTask').click();
await page.locator('#taskList .task-card').first().locator('[data-tfield=place]').fill('A동 1층');
await page.locator('#taskList .task-card').first().locator('[data-tfield=content]').fill('조명 설치');
await page.locator('#taskList .task-card').first().locator('[data-member-pool] .task-member',{hasText:'박철수'}).locator('input').click();
await page.locator('#carryBox').scrollIntoViewIfNeeded();const sy=await page.evaluate(()=>scrollY);
const top=await page.locator('#carryBox').boundingBox(), bottom=await page.locator('#taskList .task-card').first().locator('.member-head').boundingBox();top.y+=sy;bottom.y+=sy;
await page.screenshot({path:path.join(out,'s2_carry_fold.jpg'),type:'jpeg',quality:82,clip:{x:0,y:top.y-12,width:390,height:bottom.y+bottom.height-top.y+24},fullPage:true});console.log('img/s2_carry_fold.jpg');
// 이월 취소 (후보)
await page.locator('#carryBox summary').click();
const cand=page.locator('#carryList .carry-item').last();
await cand.locator('[data-carry-cancel]').click();
await shot(page.locator('#carryBox'),'s2_carry_cancel.jpg');
await page.locator('#carryList [data-cancel-close]').click();
// 저장 → ✓ 성공 표시 (홈으로 돌아가기 전에 찍는다)
await page.locator('#savePlan').click();
await page.locator('#doneOverlay.active').waitFor();
await shot(page.locator('#doneOverlay .done-card'),'s3_done.jpg');
await page.locator('#stageHome.active').waitFor();
await browser.close();await db.close();
