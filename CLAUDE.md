# attendance-test 작업 안내 (Claude Code용)

새 세션은 이 파일 → `docs/CURRENT_STATE.md` → 필요한 경우 `docs/RUNBOOK.md` 순서로 읽고 시작한다.
현재 상태(커밋·DB 숫자·배포)는 `docs/CURRENT_STATE.md`에만 적는다. 이 파일에는 바뀌지 않는 원칙만 둔다.

## 프로젝트 목적

용인 현장의 출퇴근·TBM(작업 전 안전회의)·인원 관리를 스마트폰 웹으로 운영한다.
- 사용자: 현장 팀원·팀장·소장(현장관리)·관리자. **대부분 비개발자**다.
- 배포: GitHub Pages (`main` 브랜치 루트). 서버: Supabase (DB·Auth·Storage·Edge Function).

## Season 2 구조 (현재 운영)

- 링크 하나: `https://seungbin2011-web.github.io/attendance-test/` → `index.html`(통합 로그인: 이름 + 휴대폰 뒤 4자리)
- 로그인 후 서버 역할대로 이동한다.
  - MEMBER → `member.html`
  - TEAM_LEADER → `tbm_report.html`
  - SITE_MANAGER → `tbm_manager.html`
  - ADMIN → `index.html` 관리자 명부
- 조직도 `organization.html`: SITE_MANAGER·ADMIN만 (서버 함수 `pilot_org_chart`가 확인)
- 기존 출퇴근 앱(Season 1)은 `index_season1.html`. 팀원 화면 "출결 등록"이 여기로 연결된다.
- 운영 화면 4개(`index.html`·`member.html`·`tbm_report.html`·`tbm_manager.html`)는 `python3 tests/make_prod_pages.py`가 시험 화면(`*_test.html`)에서 만든다. **직접 고치지 않는다.** 시험 화면을 고친 뒤 다시 만든다.
- JS 모듈(`personnel_test.mjs`, `tbm_*_test.mjs`)은 운영·시험이 같이 쓴다. 파일 이름에 `_test`가 없으면 운영 화면끼리 연결된다(`pageUrl`).
- 시험 화면(`*_test.html`)은 지우지 않는다.

## 기준 데이터: Supabase가 유일한 기준

- 인원·팀·역할·로그인 번호·조직도는 **Supabase**(`personnel_pilot_v1`)만 본다. TBM은 `field_pilot_v1`.
- Apps Script(정식 인원DB, `personnelOrg` 등)는 **신규 인원·권한 구조의 기준이 아니다.** 새 운영 화면에서 쓰지 않는다. 로그인 서버(`member-login`)에서도 Apps Script 호출을 없앴다.
- 역할은 서버 표(현재 `memberships` + 현재 `role_assignments`)로만 정한다. 이름·직급·직책 글자, 화면 값으로 권한을 정하지 않는다. 이름·팀·직급을 코드에 하드코딩하지 않는다.

- 역할 4가지 (화면 역할 = DB 역할 코드)
  - MEMBER = 일반 팀원. DB에는 역할 행이 없다. → 팀원 화면
  - TEAM_LEADER = 팀장. `TEAM_LEADER` → 팀장 TBM
  - SITE_MANAGER = 소장·현장관리. `SITE_MANAGER` → 현장 TBM 현황·조직도
  - ADMIN = 관리자. DB 코드는 `ADMIN_DEPT` → 관리자 명부·현황·조직도

## 인원 원칙

- 현재 활성 인원은 **인원DB 엑셀(2026-10 기준)에 있는 53명**이다. 숫자는 `docs/CURRENT_STATE.md`를 본다.
- 엑셀에 없는 기존 인원은 **DELETE하지 않는다.** `employment_status = inactive`, 현재 소속 종료(`valid_to`), 현재 역할 종료(`revoked_at`), 로그인 차단으로 정리한다.
- 사람 UUID와 과거 TBM·작업계획·사진·이월·배정 기록은 그대로 보존한다. 과거 기록을 다른 사람에게 옮기거나 합치지 않는다.
- **김태형과 김태영은 별도 인물이다.** rename·merge 금지 (김태형 = 과거 인원 inactive, 김태영 = 현재 인원, 각자 UUID).
- 같은 이름·같은 사용자ID를 임의로 동일인으로 판단하지 않는다. 사용자ID를 임의로 만들지 않는다.
- 새 인원은 관리자 화면에서 이름·뒤 4자리·팀·권한을 넣어 등록한다 (Supabase에 bcrypt 해시로 저장).

## 작업 원칙

- 새 기능보다 **현장 안정성**이 먼저다. **최소 수정**을 우선한다. 불필요한 리팩터링·UI 리뉴얼을 하지 않는다.
- 사용자에게 한 번에 너무 많은 작업을 요구하지 않는다. 한 단계씩, 사용자가 그대로 따라 할 수 있게 쓴다.
- 운영 화면에 `TEST`·`시험 화면`·`v0.xx TEST` 같은 흔적을 노출하지 않는다 (`tests/make_prod_pages.py --check`).
- DB 변경은 항상 **CHECK → APPLY/SYNC → VERIFY** 순서. VERIFY가 실패하면 다음 단계로 가지 않는다. 절차는 `docs/RUNBOOK.md`.
- 데이터를 자동으로 대량 삭제하지 않는다. `DELETE`·`DROP`·`TRUNCATE`·대량 `UPDATE`·RLS 교체는 사용자 확인 없이 하지 않는다.
- MAIN merge는 실제 운영 검증(DB VERIFY, 로그인 서버, 자동시험) 후에만 한다. 사용자가 명시적으로 허락한 경우에만 한다.
- 사용자 확인 없이 하지 않는 것: `public.works` anon 권한 회수, Apps Script 삭제, 업무계정 삭제, 사람 병합·삭제.
- 사용자 PC를 직접 조작하지 않는다 (컴퓨터 제어·브라우저 자동조작·화면 클릭 금지). 회사 내부 데이터·다른 폴더·메일·메신저에 접근하지 않는다.
- 실제 사람 계정으로 로그인 시험을 하지 않는다. 자동시험은 로컬 흉내 DB·가짜 인원으로 한다.

## 민감정보 (Git·커밋·PR·문서·로그·채팅에 넣지 않는다)

- 휴대폰 번호, 휴대폰 뒤 4자리, 로그인 번호의 bcrypt 해시(4자리라 쉽게 풀림), 주민등록번호, PIN 원문
- credential: Supabase secret·service_role 키·DB 비밀번호·access token
- 실제 명단(이름 목록)이 들어간 SQL(`*_filled.sql`), 인원DB 엑셀(`*.xlsx`), 번호 등록 SQL은 Git 밖에 둔다 (`.gitignore`에 등록).
- 저장소의 SQL 템플릿은 명단 자리가 비어 있다. 실제 명단은 적용할 때만 Git 밖에서 채운다.
- 공개값: Supabase project URL과 publishable 키(`personnel_accounts_test.mjs`)는 공개해도 되는 값이다.

## 보고 규칙

- 중간 진행·최종 보고는 **반드시 한국어**. 파일명·함수명·SQL명 같은 기술 식별자만 영어.
- 실제로 하지 않은 일을 완료했다고 보고하지 않는다. 확인 근거를 구분한다: **확인됨**(직접 실행·조회) / **코드 기준** / **확인 필요**.
- 사용자 선호 형식: 짧게, 한 단계씩, 표는 꼭 필요할 때만. 사용자 결정이 필요하면 `[사용자 확인사항] A/B`, 붙여 넣을 내용은 `[복사용 요약]` 코드블록.
- 전화번호·뒤 4자리·해시를 결과나 로그에 출력하지 않는다.

## 시험 (로컬 전용, 실제 Supabase에 연결하지 않음)

- SQL: `bash tests/run_sql_tests.sh` (Postgres 16 흉내 DB, 꺼져 있으면 `pg_ctlcluster 16 main start`)
- e2e: `bash tests/e2e/run_e2e.sh` (Playwright + 흉내 게이트웨이가 실제 Edge 코드 실행. 파일 이름 순서로 같은 DB를 이어 쓴다)
- 운영 화면 일치: `python3 tests/make_prod_pages.py --check`
- 자세한 설명: `tests/README.md`

## 문서 지도

- `docs/CURRENT_STATE.md`: 현재 커밋·배포·DB 숫자·남은 의존·롤백 기준 (사실만)
- `docs/RUNBOOK.md`: DB 변경·Edge Function 배포·GitHub merge 절차와 실패 시 대응
- `docs/TEST_CHECKLIST.md`: 현장 휴대폰 실테스트 체크리스트
- `docs/BACKLOG_FIELD_TEST.md`: 현장 테스트에서 나온 문제·개선 후보 (구현 전 검토용)
- `PERSONNEL_TEST.md`: 인원·로그인 SQL 버전별 변경 이력과 적용 순서
- `TBM_REPORT_TEST.md`: TBM 화면 이력
- `supabase/functions/member-login/README.md`: 로그인 서버 설명·배포
- `tests/README.md`: 시험 구성
