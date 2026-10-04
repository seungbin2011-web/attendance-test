import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
export const root=path.resolve(fileURLToPath(new URL('../../',import.meta.url)));
export const db=new PGlite({extensions:{pgcrypto}});
for(const file of ['tests/sql/00_mock_supabase.sql','tests/sql/01_mock_seed.sql','personnel_auth_v02.sql','personnel_auth_v08.sql','personnel_auth_v09.sql','tests/sql/02_fixture_e2e.sql','field_sql_v01.sql','field_sql_v02.sql','personnel_auth_v10.sql','personnel_auth_v11.sql','personnel_auth_v12.sql']) {
  await db.exec(await fs.readFile(path.join(root,file),'utf8')); console.log('loaded',file);
}
export const identities={leader:'d0000000-0000-0000-0000-0000000000a4',manager:'d0000000-0000-0000-0000-0000000000a2',admin:'d0000000-0000-0000-0000-0000000000a1',member:'f0000000-0000-0000-0000-000000000026',other:'f0000000-0000-0000-0000-000000000050'};
for(const n of ['026','050']) await db.exec(`
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data) values('f0000000-0000-0000-0000-000000000${n}','member-c0000000-0000-0000-0000-000000000${n}@example.com',now(),'{"attendance_pilot":"v1","kind":"member_pin","person_id":"c0000000-0000-0000-0000-000000000${n}"}');
insert into personnel_pilot_v1.account_links values('f0000000-0000-0000-0000-000000000${n}','c0000000-0000-0000-0000-000000000${n}',true);
insert into personnel_pilot_v1.member_pins(person_id,pin_hash,pin_kind,must_change) values('c0000000-0000-0000-0000-000000000${n}',extensions.crypt('730519',extensions.gen_salt('bf',4)),'PERSONAL',false);
insert into auth.sessions(id,user_id) values('90000000-0000-0000-0000-000000000${n}','f0000000-0000-0000-0000-000000000${n}');`);
export async function as(role,sql,params=[]) {return db.transaction(async tx=>{
  await tx.query("select set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:identities[role],role:'authenticated',session_id:role==='member'?'90000000-0000-0000-0000-000000000026':role==='other'?'90000000-0000-0000-0000-000000000050':undefined})]);
  await tx.exec('set local role '+(role==='anon'?'anon':'authenticated'));
  return (await tx.query(sql,params)).rows;
});}
export async function rpc(name,args={},role='leader') {assert.match(name,/^\w+$/);const keys=Object.keys(args);for(const k of keys) assert.match(k,/^\w+$/);return (await as(role,`select public.${name}(${keys.map((k,i)=>`${k} => $${i+1}`).join(',')}) as value`,Object.values(args).map(v=>v&&typeof v==='object'?JSON.stringify(v):v)))[0].value;}
let checks=0;
function ok(v,msg){assert.ok(v,msg);checks++; console.log('PASS',msg);}
async function rejects(fn,code){await assert.rejects(fn,new RegExp(code));checks++;console.log('PASS rejected',code);}
function plan(number,r){return {request_id:'plan-'+number,report_id:r?.id,version:r?.version,end_time:'17:00',risks:['전기'],safety_note:'안전 '+number,tasks:[{place:'위치 '+number,content:'내용 '+number,members:[{person_id:'c0000000-0000-0000-0000-000000000026',role:'작업자'}]}]};}
export async function photo(r,kind,digit){const p=await rpc('tbm_photo_prepare',{p_report_id:r.id,p_kind:kind,p_size:50,p_sha256:digit.repeat(64)});await as('leader',"insert into storage.objects(bucket_id,name,owner_id) values('tbm-photos',$1,$2)",[p.path,identities.leader]);const res=await rpc('tbm_photo_confirm',{p_attachment_id:p.attachment_id});return res.report;}
async function close(r,n){r=(await rpc('tbm_submit_morning',{p_report_id:r.id,p_note:'출근 '+n})).report;r=await photo(r,'MORNING',String(n));r=(await rpc('tbm_afternoon_all_clear',{p_report_id:r.id,p_note:'오후 '+n})).report;r=await photo(r,'AFTERNOON',String(n+3));r=await photo(r,'EVENING',String(n+6));return (await rpc('tbm_evening_close',{p_report_id:r.id,p_note:'퇴근 '+n,p_complete_rest:true})).report;}
async function snapshot(id){const q=await db.query(`select jsonb_build_object('report',to_jsonb(r)-'session_no','tasks',(select jsonb_agg(to_jsonb(t) order by t.id) from field_pilot_v1.report_tasks t where report_id=r.id),'photos',(select jsonb_agg(to_jsonb(p) order by p.id) from field_pilot_v1.attachments p where report_id=r.id),'history',(select jsonb_agg(to_jsonb(h) order by h.id) from field_pilot_v1.workflow_history h where report_id=r.id),'assignments',(select jsonb_agg(to_jsonb(a) order by a.task_id,a.person_id) from field_pilot_v1.task_assignments a join field_pilot_v1.report_tasks t on t.id=a.task_id where t.report_id=r.id)) as value from field_pilot_v1.daily_reports r where id=$1`,[id]);return q.rows[0].value;}
let one=(await rpc('tbm_save_plan',{p_payload:plan(1)})).report;
one=await close(one,1);
const pending=await db.query("insert into field_pilot_v1.attachments(report_id,kind,object_path,size_bytes,sha256,uploaded_by_auth_user_id) values($1,'MORNING','test-pending.jpg',50,repeat('a',64),$2) returning id",[one.id,identities.leader]);
const original=await snapshot(one.id);
ok((await db.exec(await fs.readFile(path.join(root,'field_sql_v03_check.sql'),'utf8')))[0].rows[0].ready,'preflight ready');
await db.exec(await fs.readFile(path.join(root,'field_sql_v03.sql'),'utf8'));
ok((await db.exec(await fs.readFile(path.join(root,'field_sql_v03_verify.sql'),'utf8')))[0].rows[0].ok,'verify ok');
assert.deepEqual(await snapshot(one.id),original);ok(true,'migration preserves every existing field and UUID');
one=(await rpc('tbm_today')).report;ok(one.session_no===1&&one.evening_at,'A: original completed report is session 1');
// All public mutation paths must enforce the same completed-report lock.
for(const [name,args] of [
 ['tbm_save_plan',{p_payload:plan(99,one)}],['tbm_submit_morning',{p_report_id:one.id}],['tbm_afternoon_all_clear',{p_report_id:one.id}],['tbm_task_alert',{p_task_id:one.tasks[0].id,p_alert:'RISK',p_note:'시험 위험'}],['tbm_task_result',{p_task_id:one.tasks[0].id,p_result:'NOT_DONE'}],['tbm_evening_close',{p_report_id:one.id}],['tbm_photo_prepare',{p_report_id:one.id,p_kind:'MORNING',p_size:50,p_sha256:'a'.repeat(64)}],['tbm_photo_remove',{p_attachment_id:one.photos[0].id}],['tbm_photo_confirm',{p_attachment_id:one.photos[0].id}]]) await rejects(()=>rpc(name,args),'REPORT_NOT_EDITABLE');
await rejects(()=>as('leader',"insert into storage.objects(bucket_id,name) values('tbm-photos','test-pending.jpg')"),'row-level security');
await rejects(()=>rpc('tbm_photo_confirm',{p_attachment_id:pending.rows[0].id}),'REPORT_NOT_EDITABLE');
const beforeNext=await snapshot(one.id);
export let two=(await rpc('tbm_open_next',{p_previous_report_id:one.id})).report;
ok(two.session_no===2&&two.id!==one.id&&!two.morning_at&&!two.evening_at&&two.tasks.length===0&&two.photos.length===0&&!two.safety_note,'B: new independent empty session');
await rejects(()=>rpc('tbm_submit_morning',{p_report_id:two.id}),'TASKS_REQUIRED');
const replay=await Promise.all(Array.from({length:4},()=>rpc('tbm_open_next',{p_previous_report_id:one.id})));
ok(replay.every(x=>x.report.id===two.id),'duplicate requests return same next UUID');
await rejects(()=>rpc('tbm_open_next',{p_previous_report_id:two.id}),'SESSION_NOT_CLOSED');
await rejects(()=>rpc('tbm_open_next',{p_previous_report_id:one.id},'member'),'FORBIDDEN');
await rejects(()=>rpc('tbm_open_next',{p_previous_report_id:one.id},'other'),'TEAM_FORBIDDEN');
await rejects(()=>rpc('tbm_open_next',{p_previous_report_id:one.id},'anon'),'permission denied');
const stale=plan(98,one);delete stale.report_id;await rejects(()=>rpc('tbm_save_plan',{p_payload:stale}),'REPORT_NOT_EDITABLE');
two=(await rpc('tbm_save_plan',{p_payload:plan(2,two)})).report;
let mine=await rpc('tbm_my_today',{},'member');ok(mine.tasks.length===2&&mine.tasks[0].sessionNo===2&&!mine.tasks[0].completed&&mine.tasks[1].completed,'MEMBER latest active above completed');
two=await close(two,2);assert.deepEqual(await snapshot(one.id),beforeNext);ok(true,'C: second workflow and photos leave first byte-for-byte unchanged');
const second=await snapshot(two.id);
export let three=(await rpc('tbm_open_next',{p_previous_report_id:two.id})).report;
three=(await rpc('tbm_save_plan',{p_payload:plan(3,three)})).report;
three=(await rpc('tbm_submit_morning',{p_report_id:three.id,p_note:'출근 3'})).report;
ok(three.session_no===3&&new Set([one.id,two.id,three.id]).size===3,'D: no two-session limit, separate UUIDs');
assert.deepEqual(await snapshot(two.id),second);assert.deepEqual(await snapshot(one.id),beforeNext);
const refresh=await rpc('tbm_today');ok(refresh.report.id===three.id&&refresh.reports.length===3,'E: fresh request restores current session and full list');
const overview=await rpc('tbm_site_overview',{},'manager');ok(overview.teams.filter(t=>t.report).map(t=>t.report.session_no).join(',')==='3,2,1','F: manager sees three separate reports');
for(const r of [one,two,three])ok((await rpc('tbm_report_detail',{p_report_id:r.id},'manager')).report.id===r.id,'manager detail stable '+r.session_no);
mine=await rpc('tbm_my_today',{},'member');ok(mine.tasks[0].sessionNo===3&&mine.tasks.filter(t=>t.completed).length===2,'member current session3 with completed history');
ok((await rpc('tbm_my_today',{},'other')).tasks.length===0,'member assignments cannot leak to other person');
console.log('SQL SESSION TESTS PASSED',checks);
export {one};
if(process.env.KEEP_DB!=='1')await db.close();
