// TBM 시험 화면 공통 API (tbm_api v0.1)
// - 로그인 세션은 통합 로그인(personnel_test.html)이 저장한 것을 그대로 쓴다. 이 모듈은 비밀번호·PIN을 다루지 않는다.
// - 서버 오류 메시지는 'CODE' 또는 'CODE: 상세' 형식이며, 화면에는 한국어 안내로 바꿔 보여준다.
// - 브라우저에는 publishable 키만 있다. 권한 판단은 모두 서버 RPC가 한다.
import { endpoint, publishableKey } from './personnel_accounts_test.mjs';

export const API_VERSION = '0.1';
export const PHOTO_BUCKET = 'tbm-photos';
export const PHOTO_MAX_BYTES = 2 * 1024 * 1024;
const SESSION_KEY = 'personnelPilotSessionV2';

const MESSAGES = {
  AUTH_REQUIRED: '로그인이 필요합니다.',
  AUTH_EXPIRED: '로그인이 만료됐습니다. 다시 로그인해주세요.',
  SESSION_EXPIRED: '로그인 후 16시간이 지나 다시 로그인이 필요합니다.',
  ACCOUNT_NOT_LINKED: '개인 로그인 연결이 확인되지 않습니다. 관리자에게 문의해주세요.',
  ACCOUNT_INACTIVE: '로그인이 중지된 인원입니다. 관리자에게 문의해주세요.',
  ACCOUNT_DISABLED: '로그인이 중지된 계정입니다. 관리자에게 문의해주세요.',
  PIN_CHANGE_REQUIRED: '개인 PIN 변경이 필요합니다. 로그인 화면에서 PIN을 바꿔주세요.',
  FORBIDDEN: '이 화면을 사용할 권한이 없습니다.',
  TEAM_NOT_READY: '이 계정의 팀 정보가 아직 서버에 준비되지 않았습니다. 관리자에게 문의해주세요.',
  TEAM_FORBIDDEN: '다른 팀의 보고는 수정할 수 없습니다.',
  TEAM_REQUIRED: '맡은 팀이 여러 개입니다. 팀을 선택해주세요.',
  VERSION_CONFLICT: '다른 화면에서 먼저 저장됐습니다. 최신 내용을 불러옵니다.',
  REPORT_NOT_EDITABLE: '오늘 보고가 아니거나 소장 확인이 끝나 더 이상 수정할 수 없습니다.',
  REPORT_FORBIDDEN: '이 보고를 볼 권한이 없습니다.',
  REPORT_NOT_FOUND: '보고를 찾을 수 없습니다. 새로고침해주세요.',
  TASKS_REQUIRED: '작업을 1개 이상 입력해주세요.',
  INVALID_RISK: '위험요인 값이 올바르지 않습니다.',
  INVALID_MEMBERS: '작업 인원 정보가 올바르지 않습니다.',
  DUPLICATE_MEMBER: '한 작업에 같은 인원이 두 번 들어갔습니다.',
  INVALID_ROLE: '작업 역할 값이 올바르지 않습니다.',
  MEMBER_NOT_IN_TEAM: '우리 팀 소속이 아닌 인원입니다: {detail}',
  MEMBER_ASSIGNED_ELSEWHERE: '다른 팀 작업에 이미 배정된 인원입니다: {detail}',
  MORNING_REQUIRED: '출근 TBM을 먼저 보고해주세요.',
  NOTE_REQUIRED: '내용을 2자 이상 적어주세요.',
  INVALID_ALERT: '오후 상태 값이 올바르지 않습니다.',
  TASK_CLOSED: '퇴근 결과가 입력된 작업은 오후 상태를 바꿀 수 없습니다.',
  INVALID_RESULT: '작업 결과 값이 올바르지 않습니다.',
  UNRESOLVED_TASKS: '결과를 입력하지 않은 작업이 {detail}건 있습니다.',
  CARRY_NOT_AVAILABLE: '이미 이어받았거나 제외된 이월 작업입니다. 최신 내용을 불러옵니다.',
  TASK_NOT_FOUND: '작업을 찾을 수 없습니다. 새로고침해주세요.',
  PHOTO_LIMIT: '사진은 회차마다 최대 3장입니다.',
  PHOTO_TOO_LARGE: '사진 용량이 너무 큽니다 (최대 2MB).',
  INVALID_HASH: '사진 확인값을 만들지 못했습니다. 다시 선택해주세요.',
  INVALID_KIND: '사진 회차 값이 올바르지 않습니다.',
  UPLOAD_NOT_FOUND: '사진 파일 업로드가 확인되지 않았습니다. 다시 올려주세요.',
  PHOTO_NOT_FOUND: '사진을 찾을 수 없습니다. 새로고침해주세요.',
  UPLOAD_FAILED: '사진 파일을 올리지 못했습니다. 다시 시도해주세요.',
  IMAGE_DECODE: '사진을 읽지 못했습니다. 다른 사진(JPG)으로 다시 선택해주세요.',
  NETWORK: '서버에 연결하지 못했습니다. 저장되지 않았을 수 있으니 연결을 확인한 뒤 다시 눌러주세요.',
  TIMEOUT: '서버 응답이 늦습니다. 저장 여부를 확인하려면 새로고침해주세요.',
};

export class ApiError extends Error {
  constructor(code, detail = '', status = 0) {
    const template = MESSAGES[code] || `요청에 실패했습니다 (${status || code}).`;
    super(template.replace('{detail}', detail || '-'));
    this.code = code; this.detail = detail; this.status = status;
  }
}
export function describeError(e) { return e instanceof ApiError ? e.message : '처리 중 문제가 생겼습니다. 새로고침 후 다시 시도해주세요.'; }

// 서버 메시지에서 코드 추출: 'VERSION_CONFLICT' / 'MEMBER_ASSIGNED_ELSEWHERE: 홍길동 (공사1팀)'
function parseServerError(result, status) {
  const text = String(result?.message || result?.msg || result?.error_description || '');
  const match = text.match(/^([A-Z][A-Z0-9_]{2,})(?::\s*(.*))?$/s);
  if (match && (MESSAGES[match[1]] || /^[A-Z_]+$/.test(match[1]))) return new ApiError(match[1], match[2] || '', status);
  if (status === 401 || /JWT|jwt/.test(text) || String(result?.code || '').startsWith('PGRST30')) return new ApiError('AUTH_EXPIRED', '', status);
  return new ApiError('UNKNOWN', '', status);
}

export function loadSession() {
  try {
    const value = JSON.parse(sessionStorage.getItem(SESSION_KEY) || 'null');
    return value?.access_token && value?.refresh_token ? value : null;
  } catch (_) { return null; }
}
function saveSession(session) { sessionStorage.setItem(SESSION_KEY, JSON.stringify(session)); }
export function clearSession() {
  sessionStorage.removeItem(SESSION_KEY);
  sessionStorage.removeItem('attendanceAuthUser');
  sessionStorage.removeItem('tbmAuthUser');
}
export function loginUrl(next) { return 'personnel_test.html?next=' + encodeURIComponent(next); }
// 세션이 없으면 통합 로그인으로 보낸다 (로그인 후 next 화면으로 돌아옴, 허용 역할은 로그인 화면이 서버 기준으로 확인)
export function requireLogin(next) {
  const session = loadSession();
  if (!session) { location.replace(loginUrl(next)); return null; }
  return session;
}

async function send(path, { body, token, method = 'POST', headers = {}, raw = false, timeout = 20000 } = {}) {
  const h = { apikey: publishableKey, ...headers };
  if (token) h.Authorization = `Bearer ${token}`;
  if (!raw && body !== undefined) h['Content-Type'] = 'application/json';
  let response;
  try {
    response = await fetch(endpoint + path, { method, headers: h, body: raw ? body : body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(timeout) });
  } catch (e) {
    throw new ApiError(e?.name === 'TimeoutError' ? 'TIMEOUT' : 'NETWORK');
  }
  const result = response.status === 204 ? {} : await response.json().catch(() => ({}));
  if (!response.ok) throw Object.assign(parseServerError(result, response.status), { server: result });
  return result;
}

let refreshing = null;
async function refreshSession(session) {
  if (!refreshing) {
    refreshing = send('/auth/v1/token?grant_type=refresh_token', { body: { refresh_token: session.refresh_token } })
      .then(renewed => { const next = { ...renewed, kind: session.kind, expiresAt: Date.now() + renewed.expires_in * 1000 }; saveSession(next); return next; })
      .catch(e => { if (e.code === 'NETWORK' || e.code === 'TIMEOUT') throw e; clearSession(); throw new ApiError('AUTH_EXPIRED'); })
      .finally(() => { refreshing = null; });
  }
  return refreshing;
}
async function freshSession() {
  let session = loadSession();
  if (!session) throw new ApiError('AUTH_REQUIRED');
  if (!session.expiresAt || Date.now() > session.expiresAt - 60000) session = await refreshSession(session);
  return session;
}

// RPC 호출. 토큰 만료(401)면 한 번만 갱신 후 다시 보낸다. 서버가 거절하면 ApiError.
export async function rpc(name, args = {}) {
  let session = await freshSession();
  try {
    return await send('/rest/v1/rpc/' + name, { body: args, token: session.access_token });
  } catch (e) {
    if (e.code !== 'AUTH_EXPIRED') throw e;
    session = await refreshSession(session);
    return send('/rest/v1/rpc/' + name, { body: args, token: session.access_token });
  }
}

export async function logout() {
  const session = loadSession();
  clearSession();
  if (session) await send('/auth/v1/logout?scope=local', { body: {}, token: session.access_token }).catch(() => {});
}

// 같은 요청을 다시 보낼 때(연결 오류 후 재시도) 같은 request_id를 써서 서버가 한 번만 반영하게 한다.
export function newRequestId() {
  return crypto.randomUUID ? crypto.randomUUID() : Date.now().toString(36) + Math.random().toString(36).slice(2);
}
export function requestIdFor(slot, payload) {
  const key = JSON.stringify(payload);
  if (slot.key === key && slot.id) return slot.id;
  slot.key = key; slot.id = newRequestId();
  return slot.id;
}

// ---------- 사진 ----------
export async function sha256Hex(blob) {
  const digest = await crypto.subtle.digest('SHA-256', await blob.arrayBuffer());
  return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, '0')).join('');
}
function loadImage(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => { URL.revokeObjectURL(url); resolve(img); };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new ApiError('IMAGE_DECODE')); };
    img.src = url;
  });
}
function toJpeg(canvas, quality) {
  return new Promise(resolve => canvas.toBlob(resolve, 'image/jpeg', quality));
}
// 긴 변 1280px, JPEG 0.72로 줄인다. 2MB를 넘으면 더 줄인다.
export async function compressImage(file, maxSide = 1280, quality = 0.72) {
  const img = await loadImage(file);
  let side = maxSide, q = quality;
  for (let attempt = 0; attempt < 4; attempt++) {
    const scale = Math.min(1, side / Math.max(img.naturalWidth, img.naturalHeight));
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(img.naturalWidth * scale));
    canvas.height = Math.max(1, Math.round(img.naturalHeight * scale));
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    const blob = await toJpeg(canvas, q);
    if (blob && blob.size <= PHOTO_MAX_BYTES) return blob;
    side = Math.round(side * 0.8); q = Math.max(0.5, q - 0.1);
  }
  throw new ApiError('PHOTO_TOO_LARGE');
}
function objectUrlPath(path) { return path.split('/').map(encodeURIComponent).join('/'); }
// 비공개 버킷 업로드. 같은 경로에 이미 올라가 있으면(재시도) 성공으로 본다. 서버 확인(tbm_photo_confirm)이 최종 판단.
export async function uploadPhoto(bucket, path, blob) {
  const session = await freshSession();
  try {
    await send(`/storage/v1/object/${encodeURIComponent(bucket)}/${objectUrlPath(path)}`,
      { body: blob, raw: true, token: session.access_token, headers: { 'Content-Type': 'image/jpeg', 'x-upsert': 'false', 'cache-control': '3600' }, timeout: 60000 });
  } catch (e) {
    const server = e.server || {};
    if (String(server.statusCode) === '409' || server.error === 'Duplicate') return;
    if (e.code === 'NETWORK' || e.code === 'TIMEOUT' || e.code === 'AUTH_EXPIRED') throw e;
    throw new ApiError('UPLOAD_FAILED', '', e.status);
  }
}
// 비공개 사진 보기: 짧은 서명 링크 (기본 10분)
export async function signedUrls(bucket, paths, expiresIn = 600) {
  if (!paths.length) return {};
  const session = await freshSession();
  const rows = await send(`/storage/v1/object/sign/${encodeURIComponent(bucket)}`, { body: { expiresIn, paths }, token: session.access_token });
  const out = {};
  for (const row of rows || []) if (row.signedURL) out[row.path] = endpoint + '/storage/v1' + row.signedURL;
  return out;
}

// ---------- 화면 공통 ----------
export function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
export function kstTime(iso) {
  if (!iso) return '';
  return new Date(iso).toLocaleTimeString('ko-KR', { timeZone: 'Asia/Seoul', hour: '2-digit', minute: '2-digit', hour12: false });
}
export function kstDateLabel(date) {
  if (!date) return '';
  const d = new Date(date + 'T00:00:00+09:00');
  return d.toLocaleDateString('ko-KR', { timeZone: 'Asia/Seoul', month: 'long', day: 'numeric', weekday: 'short' });
}
export function kstNowHour() {
  return Number(new Date().toLocaleString('en-US', { timeZone: 'Asia/Seoul', hour: 'numeric', hour12: false })) % 24;
}
