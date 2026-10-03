# member-login Edge Function v0.4

Season 2. `personnel_auth_v08.sql` ~ `personnel_auth_v12.sql`이 먼저 적용돼 있어야 한다.

v0.4: 이름 + 휴대폰 번호 뒤 4자리를 Supabase 안에서 확인한다 (`pilot_member_login4`, 번호는 bcrypt 해시로만 저장).
- 로그인 번호가 있는 사람: Apps Script를 부르지 않는다.
- 아직 번호가 없는 현재 인원(53명 명단의 기존 인원): 최초 1회만 정식 인원DB(Apps Script)로 확인하고 `pilot_member_login4_migrate`가 번호를 해시로 저장한다. 다음부터는 Supabase만.
- 새 인원은 관리자 화면에서 번호를 함께 등록하므로 Apps Script와 무관하다.
- 최초 이관 끄기: Edge Functions → Secrets에 `MEMBER_LOGIN_FIRST_LOGIN_FALLBACK=off` (모든 현재 인원 등록 후, `personnel_auth_v12_check.sql`의 등록 수로 확인)
- 개인 PIN 6자리 로그인은 그대로 동작한다.

v0.3(이전): Supabase만 확인 (번호가 없으면 로그인 불가).

v0.2(이전): 번호 확인을 정식 인원DB(Apps Script)가 했다.

## 하는 일

1. 브라우저에서 `{ name, phone4 }` 또는 `{ name, pin }`을 받는다. (허용 출처만)
2. 휴대폰 뒤 4자리면 `pilot_member_login4`로, PIN이면 `pilot_member_login_verify`로 번호 확인·실패 한도·잠금·재직 여부·같은 이름 구분을 DB에서 판단한다. 번호가 없는 현재 인원이면 정식 인원DB 확인 후 `pilot_member_login4_migrate`로 이관한다.
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
7. 이전 버전에서 올릴 때: 같은 함수(`member-login`)의 Code에서 `index.ts` 내용을 v0.4로 바꿔 Deploy. Verify JWT는 계속 끈 상태. v0.4는 `personnel_auth_v12.sql`까지 적용한 뒤 배포한다.

## 호출

```
POST https://<project>.supabase.co/functions/v1/member-login
headers: apikey: <publishable key>, Content-Type: application/json
body: { "name": "홍길동", "phone4": "5678" }   또는   { "name": "홍길동", "pin": "482915" }
```

응답 `{ ok: true, access_token, refresh_token, expires_in, expires_at, must_change_pin }`
또는 `{ ok: false, code, message }` (내부 오류 내용은 돌려주지 않는다)
