# 순차 작업 운영 반영

기존 `daily_reports.id`를 유지하고 `session_no`만 기본값 1로 추가합니다. 유일성은 현장·팀·날짜·작업번호이며, 미완료 작업은 팀·날짜당 하나입니다. 퇴근 마감 시각이 있으면 계획/TBM/사진 RPC와 사진 업로드 정책에서 수정을 차단합니다.

1. `field_sql_v03_check.sql`: 첫 결과 `ready=true`. 두 번째 결과 `data_fingerprint`를 보관합니다. 원본 함수가 변경됐거나 이미 적용된 경우 중단합니다.
2. `field_sql_v03.sql`: 단일 트랜잭션으로 실행합니다. 5초 안에 잠금을 얻지 못하면 중단합니다. 모든 기존 현장 테이블 행을 내부 비교해 원본 필드 변화가 있으면 전체 rollback합니다. 인원·역할·로그인·Storage 파일을 변경하지 않습니다.
3. `field_sql_v03_verify.sql`: 첫 결과 `ok=true`, 두 번째 지문이 CHECK와 같고 세 번째 결과 기존 보고 모두 작업 1이어야 합니다. 동시 운영 저장으로 지문이 달라졌다면 원인을 확인하기 전 merge하지 않습니다.
4. 새 프런트엔드로 실제 로그인·조회, 기존 완료 보고/사진 확인 후 PR을 main에 merge합니다. Pages 완료 후 루트 로그인과 팀장/팀원/소장 화면을 재확인합니다.

`tbm_open_next(previous UUID)`는 팀장 소속·오늘 날짜·이전 마감을 검사합니다. 같은 요청을 다시 보내면 기존 다음 작업을 반환하며 복사하지 않습니다. 저장은 `report_id`로 대상을 명시합니다. 구버전 화면의 ID 없는 저장은 작업 1만 대상으로 삼으므로 작업 2를 덮어쓰지 못합니다.

실패하면 merge하지 않습니다. APPLY 도중 오류는 트랜잭션 전체 취소됩니다. 적용 후 새 작업이 생겼다면 구버전의 하루 하나 제약으로 되돌리지 않습니다. 기존 UUID/다중 작업/완료 잠금을 유지하며 원인을 수정하고 재검증합니다. 완료 데이터를 삭제하거나 재생성하는 롤백은 제공하지 않습니다.

보안 점검: 신규 RPC는 authenticated만 실행할 수 있고 내부에서 실제 소속·역할·세션을 확인합니다. `tbm_my_today`는 로그인 본인의 배정만 조회합니다. 테이블 직접 접근 차단은 유지합니다. Supabase의 [인증 사용자 SECURITY DEFINER 알림](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable)은 이 구조에서 예상되는 항목이며 권한 부정 시험으로 접근 범위를 확인합니다.
