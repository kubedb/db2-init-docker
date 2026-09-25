#!/bin/bash
# Standby half of seeding. A standby must be a RESTORE of the primary's image -
# a locally created database can never be started as one.
#
#   usage: seed-standby.sh prepare <db> <fifo>
#          seed-standby.sh verify  <db> [timeout_sec]
#
# prepare: clear any previous attempt, purge stale archive logs, open the FIFO
#          and block a RESTORE on it. The coordinator then writes the stream in.
# verify : wait for the restore and check it actually landed.
#
# A failed attempt always leaves a partial database behind, which is why prepare
# drops unconditionally rather than testing first - that partial database is what
# turned the original retry loop into an endless SQL1005N / SQL1035N storm.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_args $# 2 "seed-standby.sh prepare <db> <fifo> | seed-standby.sh verify <db> [timeout_sec]"

LOG=/tmp/db2-seed-restore.log

case "$1" in
  prepare)
    require_args $# 3 "seed-standby.sh prepare <db> <fifo>"
    DB="$2"; FIFO="$3"

    kill_stale_seed_procs "$DB"

    if db_exists "$DB"; then
      log "dropping existing ${DB} before restore"
      out=$(run_db2 "db2 drop db ${DB}") || true
      if ! printf '%s\n' "$out" | grep -q DB20000I; then
        # SQL1035N: still connected - the operator's health checker, or a
        # leftover CLP process from a previous attempt.
        log "drop failed (${out%%$'\n'*}); escalating"
        drop_db_forcefully "$DB"
      fi
    fi
    db_exists "$DB" && die "${DB} still present after drop"

    "$(dirname "$0")/purge-archive-logs.sh" "$DB"

    rm -f "$FIFO" "$LOG"
    mkfifo -m 666 "$FIFO"
    chown "${INSTANCE}:${INSTANCE_GROUP}" "$FIFO" 2>/dev/null || true

    # The reader must open the FIFO before the writer, so the restore starts here
    # and blocks; the coordinator opens the write end afterwards.
    log "starting RESTORE of ${DB} from ${FIFO} (blocks until the stream arrives)"
    setsid nohup su - "$INSTANCE" \
      -c "db2 restore database ${DB} from ${FIFO} without prompting" > "$LOG" 2>&1 < /dev/null &
    log "standby ready to receive (log: ${LOG})"
    ;;

  verify)
    DB="$2"; TIMEOUT="${3:-3600}"
    for _ in $(seq 1 "$TIMEOUT"); do
      [ -s "$LOG" ] && break
      sleep 1
    done
    [ -s "$LOG" ] || die "restore did not finish within ${TIMEOUT}s"
    cat "$LOG" >&2

    # All three must hold. A matching byte count and checksum on the transport is
    # NOT proof of a seed: observed once, both ends reported every byte with
    # identical SHA-256 while the restore had already died with SQL1035N and a
    # stale reader drained the pipe.
    grep -q DB20000I "$LOG" || die "restore failed: $(cat "$LOG")"

    RFW=$(rollforward_pending "$DB")
    [ "$RFW" = "DATABASE" ] || die "restore reported success but Rollforward pending = '${RFW}' (want DATABASE)"

    ROLE=$(hadr_role "$DB")
    [ "$ROLE" = "STANDARD" ] || log "note: role is ${ROLE}, expected STANDARD for a fresh seed"

    log "seed verified: ${DB} restored, rollforward-pending, ready for START HADR AS STANDBY"
    log "REMINDER: run configure-hadr.sh now - RESTORE copied the primary's db cfg, so HADR_LOCAL_HOST is currently the primary's name"
    ;;

  *) die "unknown subcommand '$1'" ;;
esac
