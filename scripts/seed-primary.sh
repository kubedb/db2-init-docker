#!/bin/bash
# Primary half of seeding a standby: open a FIFO and start an ONLINE backup into it.
# The db2-coordinator sidecar then reads that FIFO in Go and streams the bytes to
# the standby. The bytes never pass through the kube-apiserver - pushing a backup
# image through an exec stream is what produced
# "SQL2538N Unexpected End of File of Backup Image".
#
#   usage: seed-primary.sh backup <db> <fifo>
#          seed-primary.sh wait   [timeout_sec]
#
# ONLINE, not offline, and that is deliberate: the coordinator sidecar holds
# health connections to the database over 127.0.0.1, so an offline backup fails
# with SQL1035N. Restoring an online image still leaves the standby in
# rollforward-pending, which is exactly what START HADR AS STANDBY needs.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_args $# 1 "seed-primary.sh backup <db> <fifo> | seed-primary.sh wait [timeout_sec]"

LOG=/tmp/db2-seed-backup.log

case "$1" in
  backup)
    require_args $# 3 "seed-primary.sh backup <db> <fifo>"
    DB="$2"; FIFO="$3"
    db_exists "$DB" || die "database ${DB} does not exist"

    kill_stale_seed_procs "$DB"

    # Online backup needs an active database.
    run_db2 "db2 activate db ${DB}" >/dev/null 2>&1 || true

    rm -f "$FIFO" "$LOG"
    mkfifo -m 666 "$FIFO"
    log "FIFO ready at ${FIFO}; starting ONLINE backup of ${DB}"

    # Blocks until the coordinator opens the read end. setsid so it outlives
    # the exec session that launched it.
    setsid nohup su - "$INSTANCE" \
      -c "db2 backup database ${DB} online to ${FIFO}" > "$LOG" 2>&1 < /dev/null &
    log "backup started (log: ${LOG})"
    ;;

  wait)
    TIMEOUT="${2:-3600}"
    for _ in $(seq 1 "$TIMEOUT"); do
      [ -s "$LOG" ] && break
      sleep 1
    done
    [ -s "$LOG" ] || die "backup did not finish within ${TIMEOUT}s"
    cat "$LOG" >&2
    grep -q "Backup successful" "$LOG" || die "backup failed: $(cat "$LOG")"
    log "backup complete"
    ;;

  *) die "unknown subcommand '$1'" ;;
esac
