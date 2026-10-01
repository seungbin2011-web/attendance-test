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
# 롤백은 적용의 역순
run "$ROOT/tests/sql/18_snapshot_before_rollback.sql"
for f in $(ls "$ROOT"/field_sql_v0*_rollback.sql 2>/dev/null | sort -r); do run "$f"; done
run "$ROOT/personnel_auth_v09_rollback.sql"
run "$ROOT/personnel_auth_v08_rollback.sql"
runtest "$ROOT/tests/sql/19_test_personnel_auth_v08_rollback.sql"
run "$ROOT/personnel_auth_v08.sql"
run "$ROOT/personnel_auth_v09.sql"
echo "ALL SQL TESTS PASSED"
