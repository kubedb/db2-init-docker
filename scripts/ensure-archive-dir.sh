#!/bin/bash
# Make the database rollforward-recoverable. HADR is continuous rollforward, so
# circular logging (LOGARCHMETH1 = OFF) makes it impossible.
#
# Both halves of this are needed and the DB2 image provisions them
# non-deterministically: on one observed run a pod came up with LOGARCHMETH1=OFF
# and no /database/logs at all, while its peers were correct.
#
#   usage: ensure-archive-dir.sh <db>
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_args $# 1 "ensure-archive-dir.sh <db>"
DB="$1"

mkdir -p "${ARCHIVE_DIR}/${INSTANCE}"
chown -R "${INSTANCE}:${INSTANCE_GROUP}" "${ARCHIVE_DIR}"
chmod 755 "${ARCHIVE_DIR}"
log "archive dir ready: ${ARCHIVE_DIR}"

if ! db_exists "$DB"; then
  log "database ${DB} does not exist yet; directory prepared, nothing else to do"
  exit 0
fi

# Act only on an explicit OFF. An empty read means the question could not be
# answered - typically SQL1032N while the instance is still starting - and
# treating that as "archive logging is off" would flip the setting and take an
# offline backup against a database that was already correct.
CUR=$(db_cfg "$DB" 'LOGARCHMETH1')
if [ -z "$CUR" ]; then
  log "could not read LOGARCHMETH1 (instance not up yet?) - leaving it alone"
  exit 0
fi
if [ "$CUR" = "OFF" ]; then
  log "LOGARCHMETH1 is OFF - enabling archive logging"
  out=$(run_db2 "db2 UPDATE DB CFG FOR ${DB} USING LOGARCHMETH1 \"DISK:${ARCHIVE_DIR}/\"") || true
  printf '%s\n' "$out" | grep -q DB20000I || die "failed to set LOGARCHMETH1: ${out}"

  # Switching from circular to archive logging puts the database in BACKUP
  # PENDING: it cannot be connected to, and an ONLINE backup - which is what the
  # seed needs - is not possible until a full OFFLINE backup has been taken.
  # Clearing it here is what keeps that failure from surfacing much later as an
  # unexplained seed failure.
  mkdir -p "${DATA_DIR}/backup"
  chown "${INSTANCE}:${INSTANCE_GROUP}" "${DATA_DIR}/backup"
  # The coordinator sidecar holds health connections over 127.0.0.1, so an
  # offline backup fails with SQL1035N unless everything is forced off first.
  force_quiesce "$DB"
  log "taking the offline backup required to clear BACKUP PENDING"
  out=$(run_db2 "db2 backup database ${DB} to ${DATA_DIR}/backup") || true
  printf '%s\n' "$out" >&2
  # BACKUP reports success as "Backup successful.", not DB20000I - the CLP uses
  # a different success line for this command than for UPDATE DB CFG.
  printf '%s\n' "$out" | grep -q "Backup successful" \
    || die "offline backup after enabling archive logging failed: ${out}"
else
  log "LOGARCHMETH1 already set (${CUR}) - nothing to do"
fi

log "LOGARCHMETH1 = $(db_cfg "$DB" 'LOGARCHMETH1')"
