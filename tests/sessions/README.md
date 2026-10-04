# 같은 날 순차 작업 회귀 시험

운영 서버에 연결하거나 운영 로그인 번호를 사용하지 않습니다. 기존 가짜 Supabase fixture와 실제 SQL을 PGlite(PostgreSQL 18 WASM)에 적용합니다.

이 디렉터리에서 `pnpm install --frozen-lockfile` 후 `pnpm test`, `pnpm test:ui`를 실행합니다. Node 22 이상, Chrome이 필요합니다. 다른 설치 브라우저는 `TEST_BROWSER_CHANNEL`로 지정합니다. UI 시험은 모든 요청을 로컬 파일·시험 SQL로 처리하며 외부 요청을 차단합니다. 사진 전송은 작은 시험 이미지로 대체하되, 준비/확인 RPC와 Storage 읽기·쓰기 정책은 실제 SQL로 검사합니다.

- 기존 완료 보고를 v02에서 만든 뒤 CHECK→v03→VERIFY, 모든 원본 필드·UUID 비교
- A~F: 완료 잠금, 빈 다음 작업, 독립 계획/TBM/사진, 3개 이상, 새 조회·로그아웃·세션 복원, 소장별 상세
- MEMBER 최신 진행 작업 우선, 이전 완료 작업 접기, 타인 배정 노출 차단
- 9개 변경 RPC 및 대기 사진 업로드 거부, MEMBER/타팀/익명 새 작업 생성 거부
- 중복 요청 같은 UUID, 이전 화면의 report_id 없는 저장은 작업 1만 대상으로 하여 새 작업 덮어쓰기 방지
- 모바일 390px: 직접 새 작업 열기·계획 저장·출근 TBM, 완료 상세 사진·이력, 페이지 오류·가로 넘침 점검

PGlite는 단일 연결입니다. 중복 요청 시험은 재시도 안전성을 확인하며 실제 다중 DB 연결 경쟁을 재현하지는 않습니다. 운영 SQL은 팀·날짜 단위 transaction advisory lock과 미완료 보고 partial unique index를 함께 사용합니다.

`artifacts/`의 스크린샷과 `node_modules/`는 Git에서 제외합니다. 기존 `tests/run_sql_tests.sh`는 v01/v02의 기존 동작을 검증하고 이 디렉터리는 v03 변경 후 동작을 별도로 검증합니다.
