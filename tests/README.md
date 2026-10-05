# 로컬 시험 (실제 Supabase에 연결하지 않음)

모든 시험 데이터는 가짜이며, 로컬 Postgres에만 만든다.

## SQL 시험

```
bash tests/run_sql_tests.sh
```

- `sql/00_mock_supabase.sql`: 실제 work-status-test 조회 결과를 기준으로 만든 흉내 구조 (역할, auth, storage, personnel_pilot_v1, public.works 권한)
- `sql/01_mock_seed.sql`: 가짜 인원·업무계정 (실제와 같은 형태만 흉내)
- `sql/10_*`, `sql/2*_*`: 적용 후 동작·권한 시험. 실패하면 `TEST FAILED`로 중단
- `sql/12_*`~`sql/16_*`: v0.10 역할 판정(팀원·팀장·현장관리·관리자), 소속·역할 변경 템플릿(실제 파일에 시험 명단만 넣어 실행, 잘못된 명단은 전체 취소), 점검 SQL, v0.10 롤백
- `sql/40_*`·`sql/41_*`: v0.11 Supabase 단독 로그인(역할별·비활성·틀린 번호·같은 이름·AMBIGUOUS·잠금), 관리자 인원 관리(추가·팀 이동·권한·번호 변경·비활성·재투입, 관리자 외 거절), 조직도 권한, 사용자ID 없는 인원의 TBM, v0.11 롤백
- `sql/42_*`: v0.12 최초 로그인 이관(번호 없는 현재 인원만 FIRST_LOGIN_REQUIRED, 확인 실패 시 무저장, 해시만 저장, 사용자ID 불일치·같은 이름 미구분 AMBIGUOUS, 명단 밖·비활성 거절, service_role 전용), v0.12 롤백
- `sql/29_*`~`sql/32_*` + `sql/fixture_roster_2026_10_fake.rows`: 2026-10 명단 동기화 (가짜 53명, 실제 숫자와 같은 형태). 미리보기·실패 시 무변경·숫자·사람별 역할·같은 팀 팀장 공동 작성·다른 팀 차단·자재팀 0명·재실행 무변경·되돌리기·재동기화
- 마지막에 롤백 → 재적용까지 확인

## e2e 시험 (Chromium)

```
bash tests/e2e/run_e2e.sh            # 전체
bash tests/e2e/run_e2e.sh s0_login.test.mjs
```

- `e2e/mock_gateway.mjs`: 정적 파일 + Supabase 흉내 API (RPC는 로컬 DB의 실제 SQL 함수를 해당 역할로 실행, Storage는 RLS 정책을 실제로 거침)
- `supabase/functions/member-login/index.ts`를 Deno 흉내로 그대로 실행한다.
- 브라우저의 실제 Supabase 주소 요청과 Apps Script 요청은 시험 안에서 로컬로 돌린다.
- `e2e/s4_roster_2026_10.test.mjs`: 가짜 53명 명단을 실제 동기화 파일로 넣은 뒤 관리자·현장관리·팀장 여러 명·자재팀·팀원 화면, 화면 값 조작 차단, 팀원 로그아웃, 제외 인원 차단
- `e2e/s5_admin_people.test.mjs`: 관리자 화면에서 인원 추가·팀 이동·팀장 지정·번호 변경·비활성·재투입과 그때마다 실제 로그인, 현장관리 서버 거절, 조직도 접근(로그아웃·팀원·팀장 차단, 현장관리 허용, 민감정보 없음)
- 로그인은 DB 번호 해시로만 확인하므로, 흉내 게이트웨이는 시험 인원 목록(이름|뒤4자리)을 시작할 때와 `/__test/roster` 때 DB에 등록한다.
- `e2e/s6_first_login.test.mjs`: 번호 없는 기존 인원 최초 로그인 1회 이관(정식 인원DB 흉내 호출 1회 → 해시 저장 → 다음부터 호출 없음), 틀린 번호·명단 밖 사람 거절, 역할별 이동, 관리자 등록 현황
- `e2e/s7_first_login_off.test.mjs`: `MEMBER_LOGIN_FIRST_LOGIN_FALLBACK=off`면 정식 인원DB를 전혀 부르지 않음
- `e2e/s8_prod_pages.test.mjs`: 운영 화면(루트 `index.html` → `member.html`·`tbm_report.html`·`tbm_manager.html`·관리자 명부), TEST·시험 표시 없음, 로그아웃·로그인 필요 시 운영 로그인으로, 출결 등록 → `index_season1.html`, 역할별 「사용 가이드」(팀장·소장 PDF 새 탭, PDF 정상 응답, 360·320px 폭 버튼 한 줄)
- `run_e2e.sh`는 시작할 때 `python3 tests/make_prod_pages.py --check`로 운영 화면이 시험 화면과 맞는지 먼저 확인한다.
- 결과 화면 캡처는 `e2e/artifacts/` (Git 제외)
