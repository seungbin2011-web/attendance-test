#!/usr/bin/env bash
# 로컬 Postgres에서 Supabase 흉내 DB를 만들고 SQL 시험을 실행한다. (실제 Supabase에 연결하지 않음)
# 사용: sudo 권한 또는 postgres 사용자로 psql 실행 가능해야 함. 예) bash tests/run_sql_tests.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB="${TEST_DB:-attendance_sqltest}"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d "$DB")
run() { echo "== $1"; if [ "$(id -un)" = postgres ]; then "${PSQL[@]}" < "$1"; else su postgres -c "psql -X -q -v ON_ERROR_STOP=1 -d $DB" < "$1"; fi; }
# 시험 파일: 통과 줄(ok)은 숨기고 실패하면 즉시 중단
runtest() { local out; out="$(mktemp)"; if ! run "$1" > "$out" 2>&1; then cat "$out"; rm -f "$out"; echo "SQL TEST FAILED: $1"; exit 1; fi; grep -v '^ok ' "$out" || true; rm -f "$out"; }
admin() { if [ "$(id -un)" = postgres ]; then "$@"; else su postgres -c "$*"; fi; }
q() { if [ "$(id -un)" = postgres ]; then psql -X -qtA -d "$DB" <<< "$1"; else su postgres -c "psql -X -qtA -d $DB" <<< "$1"; fi; }
# 소속·역할 변경 템플릿: 실제 파일의 "변경 대상" 자리에 시험 명단만 넣어 실행
TEMPLATE="$ROOT/personnel_roles_v10_change_template.sql"
with_targets() { local f; f="$(mktemp)"; awk -v rows="$1" '{print} /^-- ▼ 변경 대상/{print rows}' "$TEMPLATE" > "$f"; echo "$f"; }
apply_targets() { local f out; f="$(with_targets "$1")"; out="$(mktemp)"; if ! run "$f" > "$out" 2>&1; then cat "$out"; echo "TEMPLATE FAILED"; exit 1; fi; rm -f "$f" "$out"; }
expect_fail() { local f out; f="$(with_targets "$1")"; out="$(mktemp)"; if run "$f" > "$out" 2>&1; then cat "$out"; echo "TEMPLATE SHOULD FAIL: $2"; exit 1; fi
  if ! grep -q "$2" "$out"; then cat "$out"; echo "TEMPLATE WRONG ERROR (want $2)"; exit 1; fi; rm -f "$f" "$out"; }
# 읽기 전용 점검 SQL 결과를 시험용 표로 저장
inspect_to() { local f; f="$(mktemp)"; { echo "drop table if exists test_util.$1;"; echo "create table test_util.$1 as"; sed '$ s/;[[:space:]]*$//' "$ROOT/personnel_roles_v10_inspect_readonly.sql"; echo ";"; } > "$f"; run "$f" > /dev/null; rm -f "$f"; }
counts() { q "select (select count(*) from personnel_pilot_v1.memberships) || '/' || (select count(*) from personnel_pilot_v1.role_assignments) || '/' || (select count(*) from personnel_pilot_v1.teams)"; }

admin "dropdb --if-exists $DB"
admin "createdb $DB"
run "$ROOT/tests/sql/00_mock_supabase.sql"
run "$ROOT/tests/sql/01_mock_seed.sql"
run "$ROOT/personnel_auth_v02.sql" > /dev/null
run "$ROOT/tests/sql/05_test_lib.sql"
run "$ROOT/tests/sql/06_snapshot.sql"
run "$ROOT/personnel_auth_v08.sql"
runtest "$ROOT/tests/sql/10_test_personnel_auth_v08.sql"
run "$ROOT/personnel_auth_v08_check.sql" > /dev/null
run "$ROOT/personnel_auth_v09.sql"
runtest "$ROOT/tests/sql/11_test_personnel_auth_v09.sql"
run "$ROOT/personnel_auth_v09_check.sql" > /dev/null
run "$ROOT/tests/sql/02_fixture_e2e.sql"
for f in "$ROOT"/field_sql_v0*.sql; do
  case "$f" in *_rollback.sql|*_check.sql) continue;; esac
  [ -e "$f" ] || continue
  run "$f"
  t="$ROOT/tests/sql/2$(basename "$f" .sql | sed 's/field_sql_v0//')_test_$(basename "$f" .sql).sql"
  if [ -e "$t" ]; then runtest "$t"; fi
  c="${f%.sql}_check.sql"; [ -e "$c" ] && run "$c" > /dev/null
done
# v0.10: 개인 로그인 역할 판정(팀원·팀장·소장) + 소속·역할 변경 템플릿
run "$ROOT/personnel_auth_v10.sql"
runtest "$ROOT/tests/sql/12_test_personnel_auth_v10.sql"
run "$ROOT/personnel_auth_v10_check.sql" > /dev/null
inspect_to inspect_before
before="$(counts)"; run "$TEMPLATE" > /dev/null
[ "$before" = "$(counts)" ] || { echo "EMPTY TEMPLATE CHANGED DATA"; exit 1; }
apply_targets "insert into role_targets values ('T-0008','시험일팀장','CONSTRUCTION_1','공사1팀','TEAM_LEADER'), ('T-0026','시험팀원가','CONSTRUCTION_1','공사1팀','MEMBER');"
inspect_to inspect_after
runtest "$ROOT/tests/sql/13_test_personnel_roles_v10_change.sql"
CHANGE2="insert into role_targets values ('T-0008','시험일팀장','CONSTRUCTION_1','공사1팀','MEMBER'), ('T-0026','시험팀원가','CONSTRUCTION_1','공사1팀','TEAM_LEADER'), ('T-0027','시험팀원나',null,null,'LEAVE'), ('T-0003','시험소장',null,null,'MEMBER'), ('T-0016','시험자재',null,null,'SITE_MANAGER');"
apply_targets "$CHANGE2"; apply_targets "$CHANGE2"
runtest "$ROOT/tests/sql/14_test_personnel_roles_v10_change2.sql"
expect_fail "insert into role_targets values ('T-0040','시험동명','CONSTRUCTION_2','공사2팀','MEMBER'), ('T-0026','틀린이름','CONSTRUCTION_1','공사1팀','MEMBER');" PERSON_NOT_UNIQUE
expect_fail "insert into role_targets values ('T-0040','시험동명',null,null,'TEAM_LEADER');" TEAM_REQUIRED
expect_fail "insert into role_targets values ('T-0028','시험퇴사자','CONSTRUCTION_2','공사2팀','MEMBER');" INACTIVE_PERSON
expect_fail "insert into role_targets values ('T-0040','시험동명','CONSTRUCTION_2','다른이름','MEMBER');" TEAM_NAME_MISMATCH
expect_fail "insert into role_targets values ('T-0040','시험동명','NEW_FAIL','새팀','ADMIN');" INVALID_ROLE
expect_fail "insert into role_targets values ('T-0040','시험동명',null,null,'MEMBER'), ('T-0040','시험동명',null,null,'LEAVE');" DUPLICATE_TARGET
apply_targets "insert into role_targets values ('T-0003','시험소장',null,null,'SITE_MANAGER'), ('T-0016','시험자재','MATERIAL','자재팀','MEMBER');"
runtest "$ROOT/tests/sql/15_test_personnel_roles_v10_change3.sql"
run "$ROOT/personnel_auth_v10_rollback.sql"
runtest "$ROOT/tests/sql/16_test_personnel_auth_v10_rollback.sql"
run "$ROOT/personnel_auth_v10.sql"
# 롤백은 적용의 역순
run "$ROOT/tests/sql/18_snapshot_before_rollback.sql"
run "$ROOT/personnel_auth_v10_rollback.sql"
for f in $(ls "$ROOT"/field_sql_v0*_rollback.sql 2>/dev/null | sort -r); do run "$f"; done
run "$ROOT/personnel_auth_v09_rollback.sql"
run "$ROOT/personnel_auth_v08_rollback.sql"
runtest "$ROOT/tests/sql/19_test_personnel_auth_v08_rollback.sql"
run "$ROOT/personnel_auth_v08.sql"
run "$ROOT/personnel_auth_v09.sql"
run "$ROOT/personnel_auth_v10.sql"
echo "ALL SQL TESTS PASSED"
