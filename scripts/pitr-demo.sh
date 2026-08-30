#!/usr/bin/env bash
# End-to-end point-in-time recovery, proving the target was actually honoured.
#
# The shape of the proof matters. "A restore ran and the database came back" is
# not evidence of PITR — it is evidence of a restore. This writes a row, records
# a timestamp, writes a SECOND row, restores to the recorded timestamp, and then
# asserts the first row is present and the second is gone.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NS="$HA_NS"; CLUSTER="$HA_CLUSTER"; REPO="${1:-repo1}"
k -n "$NS" get pg "$CLUSTER" >/dev/null 2>&1 || die "run 'make ha-up' first"

sql() { psql_on_pod "$NS" "$(current_leader "$NS" "$CLUSTER")" "$1" "$CLUSTER"; }

log "preparing the witness table"
sql "drop table if exists public.pitr_witness;
     create table public.pitr_witness(id int primary key, note text, at timestamptz default now());" >/dev/null

log "taking a full backup of ${REPO} to restore from"
"${REPO_ROOT}/scripts/backup.sh" "$REPO" full >/dev/null

log "writing row 1 (this one must survive)"
sql "insert into public.pitr_witness(id, note) values (1, 'before');" >/dev/null

# A WAL switch here guarantees row 1 is archived before the recovery target.
sql "select pg_switch_wal();" >/dev/null
sleep 5

TARGET="$(sql "select now();" | tr -d '[:space:]')"
log "recovery target: ${TARGET}"
sleep 5

log "writing row 2 (this one must be gone after the restore)"
sql "insert into public.pitr_witness(id, note) values (2, 'after');" >/dev/null
sql "select pg_switch_wal();" >/dev/null
sleep 10

before="$(sql "select count(*) from public.pitr_witness;" | tr -d '[:space:]')"
log "rows before restore: ${before} (expected 2)"

name="pitr-$(date +%s)"
log "requesting restore ${name} to ${TARGET}"
warn "this takes the cluster down and replaces its data directory"
cat <<YAML | k -n "$NS" apply -f -
apiVersion: pgv2.percona.com/v2
kind: PerconaPGRestore
metadata:
  name: ${name}
spec:
  pgCluster: ${CLUSTER}
  repoName: ${REPO}
  options:
    - --type=time
    - --target="${TARGET}"
YAML

log "waiting for the restore to complete"
deadline=$(( SECONDS + 1200 )); state=""
while (( SECONDS < deadline )); do
  state="$(k -n "$NS" get pg-restore "$name" -o jsonpath='{.status.state}' 2>/dev/null || true)"
  case "$state" in
    Succeeded) ok "restore finished after ${SECONDS}s"; break ;;
    Failed)    k -n "$NS" get pg-restore "$name" -o yaml | tail -30 >&2
               die "restore failed" ;;
  esac
  printf '\r%s    state=%-12s %4ds%s' "$C_DIM" "${state:-<none>}" "$SECONDS" "$C_OFF" >&2
  sleep 10
done
printf '\n' >&2
[[ "$state" == "Succeeded" ]] || die "restore did not finish in time (state=${state:-<none>})"

wait_cluster_ready "$NS" "$CLUSTER" 900

log "verifying the recovery target was honoured"
r1="$(sql "select count(*) from public.pitr_witness where id=1;" | tr -d '[:space:]')"
r2="$(sql "select count(*) from public.pitr_witness where id=2;" | tr -d '[:space:]')"

printf '\n' >&2
if [[ "$r1" == "1" && "$r2" == "0" ]]; then
  ok "row 1 present, row 2 gone — recovered to ${TARGET}"
else
  die "PITR did not land on the target (row1=${r1} expected 1, row2=${r2} expected 0)"
fi
