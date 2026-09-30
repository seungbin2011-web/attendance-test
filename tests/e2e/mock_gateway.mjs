// 로컬 시험 전용 Supabase 흉내 게이트웨이 (실제 Supabase에 연결하지 않음)
// - 정적 파일: 저장소 루트를 그대로 제공 (/tbm_report_test.html 등)
// - /sb/rest/v1/rpc/*   : 로컬 Postgres의 실제 SQL 함수를 해당 역할(anon/authenticated/service_role)로 실행
// - /sb/auth/v1/*       : 업무계정 비밀번호 로그인, 토큰 갱신, 로그아웃, 관리자 API(사용자 생성·링크 생성), verify
// - /sb/storage/v1/*    : 업로드·서명 링크 (storage.objects RLS 정책을 실제로 거친다)
// - /sb/functions/v1/member-login : 저장소의 실제 Edge Function 코드를 Deno 흉내로 실행
// - /__test/*           : 시험 준비용 (임시 PIN 발급 등, 로컬 전용)
// 실행: node --experimental-strip-types --import ./npm_specifier_hooks_register.mjs mock_gateway.mjs
import http from 'node:http';
import crypto from 'node:crypto';
import path from 'node:path';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import pg from 'pg';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '../..');
const PORT = Number(process.env.PORT || 8787);
const BASE = `http://127.0.0.1:${PORT}`;
export const SERVICE_KEY = 'sb_secret_mock_local_only';
export const PUBLISHABLE_KEY = 'sb_publishable_Ui2gOfJoBOvtN4mWwN5Paw_tjvSdxJs'; // 저장소에 이미 공개된 publishable 키와 같은 값 (흉내용)
export const WORK_PASSWORD = 'pilot-test-pass'; // 흉내 DB의 업무계정 공통 비밀번호 (로컬 전용)
const STORAGE_DIR = path.join(HERE, 'artifacts', 'storage');

const pool = new pg.Pool({
  host: '127.0.0.1', port: 5432, user: 'e2e_gateway', password: 'e2e-local-only',
  database: process.env.TEST_DB || 'attendance_e2e', max: 8,
});

const refreshTokens = new Map(); // refresh_token -> { user_id, session_id }
const linkTokens = new Map();    // hashed_token -> { user_id, expires }
const signTokens = new Map();    // token -> { bucket, name, expires }
const fnCache = new Map();
let edgeHandler = null;

function b64url(obj) { return Buffer.from(JSON.stringify(obj)).toString('base64url'); }
function makeAccessToken(userId, sessionId) {
  return `mock.${b64url({ sub: userId, role: 'authenticated', session_id: sessionId, exp: Math.floor(Date.now() / 1000) + 3600 })}.local`;
}
function readToken(token) {
  if (!token || !token.startsWith('mock.')) return null;
  try { return JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()); } catch { return null; }
}
// 요청의 역할 판단: 사용자 토큰 > 비밀키 > 공개키
function requestRole(req) {
  const bearer = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  const claims = readToken(bearer);
  if (claims) return { role: 'authenticated', claims };
  if (bearer === SERVICE_KEY || req.headers.apikey === SERVICE_KEY) return { role: 'service_role', claims: { role: 'service_role' } };
  return { role: 'anon', claims: { role: 'anon' } };
}

async function withRole(role, claims, fn) {
  const client = await pool.connect();
  try {
    await client.query('begin');
    await client.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify(claims)]);
    if (!['anon', 'authenticated', 'service_role'].includes(role)) throw new Error('bad role');
    await client.query(`set local role ${role}`);
    const result = await fn(client);
    await client.query('commit');
    return result;
  } catch (e) {
    await client.query('rollback').catch(() => {});
    throw e;
  } finally { client.release(); }
}
async function asAdmin(sql, params = []) { return pool.query(sql, params); }

function send(res, status, body, headers = {}) {
  const isBuffer = Buffer.isBuffer(body);
  res.writeHead(status, { 'Content-Type': isBuffer ? headers['Content-Type'] || 'application/octet-stream' : 'application/json', 'Access-Control-Allow-Origin': '*', ...headers });
  res.end(isBuffer ? body : body === undefined ? '' : JSON.stringify(body));
}
// PostgREST의 오류 코드 → HTTP 상태 대응을 흉내 낸다 (화면은 상태가 아니라 message의 코드로 판단)
function pgError(res, e, role) {
  const c = String(e.code || '');
  const status = c === '42501' ? (role === 'anon' ? 401 : 403)
    : c === '42883' || c === '42P01' ? 404
    : c === '23503' || c === '23505' ? 409
    : c === 'P0001' ? 400
    : /^(40|P0|XX|25|55|57|58)/.test(c) ? 500
    : 400;
  send(res, status, { code: e.code, message: e.message, details: null, hint: null });
}
async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks);
}
function userJson(row) {
  return { id: row.id, aud: 'authenticated', role: 'authenticated', email: row.email, email_confirmed_at: row.email_confirmed_at,
    app_metadata: row.raw_app_meta_data || {}, user_metadata: row.raw_user_meta_data || {}, created_at: row.created_at };
}
async function newSession(userId) {
  const { rows } = await asAdmin('insert into auth.sessions(user_id) values ($1) returning id', [userId]);
  const sessionId = rows[0].id;
  const refresh = crypto.randomBytes(24).toString('hex');
  refreshTokens.set(refresh, { user_id: userId, session_id: sessionId });
  const user = (await asAdmin('select * from auth.users where id = $1', [userId])).rows[0];
  await asAdmin('update auth.users set last_sign_in_at = now() where id = $1', [userId]);
  return { access_token: makeAccessToken(userId, sessionId), token_type: 'bearer', expires_in: 3600,
    expires_at: Math.floor(Date.now() / 1000) + 3600, refresh_token: refresh, user: userJson(user) };
}

// ---------- REST RPC ----------
async function rpc(req, res, fnName, bodyBuf) {
  const { role, claims } = requestRole(req);
  let args = {};
  try { args = bodyBuf.length ? JSON.parse(bodyBuf.toString()) : {}; } catch { return send(res, 400, { message: 'bad json' }); }
  let meta = fnCache.get(fnName);
  if (!meta) {
    const { rows } = await asAdmin(`select p.proargnames as names, array(select format_type(t, null) from unnest(p.proargtypes) t) as types,
      p.proretset as retset, format_type(p.prorettype, null) as rettype
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = $1`, [fnName]);
    if (!rows.length) return send(res, 404, { code: 'PGRST202', message: `function public.${fnName} not found` });
    meta = rows[0]; fnCache.set(fnName, meta);
  }
  const params = []; const parts = [];
  (meta.names || []).slice(0, meta.types.length).forEach((name, i) => {
    if (!(name in args)) return;
    const type = meta.types[i];
    let value = args[name];
    if (type === 'jsonb' || type === 'json') value = JSON.stringify(value);
    params.push(value);
    parts.push(`${name} => $${params.length}::${type}`);
  });
  const call = `public.${fnName}(${parts.join(', ')})`;
  const sql = meta.retset || meta.rettype === 'record' ? `select coalesce(json_agg(t), '[]') as r from ${call} t` : `select to_json(${call}) as r`;
  try {
    const out = await withRole(role, claims, client => client.query(sql, params));
    send(res, 200, out.rows[0].r);
  } catch (e) { pgError(res, e, role); }
}

// ---------- AUTH ----------
async function auth(req, res, sub, url, bodyBuf) {
  const body = bodyBuf.length ? JSON.parse(bodyBuf.toString()) : {};
  const isService = requestRole(req).role === 'service_role';
  if (sub === 'token' && url.searchParams.get('grant_type') === 'password') {
    const { rows } = await asAdmin(`select u.* from auth.users u join personnel_pilot_v1.login_profiles lp on lp.auth_user_id = u.id where u.email = $1`, [body.email]);
    if (!rows.length || body.password !== WORK_PASSWORD) return send(res, 400, { error: 'invalid_grant', error_description: 'Invalid login credentials', msg: 'Invalid login credentials' });
    return send(res, 200, await newSession(rows[0].id));
  }
  if (sub === 'token' && url.searchParams.get('grant_type') === 'refresh_token') {
    const found = refreshTokens.get(body.refresh_token);
    if (!found) return send(res, 400, { error: 'invalid_grant', msg: 'Invalid Refresh Token' });
    const alive = await asAdmin('select 1 from auth.sessions where id = $1', [found.session_id]);
    if (!alive.rowCount) return send(res, 400, { error: 'invalid_grant', msg: 'Session not found' });
    refreshTokens.delete(body.refresh_token);
    const refresh = crypto.randomBytes(24).toString('hex');
    refreshTokens.set(refresh, found);
    return send(res, 200, { access_token: makeAccessToken(found.user_id, found.session_id), token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, refresh_token: refresh });
  }
  if (sub === 'logout') {
    const claims = readToken((req.headers.authorization || '').replace(/^Bearer\s+/i, ''));
    if (claims?.session_id) await asAdmin('delete from auth.sessions where id = $1', [claims.session_id]);
    return send(res, 204, undefined);
  }
  if (sub === 'admin/users' && req.method === 'POST') {
    if (!isService) return send(res, 401, { msg: 'service key required' });
    const exists = await asAdmin('select 1 from auth.users where email = $1', [body.email]);
    if (exists.rowCount) return send(res, 422, { code: 'email_exists', msg: 'A user with this email address has already been registered' });
    const { rows } = await asAdmin(`insert into auth.users(email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data)
      values ($1, case when $2 then now() end, $3::jsonb, $4::jsonb) returning *`,
      [body.email, body.email_confirm === true, JSON.stringify({ provider: 'email', providers: ['email'], ...(body.app_metadata || {}) }), JSON.stringify(body.user_metadata || {})]);
    return send(res, 200, userJson(rows[0]));
  }
  if (sub === 'admin/users' && req.method === 'GET') {
    if (!isService) return send(res, 401, { msg: 'service key required' });
    const page = Number(url.searchParams.get('page') || 1), per = Number(url.searchParams.get('per_page') || 50);
    const { rows } = await asAdmin('select * from auth.users order by created_at limit $1 offset $2', [per, (page - 1) * per]);
    return send(res, 200, { users: rows.map(userJson), aud: 'authenticated' });
  }
  if (sub === 'admin/generate_link') {
    if (!isService) return send(res, 401, { msg: 'service key required' });
    const { rows } = await asAdmin('select * from auth.users where email = $1', [body.email]);
    if (!rows.length) return send(res, 404, { msg: 'User not found' });
    const hashed = crypto.createHash('sha256').update(crypto.randomBytes(16)).digest('hex');
    linkTokens.set(hashed, { user_id: rows[0].id, expires: Date.now() + 60_000 });
    return send(res, 200, { ...userJson(rows[0]), action_link: `${BASE}/sb/auth/v1/verify?token=${hashed}&type=magiclink`, email_otp: '000000', hashed_token: hashed, redirect_to: '', verification_type: 'magiclink' });
  }
  if (sub === 'verify') {
    const found = linkTokens.get(body.token_hash);
    linkTokens.delete(body.token_hash);
    if (!found || found.expires < Date.now() || !['email', 'magiclink'].includes(body.type)) return send(res, 403, { code: 'otp_expired', msg: 'Token has expired or is invalid' });
    return send(res, 200, await newSession(found.user_id));
  }
  return send(res, 404, { msg: `auth ${sub} not mocked` });
}

// ---------- STORAGE ----------
async function storage(req, res, sub, bodyBuf) {
  const { role, claims } = requestRole(req);
  let m;
  if (req.method === 'POST' && (m = sub.match(/^object\/sign\/([^/]+)\/(.+)$/))) {
    const [, bucket, name] = m; const body = JSON.parse(bodyBuf.toString() || '{}');
    const visible = await withRole(role, claims, c => c.query('select 1 from storage.objects where bucket_id = $1 and name = $2', [bucket, decodeURIComponent(name)]));
    if (!visible.rowCount) return send(res, 400, { statusCode: '404', error: 'not_found', message: 'Object not found' });
    const token = crypto.randomBytes(16).toString('hex');
    signTokens.set(token, { bucket, name: decodeURIComponent(name), expires: Date.now() + (body.expiresIn || 60) * 1000 });
    return send(res, 200, { signedURL: `/object/sign/${bucket}/${name}?token=${token}` });
  }
  if (req.method === 'POST' && (m = sub.match(/^object\/sign\/([^/]+)$/))) {
    const [, bucket] = m; const body = JSON.parse(bodyBuf.toString() || '{}');
    const out = [];
    for (const name of body.paths || []) {
      const visible = await withRole(role, claims, c => c.query('select 1 from storage.objects where bucket_id = $1 and name = $2', [bucket, name]));
      if (!visible.rowCount) { out.push({ path: name, signedURL: null, error: 'Either the object does not exist or you do not have access to it' }); continue; }
      const token = crypto.randomBytes(16).toString('hex');
      signTokens.set(token, { bucket, name, expires: Date.now() + (body.expiresIn || 60) * 1000 });
      out.push({ path: name, signedURL: `/object/sign/${bucket}/${encodeURI(name)}?token=${token}`, error: null });
    }
    return send(res, 200, out);
  }
  if (req.method === 'GET' && (m = sub.match(/^object\/sign\/([^/]+)\/([^?]+)$/))) {
    const token = new URL(req.url, BASE).searchParams.get('token');
    const found = signTokens.get(token);
    if (!found || found.expires < Date.now()) return send(res, 400, { statusCode: '400', error: 'InvalidJWT', message: 'invalid signature' });
    try { return send(res, 200, await readFile(path.join(STORAGE_DIR, found.bucket, found.name)), { 'Content-Type': 'image/jpeg' }); }
    catch { return send(res, 404, { message: 'not found' }); }
  }
  if (req.method === 'POST' && (m = sub.match(/^object\/([^/]+)\/(.+)$/))) {
    const [, bucket, rawName] = m; const name = decodeURIComponent(rawName);
    const b = (await asAdmin('select * from storage.buckets where id = $1', [bucket])).rows[0];
    if (!b) return send(res, 400, { statusCode: '404', error: 'Bucket not found', message: 'Bucket not found' });
    const type = (req.headers['content-type'] || '').split(';')[0];
    if (b.allowed_mime_types && !b.allowed_mime_types.includes(type)) return send(res, 400, { statusCode: '415', error: 'invalid_mime_type', message: `mime type ${type} is not supported` });
    if (b.file_size_limit && bodyBuf.length > Number(b.file_size_limit)) return send(res, 400, { statusCode: '413', error: 'Payload too large', message: 'The object exceeded the maximum allowed size' });
    try {
      await withRole(role, claims, c => c.query('insert into storage.objects(bucket_id, name, owner, owner_id, metadata) values ($1, $2, $3, $4, $5)',
        [bucket, name, claims.sub || null, claims.sub || null, JSON.stringify({ mimetype: type, size: bodyBuf.length })]));
    } catch (e) {
      if (e.code === '23505') return send(res, 400, { statusCode: '409', error: 'Duplicate', message: 'The resource already exists' });
      return send(res, 400, { statusCode: '403', error: 'Unauthorized', message: 'new row violates row-level security policy' });
    }
    const file = path.join(STORAGE_DIR, bucket, name);
    await mkdir(path.dirname(file), { recursive: true });
    await writeFile(file, bodyBuf);
    return send(res, 200, { Key: `${bucket}/${name}`, Id: crypto.randomUUID() });
  }
  return send(res, 404, { message: `storage ${req.method} ${sub} not mocked` });
}

// ---------- FUNCTIONS (실제 Edge Function 코드 실행) ----------
async function loadEdgeFunction() {
  process.env.SUPABASE_URL = `${BASE}/sb`;
  process.env.SUPABASE_SECRET_KEYS = JSON.stringify({ default: SERVICE_KEY });
  process.env.SUPABASE_PUBLISHABLE_KEYS = JSON.stringify({ default: PUBLISHABLE_KEY });
  process.env.MEMBER_LOGIN_ALLOWED_ORIGINS = BASE;
  globalThis.Deno = { env: { get: (k) => process.env[k] }, serve: (handler) => { edgeHandler = handler; return {}; } };
  await import(pathToFileURL(path.join(ROOT, 'supabase/functions/member-login/index.ts')).href);
}
async function functions(req, res, name, bodyBuf) {
  if (name !== 'member-login' || !edgeHandler) return send(res, 404, { message: 'function not found' });
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) if (typeof v === 'string') headers.set(k, v);
  headers.set('x-forwarded-for', req.headers['x-test-client-ip'] || '127.0.0.1');
  const response = await edgeHandler(new Request(`${BASE}/functions/v1/${name}`, { method: req.method, headers, body: ['GET', 'HEAD'].includes(req.method) ? undefined : bodyBuf }));
  const out = Buffer.from(await response.arrayBuffer());
  res.writeHead(response.status, Object.fromEntries(response.headers.entries()));
  res.end(out);
}

// ---------- TEST HELPERS ----------
async function testApi(req, res, sub, url) {
  if (sub === 'issue_pin') {
    const { rows } = await asAdmin(`select temp_pin from personnel_pilot_v1.admin_issue_temp_pins(array[(select id from personnel_pilot_v1.people where legacy_user_id = $1 and display_name = $2)], 'e2e 시험 발급')`,
      [url.searchParams.get('legacy'), url.searchParams.get('name')]);
    return send(res, 200, { pin: rows[0].temp_pin });
  }
  if (sub === 'sql') { // 읽기 확인용 (로컬 전용)
    const body = JSON.parse((await readBody(req)).toString());
    const { rows } = await asAdmin(body.sql, body.params || []);
    return send(res, 200, rows);
  }
  if (sub === 'expire_sessions') {
    await asAdmin(`update auth.sessions set created_at = now() - interval '17 hours' where user_id = $1`, [url.searchParams.get('user')]);
    return send(res, 200, { ok: true });
  }
  return send(res, 404, {});
}

// ---------- STATIC ----------
const TYPES = { '.html': 'text/html; charset=utf-8', '.mjs': 'text/javascript', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.jpg': 'image/jpeg', '.png': 'image/png' };
async function serveStatic(res, pathname) {
  const file = path.normalize(path.join(ROOT, decodeURIComponent(pathname === '/' ? '/personnel_test.html' : pathname)));
  if (!file.startsWith(ROOT) || file.includes(`${path.sep}node_modules${path.sep}`) || file.includes(`${path.sep}.git`)) return send(res, 403, { message: 'forbidden' });
  try { res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' }); res.end(await readFile(file)); }
  catch { send(res, 404, { message: 'not found' }); }
}

export async function startGateway() {
  await loadEdgeFunction();
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, BASE);
    try {
      if (req.method === 'OPTIONS') return send(res, 204, undefined, { 'Access-Control-Allow-Headers': req.headers['access-control-request-headers'] || 'apikey, authorization, content-type', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS' });
      if (url.pathname.startsWith('/__test/')) return await testApi(req, res, url.pathname.slice(8), url);
      if (url.pathname.startsWith('/sb/')) {
        const bodyBuf = await readBody(req);
        const rest = url.pathname.slice(4);
        if (rest.startsWith('rest/v1/rpc/')) return await rpc(req, res, rest.slice(12), bodyBuf);
        if (rest.startsWith('auth/v1/')) return await auth(req, res, rest.slice(8), url, bodyBuf);
        if (rest.startsWith('storage/v1/')) return await storage(req, res, rest.slice(11), bodyBuf);
        if (rest.startsWith('functions/v1/')) return await functions(req, res, rest.slice(13), bodyBuf);
        return send(res, 404, { message: 'not mocked' });
      }
      return await serveStatic(res, url.pathname);
    } catch (e) {
      console.error('gateway error', e);
      send(res, 500, { message: 'gateway error' });
    }
  });
  await new Promise(resolve => server.listen(PORT, '127.0.0.1', resolve));
  return { server, base: BASE, close: async () => { server.close(); await pool.end(); } };
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  startGateway().then(({ base }) => console.log(`mock gateway on ${base}`));
}
