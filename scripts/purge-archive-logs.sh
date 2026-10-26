#!/bin/bash
# Remove this database's archived logs before re-seeding a standby.
#
# Required by IBM's own standby procedure ("Remove archive log files if not
# shared"). Observed failure when skipped: a standby held 35 logs from chain
# C0000000 while the new image was chain C0000002, giving SQLP_BADLOG and a
# database that shut itself down immediately after START HADR.
#
#   usage: purge-archive-logs.sh <db>
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_args $# 1 "purge-archive-logs.sh <db>"
DB=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')

TARGET="${ARCHIVE_DIR}/${INSTANCE}/${DB}"
if [ -d "$TARGET" ]; then
  n=$(find "$TARGET" -type f 2>/dev/null | wc -l)
  log "purging ${n} archived log file(s) under ${TARGET}"
  rm -rf "$TARGET"
else
  log "no archive log tree at ${TARGET} - nothing to purge"
fi
