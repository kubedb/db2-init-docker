#!/bin/bash
# Common helpers for the DB2 HADR step scripts.
#
# Source this; do not execute it.
#
# Rule every script here obeys: decide from **Db2 state**, never from Kubernetes
# state. A step that has already been done must exit 0, not fail. Deriving
# progress from Kubernetes conditions instead of from the database is what
# produced the original SQL1005N retry storm.

INSTANCE="${DB2_INSTANCE:-db2inst1}"
DATA_DIR="${DB2_DATA_DIR:-/database}"
ARCHIVE_DIR="${DB2_ARCHIVE_DIR:-${DATA_DIR}/logs}"
INSTANCE_GROUP="${DB2_INSTANCE_GROUP:-db2iadm1}"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

# Run a command as the instance owner. Returns the real exit code; callers
# capture output so they can classify benign errors themselves.
run_db2() { su - "$INSTANCE" -c "$1" 2>&1; }

# ---------------------------------------------------------------- state probes
# These three are the only sanctioned way to decide what work remains.

# NOTE: every probe captures the command output into a variable BEFORE parsing it.
# Do not pipe run_db2 straight into awk/grep: an `exit` in awk (or grep -q) closes
# the pipe early, the db2 CLP upstream takes SIGPIPE and returns non-zero, and
# `set -o pipefail` then kills the caller. That failure mode is invisible when
# run_db2 is stubbed by a shell function, so it only shows up against a real Db2.

db_exists() {                    # db_exists <db>
  local out; out=$(run_db2 "db2 list db directory") || true
  printf '%s\n' "$out" \
    | grep -qE "Database name[[:space:]]*=[[:space:]]*${1}[[:space:]]*$"
}

hadr_role() {                    # -> STANDARD | PRIMARY | STANDBY | UNKNOWN
  local out r; out=$(run_db2 "db2 get db cfg for ${1}") || true
  r=$(printf '%s\n' "$out" \
      | awk -F= '/HADR database role/ {gsub(/[[:space:]]/,"",$2); print $2}')
  case "$r" in STANDARD|PRIMARY|STANDBY) echo "$r" ;; *) echo UNKNOWN ;; esac
}

rollforward_pending() {          # -> DATABASE | NO | UNKNOWN
  local out r; out=$(run_db2 "db2 get db cfg for ${1}") || true
  r=$(printf '%s\n' "$out" \
      | awk -F= '/Rollforward pending/ {gsub(/[[:space:]]/,"",$2); print $2}')
  case "$r" in DATABASE|NO) echo "$r" ;; *) echo UNKNOWN ;; esac
}

# Runtime state; needs an activated database, so it can legitimately be empty.
hadr_state() {                   # -> PEER | REMOTE_CATCHUP | ... | ""
  local out; out=$(run_db2 "db2pd -db ${1} -hadr") || true
  printf '%s\n' "$out" \
    | awk -F= '/^[[:space:]]*HADR_STATE/ {gsub(/[[:space:]]/,"",$2); print $2; exit}'
}

hadr_runtime_role() {            # -> PRIMARY | STANDBY | "" (empty = inactive)
  local out; out=$(run_db2 "db2pd -db ${1} -hadr") || true
  printf '%s\n' "$out" \
    | awk -F= '/^[[:space:]]*HADR_ROLE/ {gsub(/[[:space:]]/,"",$2); print $2; exit}'
}

db_cfg() {                       # db_cfg <db> <PARAM_NAME>
  local out; out=$(run_db2 "db2 get db cfg for ${1}") || true
  printf '%s\n' "$out" \
    | awk -F= -v k="${2}" '$0 ~ k {gsub(/[[:space:]]/,"",$2); print $2; exit}'
}

# ---------------------------------------------------------- error classification
# HADR errors live in the SQL1760-SQL1779 band. SQL1777N ("HADR is already
# started") is exactly what a correct idempotent re-run produces, so it is
# success, not failure. Treating every SQL####N as fatal is what made the old
# hasDB2Errors() reject its own no-ops.
hadr_failed() {                  # hadr_failed "<db2 output>"
  printf '%s\n' "$1" | grep -v 'SQL1777N' | grep -qE 'SQL17[67][0-9][NWC]'
}

# ------------------------------------------------------------------- recovery
# Clear every connection so DROP/RESTORE can take the database exclusively.
# Needed because the db2-coordinator sidecar holds health connections over
# 127.0.0.1 and will otherwise cause SQL1035N.
force_quiesce() {                # force_quiesce <db>
  log "quiescing ${1}: forcing applications and recycling the instance"
  run_db2 "db2 force applications all" >/dev/null 2>&1 || true
  run_db2 "db2 terminate"              >/dev/null 2>&1 || true
  run_db2 "db2 deactivate db ${1}"     >/dev/null 2>&1 || true
  run_db2 "db2stop force"              >/dev/null 2>&1 || true
  run_db2 "db2start"                   >/dev/null 2>&1 || true
}

# Drop a database that something keeps holding open.
#
# The operator's own health checker reconnects to this database every few
# seconds, so a drop issued as a separate command after quiescing loses the race
# and returns SQL1035N. The whole sequence therefore runs inside ONE `su -`, back
# to back, leaving no window for a reconnect - and is retried, because a single
# unlucky pass is not a reason to fail a seed.
drop_db_forcefully() {           # drop_db_forcefully <db>
  local db="$1" out i
  for i in 1 2 3; do
    out=$(run_db2 "db2 force applications all; db2 terminate; db2 deactivate db ${db}; db2stop force; db2start; db2 deactivate db ${db}; db2 drop db ${db}") || true
    if ! db_exists "$db"; then
      log "dropped ${db} (attempt ${i})"
      return 0
    fi
    log "drop attempt ${i} did not take: $(printf '%s' "$out" | grep -oE 'SQL[0-9]+[NWC]' | tail -1)"
    sleep 3
  done
  die "could not drop ${db} after 3 attempts: ${out}"
}

# ------------------------------------------------------------ /etc/hosts pins
# takeover.sh pins an unresolvable peer name just long enough to promote (see
# the comment there). The pin MUST NOT outlive the takeover: a stale entry
# pointing at an unroutable address stops the peer reconnecting for good.
#
# Note the write style. /etc/hosts is a bind-mounted file in Kubernetes, so
# `sed -i` fails - it writes a temp file and renames over the target, and rename
# across a bind mount is refused. Truncating and rewriting the same inode with
# `cat >` works, which is why it is done this way.
HADR_PIN_ADDR="192.0.2.1"

pin_host() {                     # pin_host <hostname>
  printf '%s %s\n' "$HADR_PIN_ADDR" "$1" >> /etc/hosts
}

clear_hadr_pins() {              # remove every pin this code has ever added
  grep -q "^${HADR_PIN_ADDR}[[:space:]]" /etc/hosts 2>/dev/null || return 0
  local tmp; tmp=$(mktemp)
  grep -v "^${HADR_PIN_ADDR}[[:space:]]" /etc/hosts > "$tmp" || true
  cat "$tmp" > /etc/hosts
  rm -f "$tmp"
  log "cleared temporary /etc/hosts pin(s)"
}

# A previous seed attempt that died leaves its RESTORE (or BACKUP) blocked on a
# FIFO. The next attempt deletes that FIFO and makes a new one, so the old
# process ends up holding an orphaned inode - and the new writer then blocks
# forever on a pipe with no reader, which wedges the operator's reconcile loop
# rather than failing. Clear them out before starting.
kill_stale_seed_procs() {        # kill_stale_seed_procs <db>
  local pids
  # `|| true` matters: with `set -e -o pipefail` a grep that matches nothing
  # returns 1 and would abort the calling script before it logged anything -
  # which is exactly what "no stale processes" looks like, the common case.
  pids=$(ps -eo pid,args \
    | grep -E "db2 (restore|backup) database ${1}" \
    | grep -v grep | grep -v 'bash -c' | awk '{print $1}' || true)
  [ -n "$pids" ] || return 0
  log "killing stale seed process(es): ${pids}"
  # shellcheck disable=SC2086
  kill -9 $pids 2>/dev/null || true
  sleep 1
}

require_args() {                 # require_args <got> <want> <usage>
  [ "$1" -ge "$2" ] || die "usage: $3"
}
