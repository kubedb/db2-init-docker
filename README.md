# db2-init-docker

Init container image for the KubeDB DB2 operator. It publishes the DB2 HADR step
scripts into a shared `emptyDir` that the `db2` container mounts at `/scripts`.

## Why an init container

The scripts are pinned per database version through
`DB2Version.spec.initContainer.image`, alongside `spec.db.image`. When a future
DB2 release needs a different command sequence you ship a different init image
for that `DB2Version` — with no version branching in operator code. Two further
benefits: the scripts are on disk in the pod, so `kubectl exec` + running a step
by hand reproduces any failure exactly; and multi-step sequences run as one exec
instead of several round-trips through the apiserver.

## Layout

```
init-script/run.sh   entrypoint - copies scripts/ to /scripts
scripts/             the steps, published to /scripts
```

## The steps

All are idempotent and safe to re-run. Every one decides from **Db2 state**, never
from Kubernetes state — via `HADR database role`, `Rollforward pending`, and
`db2 list db directory`. Deriving progress from Kubernetes conditions instead of
from the database is what produced the original `SQL1005N` retry storm.

| Script | Purpose |
|---|---|
| `lib.sh` | shared state probes, error classification, recovery. Sourced, not executed. |
| `ensure-archive-dir.sh <db>` | create `/database/logs`, enable `LOGARCHMETH1` if `OFF` |
| `create-db.sh <db>` | create the database; no-op if it exists |
| `configure-hadr.sh <role> <db> <local_fqdn> <remote_fqdn> <port> [target_list]` | apply HADR db cfg for one member |
| `seed-primary.sh backup\|wait` | open a FIFO, run an **online** backup into it |
| `seed-standby.sh prepare\|verify` | clear, purge logs, open a FIFO, run the restore, verify it landed |
| `purge-archive-logs.sh <db>` | drop stale archived logs before a re-seed |
| `start-hadr.sh <primary\|standby> <db>` | `START HADR` behind IBM's precondition guards |
| `takeover.sh <db> [--peer-window-only\|--graceful\|--force]` | promote a standby |

The coordinator sidecar moves the backup **bytes** between the two FIFOs in Go.
These scripts only set up the Db2 side. Bulk data never passes through the
kube-apiserver — doing so is what produced
`SQL2538N Unexpected End of File of Backup Image`.

## Things these scripts exist to get right

Each was learned by breaking it on a real cluster.

- `HADR_LOCAL_HOST` / `HADR_REMOTE_HOST` must be **pod FQDNs**. A ClusterIP
  Service is TCP-reachable but the HADR handshake rejects it (`SQL1768N rc=7`).
- `HADR_PEER_WINDOW` must be non-zero on SYNC/NEARSYNC members, or a clean forced
  takeover is impossible.
- `RESTORE` copies the source's db cfg, so a freshly seeded standby believes it is
  the primary. `configure-hadr.sh` must run **after** the restore.
- Stale archived logs from an older log chain give `SQLP_BADLOG` and a standby
  that shuts itself down. Purge before re-seeding.
- Backups must be **online**: the coordinator sidecar holds health connections
  over `127.0.0.1`, so an offline backup fails with `SQL1035N`.
- `SQL1777N` ("HADR is already started") is **success**, not failure — it is
  exactly what a correct re-run produces.
- Start every standby **before** the primary; primary-first races `HADR_TIMEOUT`.

## Typical order

```
ensure-archive-dir.sh  <db>                    # every member
create-db.sh           <db>                    # primary
configure-hadr.sh      primary  <db> ...       # primary
seed-primary.sh        backup   <db> <fifo>    # primary   \  coordinator streams
seed-standby.sh        prepare  <db> <fifo>    # standby   /  between the FIFOs
seed-standby.sh        verify   <db>           # standby
configure-hadr.sh      principal|auxiliary ... # standby, AFTER the restore
start-hadr.sh          standby  <db>           # every standby first
start-hadr.sh          primary  <db>           # primary last
```

Full worked flow with expected output:
`ai-prompt/db2/clustering/plan/working_command.md`.
Design and repo split: `ai-prompt/db2/clustering/prompt/design.md`.

## Build

```bash
make container      # ghcr.io/kubedb/db2-init:<tag>
make push
```

## Tunables

`DB2_INSTANCE` (db2inst1) · `DB2_INSTANCE_GROUP` (db2iadm1) · `DB2_DATA_DIR`
(/database) · `DB2_ARCHIVE_DIR` (/database/logs) · `DB2_HADR_SYNCMODE` (NEARSYNC)
· `DB2_HADR_TIMEOUT` (120) · `DB2_HADR_PEER_WINDOW` (120)
