#!/bin/bash
# Start HADR on this member, with IBM's own precondition guards.
#
#   usage: start-hadr.sh <primary|standby> <db> [force]
#
# Ordering matters at the caller: start EVERY standby first, the primary last.
# Primary-first is a race against HADR_TIMEOUT and fails with SQL1768N rc=7.
#
# Guards ported from the DB2 image's /var/db2_setup/include/hadr_functions.sh
# (start_HADR), with one deliberate change: when the member is already running in
# the requested role this exits 0. IBM treats that as an error; for a reconciling
# operator it is the idempotent success path.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_args $# 2 "start-hadr.sh <primary|standby> <db> [force]"

WANT=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]'); DB="$2"; FORCE="${3:-}"
[ "$WANT" = "PRIMARY" ] || [ "$WANT" = "STANDBY" ] || die "role must be primary or standby"

# Clear any /etc/hosts pin a previous takeover may have left behind. A stale pin
# points a peer name at an unroutable address and silently prevents HADR from
# ever reconnecting.
clear_hadr_pins

db_exists "$DB" || die "database ${DB} does not exist"

CFG_ROLE=$(hadr_role "$DB")                       # persisted role, on disk
RUN_ROLE=$(hadr_runtime_role "$DB")
log "${DB}: cfg_role=${CFG_ROLE} runtime_role=${RUN_ROLE:-inactive} want=${WANT}"

# --- idempotent success: already running in the requested role
if [ "${RUN_ROLE:-}" = "$WANT" ]; then
  log "${DB} is already running as ${WANT} - nothing to do"
  exit 0
fi

# --- guard: refuse to start as standby on a database that is not a restored copy
if [ "$CFG_ROLE" = "STANDARD" ] && [ "$WANT" = "STANDBY" ]; then
  if [ -n "${RUN_ROLE:-}" ]; then
    die "${DB} is active as a standard database; stop HADR and deactivate before starting it as standby"
  fi
  RFW=$(rollforward_pending "$DB")
  [ "$RFW" = "DATABASE" ] || die "${DB} is not in rollforward-pending state (got '${RFW}') - the seed did not succeed, re-seed this member"
fi

# --- guard: never promote a standby by starting it as primary
if { [ "$CFG_ROLE" = "STANDBY" ] || [ "${RUN_ROLE:-}" = "STANDBY" ]; } && [ "$WANT" = "PRIMARY" ]; then
  die "${DB} is configured/running as standby - use takeover.sh to promote it, not start-hadr.sh"
fi

# --- guard: never demote a live primary this way
if [ "${RUN_ROLE:-}" = "PRIMARY" ] && [ "$WANT" = "STANDBY" ]; then
  die "${DB} is running as primary - it cannot be started as standby"
fi

# START HADR AS PRIMARY normally waits HADR_TIMEOUT for the standby and fails
# with SQL1768N rc=7 if it never appears. `BY FORCE` starts the primary anyway,
# which is what a re-established primary needs: its standby cannot be seeded
# until the primary is running, and the primary cannot start until the standby
# answers. This is the documented way out, and it is not the dangerous
# TAKEOVER ... BY FORCE - it only says "start as primary without waiting".
CMD="db2 start hadr on db ${DB} as ${WANT}"
if [ "$WANT" = "PRIMARY" ] && [ "$FORCE" = "force" ]; then
  CMD="${CMD} by force"
fi

log "starting HADR on ${DB} as ${WANT}${FORCE:+ (${FORCE})}"
out=$(run_db2 "$CMD") || true
printf '%s\n' "$out" >&2

if hadr_failed "$out"; then
  die "START HADR as ${WANT} failed: ${out}"
fi
# SQL1777N ("HADR is already started") lands here and is success.
log "HADR started on ${DB} as ${WANT} (state=$(hadr_state "$DB"))"
