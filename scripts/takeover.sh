#!/bin/bash
# Promote this standby.
#
#   usage: takeover.sh <db> [--peer-window-only|--graceful|--force]
#     --graceful          role swap with a live primary (planned maintenance)
#     --peer-window-only  DEFAULT. lossless failover, legal only inside the peer window
#     --force             last resort; MAY LOSE DATA and usually forces a re-seed
#                         of the old primary. Only ever run this from an explicit
#                         operator/human decision.
#
# Measured with --peer-window-only after deleting the primary pod: DB20000I in
# 4 seconds, new primary immediately writable, zero data loss.
#
# The takeover's final step starts the HADR engine in the primary role, and that
# step RESOLVES HADR_REMOTE_HOST - the peer that just died. It only needs the
# name to resolve, not to connect. If it cannot, you get
# SQLO_HOST_UNKNOWN -> SQL1768N rc=12 -> SQL0902C and an unusable half-promoted
# database. In Kubernetes publishNotReadyAddresses on the governing Service keeps
# the record alive; KubeDB already sets it.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_args $# 1 "takeover.sh <db> [--peer-window-only|--graceful|--force]"

DB="$1"; MODE="${2:---peer-window-only}"

db_exists "$DB" || die "database ${DB} does not exist"
STATE=$(hadr_state "$DB")
ROLE=$(hadr_role "$DB")
log "${DB}: role=${ROLE} state=${STATE:-inactive} mode=${MODE}"

[ "$ROLE" = "PRIMARY" ] && { log "${DB} is already primary - nothing to do"; exit 0; }

case "$MODE" in
  --graceful)
    [ "$STATE" = "PEER" ] || die "graceful takeover needs HADR_STATE=PEER (got '${STATE:-inactive}')"
    CMD="db2 takeover hadr on db ${DB}" ;;
  --peer-window-only)
    case "$STATE" in
      PEER|DISCONNECTED_PEER) ;;
      *) die "refusing: HADR_STATE is '${STATE:-inactive}', not PEER/DISCONNECTED_PEER. Outside the peer window promotion would lose data - escalate to an explicit --force decision." ;;
    esac
    CMD="db2 takeover hadr on db ${DB} by force peer window only" ;;
  --force)
    log "WARNING: --force may lose committed transactions and will usually force a full re-seed of the old primary"
    CMD="db2 takeover hadr on db ${DB} by force" ;;
  *) die "unknown mode '${MODE}'" ;;
esac

# The takeover's last step starts the HADR engine in the primary role, and that
# step RESOLVES HADR_REMOTE_HOST - the peer that just died. It only needs the
# name to resolve, not to connect.
#
# In Kubernetes there is a window where it does not resolve: between the old
# pod's address leaving the EndpointSlice and the replacement's arriving, the
# pod FQDN has no record at all. publishNotReadyAddresses does NOT cover it -
# that flag keeps *unready* addresses published, and during this window there is
# no address. Db2 then gives SQLO_HOST_UNKNOWN -> SQL1768N rc=12 -> SQL0902C and
# a half-promoted, unusable database. Measured: unresolvable -> SQL0902C;
# resolvable -> DB20000I in 3 seconds.
#
# So pin the name just long enough to take over, at a documented unroutable
# TEST-NET-1 address (RFC 5737) - the peer is dead, so nothing should connect to
# it anyway - and remove the pin immediately afterwards. The pin MUST be
# temporary: left in place it becomes a stale address that blocks the peer from
# ever reconnecting once its pod is back.
clear_hadr_pins                  # never start from someone else's leftovers
REMOTE=$(db_cfg "$DB" 'HADR_REMOTE_HOST')
if [ -n "$REMOTE" ] && ! getent hosts "$REMOTE" >/dev/null 2>&1; then
  log "HADR_REMOTE_HOST ${REMOTE} does not resolve; pinning it for the takeover"
  pin_host "$REMOTE"
fi
trap clear_hadr_pins EXIT

out=$(run_db2 "$CMD") || true
printf '%s\n' "$out" >&2
clear_hadr_pins
printf '%s\n' "$out" | grep -q DB20000I || die "takeover failed: ${out}"

log "takeover complete: ${DB} role=$(hadr_role "$DB") state=$(hadr_state "$DB")"
