# 운영 절차 (RUNBOOK)

Claude가 운영 작업(DB 변경, 로그인 서버 배포, main 반영)을 할 때 따르는 순서다.
공통 원칙은 다음 네 가지다.
- 한 단계가 정상이어야 다음 단계로 간다.
- 실패하면 즉시 멈추고 한국어로 보고한다.
- 데이터를 자동으로 대량 삭제하지 않는다.
- 하지 않은 일을 했다고 보고하지 않는다.

## 0. 시작 전 확인 (모든 작업 공통)

1. `CLAUDE.md`, `docs/CURRENT_STATE.md`를 읽는다.
2. `git fetch`로 원격 main과 작업 브랜치를 확인한다. 작업 브랜치의 PR이 이미 merge됐으면 최신 main에서 브랜치를 다시 시작한다.
3. 실제 DB 상태를 읽기 전용 SELECT로 확인한다: 적용 버전, 활성·비활성 수, 팀·역할 수.
4. 이번 작업에 필요한 권한이 있는지 확인한다 (`docs/CURRENT_STATE.md` 맨 아래). 없으면 시도를 반복하지 말고, 사용자가 실행할 순서를 준비한다.

## 1. DB 변경

순서: 사전 CHECK → migration → (명단이면) roster sync → VERIFY

1. 사전 CHECK (읽기 전용)
   - 이미 적용된 버전은 다시 실행하지 않는다. 대상 함수·표가 있는지 `to_regprocedure` 등으로 본다.
   - 명단 변경이면 `personnel_roster_v10_check.sql`에 명단을 넣어 실행한다.
     - `ready=true`, 충돌 0, 이름 중복 0, 숫자가 기준과 같을 때만 다음으로 간다.
     - 비활성 처리 대상이 예상과 같은지 사람 수로 확인한다.
2. migration
   - 저장소 SQL 파일 하나를 SQL Editor 새 탭에서 단독 실행한다. 파일은 `begin … commit` 한 트랜잭션이고 사전 점검(`PRECHECK`)을 포함한다.
   - 바로 짝이 되는 `_check.sql`을 별도 탭에서 실행해 `expected`와 비교한다.
   - 새 SQL을 만들 때는 rollback 파일과 check 파일을 같이 만들고, `tests/run_sql_tests.sh`에 적용·롤백·재적용 시험을 넣는다.
3. roster sync (명단 변경일 때만)
   - `personnel_roster_v10_sync.sql`에 명단을 넣어 실행한다. 한 트랜잭션이라 맞지 않으면 전체가 취소된다.
   - 명단 밖 인원은 DELETE하지 않고 정리한다.
     - inactive 처리
     - 현재 소속 종료 `valid_to`, 현재 역할 종료 `revoked_at`
   - 기존 사람은 UUID를 재사용한다. 새 사람은 새 UUID를 쓴다. 이름만 바꿔 다른 사람에게 재사용하지 않는다.
4. VERIFY (읽기 전용)
   - `personnel_roster_v10_verify.sql`이 `ok=true`여야 한다.
     - 활성 수, 팀별 수, 역할별 수가 기준과 같다.
     - `unassigned`·`multi_membership`·`multi_role`·`mismatches` 0
     - `active_not_in_roster`·`inactive_with_membership`·`inactive_with_role` 0
   - 로그인 번호 등록 수: `personnel_auth_v12_check.sql`의 `login_registered` / `active_people`
   - TBM·사진 수가 변경 전보다 줄지 않았는지 본다.
5. 실패하면
   - 다음 단계로 가지 않는다. 결과 원문을 사용자에게 보여 준다.
   - 원인을 최소 수정한다. 사전 점검이 맞지 않는 것이면 실제 DB 내용과 저장소 사본의 차이를 먼저 확인한다.
     - 예: SQL Editor 붙여넣기로 생긴 CR 줄바꿈
   - 되돌릴 때는 rollback 파일을 위에서부터 순서대로 쓴다 (`docs/CURRENT_STATE.md` 롤백 기준).

민감정보: 명단·번호가 들어간 SQL은 Git 밖에서 만들고 사용자에게 파일로 전달한다. 로그인 번호는 작업 환경에서 bcrypt 해시로 바꿔 해시만 넣는다. 평문 번호를 Supabase SQL에 넣지 않는다.

## 2. Edge Function (`member-login`)

1. 기존 버전 확인
   - Dashboard → Edge Functions → `member-login`에서 Code와 배포 기록을 본다. 지금 코드를 사용자가 보관해 둔다 (되돌리기용).
   - 필요한 DB 함수가 실제 DB에 있는지 읽기 전용으로 확인한다.
2. deploy
   - Code에 저장소 `supabase/functions/member-login/index.ts` 전체를 붙여 넣고 Deploy한다.
   - Verify JWT(Enforce JWT verification)는 꺼진 상태를 유지한다. 로그인 전 사용자가 부르는 함수다.
   - 비밀키는 Supabase가 자동으로 넣는다. 코드·저장소·채팅에 키를 적지 않는다.
3. 역할별 smoke test
   - 로컬: `bash tests/e2e/run_e2e.sh`로 실제 Edge 코드를 흉내 게이트웨이에서 실행한다.
   - 실제 서버
     - 사용자가 `docs/TEST_CHECKLIST.md`의 역할별 로그인을 휴대폰으로 확인한다. MEMBER·TEAM_LEADER·SITE_MANAGER·ADMIN 각 1명.
     - 틀린 번호, 비활성 인원, 명단 밖 이름은 거절돼야 한다.
   - Supabase 로그(`function_edge_logs`)에서 오류 응답(5xx)이 없는지 본다.
4. 실패하면 이전 코드로 다시 Deploy하고 원인을 확인한다.

## 3. GitHub → MAIN → Pages

1. branch: 지정된 작업 브랜치에서만 작업한다. 다른 브랜치에 push하려면 사용자 허락을 받는다.
2. 커밋 전 검사
   - `bash tests/run_sql_tests.sh`
   - `bash tests/e2e/run_e2e.sh`
   - `python3 tests/make_prod_pages.py --check`
   - 변경분에 실제 이름·번호·비밀값이 없는지 확인한다.
3. PR
   - 사용자가 요청할 때만 만든다. 본문은 한국어로 쓴다. 변경 요약, 적용 순서, merge 조건 체크리스트, 되돌리기를 넣는다.
4. merge gate (전부 통과해야 한다)
   - 실제 DB VERIFY `ok=true`, 로그인 서버 배포 확인
   - 자동시험 통과
   - 운영 화면 TEST 흔적 없음
   - 롤백 기준점이 원격에 있음 (브랜치 또는 태그)
   - PR 충돌 없음
   - 사용자의 merge 허락
5. MAIN: merge 전에 현재 main을 롤백 기준으로 남긴다. 예: `rollback/<설명>-<날짜>` 브랜치
6. Pages 확인
   - Actions의 "pages build and deployment"가 merge 커밋으로 성공했는지 본다.
   - 루트가 통합 로그인인지, 운영 화면에 `_test` 링크·TEST 표시가 없는지 확인한다. 이 환경에서 github.io가 막혀 있으면 사용자 휴대폰 확인으로 대신한다.
7. 실패하면
   - main을 롤백 기준으로 되돌리는 PR을 만들고, 사용자 확인 뒤 merge한다.
   - 강제 push·히스토리 재작성은 하지 않는다.

## 4. 하지 않는 것

- 사람 행·TBM·사진·이월·배정 기록 DELETE
- 사람 UUID 합치기, 이름 바꿔 재사용
- 사용자 확인 없는 `DROP`·`TRUNCATE`·대량 `UPDATE`·RLS 교체·`public.works` 권한 변경
- Apps Script 삭제·기능 추가 (Season 2는 Apps Script를 기준으로 쓰지 않는다)
- 실제 사람 계정으로 자동 로그인 시험
- 운영 화면(`index.html`·`member.html`·`tbm_report.html`·`tbm_manager.html`) 직접 수정
  - 시험 화면을 고친 뒤 `tests/make_prod_pages.py`로 다시 만든다.
