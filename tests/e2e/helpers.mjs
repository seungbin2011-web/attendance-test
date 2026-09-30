// e2e 시험 공통 도우미 (로컬 전용)
import assert from 'node:assert/strict';
import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
import { startGateway } from './mock_gateway.mjs';

export const SUPABASE_HOST = 'https://cgeciwdibirvdsucgrnz.supabase.co';
export { assert };

export async function setup() {
  const gateway = await startGateway();
  const browser = await chromium.launch();
  return { gateway, browser, base: gateway.base, async close() { await browser.close(); await gateway.close(); } };
}

// 실제 Supabase 주소 요청을 로컬 게이트웨이로 돌리고, Apps Script는 가짜 JSONP로 응답한다.
export async function newPage(env, { mobile = false, appsScript } = {}) {
  const context = await env.browser.newContext(mobile ? { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true } : {});
  await context.route(`${SUPABASE_HOST}/**`, async route => {
    const req = route.request(); const url = new URL(req.url());
    const headers = { ...(await req.allHeaders()), origin: env.base, 'x-test-client-ip': context._testIp || '127.0.0.1' };
    if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: { 'Access-Control-Allow-Origin': env.base, 'Access-Control-Allow-Headers': 'apikey, authorization, content-type, x-client-info, x-upsert', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS' } });
    const response = await route.fetch({ url: `${env.base}/sb${url.pathname}${url.search}`, headers });
    await route.fulfill({ response, headers: { ...response.headers(), 'access-control-allow-origin': env.base } });
  });
  await context.route('https://script.google.com/**', route => {
    const url = new URL(route.request().url());
    const cb = url.searchParams.get('callback');
    const payload = appsScript ? appsScript(Object.fromEntries(url.searchParams)) : { success: false, message: '시험 환경' };
    if (!cb) return route.fulfill({ status: 200, body: '' });
    return route.fulfill({ status: 200, contentType: 'text/javascript', body: `${cb}(${JSON.stringify(payload)});` });
  });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(`pageerror: ${e.message}`));
  page.on('console', m => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`console: ${m.text()}`); });
  return { page, context, errors };
}

export async function issuePin(env, legacy, name) {
  const r = await fetch(`${env.base}/__test/issue_pin?legacy=${encodeURIComponent(legacy)}&name=${encodeURIComponent(name)}`);
  return (await r.json()).pin;
}
export async function sql(env, text, params = []) {
  const r = await fetch(`${env.base}/__test/sql`, { method: 'POST', body: JSON.stringify({ sql: text, params }) });
  return r.json();
}
export async function noHorizontalScroll(page) {
  return page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
}

let passed = 0;
export async function step(name, fn) {
  try { await fn(); passed++; console.log(`ok  ${name}`); }
  catch (e) { console.error(`FAIL ${name}\n     ${e.message.split('\n').slice(0, 6).join('\n     ')}`); process.exitCode = 1; }
}
export function summary(label) { console.log(`${label}: ${passed} steps passed${process.exitCode ? ' (with failures)' : ''}`); }
