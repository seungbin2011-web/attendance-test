#!/usr/bin/env bash
# 로컬 e2e 시험: 흉내 DB 구성 → 게이트웨이 → Playwright(Chromium) 시험 (실제 Supabase에 연결하지 않음)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
DB="${TEST_DB:-attendance_e2e}"; export TEST_DB="$DB"
as_pg() { if [ "$(id -un)" = postgres ]; then bash -c "$*"; else su postgres -c "$*"; fi; }
run() { as_pg "psql -X -q -v ON_ERROR_STOP=1 -d $DB" < "$1" > /dev/null; }
as_pg "psql -X -q -c \"do \\\$\\\$ begin if not exists (select 1 from pg_roles where rolname='e2e_gateway') then create role e2e_gateway login superuser password 'e2e-local-only'; end if; end \\\$\\\$\""
as_pg "dropdb --if-exists $DB" 2>/dev/null; as_pg "createdb $DB"
run "$ROOT/tests/sql/00_mock_supabase.sql"
run "$ROOT/tests/sql/01_mock_seed.sql"
run "$ROOT/personnel_auth_v02.sql"
run "$ROOT/personnel_auth_v08.sql"
run "$ROOT/tests/sql/02_fixture_e2e.sql"
for f in "$ROOT"/field_sql_v0*.sql; do case "$f" in *_rollback.sql|*_check.sql) continue;; esac; [ -e "$f" ] && run "$f"; done
[ -d "$HERE/node_modules" ] || (cd "$HERE" && npm install --no-audit --no-fund > /dev/null)
rm -rf "$HERE/artifacts"; mkdir -p "$HERE/artifacts"
cd "$HERE"
status=0
for t in ${@:-$(ls *.test.mjs)}; do
  echo "== $t"
  NODE_PATH=/opt/node22/lib/node_modules node --experimental-strip-types --no-warnings --import ./npm_specifier_hooks_register.mjs "$t" || status=1
done
exit $status
