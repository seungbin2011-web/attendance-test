// 사용 가이드 v1.1 그림 만들기 (흉내 DB + Chromium). 실제 Supabase·실제 인원을 쓰지 않는다.
// 가짜 시험 인원 이름을 예시 이름(홍길동·김철수·이영희 등)으로 바꾼 뒤 찍어 guides/source/img/에 저장한다.
//   cd tests/sessions && node guide_shots_v11.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
process.env.KEEP_DB='1';
const {db,root,rpc,as}=await import('./sql.mjs');
const {chromium}=await import('playwright');
const file=async f=>db.exec(await fs.readFile(path.join(root,f),'utf8'));
assert.ok((await file('field_sql_v04_check.sql'))[0].rows[0].ready);
await file('field_sql_v04.sql');
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

// 작업 3(출근 보고 완료)을 예시 작업으로 바꾼다
let r=(await rpc('tbm_today')).report;
r=(await rpc('tbm_save_plan',{p_payload:{request_id:'guide-plan',report_id:r.id,version:r.version,end_time:'17:00',risks:['전기','고소작업'],safety_note:'안전대 착용, 작업 전 전원 차단 확인',
  tasks:[{id:r.tasks[0].id,place:'3층 전기실',content:'케이블 포설',members:[{person_id:P('026'),role:'작업자'}]},
    {place:'B동 지하',content:'배관 작업',members:[{person_id:P('027'),role:'작업자'}]},{place:'옥상',content:'자재 정리',members:[{person_id:P('036'),role:'작업자'}]}]}})).report;
await db.query(`update field_pilot_v1.daily_reports set morning_at=${at('07:40')} where id=$1`,[r.id]);

await login('leader','tbm_report.html');await page.locator('#homeTitle').filter({hasText:'작업 3'}).waitFor();await idle();
// 홈: 출역 관리 버튼
await shot(page.locator('#stageHome .card').first(),'s0_home_v11.jpg');

// 작업계획: 다른 팀 인원 검색 · 선택된 인원
await page.locator('#openPlan').click();await page.locator('#stagePlan.active').waitFor();await idle();
await page.locator('#addTask').click();
const card=page.locator('.task-card').last();
await card.locator('[data-tfield=place]').fill('A동 1층');await card.locator('[data-tfield=content]').fill('조명 설치 지원');
await card.locator('[data-member-pool] .task-member',{hasText:'김민수'}).locator('input').click();
await page.locator('.task-card').last().locator('[data-msearch]').fill('공사3');
await page.locator('.task-card').last().locator('[data-member-pool] .task-member',{hasText:'김철수'}).locator('input').click();
await page.locator('.task-card').last().locator('[data-msearch]').fill('공사3');
await page.locator('.task-card').last().locator('[data-msearch]').dispatchEvent('input');
await shot(page.locator('.task-card').last(),'s2_people_v11.jpg');
await page.locator('#draftClear').click();await idle();

// 오후 TBM: 작업정지
await page.locator('#stagePlan [data-go="stageHome"]').click();
await page.locator('#openAfternoon').click();await page.locator('#stageAfternoon.active').waitFor();await idle();
const t1=page.locator('[data-afternoon-task]').first();
await t1.locator('[data-alert=STOPPED]').click();
await t1.locator('[data-aedit=note]').fill('자재 미입고');
await t1.locator('[data-stop-disp=CARRY]').click();
await t1.locator('[data-aedit=action]').fill('내일 오전 자재 입고 후 재개');
await shot(t1,'s5_stop_form.jpg');
await t1.locator('[data-stop-save]').click();await page.locator('#message').filter({hasText:'작업정지'}).waitFor();await idle();
await db.query(`update field_pilot_v1.report_tasks set alert_at=${at('13:20')},result_at=${at('13:20')} where report_id=$1 and alert='STOPPED'`,[r.id]);
await page.locator('#stageAfternoon [data-go="stageHome"]').click();
await page.locator('#refreshBtn').click();await idle();
await page.locator('#openAfternoon').click();await page.locator('#stageAfternoon.active').waitFor();await idle();
await shot(page.locator('[data-afternoon-task]').first(),'s5_stop_done.jpg');
await page.locator('#stageAfternoon [data-open="openEvening"]').click();await page.locator('#stageEvening.active').waitFor();await idle();

// 출역 관리
await page.locator('#stageEvening [data-go="stageHome"]').click();
await page.locator('#openAttendance').click();await page.locator('#stageAttendance.active').waitFor();await idle();
await page.locator('#attendanceAll').click();
await page.locator('.att-row',{hasText:'이영희'}).locator('[data-att-status=LATE]').click();
await page.locator('.att-row',{hasText:'박철수'}).locator('[data-att-status=OFF]').click();
await shot(page.locator('#stageAttendance .card'),'s8_att_in.jpg');
await page.locator('#attendanceConfirm').click();await page.locator('#message').filter({hasText:'확정했습니다'}).waitFor();await idle();
await db.query(`update field_pilot_v1.attendance_records set check_in_at=${at('07:35')}`);
await db.query(`update field_pilot_v1.attendance_records set check_in_at=${at('08:20')} where person_id=$1`,[P('027')]);
await page.locator('#attendanceRefresh').click();await idle();
await page.locator('[data-att-tab=OUT]').click();
await page.locator('#attendanceAll').click();
await page.locator('.att-row',{hasText:'홍길동'}).locator('[data-att-status=EARLY]').click();
await page.locator('#attendanceConfirm').click();await page.locator('#message').filter({hasText:'확정했습니다'}).waitFor();await idle();
await db.query(`update field_pilot_v1.attendance_records set check_out_at=${at('17:05')} where check_out_status is not null`);
await db.query(`update field_pilot_v1.attendance_records set check_out_at=${at('15:30')} where person_id=$1`,[P('026')]);
await page.locator('#attendanceRefresh').click();await idle();
await page.locator('[data-att-tab=IN]').click();
await page.locator('[data-att-tab=OUT]').click();
await shot(page.locator('#stageAttendance .card'),'s8_att_out.jpg');

// 소장: 작업정지 카드 · 출역 현황
await login('manager','tbm_manager.html');await page.locator('#loadedAt').filter({hasText:'최근 조회'}).waitFor();await idle();
await shot(page.locator('.team-card').filter({hasText:'작업정지'}).first(),'m7_stop_card.jpg');
await shot(page.locator('#stageList .card').first(),'m2_dash_v11.jpg');
await page.locator('#openAttendance').click();await page.locator('#stageAttendance.active').waitFor();await idle();
await shot(page.locator('#attendanceBody'),'m8_attendance.jpg');
await browser.close();await db.close();
