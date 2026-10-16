# field v0.5 운영 반영 (TBM v1.1 현장 UX 보정 — 이월 취소)

잘못 이월한 작업을 오늘 작업계획에서 정정하는 서버 함수 `tbm_carry_cancel` 하나만 더한다. 표·열·제약은 바꾸지 않는다.

## 순서 (DB 먼저 → 화면)

v0.5 DB는 지금 운영 화면(v1.1)과 같이 써도 된다 (새 RPC만 추가). **DB를 먼저 적용하고 확인한 뒤 PR을 merge**한다.
화면만 먼저 나가면 「이월 취소」를 누를 때 "서버 준비(DB v0.5) 뒤에 쓸 수 있습니다" 안내만 나온다 (다른 기능은 그대로 동작).

1. **CHECK** — SQL Editor 새 탭에 `field_sql_v05_check.sql` 전체 실행 (읽기 전용)
   - 첫 결과 `ready = true`. 아니면 멈추고 결과를 전달한다.
   - 두 번째 결과 `data_fingerprint`를 메모해 둔다.
2. **APPLY** — 새 탭에 `field_sql_v05.sql` 전체 실행 (한 트랜잭션, 오류면 전부 취소)
3. **VERIFY** — 새 탭에 `field_sql_v05_verify.sql` 전체 실행 (읽기 전용)
   - 첫 결과 `ok = true`, 두 번째 결과 지문이 1단계와 같아야 한다.
4. **PR merge** — 사용자가 직접. 배포 뒤 `docs/TEST_CHECKLIST.md`의 「v1.2」 항목을 휴대폰으로 확인한다.

## 이월 취소가 하는 일

| 경우 | 오늘 작업 | 어제 작업 | 이력 |
| --- | --- | --- | --- |
| 아직 이어받지 않은 후보 | 변화 없음 | `carry_status` PENDING → DROPPED (다음 날부터 후보에 안 나옴) | 어제 보고에 `CARRY_CANCELLED` (누가·언제·사유·전후) |
| 오늘 계획에 이미 이어받은 작업 (결과 전) | 오늘 작업에서 뺀다 (`is_active=false`, 행은 남김) | CONTINUED → DROPPED | 오늘 보고와 어제 보고 둘 다 |

- 어제 보고·작업 결과·사진·배정은 지우거나 고치지 않는다 (이월 상태 값만 바뀜).
- 결과가 이미 난 작업, 다른 팀 작업, 14일이 지난 작업은 거절한다.
- 같은 요청을 다시 보내도 한 번만 반영된다.

## 되돌리기 (문제가 생겼을 때만, 사용자 확인 후)

- 화면: PR merge 커밋 revert.
- DB: `field_sql_v05_rollback.sql` — 함수만 지운다. 이미 취소된 이월(DROPPED)과 이력은 남는다. 다시 `field_sql_v05.sql`을 실행할 수 있다.

## 시험 (로컬)

- `cd tests/sessions && node v05.mjs` — CHECK → APPLY → VERIFY → 되돌리기 → 재적용, 후보·오늘 이어받은 작업 취소, 권한, 어제 기록 불변 (30개)
- `cd tests/sessions && node ui_v12.mjs` — 화면 (전일 이월 접힘·이월 취소·저장 후 홈·실패 유지·로그인 뒤로가기·소장 PC)
