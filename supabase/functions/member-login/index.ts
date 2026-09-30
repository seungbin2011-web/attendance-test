// 현장 업무 통합 로그인 · Edge Function member-login v0.1 (전환 단계 S0-3, SQL personnel_auth v0.8 필요)
// 이름 + 개인 PIN을 서버에서 검증한 뒤, 그 사람 전용 Supabase 세션을 발급한다.
// - 역할은 돌려주지 않는다. 화면은 받은 세션으로 pilot_whoami를 호출해 서버에서 역할을 다시 받는다.
// - 비밀키는 Supabase가 함수 환경변수로 넣어 준다. 코드·저장소·화면에 키를 적지 않는다.
// - 배포 설정: verify_jwt = false (로그인 전 사용자가 호출하므로 함수 안에서 직접 검증)
// - 이름·PIN은 로그에 남기지 않는다.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

// 허용 출처: 기본은 GitHub Pages. 시험용으로 MEMBER_LOGIN_ALLOWED_ORIGINS(쉼표 구분)로 바꿀 수 있다.
const ALLOWED_ORIGINS = new Set(
  (Deno.env.get('MEMBER_LOGIN_ALLOWED_ORIGINS') ?? 'https://seungbin2011-web.github.io')
    .split(',').map((origin) => origin.trim()).filter(Boolean),
);

const MESSAGES: Record<string, string> = {
  INVALID_INPUT: '이름과 6자리 PIN을 입력해주세요.',
  INVALID_CREDENTIALS: '이름 또는 PIN이 일치하지 않습니다.',
  LOCKED: '로그인 실패가 반복되어 30분간 잠겼습니다. 잠시 후 다시 시도하거나 관리자에게 문의해주세요.',
  RATE_LIMITED: '로그인 요청이 많습니다. 잠시 후 다시 시도해주세요.',
  AMBIGUOUS: '동일 이름 확인이 필요합니다. 관리자에게 문의해주세요.',
  ACCOUNT_DISABLED: '로그인이 중지된 계정입니다. 관리자에게 문의해주세요.',
  SERVER_ERROR: '로그인 처리 중 오류가 발생했습니다. 잠시 후 다시 시도해주세요.',
};

// 새 키(SUPABASE_SECRET_KEYS / SUPABASE_PUBLISHABLE_KEYS)를 우선 사용하고, 없으면 기존 키를 사용한다.
function readKey(jsonEnv: string, legacyEnv: string): string {
  const json = Deno.env.get(jsonEnv);
  if (json) {
    try {
      const key = JSON.parse(json)?.default;
      if (typeof key === 'string' && key) return key;
    } catch (_) {
      // 기존 키로 대체
    }
  }
  const legacy = Deno.env.get(legacyEnv);
  if (!legacy) throw new Error(`MISSING_ENV ${jsonEnv}`);
  return legacy;
}

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SECRET_KEY = readKey('SUPABASE_SECRET_KEYS', 'SUPABASE_SERVICE_ROLE_KEY');
const PUBLISHABLE_KEY = readKey('SUPABASE_PUBLISHABLE_KEYS', 'SUPABASE_ANON_KEY');
const CLIENT_OPTIONS = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };

function corsHeaders(origin: string | null): Record<string, string> {
  const headers: Record<string, string> = { Vary: 'Origin' };
  if (origin && ALLOWED_ORIGINS.has(origin)) {
    headers['Access-Control-Allow-Origin'] = origin;
    headers['Access-Control-Allow-Methods'] = 'POST, OPTIONS';
    headers['Access-Control-Allow-Headers'] = 'apikey, content-type, x-client-info';
    headers['Access-Control-Max-Age'] = '600';
  }
  return headers;
}

function reply(origin: string | null, status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(origin), 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

function fail(origin: string | null, status: number, code: string): Response {
  return reply(origin, status, { ok: false, code, message: MESSAGES[code] ?? MESSAGES.SERVER_ERROR });
}

function clientIp(req: Request): string | null {
  const first = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim();
  return first || req.headers.get('cf-connecting-ip') || null;
}

function memberEmail(personId: string): string {
  return `member-${personId}@example.com`;
}

// 사용하지 않는 무작위 비밀번호 (저장·반환하지 않음, 비밀번호 로그인 차단 목적)
function unusedPassword(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes));
}

async function findUserIdByEmail(admin: SupabaseClient, email: string): Promise<string | null> {
  for (let page = 1; page <= 10; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 100 });
    if (error) return null;
    const hit = data.users.find((user) => user.email === email);
    if (hit) return hit.id;
    if (data.users.length < 100) return null;
  }
  return null;
}

// 첫 로그인이면 개인 Auth 사용자를 만들고 account_links에 연결한다.
// 연결 함수가 이메일·app_metadata·재직 상태를 다시 검증하므로, 다른 경로로 만들어진 사용자는 연결되지 않는다.
async function ensureAuthUser(admin: SupabaseClient, personId: string, linkedId: string | null): Promise<void> {
  if (linkedId) return;
  const email = memberEmail(personId);
  const { data, error } = await admin.auth.admin.createUser({
    email,
    email_confirm: true,
    password: unusedPassword(),
    app_metadata: { attendance_pilot: 'v1', kind: 'member_pin', person_id: personId },
  });
  let userId = data?.user?.id ?? null;
  if (error || !userId) {
    // 동시에 두 번 로그인해 이미 만들어진 경우
    userId = await findUserIdByEmail(admin, email);
    if (!userId) throw new Error('CREATE_USER_FAILED');
  }
  const { error: linkError } = await admin.rpc('pilot_member_link_account', {
    p_person_id: personId,
    p_auth_user_id: userId,
  });
  if (linkError) throw new Error('LINK_FAILED');
}

// 서버에서만 일회용 로그인 토큰을 만들고 즉시 세션으로 교환한다. (메일은 보내지 않음)
async function issueSession(admin: SupabaseClient, personId: string) {
  const { data, error } = await admin.auth.admin.generateLink({ type: 'magiclink', email: memberEmail(personId) });
  const tokenHash = data?.properties?.hashed_token;
  if (error || !tokenHash) throw new Error('LINK_GENERATION_FAILED');
  const publicClient = createClient(SUPABASE_URL, PUBLISHABLE_KEY, CLIENT_OPTIONS);
  const { data: verified, error: verifyError } = await publicClient.auth.verifyOtp({ token_hash: tokenHash, type: 'email' });
  if (verifyError || !verified.session) throw new Error('SESSION_FAILED');
  return verified.session;
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get('Origin');
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders(origin) });
  if (req.method !== 'POST' || !origin || !ALLOWED_ORIGINS.has(origin)) return fail(origin, 403, 'INVALID_INPUT');

  let body: { name?: unknown; pin?: unknown };
  try {
    body = await req.json();
  } catch (_) {
    return fail(origin, 400, 'INVALID_INPUT');
  }
  const name = typeof body?.name === 'string' ? body.name.slice(0, 101) : '';
  const pin = typeof body?.pin === 'string' ? body.pin.replace(/\D/g, '').slice(0, 7) : '';

  const admin = createClient(SUPABASE_URL, SECRET_KEY, CLIENT_OPTIONS);

  // 입력 형식·실패 한도·잠금·재직 여부는 모두 DB 함수가 판단하고 기록한다.
  const { data: result, error } = await admin.rpc('pilot_member_login_verify', {
    p_name: name,
    p_pin: pin,
    p_client_ip: clientIp(req),
  });
  if (error || !result) {
    console.error('member-login verify error', error?.code ?? 'unknown');
    return fail(origin, 500, 'SERVER_ERROR');
  }
  if (!result.ok) {
    const status = result.code === 'LOCKED' || result.code === 'RATE_LIMITED' ? 429
      : result.code === 'INVALID_INPUT' ? 400 : 401;
    return fail(origin, status, String(result.code));
  }

  try {
    await ensureAuthUser(admin, result.person_id, result.auth_user_id ?? null);
    const session = await issueSession(admin, result.person_id);
    return reply(origin, 200, {
      ok: true,
      access_token: session.access_token,
      refresh_token: session.refresh_token,
      expires_in: session.expires_in,
      expires_at: session.expires_at,
      must_change_pin: result.must_change_pin === true,
    });
  } catch (e) {
    console.error('member-login session error', e instanceof Error ? e.message : 'unknown');
    return fail(origin, 500, 'SERVER_ERROR');
  }
});
