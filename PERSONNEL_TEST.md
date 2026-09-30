# 인원DB 통합 로그인 시험 v0.9

진입점: `personnel_test.html`(일반 인원과 업무 계정 통합 로그인), `admin_sql_test.html`(관리자·소장 전용 인원 및 출결등급 관리). `index_test.html`·`leader_test.html`은 첫 화면으로, `admin_test.html`은 SQL 관리자 화면으로 연결한다. 기존 운영 페이지/Apps Script는 변경하지 않는다.

## 범위

Supabase `work-status-test`의 격리 스키마 `personnel_pilot_v1`에 가져온 52행을 사용한다. 기존 ID 중복은 UUID로 구분한다. Spreadsheet를 실시간으로 읽거나 편집 내용을 되쓰지 않는다.

| 시험 로그인 | 조회 | 편집 |
| --- | --- | --- |
| 관리자 / 소장 | 전체 52행 | 가능 |
| 1팀장팀 | 공사1팀 8행 | 불가 |
| 2팀장팀 | 공사2팀 8행 | 불가 |
| 일반 명부 인원 | 본인 팀원 화면 | 불가 |

수치는 최초 반입 기준이다. 관리자·소장·팀장은 Supabase 업무 계정으로 로그인하며 권한은 공개 JS의 역할 값이 아니라 서버 로그인 연결과 DB 함수에서 검사한다. 일반 인원은 통합 로그인 화면에서 기존 정식 인원DB의 이름과 휴대폰 번호 뒤 4자리로 본인 확인한 뒤 팀원 화면만 이용한다. 업무 계정 토큰은 같은 탭의 `sessionStorage`에만 보관해 페이지 이동과 새로고침을 지원한다.

## v0.9 적용 내용 (화면, 전환 단계 S0-4·S0-5)

- `personnel_test.html` / `personnel_test.mjs` TEST v0.9
  - 일반 인원·팀장: 이름 + 개인 PIN 6자리 → Edge Function `member-login` → 개인 Supabase 세션
  - 로그인 후 역할·팀은 서버 `pilot_whoami` 결과로만 정한다. (화면·로그인 응답의 역할 값을 믿지 않음)
  - 임시 PIN으로 처음 로그인하면 "개인 PIN 변경" 화면이 먼저 나온다. PIN은 브라우저 저장소에 남기지 않는다.
  - `?next=` 이동은 허용된 시험 화면과 역할 조합만 따른다.
  - 전환 기간: 휴대폰 뒤 4자리(Apps Script) 경로를 `LEGACY_ROSTER_LOGIN = true`로 유지한다. PIN 발급이 끝나면 false로 바꾼다.
  - 관리자 전용 `admin_sql_test.html`은 개인 PIN 로그인을 받지 않는다.
- `leader_test.html` v0.42: 로그인 조건에 새 인증 출처 `supabase-pin` 허용 (그 외 변경 없음)
- `admin_test.html`은 변경하지 않는다. 개인 PIN 로그인으로는 소장·관리자 권한을 받을 수 없기 때문이다.

## v0.8 적용 내용 (SQL, 전환 단계 S0-2·S0-3)

- `personnel_auth_v08.sql`: 개인 PIN(해시), 로그인 시도 기록·잠금, `pilot_whoami`, `require_actor`
  - 같은 이름 연속 5회 실패 시 30분 잠금, IP별 15분 20회, 전체 1시간 100회 한도
  - PIN 로그인 허용 역할은 MEMBER·TEAM_LEADER. 소장·관리자는 업무계정만 사용
  - 퇴사(inactive)가 아니고 PIN이 발급된 사람만 로그인 가능. unknown 인원을 일괄 변경하지 않는다.
- `personnel_auth_v08_check.sql`: 적용 후 읽기 전용 확인 / `personnel_auth_v08_rollback.sql`: 되돌리기
- `personnel_membership_v08_template.sql`: 현장 명부 확인 후 쓰는 팀·소속·팀장 반입 템플릿 (비어 있으면 변경 없음)
- `supabase/functions/member-login`: 배포 방법은 폴더의 README 참고 (Verify JWT 끄기)

### 적용 순서 (사용자 작업)

1. SQL Editor에서 `personnel_auth_v08.sql` 전체 실행
2. `personnel_auth_v08_check.sql` 실행 → anon 실행 권한이 모두 false인지 확인
3. Edge Function `member-login` 배포 (Verify JWT 끄기)
4. 시험 인원에게 임시 PIN 발급 (SQL Editor, 결과 화면에서만 PIN이 보인다. 본인에게 직접 전달)

```sql
select legacy_user_id, display_name, team_name, temp_pin
from personnel_pilot_v1.admin_issue_temp_pins(
  array(select id from personnel_pilot_v1.people where legacy_user_id = '사용자ID' and display_name = '이름'),
  '시험 발급');
```

5. 잠금 해제·사용 중지가 필요할 때

```sql
select personnel_pilot_v1.admin_unlock_member((select id from personnel_pilot_v1.people where legacy_user_id = '사용자ID' and display_name = '이름'), '잠금 해제 사유');
select personnel_pilot_v1.admin_set_member_login((select id from personnel_pilot_v1.people where legacy_user_id = '사용자ID' and display_name = '이름'), false, '사용 중지 사유');
```

### 수동 설정 (Supabase Dashboard)

- Authentication → Sign In / Providers → "Allow new users to sign up" 끄기 (브라우저에서 임의 가입 방지)
- 개인 PIN 로그인은 가입 기능을 쓰지 않으므로 꺼도 동작한다.

### 로컬 시험

- `tests/run_sql_tests.sh`: 흉내 DB에서 SQL 적용·권한·잠금·롤백 시험
- `tests/e2e/run_e2e.sh`: 흉내 게이트웨이 + 실제 Edge Function 코드 + Chromium으로 역할별 이동 시험

## v0.7 적용 내용

- 이름과 휴대폰 뒤 4자리 로그인 결과에서 직급·권한을 다시 판별한다.
- 현장소장·소장은 기존 관리자 현황, 팀장은 기존 팀장 TBM, 일반 인원은 팀원 홈으로 이동한다.
- 별도 Supabase `관리자` 업무 계정만 새 인원관리 화면을 사용한다.

## v0.6 적용 내용

- 통합 로그인 후 새 인원관리 화면은 관리자 계정에만 표시한다.
- 소장은 기존 `admin_test.html`, 팀장은 기존 `leader_test.html`로 바로 이동하도록 이전 화면 흐름을 복원했다.
- 일반 인원의 `member_test.html` 이동과 기존 소장 권한은 유지한다.

## v0.5 적용 내용

- 로그인과 일반 인원·팀장·소장 화면은 네이비·파란색을 유지한다.
- Supabase 역할이 `ADMIN`으로 확인된 관리자 화면에만 초록색 관리 테마를 적용한다.
- 일반 인원 로그인 v0.4 변경을 포함하며 배포 캐시 주소를 v0.5로 갱신했다.

## v0.4 적용 내용

- 통합 로그인 기본 디자인을 기존 출퇴근 화면의 네이비·파란색 톤으로 통일했다.
- CSS와 모듈 주소에 버전 값을 추가해 GitHub Pages 캐시로 이전 초록색 화면이 섞이는 문제를 방지했다.
- 일반 명부 인원도 이름과 휴대폰 번호 뒤 4자리로 로그인할 수 있으며, 성공 시 팀원 화면으로 이동한다.
- 일반 인원의 휴대폰 정보는 Supabase 시험 명부에 없으므로 기존 정식 인원DB에서 검증한다. 관리자·소장·팀장 업무 권한은 계속 Supabase 인증으로만 부여한다.

## v0.2 적용 내용

- `personnel_auth_v02.sql`: 출결등급 A/B/C, 등급 변경 이력, 관리자·소장 전용 변경 함수 추가.
- 관리자·소장은 전체 명부의 출결등급을 변경할 수 있고 사유·변경 전후 값·변경자·시간이 저장된다.
- 팀장은 담당 팀 명부를 조회하지만 인원 편집과 출결등급 변경은 할 수 없다.
- 자재팀 시험 계정은 운영 로그인 범위에서 비활성화한다.
- 로그인 성공 후 기존 관리자 또는 팀장 업무 화면으로 이동할 수 있다.

## 적용 상태 및 검증

- 2026-09-23 Supabase에 v0.2 SQL 적용 완료. 기존 명부 52행은 모두 A등급으로 유지됐다.
- 활성 로그인은 관리자 1개·소장 1개·팀장 2개이며 자재팀 시험 계정은 비활성화됐다.
- `authenticated`는 등급 변경 RPC를 실행할 수 있지만 이력 테이블을 직접 조회할 수 없다. 함수 안에서 관리자·소장 역할을 다시 검사한다.
- HTML/JS 문법과 역할별 화면 진입 조건을 점검했다. 실제 등급 변경 저장과 모바일 화면은 GitHub Pages 배포 후 확인해야 한다.
- 공개 가능한 Supabase publishable key만 포함한다. service-role/secret key, 비밀번호, 원본 인원 명단, 계정 생성 도구는 배포 파일에 포함하지 않는다.
- 명부 팀 수정은 계정 권한이나 기존 소속 관계를 변경하지 않는다. 시험 비밀번호는 실운영에 사용하지 않는다.

`admin_sql_test.html`은 Supabase 인원 명부와 출결등급을 다룬다. 기존 관리자 화면의 출결·TBM 데이터는 아직 Apps Script에 있으며 통합 로그인 후 기존 화면으로 연결한다.

PR 병합 후 GitHub Pages에서 관리자·소장 등급 변경, 팀장 변경 거부, 모바일 화면을 확인한다. 시험 비밀번호는 운영 전 역할별 개별 비밀번호로 교체한다. main 자동 병합은 하지 않는다.
