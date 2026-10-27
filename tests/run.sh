#!/usr/bin/env bash
# Runs the database tests against a throwaway Postgres database.
#   Needs a reachable Postgres (set PGHOST/PGPORT/PGUSER/PGPASSWORD as usual) and psql.
#   SQL_DIR = folder with the migration files (default: ../sql, or the repo's sql folder)
set -euo pipefail
cd "$(dirname "$0")"
SQL_DIR="${SQL_DIR:-../sql}"
DB="tutmatching_test_$$"
PSQL="psql -v ON_ERROR_STOP=1 -q -X"
ORDER=(tutmatching-v5-migration.sql tutmatching-v5.1-emails.sql tutmatching-v5.2-email-details.sql tutmatching-v5.3-cancel-details.sql tutmatching-v6-edit-limits-admin.sql)

cleanup() { $PSQL -d postgres -c "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1 || true; }
trap cleanup EXIT

build_db() { # $1 = legacy|fresh
  $PSQL -d postgres -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB" >/dev/null
  $PSQL -d "$DB" -f setup/roles.sql >/dev/null
  if [ "$1" = legacy ]; then $PSQL -d "$DB" -f setup/legacy_schema.sql >/dev/null; else
    $PSQL -d "$DB" -c "CREATE TABLE submissions (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), student_id TEXT NOT NULL, email TEXT NOT NULL, major TEXT NOT NULL, current_tut TEXT NOT NULL, desired_tut TEXT NOT NULL, german_level TEXT, english_level TEXT, status TEXT DEFAULT 'waiting', created_at TIMESTAMP DEFAULT NOW(), matched_at TIMESTAMP); CREATE TABLE matches (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), submission_a_id UUID REFERENCES submissions(id), submission_b_id UUID REFERENCES submissions(id), coordinator_needed BOOLEAN, created_at TIMESTAMP DEFAULT NOW());" >/dev/null
  fi
  for f in "${ORDER[@]}"; do $PSQL -d "$DB" -f "$SQL_DIR/$f" >/dev/null 2>&1 || { echo "Migration failed: $f"; $PSQL -d "$DB" -f "$SQL_DIR/$f"; exit 1; }; done
}

echo "== migrations: upgrade an older database, then a fresh one, and run them twice"
build_db legacy
for f in "${ORDER[@]}"; do $PSQL -d "$DB" -f "$SQL_DIR/$f" >/dev/null 2>&1 || { echo "Re-run failed: $f"; exit 1; }; done
echo "ok"
build_db fresh

fail=0
for t in sql/*.sql; do
  echo "== $t"
  $PSQL -d "$DB" -c "DELETE FROM notifications; DELETE FROM matches; DELETE FROM submissions; DELETE FROM rate_events; DELETE FROM admins; DELETE FROM net.calls;" >/dev/null
  if ! out=$($PSQL -d "$DB" -f "$t" 2>&1); then echo "$out" | grep -E "FAIL|ERROR" || echo "$out"; fail=1; else echo "$out" | grep -c "PASS" | sed 's/^/   checks passed: /'; fi
done

echo "== sql/ concurrency (60 simultaneous requests)"
$PSQL -d "$DB" -c "DELETE FROM notifications; DELETE FROM matches; DELETE FROM submissions; DELETE FROM rate_events;" >/dev/null
export DB
seq 1 60 | xargs -P 30 -I{} bash -c 'if [ $(({}%2)) -eq 0 ]; then c=1; d=2; else c=2; d=1; fi; psql -X -q -At -d "$DB" -c "SET ROLE anon; SELECT submit_request('"'"'55-{}'"'"','"'"'s{}@student.guc.edu.eg'"'"','"'"'CS'"'"','"'"'$c'"'"','"'"'$d'"'"',NULL,NULL,NULL,false)" >/dev/null'
$PSQL -d "$DB" -f concurrency_check.sql 2>&1 | grep -E "PASS|FAIL" || fail=1
$PSQL -d "$DB" -f concurrency_check.sql >/dev/null 2>&1 || fail=1

if [ $fail -ne 0 ]; then echo "SOME TESTS FAILED"; exit 1; fi
echo "ALL DATABASE TESTS PASSED"
