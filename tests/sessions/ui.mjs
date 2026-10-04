import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
process.env.KEEP_DB='1';
const {db,root,rpc,as,one,two,three}=await import('./sql.mjs');
const {chromium}=await import('playwright');
await fs.mkdir('artifacts',{recursive:true});
const browser=await chromium.launch({channel:process.env.TEST_BROWSER_CHANNEL||'chrome',headless:true});
const context=await browser.newContext({viewport:{width:390,height:844},deviceScaleFactor:1});
const origin='https://seungbin2011-web.github.io/attendance-test/';
let errors=[];let external=[];
await context.route('**/*',async route=>{
 const req=route.request(),u=new URL(req.url());
 if(u.hostname==='cgeciwdibirvdsucgrnz.supabase.co'){
  const role=(req.headers().authorization||'').replace('Bearer ','');
  try{
   let value;
   if(u.pathname.startsWith('/rest/v1/rpc/')) value=await rpc(u.pathname.split('/').pop(),req.postDataJSON()||{},role);
   else if(u.pathname.startsWith('/storage/v1/object/sign/')){const p=req.postDataJSON();value=[];for(const name of p.paths){const allowed=await as(role,'select field_pilot_v1.storage_can_read($1) as ok',[name]);assert.ok(allowed[0].ok);value.push({path:name,signedURL:'/object/fake.jpg'});}}
   else if(u.pathname==='/storage/v1/object/fake.jpg')return route.fulfill({status:200,contentType:'image/svg+xml',body:'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10" fill="navy"/></svg>'});
   else if(u.pathname==='/auth/v1/logout')value={};
   else throw new Error('Unexpected API '+u.pathname);
   return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(value)});
  }catch(e){console.log('RPC error',u.pathname,e.message);return route.fulfill({status:400,contentType:'application/json',body:JSON.stringify({message:e.message})});}
 }
 if(req.url().startsWith(origin)){try{const name=decodeURIComponent(u.pathname.slice('/attendance-test/'.length))||'index.html';const file=path.resolve(root,name);assert.ok(file.startsWith(root+path.sep));const body=await fs.readFile(file);return route.fulfill({status:200,body,contentType:name.endsWith('.html')?'text/html; charset=utf-8':name.endsWith('.mjs')?'text/javascript':name.endsWith('.css')?'text/css':'application/octet-stream'});}catch(e){return route.fulfill({status:404,body:'not found'});}}
 external.push(req.url());return route.abort();
});
const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
async function login(role,file){if(page.url().startsWith(origin))await page.evaluate(()=>sessionStorage.clear());await page.goto(origin+'index.html');await page.evaluate(({role})=>{sessionStorage.setItem('personnelPilotSessionV2',JSON.stringify({access_token:role,refresh_token:role,expiresAt:Date.now()+3600000}));sessionStorage.setItem('attendanceAuthUser',JSON.stringify({name:'시험팀원가',personId:'c0000000-0000-0000-0000-000000000026',userId:'T-0026',authSource:'supabase-pin'}));}, {role});await page.goto(origin+file);}
async function idle(){await page.locator('#loadingOverlay.active').waitFor({state:'hidden'});}
await login('leader','tbm_report.html');await page.locator('#homeTitle').filter({hasText:'작업 3'}).waitFor();await idle();
assert.equal(await page.locator('#sessionList [data-session-view]').count(),2);
await page.locator(`[data-session-view="${one.id}"]`).click();await page.locator('#stageSessionDetail.active').waitFor();
assert.match(await page.locator('#sessionDetailBody').innerText(),/내용 1/);assert.equal(await page.locator('#sessionDetailBody img').count(),3);assert.equal(await page.locator('#sessionDetailBody input, #sessionDetailBody textarea').count(),0);
await page.locator('#stageSessionDetail [data-go="stageHome"]').click();
await rpc('tbm_afternoon_all_clear',{p_report_id:three.id});await rpc('tbm_evening_close',{p_report_id:three.id,p_complete_rest:true});
await page.locator('#refreshBtn').click();await page.locator('#homeTitle').filter({hasText:'완료'}).waitFor();await idle();
assert.equal(await page.locator('#currentActions').isVisible(),false);assert.equal(await page.locator('#openNextSession').isVisible(),true);
await page.screenshot({path:'artifacts/leader-completed.png',fullPage:true});
await page.locator('#openNextSession').click();await page.locator('#stagePlan.active').waitFor();await idle();
const four=(await rpc('tbm_today')).report;assert.equal(four.session_no,4);assert.equal(four.tasks.length,0);
assert.equal(await page.locator('#safetyNote').inputValue(),'');assert.equal(await page.locator('#endTime').inputValue(),'');
await page.screenshot({path:'artifacts/leader-empty.png',fullPage:true});
await page.locator('[data-tfield="place"]').fill('화면 작성 위치 4');
await page.locator('[data-tfield="content"]').fill('화면 작성 내용 4');
await page.locator('[data-member="c0000000-0000-0000-0000-000000000026"]').check();
await page.locator('#savePlan').click();await page.locator('#message').filter({hasText:'서버에 저장했습니다'}).waitFor();await idle();
assert.equal((await rpc('tbm_today')).report.id,four.id);
assert.equal((await rpc('tbm_today')).report.tasks[0].content,'화면 작성 내용 4');
await page.locator('#stagePlan [data-open="openMorning"]').click();await page.locator('#submitMorning').click();await idle();
assert.ok((await rpc('tbm_today')).report.morning_at);
await page.reload();await page.locator('#homeTitle').filter({hasText:'작업 4'}).waitFor();await idle();
await page.locator('#logoutBtn').click();await page.waitForURL(origin+'index.html');assert.equal(await page.evaluate(()=>sessionStorage.getItem('personnelPilotSessionV2')),null);
await login('leader','tbm_report.html');await page.locator('#homeTitle').filter({hasText:'작업 4'}).waitFor();await idle();
await login('manager','tbm_manager.html');await page.locator('#loadedAt').filter({hasText:'최근 조회'}).waitFor();await idle();
for(const n of [1,2,3,4])assert.match(await page.locator('body').innerText(),new RegExp('작업 '+n));
await page.screenshot({path:'artifacts/manager.png',fullPage:true});
await login('member','member.html');await page.locator('#myTasks details').first().waitFor();assert.equal(await page.locator('#myTasks details').count(),3);assert.equal(await page.locator('#myTasks .my-task').count(),1);
assert.match(await page.locator('#myTasks .my-task').innerText(),/작업 4/);
assert.ok(!external.some(u=>u.includes('script.google.com')),'Supabase member makes no Apps Script request');
assert.deepEqual(errors,[]);assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
await page.screenshot({path:'artifacts/member.png',fullPage:true});
console.log('UI PASSED: read-only history/photos, completed lock, empty fourth session, reload/logout/relogin, manager 1–4, member completion state, no Apps Script');
await browser.close();await db.close();
