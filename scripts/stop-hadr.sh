#!/bin/bash
# Stop HADR on this member, leaving the database usable on its own.
#
#   usage: stop-hadr.sh <db>
#
# Used when a cluster is scaled back to a single replica: the survivor must end
# up STANDARD, not a primary still pointing at peers that no longer exist.
#
# Idempotent. SQL1770N rc=4 ("HADR is not started") is the expected answer on a
# member that is already standalone, so it is success, not failure.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_args $# 1 "stop-hadr.sh <db>"
DB="$1"

db_exists "$DB" || { log "database ${DB} does not exist - nothing to stop"; exit 0; }

ROLE=$(hadr_role "$DB")
if [ "$ROLE" = "STANDARD" ]; then
  log "${DB} is already STANDARD - nothing to do"
  exit 0
fi

log "stopping HADR on ${DB} (role=${ROLE})"
out=$(run_db2 "db2 stop hadr on db ${DB}") || true
printf '%s\n' "$out" >&2

if printf '%s\n' "$out" | grep -q DB20000I; then
  log "HADR stopped; role=$(hadr_role "$DB")"
  exit 0
fi
# Already stopped is the idempotent success path.
printf '%s\n' "$out" | grep -q 'SQL1770N' \
  && { log "HADR was not started on ${DB} - treating as success"; exit 0; }

hadr_failed "$out" && die "STOP HADR failed: ${out}"
log "HADR stopped; role=$(hadr_role "$DB")"
