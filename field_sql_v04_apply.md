# field v0.4 운영 반영 (TBM / 출역 관리 개선 v0.1)

작업정지 · 타 팀원 투입 · 팀장 출역 관리. 한 번에 한 단계씩, 앞 단계가 맞을 때만 다음으로 간다.

## 순서 (DB 먼저 → 화면)

DB v0.4는 지금 운영 화면(v1.0)과 같이 써도 된다 (새 열·새 표·새 RPC만 더하고, 기존 RPC 응답은 항목만 늘어남).
그래서 **DB를 먼저 적용하고, 확인한 뒤 PR을 merge**한다. 화면만 먼저 나가면 작업정지·출역 버튼이 "서버 준비 전"으로 막힌다.

1. **CHECK** — SQL Editor 새 탭에 `field_sql_v04_check.sql` 전체를 붙여 실행 (읽기 전용)
   - 첫 결과 `ready = true` 이어야 한다. 하나라도 false면 멈추고 결과를 그대로 전달한다.
   - 두 번째 결과 `data_fingerprint`를 메모장에 복사해 둔다.
   - 세 번째 결과 숫자(보고·작업·배정·사진·이력·활성 인원)를 적어 둔다.
2. **APPLY** — 새 탭에 `field_sql_v04.sql` 전체를 붙여 실행
   - 한 트랜잭션이다. 오류가 나면 전부 취소되고 아무것도 바뀌지 않는다. 오류 문구를 그대로 전달한다.
   - 잠금을 5초 안에 못 얻으면(`lock timeout`) 팀장들이 저장 중인 것이다. 잠시 뒤 다시 실행한다.
3. **VERIFY** — 새 탭에 `field_sql_v04_verify.sql` 전체를 붙여 실행 (읽기 전용)
   - 첫 결과 `ok = true`
   - 두 번째 결과 `data_fingerprint`가 1단계와 **같아야** 한다 (적용 중 다른 저장이 없을 때). 다르면 merge하지 말고 원인부터 본다.
   - 세 번째 결과 숫자가 1단계보다 줄지 않아야 한다. `attendance_records`는 0이다.
4. **PR merge** — 사용자가 직접 한다. Pages 배포가 끝나면(보통 1~2분) 휴대폰에서 `docs/TEST_CHECKLIST.md`의 "v0.4" 항목을 확인한다.

## 바뀌는 것

| 구분 | 내용 |
| --- | --- |
| 작업정지 | `report_tasks.alert / result`에 `STOPPED` 추가. 사유(`alert_note`)·조치(`alert_action`)·시각(`alert_at`) 저장. 처리 방향은 기존 이월 열(`carry_over`, `carry_status=PENDING`)을 그대로 쓴다. 새 RPC `tbm_task_stop(작업, 사유, CARRY/END/CANCEL)` |
| 타 팀원 투입 | 같은 현장의 현재 인원(퇴사·비활성 제외)이면 다른 팀 작업에 넣을 수 있다. `task_assignments.home_team_id`에 배정 당시 공식 소속을 남긴다. 공식 소속(`memberships`)은 바꾸지 않는다. 새 RPC `tbm_site_people` |
| 출역 관리 | 새 표 `attendance_records`(하루·사람 1행) + `attendance_history`(모든 입력·수정). 직접 접근은 막고 RPC로만: `tbm_attendance_today`·`tbm_attendance_save`(팀장 오늘 자기 팀 / 관리자 7일 안 정정)·`tbm_attendance_overview`(현장관리·관리자 조회) |
| 바뀌는 기존 함수 | `check_members`, `replace_assignments`, `report_json`, `tbm_task_result`(정지 작업 재입력 막음), `tbm_site_overview`(정지 수·사유), `tbm_my_today`(정지 표시, 다른 팀 작업도 보임) |

바뀌지 않는 것: 기존 보고·작업·배정·사진·이력 행(APPLY 안에서 전후 비교, 다르면 전체 취소), 인원·소속·역할·로그인 표, Storage, 로그인 서버, Apps Script.

## 되돌리기 (문제가 생겼을 때만, 사용자 확인 후)

- 화면: PR merge 커밋을 revert한다 (v1.0 화면으로 돌아감).
- DB: `field_sql_v04_rollback.sql` — 함수·제약만 v03으로 되돌린다. 데이터는 지우지 않는다.
  - 출역 표와 `home_team_id` 열은 남긴다 (RPC가 없어져 화면에서는 안 보임). 다시 `field_sql_v04.sql`을 실행할 수 있다.
  - **작업정지 기록이 한 건이라도 있으면 `ROLLBACK_BLOCKED`로 멈춘다.** 기록을 지우는 되돌리기는 만들지 않았다.
    현장에서 작업정지를 한 번 쓰고 나면 DB는 v0.4로 유지하고, 문제는 고쳐서 다시 적용하는 쪽으로 간다.

## 보안 확인 (로컬 시험으로 확인됨)

- 새 RPC는 `authenticated`만 실행. `anon`·`service_role` 실행 불가. 함수 안에서 실제 역할·소속·세션을 다시 확인한다.
- 팀원·현장관리는 출역 저장 불가(`FORBIDDEN`), 다른 팀 팀장은 `TEAM_FORBIDDEN`, 출역 표 직접 조회 `permission denied`.
- 같은 요청을 두 번 보내도 한 번만 반영(`request_id`). 출역 수정은 이력에 전후 값·입력자·역할이 남는다.
- Supabase 보안 알림의 "authenticated SECURITY DEFINER 실행 가능"은 이 구조(RPC로만 접근)에서 예상되는 항목이다.

## 시험 (실제 Supabase에 연결하지 않음)

- `cd tests/sessions && node v04.mjs` — CHECK → APPLY → VERIFY → 되돌리기 → 재적용, 작업정지·타 팀원·출역 권한 89개
- `cd tests/sessions && node ui_v04.mjs` — 화면(팀장·소장·관리자·팀원), 320/360/390 폭
- `bash tests/e2e/run_e2e.sh` — v04를 포함한 전체 회귀 (main 기준 실패 14건과 같은지 비교)
