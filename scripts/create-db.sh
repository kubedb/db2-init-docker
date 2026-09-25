#!/bin/bash
# Create the HADR database on the primary. Idempotent: if it already exists this
# is a no-op, which is what makes a re-reconcile safe.
#
#   usage: create-db.sh <db>
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_args $# 1 "create-db.sh <db>"
DB="$1"

if db_exists "$DB"; then
  log "database ${DB} already exists - skipping create (role=$(hadr_role "$DB"))"
  exit 0
fi

log "creating database ${DB}"
out=$(run_db2 "db2 create database ${DB}") || true
if ! printf '%s\n' "$out" | grep -q DB20000I; then
  # SQL1005N means it exists after all - another reconcile won the race.
  printf '%s\n' "$out" | grep -q SQL1005N \
    && { log "database ${DB} created concurrently - treating as success"; exit 0; }
  die "create database failed: ${out}"
fi

db_exists "$DB" || die "create reported success but ${DB} is not in the db directory"
log "database ${DB} created"
