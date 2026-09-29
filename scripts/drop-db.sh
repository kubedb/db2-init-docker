#!/bin/bash
# Drop the HADR standby copy of a database that was removed from
# spec.hadr.databases.
#
#   usage: drop-db.sh <db>
#
# Only a STANDBY copy is ever dropped. A primary or a standard database may hold
# the only copy of the data, so anything else is refused - the operator stops
# HADR on those instead and leaves the data where it is. Idempotent: a database
# that is already gone is success.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_args $# 1 "drop-db.sh <db>"
DB="$1"

db_exists "$DB" || { log "${DB} does not exist - nothing to drop"; exit 0; }

ROLE=$(hadr_role "$DB")
[ "$ROLE" = "STANDBY" ] || die "refusing to drop ${DB}: HADR role is ${ROLE}, not STANDBY - it may hold the only copy of its data"

log "retiring the standby copy of ${DB}"
out=$(run_db2 "db2 deactivate db ${DB}; db2 stop hadr on db ${DB}") || true
printf '%s\n' "$out" >&2

out=$(run_db2 "db2 drop db ${DB}") || true
if ! printf '%s\n' "$out" | grep -q DB20000I; then
  log "drop failed (${out%%$'\n'*}); escalating"
  drop_db_forcefully "$DB"
fi
db_exists "$DB" && die "${DB} still present after drop"
"$(dirname "$0")/purge-archive-logs.sh" "$DB"
log "${DB} standby copy dropped"
