#!/bin/bash
# fence-watchdog.sh - stop this pod's Db2 instance when it has lost the primary
# lease and could be replaced.
#
# Started once per db2 container by a postStart hook, and runs for the life of
# the container.
#
# Why this exists: the operator promotes a standby only after the old primary's
# Lease has run out. A primary that is cut off from the API server keeps running
# and, once its own HADR peer window ends, resumes accepting writes on its own.
# Without a fence, that is a split brain. The coordinator renews the lease and,
# after every successful renewal, writes a deadline to $DEADLINE_FILE, due
# shortly before the lease expires. This loop enforces that deadline.
#
# The fence runs here, in the db2 container, not in the coordinator, because
# the coordinator reaches Db2 only through the kube-apiserver's exec
# subresource. The pod that has to fence itself is exactly the pod that cannot
# do it that way.
#
# It fences only when all of these hold:
#   - the deadline file exists: this pod held the lease and has not given it up;
#   - the deadline has passed: the lease could not be renewed in time;
#   - some database here is an HADR PRIMARY with no standby in PEER.
#
# The last condition matters. A standby that is still connected and in PEER is
# not in DISCONNECTED_PEER, so the operator cannot promote it, and there is
# nothing to fence against. This keeps a control-plane outage from taking
# healthy primaries down with it.
#
# The fence is `db2stop force` (falling back to db2_kill) followed by `db2start`. With the instance back
# up but no database activated, activating a primary needs its standby within
# HADR_TIMEOUT. That fails while the pod is still cut off, and fails for good
# once the standby has been promoted. When the partition heals, the operator
# rejoins this pod as a standby.
set -uo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

DEADLINE_FILE="${HADR_LEASE_DEADLINE_FILE:-${DATA_DIR}/.hadr-lease-deadline}"
INTERVAL="${HADR_FENCE_INTERVAL_SECONDS:-2}"
# After a fence, give the instance time to come back before judging it again.
BACKOFF="${HADR_FENCE_BACKOFF_SECONDS:-30}"
STOP_TIMEOUT="${HADR_FENCE_STOP_TIMEOUT_SECONDS:-15}"

# Write to the container's log, not the hook's discarded output. Each line is
# opened afresh: when the postStart hook fires, PID 1's stdout may not be
# writable yet, so a redirect taken once at startup can end up in /dev/null.
wlog() {
  local line
  line=$(printf '[fence-watchdog %s] %s' "$(date -u +%H:%M:%S)" "$*")
  printf '%s\n' "$line" >>/proc/1/fd/1 2>/dev/null || printf '%s\n' "$line" >>"${DATA_DIR}/fence-watchdog.log"
}

# One watchdog per container, however many times the hook fires.
if command -v flock >/dev/null 2>&1; then
  exec 9>/tmp/fence-watchdog.lock
  flock -n 9 || exit 0
fi

# A deadline left on the volume by a previous life of this container means
# nothing now: only the running coordinator's renewals may arm the fence.
rm -f "$DEADLINE_FILE"
wlog "started (deadline file ${DEADLINE_FILE})"

instance_running() {
  ps -e -o comm= 2>/dev/null | grep -qx db2sysc
}

# unpeered_primaries <db2pd -hadr -alldbs output>
# Prints every database that is an HADR primary with no standby in PEER and
# CONNECTED. Each standby gets its own block starting at HADR_ROLE, and
# HADR_STATE comes before HADR_CONNECT_STATUS within a block.
unpeered_primaries() {
  printf '%s\n' "$1" | awk '
    /-- Database / {
      # "Database Member 0 -- Database TESTDB -- Active ..."
      for (i = 1; i < NF - 1; i++) if ($i == "--" && $(i + 1) == "Database") { db = $(i + 2); break }
    }
    /^[[:space:]]*HADR_ROLE[[:space:]]*=/ {
      role = $NF; state = ""
      if (role == "PRIMARY") primary[db] = 1
    }
    /^[[:space:]]*HADR_STATE[[:space:]]*=/ { state = $NF }
    /^[[:space:]]*HADR_CONNECT_STATUS[[:space:]]*=/ {
      if (role == "PRIMARY" && state == "PEER" && $NF == "CONNECTED") peered[db] = 1
    }
    END { for (d in primary) if (!(d in peered)) print d }
  '
}

# fence stops the instance, fast. Speed matters more than grace here: this
# primary's own peer window is running out, and when it does the database
# accepts commits again on its own.
#
# db2stop force was observed to take a full minute on a primary whose standby
# had gone silent, and signalling it only makes it slower - it answers SIGTERM
# by writing an FODC diagnostic dump. So it runs in the background, and if the
# engine is still up after STOP_TIMEOUT seconds, db2_kill ends it directly.
fence() {
  local out stop_pid killed
  out=$(run_db2 "db2 force application all") || true
  wlog "force application all: $(printf '%s' "$out" | tail -1)"
  run_db2 "db2stop force" >/dev/null 2>&1 &
  stop_pid=$!
  for _ in $(seq 1 "$STOP_TIMEOUT"); do
    instance_running || break
    sleep 1
  done
  killed=false
  if instance_running; then
    wlog "db2stop force still running after ${STOP_TIMEOUT}s; db2_kill"
    run_db2 "db2_kill" >/dev/null 2>&1 || true
    killed=true
  fi
  if instance_running; then
    wlog "WARNING: db2 engine still running after db2_kill"
  else
    wlog "instance stopped"
  fi
  # Let the stop finish or die with the engine before starting again; a
  # db2start racing a db2stop fails on the instance lock.
  for _ in $(seq 1 30); do
    kill -0 "$stop_pid" 2>/dev/null || break
    sleep 1
  done
  pkill -9 -f 'db2stop' 2>/dev/null || true
  # IPC left behind by a killed engine blocks db2start. Only then, and never
  # while an engine is running: Db2's fault monitor may already have restarted
  # it, and cleaning IPC from under a live instance breaks it.
  if $killed && ! instance_running; then
    run_db2 "ipclean -a" >/dev/null 2>&1 || true
  fi
  if instance_running; then
    wlog "instance already restarted"
    return
  fi
  out=$(run_db2 "db2start") || true
  wlog "db2start: $(printf '%s' "$out" | tail -1)"
}

while true; do
  sleep "$INTERVAL"

  [ -f "$DEADLINE_FILE" ] || continue
  deadline=$(cat "$DEADLINE_FILE" 2>/dev/null) || continue
  [[ "$deadline" =~ ^[0-9]+$ ]] || continue
  (( $(date +%s) < deadline )) && continue
  instance_running || continue

  pd=$(run_db2 "db2pd -hadr -alldbs") || true
  exposed=$(unpeered_primaries "$pd" | sort | tr '\n' ' ')
  [ -n "${exposed// /}" ] || continue

  wlog "primary lease not renewed since deadline $(date -u -d "@${deadline}" +%H:%M:%S 2>/dev/null || echo "$deadline")" \
       "and no standby in PEER for: ${exposed}- fencing"
  fence
  sleep "$BACKOFF"
done
