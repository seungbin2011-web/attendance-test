# 현재 상태 (2026-10-05 07:30 KST 무렵 확인, 맨 위 절은 2026-10-15)

이 문서는 확인한 사실만 적는다. 상태가 바뀌면 이 문서를 고친다.
표시: **확인됨** = 직접 조회·실행 / **코드 기준** = 저장소 코드로 판단 / **확인 필요** = 이 환경에서 확인 못 함

## TBM v1.1 현장 UX 보정 (화면 v1.2, field v0.5) — PR 대기, 2026-10-16

- 브랜치 `claude/tbm-v11-field-ux` (main `535300d` = PR #19 merge에서 시작). **MAIN merge 안 함** — 사용자 결정.
- 실제 DB: v0.5 **아직 적용 안 됨** (새 RPC `tbm_carry_cancel` 하나). 적용 순서 `field_sql_v05_apply.md` (CHECK → APPLY → VERIFY → PR merge).
  - DB를 먼저 적용해도 지금 운영 화면(v1.1)은 그대로 동작한다. **코드 기준·로컬 시험**
  - 화면만 먼저 나가면 「이월 취소」만 "서버 준비 전" 안내로 막히고 나머지는 동작한다. **코드 기준**
- 바뀌는 것: 저장 후 홈 복귀(실패 시 화면 유지·「다시 저장」), 전일 이월 기본 접힘·「전일 이월/오늘 신규」 구분·인원 N명 요약·「이월 취소」(사유 이력), 「작업N에도 투입」 문구, 홈 작업정지 표시, 소장 PC 넓은 화면, 로그인 뒤로가기(`location.replace`·세션 있으면 역할 화면·pageshow 확인). 운영 표시 v1.2, 사용 가이드 v1.2.
- 대표 브라우저: **iPhone Chrome** (사용자 주 브라우저). 뒤로가기 대응은 브라우저를 가리지 않는 방식이라 iPhone Safari 대응도 그대로 유지한다. **코드 기준**
  - iPhone의 Chrome도 Safari와 같은 WebKit 엔진을 쓴다. 자동시험은 Chromium(Chrome 엔진)으로만 돌리므로 iPhone 실기기 확인은 `docs/TEST_CHECKLIST.md` 「v1.2」 4번으로 한다. **확인 필요**
- 자동시험 (로컬, 2026-10-16) **확인됨** — 기준선 main `535300d`: SQL 통과, sessions 전부 통과, e2e 83 통과 / 14 실패
  - 이 브랜치: SQL 통과, sessions(sql 33·v04 89·v05 30·ui·ui_v04·ui_v12 17) 통과, 운영 화면 일치
  - Chrome 계열 뒤로가기·앞으로가기·새로고침 `history_chrome.mjs` 38개 통과 (Chromium, 뒤로가기 캐시 켬·끔 두 번). 같은 시험을 main `535300d` 화면에 돌리면 첫 단계에서 로그인 화면이 다시 나와 실패한다 (고치기 전 문제 재현)
  - e2e 83 통과 / 14 실패 = 기준선과 같은 단계·같은 원인 14건, 신규 실패 0

## TBM / 출역 관리 개선 v0.1 (field v0.4) — DB 적용·VERIFY 완료 (2026-10-16 06:36 KST), PR #19 merge 완료 (main `535300d`)

- PR #19 (`claude/tbm-attendance-v0.1`, main `e479c2f`에서 시작). **MAIN merge 안 함** — 사용자 결정.
- 실제 DB: v0.4 **적용됨** (사용자가 SQL Editor에서 실행). **확인됨** (읽기 전용 조회)
  - CHECK `ready=true` (06:29 KST) → APPLY(사용자) → VERIFY `ok=true` (06:36 KST), 검사 9개 모두 통과
  - 원본 지문 9종(보고·작업·배정·사진·이력·인원·소속·역할·credential) CHECK와 VERIFY가 모두 같음 = 기존 데이터 변경 없음
  - 숫자: 보고 6 · 작업 6 · 배정 14 · 사진 13 · 이력 42 · 출역 기록 0 · 사람 행 65 · 활성 44
- 활성 44 확인 (읽기 전용) **확인됨**
  - 2026-10-15 17:45~17:46 KST 관리자 계정 1개가 관리자 화면에서 9명을 비활성 처리 (53 − 9 = 44). 10/05 이후 새 인원 0
  - 활성 44명 모두 현재 소속 1개·로그인 번호 등록. 비활성 21명은 현재 소속·역할 0
  - 오늘 비활성된 9명은 로그인 번호 해시가 남아 있으나, 로그인 함수가 비활성 인원을 거절한다 (**코드 기준**, `pilot_member_login4`의 `employment_status <> 'inactive'` 조건과 SQL 시험)
- Supabase 보안 알림 (적용 후): 새 출역 표 2개 "RLS 켜짐·정책 없음"(INFO, 의도: 직접 접근 차단·RPC로만), 새 RPC 5개 "authenticated SECURITY DEFINER"(기존 TBM RPC와 같은 구조). 그 밖의 경고(`public.rls_auto_enable` anon 실행 가능, 유출 비밀번호 보호 꺼짐)는 이 저장소 SQL에 없는 기존 항목이다. **확인 필요**
- 적용 순서: `field_sql_v04_apply.md` (CHECK → APPLY → VERIFY → PR merge). DB가 먼저 적용된 지금도 운영 화면(v1.0)은 그대로 동작한다. **코드 기준·로컬 시험** (실제 운영 화면에서는 확인 필요)
- 바뀌는 것: 오후 TBM 작업정지(사유·내일 이월/정지 종료), 작업계획 다른 팀 인원 검색·투입(공식 소속 불변), 팀장 출역 관리(출근·퇴근 확정, 수정 이력), 소장 출역 현황(조회)·관리자 정정, 글자·버튼 크게. 운영 화면 표시 v1.1, 사용 가이드 v1.1.
- 되돌리기: 화면은 PR revert, DB는 `field_sql_v04_rollback.sql`(데이터 삭제 없음, 작업정지 기록이 생기면 `ROLLBACK_BLOCKED`로 멈춤).
- 자동시험 (로컬, 2026-10-15) **확인됨**
  - `tests/sessions`: v03 33개 통과, v04 89개 통과, v04 화면 시험 통과, 기존 화면 시험(ui.mjs) 통과
  - SQL `run_sql_tests.sh` 통과, 운영 화면 일치(`make_prod_pages.py --check`) 통과
  - e2e: 실패 14건 = main `e479c2f` 기준 실패 14건과 같은 단계·같은 원인 (신규 실패 0). S8 두 단계는 이름만 v1.0→v1.1로 바뀜

## 순차 작업 반영 (PR #17, 2026-10-05)

- **확인됨**: `field_v03_sequential_sessions` 운영 migration, CHECK `ready=true` → APPLY 성공 → VERIFY `ok=true`.
- **확인됨**: 보고 3·작업 3·사진 메타데이터 6·이력 21, 기존 보고 모두 `session_no=1`. 적용 직전/직후 원본 9종 지문 일치(보고·작업·배정·사진·이력·인원·소속·역할·credential). UUID 재발급/삭제 없음. 활성 53·로그인 등록 53 유지.
- **확인됨**: 새 화면 + 실제 운영 API의 MEMBER/TEAM_LEADER/SITE_MANAGER/ADMIN 로그인·조회 통과, 시험 세션 로그아웃. 운영 TBM 생성·수정 없이 기존 완료 작업의 읽기 전용 표시 확인.
- **확인됨**: 격리된 PostgreSQL에서 순차 작업 33개 검증 및 모바일 A~F 화면 검증 통과. 실제 다중 연결 경합 시험은 아니며 advisory lock과 미완료 작업 유일 인덱스로 보호.
- **코드 기준**: PR #17은 완료 후 빈 작업 2·3… 생성, 완료 기록 잠금, MEMBER 최신 배정, 소장 작업별 조회를 포함한다. MEMBER의 Season 2 오늘 작업은 `tbm_my_today`를 사용한다. 기존 로그인·명단·Edge Function 변경 없음.
- 운영 반영 절차: `field_sql_v03_apply.md`. 아래는 PR #16 작성 당시의 기존 기준이며, 순차 작업 관련 내용은 이 절을 우선한다. PR/Pages 최종 배포 결과는 PR #17 기록을 확인한다.

## Git·배포

- MAIN: `dfcf91c` = PR #15 merge (2026-10-05 07:02 KST, 사용자 계정). **확인됨**
  - PR #15 마지막 커밋 2개는 사용자 계정 커밋이다.
    - `366afcf`: 로그인 서버의 Apps Script 최초 이관 경로를 제거했다.
    - `a3e75cb`: 같은 내용을 README에 반영했다.
- GitHub Pages: `https://seungbin2011-web.github.io/attendance-test/`
  - `main` dfcf91c 기준 "pages build and deployment" #92가 성공했다 (07:03 KST). **확인됨** (Actions 기록)
  - 실제 페이지 응답은 이 Claude 환경에서 github.io 접속이 막혀 직접 열어 보지 못했다. **확인 필요** (휴대폰으로 확인)
- 롤백 기준: 브랜치 `rollback/pre-s2-main-20261003` = `d50f56a` (Season 2 승격 전 main). **확인됨**
  - 태그 `pre-s2-main-20261003`은 원격에 없다 (이 환경 권한으로 태그 생성 불가).
- 작업 브랜치: `claude/busy-davinci-ndk9a3` (PR #15 merge 후 main에서 다시 시작)

## Supabase

- 프로젝트: work-status-test, project ref `cgeciwdibirvdsucgrnz`
- 적용된 SQL: `personnel_auth_v10`·`v11`·`v12` 함수가 있다. 명단 동기화(2026-10)와 로그인 번호 선등록도 실행됐다. **확인됨** (읽기 전용 조회)
  - 사용자가 SQL Editor에서 실행했다.
  - 적용 묶음은 `season2_apply_20261004.zip`이고 Git 밖에 있다.
- 인원 (2026-10-05 조회) **확인됨**
  - 사람 행 65 = 활성 53 + 비활성 12 (삭제 없음)
  - 팀: 1팀 15 / 2팀 23 / 3팀 9 / 자재팀 1 / 현장·관리 5
    - 팀 코드: `CONSTRUCTION_1`·`CONSTRUCTION_2`·`CONSTRUCTION_3`·`MATERIAL`·`SITE_MANAGEMENT`, 현장 `YONGIN_PILOT`
  - 역할: TEAM_LEADER 13 / MEMBER 35 / SITE_MANAGER 4 / ADMIN 1 (`ADMIN_DEPT`)
  - 미지정 0, 소속 여러 개 0, 비활성 인원의 현재 소속 0, 비활성 인원의 현재 역할 0
  - 김태형 inactive, 김태영 active (별도 UUID)
- 로그인 번호 (`member_pins.login4_hash`, bcrypt) **확인됨**
  - 활성 53명 모두 등록 (선등록 53건)
  - 비활성 인원 등록 0
  - 최초 이관(`first_login`) 0건
- 업무계정 (`login_profiles`) 5개 **확인됨**
  - 관리자(ADMIN), 소장(MANAGER), 1팀장팀·2팀장팀(LEADER), 자재팀(MATERIAL, 사용 중지)
  - 1팀장팀·2팀장팀은 지금 없는 옛 팀 이름(공사1팀·공사2팀)에 묶여 있어, TBM 화면에서 "팀 정보 준비 안 됨"으로 막힌다. **코드 기준** (현장 사용은 개인 로그인)
- TBM 데이터 (조회 시점): 보고 3, 작업 3, 사진 6, 이력 21. 지우거나 초기화하지 않는다.
- 조직도 함수 `pilot_org_chart`: anon 실행 불가, authenticated 실행 가능 (함수 안에서 SITE_MANAGER·ADMIN만 허용). **확인됨**

## Edge Function `member-login`

- main 코드: v0.4. 이름 + 뒤 4자리를 `pilot_member_login4`로 확인한다. **코드 기준**
  - Apps Script 최초 이관 경로는 제거됐다 (`366afcf`). 번호가 없는 사람은 "관리자에게 문의" 안내로 거절한다.
  - 개인 PIN 6자리 로그인은 유지된다.
- 배포 상태
  - Supabase 로그 기준으로 함수 배포 번호는 3이다. 07:19 KST까지 200 응답이 있다. **확인됨** (로그)
  - 배포된 코드가 main의 `366afcf` 버전과 같은지는 확인하지 못했다. **확인 필요** (Dashboard → Edge Functions → member-login → Code)
- Verify JWT: 꺼짐이어야 한다 (로그인 전 호출). **확인 필요** (Dashboard)
- DB의 `pilot_member_login4_migrate`(v12)는 남아 있지만, 지금 로그인 서버는 호출하지 않는다. **코드 기준**

## 로그인 구조 (코드 기준)

1. `index.html`에서 이름 + 뒤 4자리를 입력한다.
2. `member-login`이 `pilot_member_login4`로 bcrypt를 확인한다. 실패 한도는 이름 5회 → 30분 잠금, IP·전체 한도가 있다.
3. 개인 Supabase 세션을 발급한다 (16시간).
4. 화면이 `pilot_whoami`로 역할을 받아 이동한다.
- 비활성 인원, 명단 밖 사람, 미등록 번호, 같은 이름을 구분할 수 없는 경우(AMBIGUOUS)는 로그인을 거절한다.

## 화면

- Season 2 운영
  - `index.html`: 통합 로그인·관리자 명부
  - `member.html`, `tbm_report.html`, `tbm_manager.html`
  - `organization.html` (v3.0, Supabase)
- Season 2 시험(유지): `personnel_test.html`, `member_test.html`, `tbm_report_test.html`, `tbm_manager_test.html`, `admin_sql_test.html`
- Season 1: `index_season1.html`(출퇴근, 이전 루트 앱 그대로), `leader.html`(팀장), 그 밖의 `*_test.html`

## 남아 있는 Apps Script 의존 (코드 기준)

- `index_season1.html`: 출퇴근 기록 (Season 1 그대로)
- `member.html` "오늘 작업": Season 1 TBM DB(Apps Script)를 조회한다. Season 2 TBM과 연결돼 있지 않다.
- `member.html` "우리 팀": Season 1 세션일 때만 Apps Script를 쓴다. 개인 로그인은 Supabase `pilot_my_team`을 쓴다.
- `leader.html`, `admin_test.html`, `admin_cleanup_test.html` 등 Season 1 화면
- `organization.html`·`personnel_test.mjs`에는 Apps Script 주소 상수만 남아 있고, 운영 경로에서는 호출하지 않는다.
- Apps Script `personnelOrg` 공개 조회는 이 저장소 밖에 있다. 민감정보(전화번호·출입증번호 등)가 노출되는지는 확인하지 못했다. **확인 필요**
  - 막는 방법: Apps Script `doGet`에서 `action=personnelOrg`이면 `{success:false}`를 돌려주게 하고 새 버전으로 배포한다.

## 자동시험 (main dfcf91c, 2026-10-05) **확인됨**

- SQL: 전체 통과
- e2e: 96단계 중 90 통과, 6 실패
  - S6 최초 이관 3단계, S8 운영 화면 3단계가 실패한다.
  - 원인: `366afcf`에서 최초 이관을 제거했는데, 시험이 아직 그 동작(번호 없는 사람의 첫 로그인 등록)을 전제로 한다. 앱 오류가 아니라 시험 기대값이 맞지 않는 것이다. → `docs/BACKLOG_FIELD_TEST.md`

## 롤백 기준

- 화면: main을 `rollback/pre-s2-main-20261003`(`d50f56a`)으로 되돌린다.
- 로그인 서버: 이전 코드로 다시 Deploy한다.
- DB (위에서부터 순서대로, 삭제 없음)
  1. `personnel_roster_v10_rollback.sql`: 가장 최근 명단 동기화 1회
  2. `personnel_auth_v12_rollback.sql`
  3. `personnel_auth_v11_rollback.sql`
  4. `personnel_auth_v10_rollback.sql`
- 현장 사용이 시작된 뒤의 롤백은 새로 생긴 TBM·로그인 기록에 영향을 줄 수 있다. 실행 전에 사용자 확인을 받는다.

## 이 Claude 환경의 권한 (2026-10-05 진단)

- GitHub
  - 작업 브랜치 push 가능
  - 보호용 브랜치 생성 가능
  - 태그 push 불가
  - PR 생성·수정 가능
  - PR merge: 도구와 권한은 있으나 실행해 보지 않았다.
- Supabase
  - DB: 읽기 전용 (`supabase_read_only_user`). 조회·로그 조회는 가능하다.
  - Edge Function 배포: 불가 (도구 없음, `*.supabase.co`·`api.supabase.com` 네트워크 차단)
- `script.google.com`, `seungbin2011-web.github.io`: 네트워크 차단
