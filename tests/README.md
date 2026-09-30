# 로컬 시험 (실제 Supabase에 연결하지 않음)

모든 시험 데이터는 가짜이며, 로컬 Postgres에만 만든다.

## SQL 시험

```
bash tests/run_sql_tests.sh
```

- `sql/00_mock_supabase.sql`: 실제 work-status-test 조회 결과를 기준으로 만든 흉내 구조 (역할, auth, storage, personnel_pilot_v1, public.works 권한)
- `sql/01_mock_seed.sql`: 가짜 인원·업무계정 (실제와 같은 형태만 흉내)
- `sql/10_*`, `sql/2*_*`: 적용 후 동작·권한 시험. 실패하면 `TEST FAILED`로 중단
- 마지막에 롤백 → 재적용까지 확인

## e2e 시험 (Chromium)

```
bash tests/e2e/run_e2e.sh            # 전체
bash tests/e2e/run_e2e.sh s0_login.test.mjs
```

- `e2e/mock_gateway.mjs`: 정적 파일 + Supabase 흉내 API (RPC는 로컬 DB의 실제 SQL 함수를 해당 역할로 실행, Storage는 RLS 정책을 실제로 거침)
- `supabase/functions/member-login/index.ts`를 Deno 흉내로 그대로 실행한다.
- 브라우저의 실제 Supabase 주소 요청과 Apps Script 요청은 시험 안에서 로컬로 돌린다.
- 결과 화면 캡처는 `e2e/artifacts/` (Git 제외)
