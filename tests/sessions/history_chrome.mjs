// Chrome 계열 브라우저의 뒤로가기·앞으로가기·새로고침 시험 (흉내 DB + Chromium, 실제 Supabase에 연결하지 않음)
// 현장 대표 브라우저는 iPhone Chrome이다. 같은 흐름을 Chromium(Chrome 엔진)에서
// 뒤로가기 캐시(BFCache)를 켠 경우·끈 경우로 두 번 돌린다. Playwright는 기본으로 BFCache를 끄므로 켬 모드에서는 그 설정을 뺀다.
// iPhone의 Chrome·Safari는 같은 WebKit 엔진을 쓰므로 실기기 확인은 docs/TEST_CHECKLIST.md 「v1.2」에서 한다.
// 확인하는 것
//   A 로그인 → 업무 화면 → 뒤로가기: 로그인 폼이 다시 나오지 않음 / 앞으로가기·새로고침: 로그인 유지
//   B 세션이 끊긴 뒤 캐시된 업무 화면으로 뒤로가기: 로그인 화면으로
//   C 로그아웃 → 뒤로가기·앞으로가기·새로고침: 업무 화면이 다시 열리지 않음
//   D 팀원 화면 → 출결 등록 → 뒤로가기: 로그인 유지
//   E 소장 화면 뒤로가기·앞으로가기·새로고침
//   F 캐시된 로그인 화면: 세션이 있으면 역할 화면, 없으면 로그인 폼 그대로
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
process.env.KEEP_DB='1';
const {db,root,rpc}=await import('./sql.mjs');
const {chromium}=await import('playwright');
const file=async f=>db.exec(await fs.readFile(path.join(root,f),'utf8'));
for(const v of ['04','05']){assert.ok((await file(`field_sql_v${v}_check.sql`))[0].rows[0].ready);await file(`field_sql_v${v}.sql`);assert.ok((await file(`field_sql_v${v}_verify.sql`))[0].rows[0].ok);}

const origin='https://seungbin2011-web.github.io/attendance-test/';
const SESSION_KEY='personnelPilotSessionV2';
const session=(token,extra={})=>JSON.stringify({access_token:token,refresh_token:token,expiresAt:Date.now()+3600000,...extra});
let checks=0;const restored={};
function ok(mode,msg){checks++;console.log('PASS',`[${mode}]`,msg);}
const GUIDE=origin+'guides/source/team-leader-tbm-guide.html'; // 같은 사이트의 다른 화면 (세션과 무관한 정적 화면)

async function route(route){
  const req=route.request(),u=new URL(req.url());
  if(u.hostname==='cgeciwdibirvdsucgrnz.supabase.co'){
    const role=(req.headers().authorization||'').replace('Bearer ','');
    try{
      let value;
      if(u.pathname.startsWith('/rest/v1/rpc/'))value=await rpc(u.pathname.split('/').pop(),req.postDataJSON()||{},role);
      // 로그인 서버 흉내: 시험 팀원 이름이면 팀원 세션, 그 밖은 시험 팀장 세션 (번호 확인은 실제 서버 몫이라 여기서 하지 않음)
      else if(u.pathname==='/functions/v1/member-login'){const t=(req.postDataJSON()||{}).name==='시험팀원가'?'member':'other';value={ok:true,access_token:t,refresh_token:t,expires_in:3600};}
      else if(u.pathname.startsWith('/storage/v1/object/sign/'))value=[];
      else if(u.pathname.startsWith('/auth/v1/logout'))value={};
      else throw new Error('Unexpected API '+u.pathname);
      return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(value)});
    }catch(e){return route.fulfill({status:400,contentType:'application/json',body:JSON.stringify({message:e.message})});}
  }
  if(req.url().startsWith(origin)){
    try{
      const name=decodeURIComponent(u.pathname.slice('/attendance-test/'.length))||'index.html';
      const f=path.resolve(root,name);assert.ok(f.startsWith(root+path.sep));
      const body=await fs.readFile(f);
      return route.fulfill({status:200,body,contentType:name.endsWith('.html')?'text/html; charset=utf-8':name.endsWith('.mjs')?'text/javascript':name.endsWith('.css')?'text/css':name.endsWith('.jpg')?'image/jpeg':name.endsWith('.png')?'image/png':'application/octet-stream'});
    }catch(e){return route.fulfill({status:404,body:'not found'});}
  }
  return route.abort();
}

for(const bfcache of [true,false]){
  const mode=bfcache?'BFCache 켬':'BFCache 끔';
  const browser=await chromium.launch({channel:process.env.TEST_BROWSER_CHANNEL||'chrome',headless:true,...(bfcache?{ignoreDefaultArgs:['--disable-back-forward-cache']}:{})});
  restored[mode]=0;
  const errors=[];

  // 휴대폰 크기 새 탭 (시나리오마다 방문 기록을 새로 시작)
  async function tab(init){
    const context=await browser.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true});
    await context.route('**/*',route);
    // 캐시 복원(pageshow persisted) 기록: 화면의 pageshow 처리보다 먼저 돌고, 화면이 곧바로 다른 곳으로 가도 남도록 sessionStorage에 적는다
    await context.addInitScript(()=>{addEventListener('pageshow',e=>{if(!e.persisted)return;const l=JSON.parse(sessionStorage.getItem('__restored')||'[]');l.push(location.pathname.split('/').pop());sessionStorage.setItem('__restored',JSON.stringify(l));});});
    if(init)await context.addInitScript(...init);
    const page=await context.newPage();
    page.on('pageerror',e=>{if(!page.url().includes('index_season1'))errors.push(page.url()+' '+e.message);});
    page.on('dialog',d=>d.accept());
    await page.goto('about:blank');
    return page;
  }
  const here=page=>page.url().replace(origin,'').split('?')[0];
  const at=(page,name)=>page.waitForURL(u=>String(u).replace(origin,'').split('?')[0]===name,{waitUntil:'commit'});
  // 브라우저 버튼과 같은 동작 (history.back/forward). 캐시 복원이면 load가 다시 오지 않으므로 commit까지만 기다린다
  const back=async page=>{await page.evaluate(()=>history.back());};
  const forward=async page=>{await page.evaluate(()=>history.forward());};
  // 켬 모드: 이 화면이 실제로 캐시에서 복원됐어야 한다 / 끔 모드: 다시 읽었어야 한다
  const cachePath=async(page,name)=>{
    const log=await page.evaluate(()=>JSON.parse(sessionStorage.getItem('__restored')||'[]'));
    assert.equal(log.includes(name),bfcache,`${name} ${bfcache?'restored from':'reloaded without'} BFCache: ${JSON.stringify(log)}`);
    if(bfcache)restored[mode]++;
    return bfcache?' (restored from BFCache)':' (reloaded)';
  };
  const loginForm=async page=>{await at(page,'index.html');await page.locator('#loginPanel:not([hidden])').waitFor();assert.equal(await page.locator('#loginButton').isDisabled(),false,'login button usable');};
  const leaderHome=async page=>{await at(page,'tbm_report.html');await page.locator('#stageHome.active').waitFor();await page.locator('#loadingOverlay.active').waitFor({state:'hidden'});};
  const memberHome=async page=>{await at(page,'member.html');await page.locator('#myName').filter({hasText:'시험팀원가'}).waitFor();};
  const managerHome=async page=>{await at(page,'tbm_manager.html');await page.locator('#loadedAt').filter({hasText:'최근 조회'}).waitFor();};
  // 업무 화면에서 뒤로가기: 앱 밖(처음 빈 탭)으로 나가야 한다. 로그인 화면이 다시 나오면 실패
  const backOutOfApp=async page=>{const from=page.url();await back(page);await page.waitForURL(u=>String(u)!==from,{waitUntil:'commit'});assert.equal(page.url(),'about:blank','back must not show the login page: '+page.url());};
  const hasSession=page=>page.evaluate(k=>!!sessionStorage.getItem(k),SESSION_KEY);
  // 잠시 뒤에도 같은 화면인지 (뒤늦은 로그아웃·이동이 없는지)
  const stays=async(page,name)=>{await page.waitForTimeout(600);assert.equal(here(page),name,'stays on '+name);};
  async function loginAs(page,name){
    await page.goto(origin+'index.html');await loginForm(page);
    await page.fill('#username',name);await page.fill('#password','1234');await page.click('#loginButton');
  }

  // ---- A 팀장: 로그인 → 업무 화면 → 뒤로·앞으로·새로고침 ----
  let page=await tab();
  await loginAs(page,'시험삼팀장');await leaderHome(page);
  await backOutOfApp(page);
  ok(mode,'A leader page → back leaves the app (login form is not in history)');
  await forward(page);await leaderHome(page);await stays(page,'tbm_report.html');
  assert.ok(await hasSession(page));
  ok(mode,'A forward → leader page, still logged in');
  await page.goto(GUIDE);await back(page);await leaderHome(page);await stays(page,'tbm_report.html');assert.ok(await hasSession(page));
  ok(mode,'A leader → other page → back: leader page, still logged in'+await cachePath(page,'tbm_report.html'));
  await page.reload();await leaderHome(page);await stays(page,'tbm_report.html');assert.ok(await hasSession(page));
  ok(mode,'A reload on leader page keeps the session');
  await page.locator('#openPlan').click();await page.locator('#stagePlan.active').waitFor();
  await page.reload();await leaderHome(page);assert.ok(await hasSession(page));
  ok(mode,'A reload while editing the plan keeps the session (back to home)');
  await page.goto(origin+'index.html');await leaderHome(page);
  await back(page);await leaderHome(page);await stays(page,'tbm_report.html');
  ok(mode,'A opening the login address with a live session → role page; back does not show the login form');
  await page.context().close();

  // ---- B 세션이 끊긴 뒤 캐시된 업무 화면 → 로그인 ----
  page=await tab();
  await loginAs(page,'시험삼팀장');await leaderHome(page);
  await page.goto(GUIDE);
  await page.evaluate(()=>sessionStorage.clear()); // 다른 화면에서 세션이 끝난 경우
  await back(page);await loginForm(page);
  assert.ok(page.url().includes('next=tbm_report.html'),'login returns to leader page: '+page.url());
  ok(mode,'B leader page after the session ended → back shows login (no stale work screen)'+await cachePath(page,'tbm_report.html'));
  await page.context().close();

  // ---- C 로그아웃 → 뒤로·앞으로·새로고침 ----
  page=await tab();
  await loginAs(page,'시험삼팀장');await leaderHome(page);
  await page.locator('#logoutBtn').click();await loginForm(page);
  assert.equal(await hasSession(page),false);
  await backOutOfApp(page);
  await forward(page);await loginForm(page);await stays(page,'index.html');assert.equal(await hasSession(page),false);
  await page.reload();await loginForm(page);await stays(page,'index.html');
  ok(mode,'C logout → back/forward/reload never reopens the leader page');
  await page.context().close();

  // ---- D 팀원: 출결 등록(Season 1) 갔다가 뒤로 ----
  page=await tab();
  await loginAs(page,'시험팀원가');await memberHome(page);
  await page.reload();await memberHome(page);await stays(page,'member.html');
  ok(mode,'D reload on member page keeps the login');
  await page.evaluate(()=>goAttendance());await at(page,'index_season1.html');
  await back(page);await memberHome(page);await stays(page,'member.html');
  ok(mode,'D member → 출결 등록 → back: member page, still logged in'+await cachePath(page,'member.html'));
  await backOutOfApp(page);
  await forward(page);await memberHome(page);await stays(page,'member.html');
  ok(mode,'D back from member page leaves the app; forward returns logged in');
  await forward(page);await at(page,'index_season1.html');
  await page.evaluate(()=>sessionStorage.clear());
  await back(page);await loginForm(page);
  ok(mode,'D member page after the session ended → back shows login'+await cachePath(page,'member.html'));
  await page.context().close();
  page=await tab();
  await loginAs(page,'시험팀원가');await memberHome(page);
  await page.evaluate(()=>logout());await loginForm(page);assert.equal(await hasSession(page),false);
  await backOutOfApp(page);
  await forward(page);await loginForm(page);await stays(page,'index.html');
  ok(mode,'D member logout → back/forward never reopens the member page');
  await page.context().close();

  // ---- E 소장 화면 ----
  page=await tab([(args)=>{if(location.pathname.endsWith('/tbm_manager.html')&&!sessionStorage.getItem('__seeded')){sessionStorage.setItem(args.key,args.value);sessionStorage.setItem('__seeded','1');}},{key:SESSION_KEY,value:session('manager')}]);
  await page.goto(origin+'tbm_manager.html');await managerHome(page);
  await backOutOfApp(page);
  await forward(page);await managerHome(page);await stays(page,'tbm_manager.html');
  ok(mode,'E manager page back/forward keeps the login');
  await page.goto(GUIDE);await back(page);await managerHome(page);await stays(page,'tbm_manager.html');
  ok(mode,'E manager → other page → back: manager page, still logged in'+await cachePath(page,'tbm_manager.html'));
  await page.reload();await managerHome(page);await stays(page,'tbm_manager.html');
  ok(mode,'E reload on manager page keeps the login');
  await page.goto(GUIDE);
  await page.evaluate(()=>{sessionStorage.removeItem('personnelPilotSessionV2');sessionStorage.removeItem('__restored');});
  await back(page);await loginForm(page);
  ok(mode,'E manager page after the session ended → back shows login'+await cachePath(page,'tbm_manager.html'));
  await page.context().close();

  // ---- F 캐시된 로그인 화면 ----
  page=await tab();
  await page.goto(origin+'index.html');await loginForm(page);
  await page.goto(GUIDE);
  await back(page);await loginForm(page);await stays(page,'index.html');
  ok(mode,'F login page back again without a session: form ready (button not stuck)'+await cachePath(page,'index.html'));
  await page.evaluate(()=>sessionStorage.removeItem('__restored'));
  await page.goto(GUIDE);
  await page.evaluate(v=>sessionStorage.setItem('personnelPilotSessionV2',v),session('other',{kind:'member'}));
  await back(page);await leaderHome(page);
  ok(mode,'F login page shown again with a live session → role page (no login form)'+await cachePath(page,'index.html'));
  await page.context().close();

  assert.deepEqual(errors,[],'page errors');
  await browser.close();
}

console.log('BFCache restores checked',JSON.stringify(restored));
console.log('HISTORY CHROME TESTS PASSED',checks);
await db.close();
