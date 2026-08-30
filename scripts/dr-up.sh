#!/usr/bin/env bash
# Deploy the DR standby cluster and wait until it is replaying the primary's WAL.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

k -n "$HA_NS" get pg "$HA_CLUSTER" >/dev/null 2>&1 || die "run 'make ha-up' first"
k get ns "$MINIO_NS"               >/dev/null 2>&1 || die "run 'make minio-up' first"
k -n "$HA_NS" get secret pgbackrest-s3-creds >/dev/null 2>&1 || die "run 'scripts/s3-repo-up.sh' first"

k get ns "$DR_NS" >/dev/null 2>&1 || k create ns "$DR_NS"

log "copying the S3 credentials into ${DR_NS}"
# Secrets are namespaced, so the standby needs its own copy to read the repo.
k -n "$HA_NS" get secret pgbackrest-s3-creds -o json \
  | python3 -c "
import json,sys
s=json.load(sys.stdin)
s['metadata']={'name':'pgbackrest-s3-creds','namespace':'${DR_NS}'}
print(json.dumps(s))" \
  | k apply -f -

log "ensuring the primary has at least one backup in repo2"
if ! k -n "$HA_NS" exec "statefulset/${HA_CLUSTER}-repo-host" -c pgbackrest -- \
     pgbackrest --stanza=db --repo=2 info 2>/dev/null | grep -q "full backup:"; then
  warn "no full backup in repo2 yet — taking one now (the standby cannot start without it)"
  "${REPO_ROOT}/scripts/backup.sh" repo2 full
fi

log "deploying the standby cluster"
k apply -k "${REPO_ROOT}/clusters/dr-standby"
wait_cluster_ready "$DR_NS" "$DR_CLUSTER" "${READY_TIMEOUT:-900}"

log "confirming the standby is in recovery"
pod="$(k -n "$DR_NS" get pods -l postgres-operator.crunchydata.com/data=postgres \
  -o jsonpath='{.items[0].metadata.name}')"
in_recovery="$(psql_on_pod "$DR_NS" "$pod" "select pg_is_in_recovery();" | tr -d '[:space:]')"
[[ "$in_recovery" == "t" ]] || die "standby is not in recovery (pg_is_in_recovery=${in_recovery})"
ok "standby is replaying WAL from repo2"

k -n "$DR_NS" get pods -o wide
