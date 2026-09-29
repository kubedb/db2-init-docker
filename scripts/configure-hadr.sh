#!/bin/bash
# Apply the HADR db cfg for one member.
#
#   usage: configure-hadr.sh <role> <db> <local_fqdn> <remote_fqdn> <port> [target_list]
#     role : primary | principal | auxiliary
#
# Two things here are load-bearing and were each verified by breaking them:
#
#  * HADR_LOCAL_HOST / HADR_REMOTE_HOST must be **pod FQDNs**. A ClusterIP
#    Service is TCP-reachable but the HADR handshake rejects it (SQL1768N rc=7).
#    DB2 also binds HADR_LOCAL_HOST's resolved address specifically, never
#    0.0.0.0, so it must resolve to an address on this pod.
#  * HADR_PEER_WINDOW must be non-zero on SYNC/NEARSYNC members. At 0 the standby
#    falls straight to REMOTE_CATCHUP_PENDING when the primary dies and a clean
#    forced takeover becomes impossible.
#
# Run this on a standby AFTER the restore: RESTORE copies the primary's db cfg,
# so an un-corrected standby believes HADR_LOCAL_HOST is the primary's name.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_args $# 5 "configure-hadr.sh <role> <db> <local_fqdn> <remote_fqdn> <port> [target_list]"

ROLE="$1"; DB="$2"; LOCAL_HOST="$3"; REMOTE_HOST="$4"; PORT="$5"; TARGET_LIST="${6:-}"

case "$ROLE" in
  primary|principal) SYNCMODE="${DB2_HADR_SYNCMODE:-NEARSYNC}" ;;
  # Auxiliaries are forced to SUPERASYNC by Db2 regardless; set it explicitly so
  # the configured and effective values agree and drift checks stay quiet.
  auxiliary)         SYNCMODE="SUPERASYNC" ;;
  *) die "role must be primary | principal | auxiliary (got '${ROLE}')" ;;
esac

TIMEOUT="${DB2_HADR_TIMEOUT:-60}"
# Peer window is only meaningful under SYNC/NEARSYNC; Db2 ignores it otherwise.
if [ "$SYNCMODE" = "SUPERASYNC" ] || [ "$SYNCMODE" = "ASYNC" ]; then
  PEER_WINDOW=0
else
  PEER_WINDOW="${DB2_HADR_PEER_WINDOW:-120}"
  [ "$PEER_WINDOW" -gt 0 ] || die "HADR_PEER_WINDOW must be > 0 for ${SYNCMODE}"
fi

# Clear any /etc/hosts pin a previous takeover may have left behind. A stale pin
# points a peer name at an unroutable address and silently prevents HADR from
# ever reconnecting.
clear_hadr_pins

db_exists "$DB" || die "database ${DB} does not exist on this member"

CFG=$(mktemp)
trap 'rm -f "$CFG"' EXIT
{
  echo "LOGINDEXBUILD ON"
  echo "INDEXREC RESTART"
  echo "HADR_LOCAL_HOST ${LOCAL_HOST}"
  echo "HADR_LOCAL_SVC ${PORT}"
  echo "HADR_REMOTE_HOST ${REMOTE_HOST}"
  echo "HADR_REMOTE_SVC ${PORT}"
  echo "HADR_REMOTE_INST ${INSTANCE}"
  echo "HADR_SYNCMODE ${SYNCMODE}"
  echo "HADR_TIMEOUT ${TIMEOUT}"
  echo "HADR_PEER_WINDOW ${PEER_WINDOW}"
  echo "HADR_REPLAY_DELAY 0"
} > "$CFG"

log "configuring ${DB} as ${ROLE}: local=${LOCAL_HOST}:${PORT} remote=${REMOTE_HOST}:${PORT} syncmode=${SYNCMODE} peer_window=${PEER_WINDOW}"

# Apply one parameter per statement, the way IBM's own update_db_cfg.sh does.
while read -r param value; do
  [ -z "${param:-}" ] && continue
  out=$(run_db2 "db2 UPDATE DB CFG FOR ${DB} USING ${param} ${value}") || true
  printf '%s\n' "$out" | grep -q DB20000I \
    || die "UPDATE DB CFG ${param} ${value} failed: ${out}"
done < "$CFG"

# HADR_TARGET_LIST is separate: it is quoted, and it is only set for >1 standby.
# Order is promotion policy - the first entry is the principal standby, and after
# a takeover the first entry of the NEW primary's list becomes the next principal.
# It must also be reciprocal: every member lists every other, or a surviving
# standby cannot find whoever was promoted.
if [ -n "$TARGET_LIST" ]; then
  out=$(run_db2 "db2 UPDATE DB CFG FOR ${DB} USING HADR_TARGET_LIST \"${TARGET_LIST}\"") || true
  printf '%s\n' "$out" | grep -q DB20000I || die "UPDATE HADR_TARGET_LIST failed: ${out}"
  log "HADR_TARGET_LIST = ${TARGET_LIST}"
fi

# Reads on standby. These are REGISTRY variables, not db cfg - they need an
# instance restart, so they must be set before the database is first activated.
# Missing this means a promoted or rejoined member cannot serve reads (SQL1776N rc=1).
run_db2 "db2set DB2_HADR_ROS=ON"     >/dev/null 2>&1 || true
run_db2 "db2set DB2_STANDBY_ISO=UR"  >/dev/null 2>&1 || true

log "configured. local_host=$(db_cfg "$DB" 'HADR_LOCAL_HOST') remote_host=$(db_cfg "$DB" 'HADR_REMOTE_HOST')"
