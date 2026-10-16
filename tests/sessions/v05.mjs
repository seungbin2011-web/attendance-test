// field v0.5 (이월 취소) 로컬 시험. 실제 Supabase에 연결하지 않는다.
// sql.mjs(v03) 위에 v04를 적용한 흉내 DB에서 CHECK → APPLY → VERIFY → 되돌리기 → 재적용 후 이월 취소를 확인한다.
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
process.env.KEEP_DB='1';
const {root,db,rpc}=await import('./sql.mjs');
let checks=0;
function ok(v,msg){assert.ok(v,msg);checks++;console.log('PASS',msg);}
async function rejects(fn,code){await assert.rejects(fn,new RegExp(code));checks++;console.log('PASS rejected',code);}
const file=async f=>db.exec(await fs.readFile(path.join(root,f),'utf8'));
async function verify(label){const v=await file('field_sql_v05_verify.sql');assert.ok(v[0].rows[0].ok,label+' '+JSON.stringify(v[0].rows[0].checks));ok(true,label);return v[1].rows[0].data_fingerprint;}
const P=n=>'c0000000-0000-0000-0000-000000000'+n;
const TEAM2='b0000000-0000-0000-0000-000000000002';

assert.ok((await file('field_sql_v04_check.sql'))[0].rows[0].ready);
await file('field_sql_v04.sql');
assert.ok((await file('field_sql_v04_verify.sql'))[0].rows[0].ok);

// ---- 1. CHECK → APPLY → VERIFY → 되돌리기 → 재적용 ----
const pre=await file('field_sql_v05_check.sql');
ok(pre[0].rows[0].ready,'v05 CHECK ready '+JSON.stringify(pre[0].rows[0].checks));
const fp0=pre[1].rows[0].data_fingerprint;
await file('field_sql_v05.sql');
assert.deepEqual(await verify('v05 VERIFY ok'),fp0);ok(true,'v05 keeps data fingerprint');
let err=null;try{await file('field_sql_v05.sql');}catch(e){err=e;}await db.exec('rollback');
ok(err&&/already applied/.test(err.message),'v05 cannot be applied twice');
await file('field_sql_v05_rollback.sql');
ok((await db.query("select to_regprocedure('public.tbm_carry_cancel(uuid,text,text)') is null as gone")).rows[0].gone,'rollback drops only the new RPC');
assert.ok((await file('field_sql_v05_check.sql'))[0].rows[0].ready);
await file('field_sql_v05.sql');
await verify('v05 VERIFY ok after re-apply');

// ---- 2. 어제 작업 만들기 (작업 3: 미완료 이월 · 일부완료 이월 · 미완료 이월 · 완료) ----
let r=(await rpc('tbm_today')).report;
r=(await rpc('tbm_save_plan',{p_payload:{request_id:'v05-plan',report_id:r.id,version:r.version,end_time:'17:00',risks:[],tasks:[
  {id:r.tasks[0].id,place:r.tasks[0].place,content:r.tasks[0].content,members:r.tasks[0].members.map(m=>({person_id:m.person_id,role:m.role}))},
  {place:'B동',content:'배관',members:[{person_id:P('027'),role:'작업자'}]},
  {place:'C동',content:'케이블',members:[{person_id:P('036'),role:'작업자'}]},
  {place:'D동',content:'정리',members:[]}]}})).report;
const [y1,y2,y3,y4]=r.tasks;
await rpc('tbm_task_result',{p_task_id:y1.id,p_result:'NOT_DONE',p_carry:true,p_note:'자재 없음'});
await rpc('tbm_task_result',{p_task_id:y2.id,p_result:'PARTIAL',p_carry:true,p_note:'절반'});
await rpc('tbm_task_result',{p_task_id:y3.id,p_result:'NOT_DONE',p_carry:true,p_note:'시간 부족'});
await rpc('tbm_evening_close',{p_report_id:r.id,p_complete_rest:true});
await db.query("update field_pilot_v1.daily_reports set work_date=work_date-1 where team_id=$1 and work_date=field_pilot_v1.kst_today()",[TEAM2]);
const yesterday=async()=>(await db.query(`select to_jsonb(r) as report,(select jsonb_agg(to_jsonb(k)-'carry_status'-'updated_at' order by k.task_no) from field_pilot_v1.report_tasks k where k.report_id=r.id) as tasks from field_pilot_v1.daily_reports r where id=$1`,[r.id])).rows[0];
const before=await yesterday();
let today=await rpc('tbm_today');
ok(today.report===null&&today.carry_candidates.length===3,'next day: 3 carry candidates');

// ---- 3. 아직 이어받지 않은 후보 취소 ----
await rejects(()=>rpc('tbm_carry_cancel',{p_task_id:y1.id,p_reason:' '}),'NOTE_REQUIRED');
await rejects(()=>rpc('tbm_carry_cancel',{p_task_id:y1.id,p_reason:'잘못 이월'},'member'),'FORBIDDEN');
await rejects(()=>rpc('tbm_carry_cancel',{p_task_id:y1.id,p_reason:'잘못 이월'},'other'),'TEAM_FORBIDDEN');
await rejects(()=>rpc('tbm_carry_cancel',{p_task_id:y1.id,p_reason:'잘못 이월'},'anon'),'permission denied');
let res=await rpc('tbm_carry_cancel',{p_task_id:y1.id,p_reason:'잘못 이월 처리함',p_request_id:'cc-1'});
ok(res.mode==='CANDIDATE','candidate cancel');
ok((await db.query('select carry_status from field_pilot_v1.report_tasks where id=$1',[y1.id])).rows[0].carry_status==='DROPPED','candidate becomes DROPPED (not deleted)');
const h1=(await db.query("select report_id,note,actor_label,before_data,after_data from field_pilot_v1.workflow_history where entity_id=$1 and action='CARRY_CANCELLED'",[y1.id])).rows;
ok(h1.length===1&&h1[0].report_id===r.id&&h1[0].note==='잘못 이월 처리함'&&h1[0].actor_label&&h1[0].before_data.carry_status==='PENDING','history: who, when, which task, reason on the original report');
res=await rpc('tbm_carry_cancel',{p_task_id:y1.id,p_reason:'잘못 이월 처리함'});
ok(res.replayed,'cancel again is a replay');
today=await rpc('tbm_today');
ok(today.carry_candidates.map(c=>c.task_id).sort().join()===[y2.id,y3.id].sort().join(),'cancelled candidate no longer offered');
await rejects(()=>rpc('tbm_carry_cancel',{p_task_id:y4.id,p_reason:'완료 작업'}),'CARRY_NOT_AVAILABLE');

// ---- 4. 오늘 이어받은 작업 취소 ----
let t=(await rpc('tbm_save_plan',{p_payload:{request_id:'v05-today',end_time:'17:00',risks:[],tasks:[
  {place:'B동',content:'배관',carried_from_task_id:y2.id,members:[{person_id:P('027'),role:'작업자'}]},
  {place:'C동',content:'케이블',carried_from_task_id:y3.id,members:[{person_id:P('036'),role:'작업자'}]},
  {place:'새 작업',content:'오늘 신규',members:[{person_id:P('026'),role:'작업자'}]}]}})).report;
const [c2,c3,n1]=t.tasks;
ok(c2.carried_from_task_id===y2.id&&(await db.query('select carry_status from field_pilot_v1.report_tasks where id=$1',[y2.id])).rows[0].carry_status==='CONTINUED','carry taken today (CONTINUED)');
await rejects(()=>rpc('tbm_carry_cancel',{p_task_id:n1.id,p_reason:'신규 작업'}),'CARRY_NOT_AVAILABLE');
await rejects(()=>rpc('tbm_carry_cancel',{p_task_id:c2.id,p_reason:'다른 팀'},'other'),'REPORT_FORBIDDEN');
const v0=t.version;
res=await rpc('tbm_carry_cancel',{p_task_id:c2.id,p_reason:'전일 작업 이미 끝남'});
ok(res.mode==='TODAY'&&res.report.tasks.length===2&&!res.report.tasks.some(k=>k.id===c2.id)&&res.report.version===v0+1,'today carried task removed from today plan (version+1)');
const rows=(await db.query('select is_active,(select carry_status from field_pilot_v1.report_tasks where id=$2) as src from field_pilot_v1.report_tasks where id=$1',[c2.id,y2.id])).rows[0];
ok(rows.is_active===false&&rows.src==='DROPPED','today row kept (inactive), original DROPPED so it is not offered again');
const h2=(await db.query("select report_id,note from field_pilot_v1.workflow_history where action='CARRY_CANCELLED' and entity_id in ($1,$2) order by id",[c2.id,y2.id])).rows;
ok(h2.length===2&&h2.every(h=>h.note==='전일 작업 이미 끝남')&&new Set(h2.map(h=>h.report_id)).size===2,'history on both today and original report');
ok((await rpc('tbm_carry_cancel',{p_task_id:c2.id,p_reason:'전일 작업 이미 끝남'})).replayed,'today cancel again is a replay');
ok((await rpc('tbm_today')).carry_candidates.length===0,'no candidates left');
// 결과가 난 이어받은 작업은 취소하지 않는다
t=(await rpc('tbm_submit_morning',{p_report_id:t.id})).report;
await rpc('tbm_task_result',{p_task_id:c3.id,p_result:'DONE'});
await rejects(()=>rpc('tbm_carry_cancel',{p_task_id:c3.id,p_reason:'이미 완료'}),'TASK_CLOSED');
// 어제 기록은 이월 상태 말고는 그대로
const after=await yesterday();
assert.deepEqual(after.report,before.report);assert.deepEqual(after.tasks,before.tasks);
ok(true,'yesterday report and results unchanged (only carry_status)');
// 오늘 계획을 다시 저장해도 취소된 작업은 돌아오지 않는다
const today2=(await rpc('tbm_today')).report;
const re=(await rpc('tbm_save_plan',{p_payload:{request_id:'v05-again',report_id:today2.id,version:today2.version,end_time:'17:00',risks:[],tasks:today2.tasks.map(k=>({id:k.id,place:k.place,content:k.content,members:k.members.map(m=>({person_id:m.person_id,role:m.role}))}))}})).report;
ok(re.tasks.length===2&&(await db.query('select carry_status from field_pilot_v1.report_tasks where id=$1',[y2.id])).rows[0].carry_status==='DROPPED','re-saving plan keeps the cancellation');
// 되돌려도 데이터는 남는다
await file('field_sql_v05_rollback.sql');
ok((await db.query("select count(*)::int as n from field_pilot_v1.workflow_history where action='CARRY_CANCELLED'")).rows[0].n===3,'rollback keeps cancel history');
await file('field_sql_v05.sql');
await verify('VERIFY ok at end');
console.log('V05 TESTS PASSED',checks);
await db.close();
