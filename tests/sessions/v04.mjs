// field v0.4 (작업정지 · 타 팀원 투입 · 출역 관리) 로컬 시험. 실제 Supabase에 연결하지 않는다.
// sql.mjs(v03 순차 작업 시험)를 먼저 돌린 같은 흉내 DB 위에서 CHECK → APPLY → VERIFY → 되돌리기 → 재적용 후 기능을 확인한다.
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
process.env.KEEP_DB='1';
const {root,db,as,rpc,photo}=await import('./sql.mjs');
let checks=0;
function ok(v,msg){assert.ok(v,msg);checks++;console.log('PASS',msg);}
async function rejects(fn,code){await assert.rejects(fn,new RegExp(code));checks++;console.log('PASS rejected',code);}
const file=async f=>db.exec(await fs.readFile(path.join(root,f),'utf8'));
async function fileFails(f,code){
  let err=null;try{await file(f);}catch(e){err=e;}
  await db.exec('rollback');
  ok(err&&new RegExp(code).test(err.message),`${f} stops with ${code}`);
}
async function md5s(){return Object.fromEntries((await db.query(`select n.nspname||'.'||p.proname as name,md5(replace(p.prosrc,chr(13),'')) as hash from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','field_pilot_v1')`)).rows.map(x=>[x.name,x.hash]));}
async function verify(label){const v=await file('field_sql_v04_verify.sql');assert.ok(v[0].rows[0].ok,label+' '+JSON.stringify(v[0].rows[0].checks));ok(true,label);return v[1].rows[0].data_fingerprint;}
const P=n=>'c0000000-0000-0000-0000-000000000'+n;
const TEAM2='b0000000-0000-0000-0000-000000000002',TEAM3='b0000000-0000-0000-0000-000000000003';
const today=(await db.query("select field_pilot_v1.kst_today()::text as d")).rows[0].d;
const days=n=>{const x=new Date(today+'T00:00:00Z');x.setUTCDate(x.getUTCDate()+n);return x.toISOString().slice(0,10);};

// ---- 1. CHECK → APPLY → VERIFY → 되돌리기 → 재적용 ------------------------------------------
const v03=await md5s();
const pre=await file('field_sql_v04_check.sql');
ok(pre[0].rows[0].ready,'v04 CHECK ready '+JSON.stringify(pre[0].rows[0].checks));
const fp0=pre[1].rows[0].data_fingerprint;
await file('field_sql_v04.sql');
assert.deepEqual(await verify('v04 VERIFY ok after first apply'),fp0);ok(true,'v04 keeps data fingerprint (reports, tasks, photos, history, people, credentials)');
await fileFails('field_sql_v04.sql','already applied');
await file('field_sql_v04_rollback.sql');
const back=await md5s();
for(const f of ['field_pilot_v1.check_members','field_pilot_v1.replace_assignments','field_pilot_v1.report_json','public.tbm_task_result','public.tbm_site_overview','public.tbm_my_today'])
  assert.equal(back[f],v03[f],'rollback restores '+f);
ok(!back['public.tbm_task_stop']&&!back['public.tbm_attendance_save'],'rollback restores v03 functions byte-for-byte and drops new RPCs');
const again=await file('field_sql_v04_check.sql');
ok(again[0].rows[0].ready,'CHECK ready again after rollback');assert.deepEqual(again[1].rows[0].data_fingerprint,fp0);
await file('field_sql_v04.sql');
await verify('v04 VERIFY ok after re-apply');

// 타 팀원(시험삼팀원) 로그인 계정 (sql.mjs와 같은 방식의 가짜 계정)
await db.exec(`
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data) values('f0000000-0000-0000-0000-000000000051','member-c0000000-0000-0000-0000-000000000051@example.com',now(),'{"attendance_pilot":"v1","kind":"member_pin","person_id":"c0000000-0000-0000-0000-000000000051"}');
insert into personnel_pilot_v1.account_links values('f0000000-0000-0000-0000-000000000051','c0000000-0000-0000-0000-000000000051',true);
insert into personnel_pilot_v1.member_pins(person_id,pin_hash,pin_kind,must_change) values('c0000000-0000-0000-0000-000000000051',extensions.crypt('730519',extensions.gen_salt('bf',4)),'PERSONAL',false);
insert into auth.sessions(id,user_id) values('90000000-0000-0000-0000-000000000051','f0000000-0000-0000-0000-000000000051');`);
const as51=sql=>db.transaction(async tx=>{await tx.query("select set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:'f0000000-0000-0000-0000-000000000051',role:'authenticated',session_id:'90000000-0000-0000-0000-000000000051'})]);await tx.exec('set local role authenticated');return (await tx.query(sql)).rows;});

// ---- 2. 작업 인원: 같은 현장 전체 검색 · 타 팀원 투입 ----------------------------------------
const people=(await rpc('tbm_site_people')).people;
const ids=people.map(x=>x.person_id);
ok(ids.includes(P('051'))&&ids.includes(P('016'))&&ids.includes(P('026'))&&!ids.includes(P('028')),'site people: other teams included, inactive excluded');
ok(people[0].team_id===TEAM2&&people.find(x=>x.person_id===P('051')).team_name==='시험3팀','site people: own team first, official team shown');
await rejects(()=>rpc('tbm_site_people',{},'member'),'FORBIDDEN');
await rejects(()=>rpc('tbm_site_people',{},'manager'),'FORBIDDEN');
await rejects(()=>rpc('tbm_site_people',{},'anon'),'permission denied');

let r=(await rpc('tbm_today')).report;
ok(r.session_no===3&&r.morning_at&&!r.afternoon_at,'session 3 open after morning (from sql.mjs)');
const planOf=(r,extra)=>({request_id:'v04-'+Math.random(),report_id:r.id,version:r.version,end_time:'17:00',risks:['전기'],safety_note:'안전 v04',
  tasks:[...r.tasks.map(k=>({id:k.id,place:k.place,content:k.content,members:k.members.map(m=>({person_id:m.person_id,role:m.role}))})),...extra]});
await rejects(()=>rpc('tbm_save_plan',{p_payload:planOf(r,[{place:'퇴사자',content:'x',members:[{person_id:P('028'),role:'작업자'}]}])}),'MEMBER_NOT_AVAILABLE');
r=(await rpc('tbm_save_plan',{p_payload:planOf(r,[
  {place:'정지 종료',content:'정지 종료 작업',members:[{person_id:P('027'),role:'작업자'}]},
  {place:'타 팀',content:'타 팀원 투입 작업',members:[{person_id:P('051'),role:'작업자'},{person_id:P('036'),role:'신호수'}]},
  {place:'정상',content:'정상 작업',members:[]}])})).report;
const [tA,tB,tC,tD]=r.tasks;
ok(r.tasks.length===4,'plan saved with 4 tasks');
const m51=tC.members.find(m=>m.person_id===P('051')),m36=tC.members.find(m=>m.person_id===P('036'));
ok(m51.other_team===true&&m51.home_team_name==='시험3팀'&&m36.other_team===false&&m36.home_team_name==='공사2팀','other-team badge data: other_team + home_team_name');
ok((await db.query('select home_team_id from field_pilot_v1.task_assignments where task_id=$1 and person_id=$2',[tC.id,P('051')])).rows[0].home_team_id===TEAM3,'assignment keeps official team at assignment time');
ok((await db.query("select team_id from personnel_pilot_v1.memberships where person_id=$1 and valid_to is null",[P('051')])).rows[0].team_id===TEAM3,'official team unchanged by cross-team assignment');
await rejects(()=>rpc('tbm_save_plan',{p_payload:{request_id:'other-1',end_time:'17:00',risks:[],tasks:[{place:'삼팀',content:'중복',members:[{person_id:P('051'),role:'작업자'}]}]}},'other'),'MEMBER_ASSIGNED_ELSEWHERE');
const mine51=(await as51('select public.tbm_my_today() as v'))[0].v;
ok(mine51.tasks.length===1&&mine51.tasks[0].content==='타 팀원 투입 작업','other-team member sees assigned task on member screen');
ok((await rpc('tbm_today',{},'other')).locks.some(l=>l.person_id===P('051')),'other team leader sees the person as busy (locks)');

// ---- 3. 작업정지 ---------------------------------------------------------------------------
await rejects(()=>rpc('tbm_task_stop',{p_task_id:tA.id,p_reason:' ',p_disposition:'CARRY'}),'NOTE_REQUIRED');
await rejects(()=>rpc('tbm_task_stop',{p_task_id:tA.id,p_reason:'자재 미입고',p_disposition:'LATER'}),'INVALID_DISPOSITION');
await rejects(()=>rpc('tbm_task_stop',{p_task_id:tA.id,p_reason:'자재 미입고',p_disposition:'CARRY'},'member'),'FORBIDDEN');
await rejects(()=>rpc('tbm_task_stop',{p_task_id:tA.id,p_reason:'자재 미입고',p_disposition:'CARRY'},'other'),'REPORT_FORBIDDEN');
await rejects(()=>rpc('tbm_task_stop',{p_task_id:tA.id,p_reason:'자재 미입고',p_disposition:'CARRY'},'anon'),'permission denied');
let res=await rpc('tbm_task_stop',{p_task_id:tA.id,p_reason:'자재 미입고',p_disposition:'CARRY',p_action:'내일 오전 재개',p_request_id:'stop-a'});
let a1=res.report.tasks[0];
ok(a1.alert==='STOPPED'&&a1.result==='STOPPED'&&a1.alert_note==='자재 미입고'&&a1.alert_action==='내일 오전 재개'&&a1.carry_over&&a1.carry_status==='PENDING'&&a1.alert_at&&a1.result_at,'stop CARRY: reason, action, carryover PENDING, time kept');
ok(res.report.afternoon_at,'stop marks afternoon TBM started');
const ver=res.report.version;
res=await rpc('tbm_task_stop',{p_task_id:tA.id,p_reason:'자재 미입고',p_disposition:'CARRY',p_action:'내일 오전 재개'});
ok(res.replayed&&res.report.version===ver,'identical stop is a replay (no new version)');
res=await rpc('tbm_task_stop',{p_task_id:tB.id,p_reason:'우천',p_disposition:'END'});
let b1=res.report.tasks[1];
ok(b1.result==='STOPPED'&&!b1.carry_over&&b1.carry_status===null,'stop END: closed today without carryover');
res=await rpc('tbm_task_stop',{p_task_id:tB.id,p_reason:'우천 지속',p_disposition:'CARRY'});
ok(res.report.tasks[1].carry_over&&res.report.tasks[1].alert_at===b1.alert_at&&res.report.tasks[1].alert_note==='우천 지속','switch END→CARRY keeps first stop time');
res=await rpc('tbm_task_stop',{p_task_id:tB.id,p_reason:'우천 지속',p_disposition:'END'});
ok(!res.report.tasks[1].carry_over,'switch back CARRY→END');
res=await rpc('tbm_task_stop',{p_task_id:tC.id,p_reason:'잘못 누름',p_disposition:'END'});
res=await rpc('tbm_task_stop',{p_task_id:tC.id,p_reason:'',p_disposition:'CANCEL'});
const c1=res.report.tasks[2];
ok(c1.alert==='NONE'&&c1.result===null&&!c1.carry_over&&c1.alert_at===null,'CANCEL returns mistaken stop to before afternoon input');
await rejects(()=>rpc('tbm_task_result',{p_task_id:tA.id,p_result:'DONE'}),'TASK_STOPPED');
await rejects(()=>rpc('tbm_task_alert',{p_task_id:tA.id,p_alert:'NORMAL'}),'TASK_CLOSED');
const hist=(await db.query("select action,note from field_pilot_v1.workflow_history where entity_id=$1 order by id",[tA.id])).rows;
ok(hist.some(h=>h.action==='TASK_STOPPED'&&h.note==='자재 미입고 · 내일 이월'),'history TASK_STOPPED with reason and disposition');
ok((await db.query("select count(*)::int as n from field_pilot_v1.workflow_history where entity_id=$1 and action='TASK_STOP_CANCELLED'",[tC.id])).rows[0].n===1,'history keeps cancelled stop');

const mine=await rpc('tbm_my_today',{},'member');
const mA=mine.tasks.find(t=>t.content===tA.content&&t.sessionNo===3);
ok(mA.stopped&&mA.afternoonStatus==='작업정지'&&mA.eveningStatus==='작업정지 · 내일 이월','member screen shows 작업정지 · 내일 이월');
const ov=await rpc('tbm_site_overview',{},'manager');
const card=ov.teams.find(t=>t.team_id===TEAM2&&t.report?.session_no===3).report;
ok(card.alerts.STOPPED===2&&card.results.STOPPED===2&&card.results.OPEN===2,'manager card counts 작업정지');
ok(card.tasks.find(k=>k.task_no===1).alert_note==='자재 미입고'&&card.tasks.find(k=>k.task_no===4).alert_note===null,'manager sees stop reason only for stopped tasks');
const det=(await rpc('tbm_report_detail',{p_report_id:r.id},'manager')).report;
ok(det.tasks[0].alert_note==='자재 미입고'&&det.tasks[0].carry_over&&det.tasks[1].result==='STOPPED','manager detail shows reason and disposition');

res=await rpc('tbm_afternoon_all_clear',{p_report_id:r.id,p_note:'오후 v04'});
ok(res.report.tasks[0].alert==='STOPPED'&&res.report.tasks[1].alert==='STOPPED'&&res.report.tasks[2].alert==='NORMAL'&&res.report.tasks[3].alert==='NORMAL','afternoon all-clear leaves stopped tasks untouched');
r=await photo(res.report,'AFTERNOON','b');r=await photo(r,'EVENING','c');
await rpc('tbm_task_result',{p_task_id:tC.id,p_result:'DONE'});
await rejects(()=>rpc('tbm_evening_close',{p_report_id:r.id,p_note:'퇴근'}),'UNRESOLVED_TASKS: 1');
res=await rpc('tbm_task_result',{p_task_id:tD.id,p_result:'NOT_DONE',p_carry:false});
res=await rpc('tbm_evening_close',{p_report_id:r.id,p_note:'퇴근 v04'});
ok(res.report.evening_at&&res.report.tasks[0].result==='STOPPED'&&res.report.tasks[0].alert_note==='자재 미입고','evening close needs no re-entry for stopped tasks; reason kept');
ok(['AFTERNOON','EVENING'].every(k=>res.report.photos.some(p=>p.kind===k)),'photos kept');
await rejects(()=>rpc('tbm_task_stop',{p_task_id:tB.id,p_reason:'마감 후',p_disposition:'CARRY'}),'REPORT_NOT_EDITABLE');
await fileFails('field_sql_v04_rollback.sql','ROLLBACK_BLOCKED');
await verify('VERIFY still ok after blocked rollback');

// ---- 4. 출역 관리 --------------------------------------------------------------------------
const count=async()=>(await db.query('select (select count(*) from field_pilot_v1.attendance_records)::int as r,(select count(*) from field_pilot_v1.attendance_history)::int as h')).rows[0];
let at=await rpc('tbm_attendance_today');
ok(at.team.id===TEAM2&&at.people.map(p=>p.person_id).sort().join()===[P('025'),P('026'),P('027'),P('036')].sort().join()&&at.people.every(p=>p.check_in_status===null),'attendance: own official team only, inactive excluded');
ok((await count()).r===0,'opening attendance creates no records');
await rejects(()=>rpc('tbm_attendance_today',{},'member'),'FORBIDDEN');
await rejects(()=>rpc('tbm_attendance_today',{},'anon'),'permission denied');
const IN=(entries,extra={})=>({kind:'IN',request_id:'in-'+Math.random(),entries:entries.map(([n,s])=>({person_id:P(n),status:s})),...extra});
const OUT=(entries,extra={})=>({kind:'OUT',request_id:'out-'+Math.random(),entries:entries.map(([n,s])=>({person_id:P(n),status:s})),...extra});
await rejects(()=>rpc('tbm_attendance_save',{p_payload:IN([['051','PRESENT']])}),'MEMBER_NOT_IN_TEAM');
await rejects(()=>rpc('tbm_attendance_save',{p_payload:IN([['026','LEFT']])}),'INVALID_STATUS');
await rejects(()=>rpc('tbm_attendance_save',{p_payload:IN([['026','PRESENT'],['026','LATE']])}),'DUPLICATE_MEMBER');
await rejects(()=>rpc('tbm_attendance_save',{p_payload:{kind:'X',entries:[{person_id:P('026'),status:'PRESENT'}]}}),'INVALID_INPUT');
await rejects(()=>rpc('tbm_attendance_save',{p_payload:IN([])}),'INVALID_INPUT');
await rejects(()=>rpc('tbm_attendance_save',{p_payload:IN([['026','PRESENT']],{work_date:days(-1)})}),'ATTENDANCE_DATE_LOCKED');
await rejects(()=>rpc('tbm_attendance_save',{p_payload:OUT([['026','LEFT']])}),'ATTENDANCE_NOT_CHECKED_IN');
await rejects(()=>rpc('tbm_attendance_save',{p_payload:IN([['026','PRESENT']])},'member'),'FORBIDDEN');
await rejects(()=>rpc('tbm_attendance_save',{p_payload:IN([['026','PRESENT']])},'manager'),'FORBIDDEN');
await rejects(()=>rpc('tbm_attendance_save',{p_payload:IN([['026','PRESENT']],{team_id:TEAM2})},'other'),'TEAM_FORBIDDEN');
await rejects(()=>rpc('tbm_attendance_save',{p_payload:IN([['026','PRESENT']])},'anon'),'permission denied');
ok((await count()).r===0,'rejected saves leave no records');
const first=IN([['025','PRESENT'],['026','PRESENT'],['027','ABSENT'],['036','LATE']]);
res=await rpc('tbm_attendance_save',{p_payload:first});
ok(res.changed===4&&res.people.find(p=>p.person_id===P('027')).check_in_status==='ABSENT'&&res.people.every(p=>p.check_in_at&&p.check_in_role==='TEAM_LEADER'&&p.check_in_by),'check-in confirmed with status, time, who and role');
const c0=await count();
res=await rpc('tbm_attendance_save',{p_payload:first});
ok(res.replayed&&(await count()).h===c0.h,'same request is a replay (double tap safe)');
res=await rpc('tbm_attendance_save',{p_payload:IN([['025','PRESENT'],['026','PRESENT']])});
ok(res.changed===0&&(await count()).h===c0.h,'unchanged statuses write no history');
await rejects(()=>rpc('tbm_attendance_save',{p_payload:OUT([['027','LEFT']])}),'ATTENDANCE_NOT_CHECKED_IN');
const t27=res.people.find(p=>p.person_id===P('027')).check_in_at;
res=await rpc('tbm_attendance_save',{p_payload:IN([['027','LATE']])});
const p27=res.people.find(p=>p.person_id===P('027'));
ok(p27.check_in_status==='LATE'&&p27.check_in_at===t27&&p27.corrections===1,'correction keeps first time and counts history');
res=await rpc('tbm_attendance_save',{p_payload:OUT([['025','LEFT'],['026','EARLY'],['027','LEFT'],['036','NOT_LEFT']])});
ok(res.changed===4&&res.people.find(p=>p.person_id===P('026')).check_out_status==='EARLY','check-out confirmed (퇴근/조퇴/미퇴근)');
res=await rpc('tbm_attendance_save',{p_payload:IN([['026','ABSENT']])});
ok(res.people.find(p=>p.person_id===P('026')).check_out_status===null,'check-in corrected to 결근 clears check-out');
const h26=(await db.query("select h.action,h.before_data->>'check_out_status' as before_out,h.actor_role from field_pilot_v1.attendance_history h join field_pilot_v1.attendance_records r on r.id=h.attendance_id where r.person_id=$1 order by h.id",[P('026')])).rows;
ok(h26.map(h=>h.action).join()==='CHECK_IN,CHECK_OUT,CHECK_IN_CORRECT'&&h26[2].before_out==='EARLY','history keeps every input and the removed check-out');
await rejects(()=>as('leader','select * from field_pilot_v1.attendance_records'),'permission denied');
await rejects(()=>as('leader','select * from field_pilot_v1.attendance_history'),'permission denied');
await rejects(()=>as('anon','select * from field_pilot_v1.attendance_records'),'permission denied');
const at3=await rpc('tbm_attendance_today',{},'other');
ok(at3.team.id===TEAM3&&at3.people.length===2&&at3.people.every(p=>!p.check_in_status),'other leader sees only own team');
let mov=await rpc('tbm_attendance_overview',{},'manager');
const t2=mov.teams.find(t=>t.team_id===TEAM2);
ok(!mov.can_correct&&t2.people.length===4&&t2.people.some(p=>p.check_in_status==='LATE')&&mov.teams.some(t=>t.team_id===TEAM3),'site manager sees all teams (read only)');
await rejects(()=>rpc('tbm_attendance_overview',{p_date:days(-40)},'manager'),'ATTENDANCE_DATE_LOCKED');
await rejects(()=>rpc('tbm_attendance_overview',{},'leader'),'FORBIDDEN');
const aov=await rpc('tbm_attendance_overview',{},'admin');
ok(aov.can_correct,'admin overview can correct');
await rejects(()=>rpc('tbm_attendance_save',{p_payload:IN([['026','PRESENT']])},'admin'),'TEAM_FORBIDDEN');
await rejects(()=>rpc('tbm_attendance_save',{p_payload:IN([['026','PRESENT']],{team_id:TEAM2,work_date:days(-8)})},'admin'),'ATTENDANCE_DATE_LOCKED');
res=await rpc('tbm_attendance_save',{p_payload:IN([['026','PRESENT']],{team_id:TEAM2})},'admin');
const p26=res.people.find(p=>p.person_id===P('026'));
ok(p26.check_in_status==='PRESENT'&&p26.check_in_role==='ADMIN'&&p26.corrections===2,'admin correction recorded with ADMIN role');
res=await rpc('tbm_attendance_save',{p_payload:IN([['051','LATE']],{team_id:TEAM3,work_date:days(-3)})},'admin');
ok(res.date===days(-3)&&res.people.find(p=>p.person_id===P('051')).check_in_status==='LATE','admin can correct within 7 days');

// ---- 5. 다음 날 이월 (날짜를 하루 앞으로 옮겨 흉내) ------------------------------------------
await db.query("update field_pilot_v1.daily_reports set work_date=work_date-1 where team_id=$1 and work_date=field_pilot_v1.kst_today()",[TEAM2]);
let next=await rpc('tbm_today');
const cand=next.carry_candidates.filter(c=>c.result==='STOPPED');
ok(cand.length===1&&cand[0].task_id===tA.id&&cand[0].members.length===1,'next day: only stopped-and-carried task is a candidate (stopped END is not)');
next=(await rpc('tbm_save_plan',{p_payload:{request_id:'next-1',end_time:'17:00',risks:[],tasks:[{place:tA.place,content:tA.content,carried_from_task_id:tA.id,members:[{person_id:P('026'),role:'작업자'}]}]}})).report;
ok(next.tasks[0].carried_from_task_id===tA.id,'stopped task carried into next day');
ok((await db.query('select carry_status from field_pilot_v1.report_tasks where id=$1',[tA.id])).rows[0].carry_status==='CONTINUED','carry taken once (CONTINUED)');
await rejects(()=>rpc('tbm_save_plan',{p_payload:{request_id:'next-2',report_id:next.id,version:next.version,end_time:'17:00',risks:[],tasks:[{id:next.tasks[0].id,place:'a',content:'b',members:[]},{place:'x',content:'y',carried_from_task_id:tA.id,members:[]}]}}),'CARRY_NOT_AVAILABLE');
await verify('VERIFY ok at end');
console.log('V04 TESTS PASSED',checks);
await db.close();
