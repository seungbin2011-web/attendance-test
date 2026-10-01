# member-login Edge Function v0.2

Season 2 현장 시연 준비. `personnel_auth_v08.sql`, `personnel_auth_v09.sql`이 먼저 적용돼 있어야 한다.

v0.2: 이름 + 휴대폰 번호 뒤 4자리 로그인 추가. 번호 확인은 기존 정식 인원DB(Apps Script, 화면의 기존 4자리 로그인과 같은 주소)가 하고, 휴대폰 번호는 Supabase에 저장하지 않는다. 개인 PIN 6자리 로그인은 그대로 동작한다.

## 하는 일

1. 브라우저에서 `{ name, phone4 }` 또는 `{ name, pin }`을 받는다. (허용 출처만)
2. 휴대폰 뒤 4자리면 정식 인원DB에 서버에서 확인한 뒤 `pilot_member_roster_login`으로, PIN이면 `pilot_member_login_verify`로 실패 한도·잠금·재직 여부를 DB에서 판단한다.
3. 첫 로그인이면 개인 Auth 사용자(`member-<people.id>@example.com`)를 만들고 `pilot_member_link_account`로 연결한다.
4. 서버에서만 일회용 토큰을 만들어 세션으로 바꾸고 `access_token`, `refresh_token`을 돌려준다. (메일 발송 없음)
5. 역할은 돌려주지 않는다. 화면이 `pilot_whoami`로 서버에서 다시 받는다.

## 배포 (Supabase Dashboard)

1. Edge Functions → Deploy a new function → Via Editor
2. 함수 이름: `member-login`
3. `index.ts` 내용을 붙여넣고 Deploy
4. 함수 설정에서 **Verify JWT(Enforce JWT verification) 끄기** (로그인 전 사용자가 호출하는 함수)
5. 비밀키는 Supabase가 자동으로 넣어 준다 (`SUPABASE_SECRET_KEYS` 또는 `SUPABASE_SERVICE_ROLE_KEY`). 코드·저장소에 키를 적지 않는다.
6. 선택: 시험 주소를 추가하려면 Edge Functions → Secrets에 `MEMBER_LOGIN_ALLOWED_ORIGINS` (쉼표 구분)
7. v0.1에서 올릴 때: 같은 함수(`member-login`)의 Code에서 `index.ts` 내용을 v0.2로 바꿔 Deploy. Verify JWT는 계속 끈 상태

## 호출

```
POST https://<project>.supabase.co/functions/v1/member-login
headers: apikey: <publishable key>, Content-Type: application/json
body: { "name": "홍길동", "phone4": "5678" }   또는   { "name": "홍길동", "pin": "482915" }
```

응답 `{ ok: true, access_token, refresh_token, expires_in, expires_at, must_change_pin }`
또는 `{ ok: false, code, message }` (내부 오류 내용은 돌려주지 않는다)
