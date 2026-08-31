#!/usr/bin/env bats
# Network policy: the required flows still work, and nothing else does.
#
# Both halves are the test. A policy set that blocks everything passes a naive
# "is the internet blocked?" check while taking the database down with it —
# which is why every allow is asserted alongside every deny.

load helpers/common

setup_file() {
  require_cluster "$HA_NS" "$HA_CLUSTER"
  k -n "$HA_NS" get networkpolicy default-deny >/dev/null 2>&1 \
    || skip "network policies not installed — run 'make netpol-install'"
}

# A real TCP connect, in Python.
#
# Not `cat < /dev/tcp/host/port`: that opens the socket and then blocks waiting
# for PostgreSQL to speak first, so it times out on a WORKING connection and
# reports every flow as blocked. We shipped that mistake briefly and it made a
# perfectly healthy policy set look like a total outage.
PROBE='import socket,sys
s = socket.socket(); s.settimeout(6)
try:
    s.connect((sys.argv[1], int(sys.argv[2]))); print("OPEN")
except Exception:
    print("BLOCKED")'

probe() {  # pod container host port -> OPEN|BLOCKED
  k -n "$HA_NS" exec "$1" -c "$2" -- python3 -c "$PROBE" "$3" "$4" 2>/dev/null | tr -d '[:space:]'
}

leader_pod() { current_leader "$HA_NS" "$HA_CLUSTER"; }
peer_pod() { current_replicas "$HA_NS" "$HA_CLUSTER" | head -1; }
repo_host() { echo "${HA_CLUSTER}-repo-host-0"; }

# --------------------------------------------------------------- must work

@test "the cluster is still healthy under default-deny" {
  # The headline risk of this policy set: Patroni uses the Kubernetes API as its
  # DCS, so a too-strict egress rule makes the cluster demote itself and go
  # read-only. That failure looks like a database problem, not a network one.
  run k -n "$HA_NS" get pg "$HA_CLUSTER" -o jsonpath='{.status.state}'
  assert_equal "$output" "ready"
  run k -n "$HA_NS" get pg "$HA_CLUSTER" -o jsonpath='{.status.postgres.ready}'
  assert_equal "$output" "3"
}

@test "replication still streams" {
  run psql_on_pod "$HA_NS" "$(leader_pod)" \
    "select count(*) from pg_stat_replication where state='streaming';"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "2"
}

@test "postgres can still reach the Kubernetes API (Patroni's DCS)" {
  local api
  api="$(k get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[0].ip}')"
  assert_equal "$(probe "$(leader_pod)" database "$api" 6443)" "OPEN" \
    "Patroni cannot renew its leader lease without this — the cluster goes read-only"
}

@test "postgres can still reach its peers" {
  local peer; peer="$(peer_pod)"
  [ -n "$peer" ]
  assert_equal "$(probe "$(leader_pod)" database "${peer}.${HA_CLUSTER}-pods" 5432)" "OPEN"
}

@test "postgres can still reach the pgBackRest repo host" {
  assert_equal "$(probe "$(leader_pod)" database "$(repo_host).${HA_CLUSTER}-pods" 8432)" "OPEN"
}

@test "the repo host can still reach object storage" {
  k get ns "$MINIO_NS" >/dev/null 2>&1 || skip "MinIO not deployed"
  assert_equal "$(probe "$(repo_host)" pgbackrest "minio.${MINIO_NS}.svc" 9000)" "OPEN"
}

@test "clients can still reach the database through pgbouncer" {
  run sql_pooled "$HA_NS" "$HA_CLUSTER" "select 1;"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "1"
}

# -------------------------------------------------------------- must not

@test "postgres cannot reach the public internet" {
  # The rule the whole exercise is for.
  assert_equal "$(probe "$(leader_pod)" database 1.1.1.1 443)" "BLOCKED"
}

@test "postgres cannot reach object storage directly" {
  # Only the repo host may talk to the backup target. Scoping that egress to one
  # pod instead of granting it cluster-wide is most of the value of splitting
  # these policies by role: a compromised PostgreSQL process cannot exfiltrate
  # to the bucket even though the bucket is reachable from the namespace.
  k get ns "$MINIO_NS" >/dev/null 2>&1 || skip "MinIO not deployed"
  assert_equal "$(probe "$(leader_pod)" database "minio.${MINIO_NS}.svc" 9000)" "BLOCKED"
}

@test "the repo host cannot reach the public internet" {
  assert_equal "$(probe "$(repo_host)" pgbackrest 1.1.1.1 443)" "BLOCKED"
}

@test "an unlabelled namespace cannot reach pgbouncer" {
  # The pgbouncer ingress rule admits namespaces labelled
  # percona-pg-lab.io/database-client=true. If this passes, that selector is
  # wrong and every namespace in the cluster can reach your database.
  local ns="netpol-outsider-$$"
  k create ns "$ns" >/dev/null
  k -n "$ns" run outsider --image="$PG_IMAGE" --restart=Never \
    --command -- sleep 300 >/dev/null
  k -n "$ns" wait --for=condition=Ready pod/outsider --timeout=180s >/dev/null

  local result
  result="$(k -n "$ns" exec outsider -- python3 -c "$PROBE" \
    "${HA_CLUSTER}-pgbouncer.${HA_NS}.svc" 5432 2>/dev/null | tr -d '[:space:]')"
  k delete ns "$ns" --wait=false >/dev/null 2>&1 || true

  assert_equal "$result" "BLOCKED" "an unlabelled namespace reached pgbouncer"
}

# ------------------------------------------------------------- functional

@test "a backup still completes end to end" {
  # The strongest check available: archive-push and the backup itself traverse
  # postgres -> repo host -> object storage, so a success here exercises the
  # whole permitted path rather than individual ports.
  local name="netpol-backup-${RANDOM}"
  cat <<YAML | k -n "$HA_NS" apply -f - >/dev/null
apiVersion: pgv2.percona.com/v2
kind: PerconaPGBackup
metadata: {name: ${name}}
spec:
  pgCluster: ${HA_CLUSTER}
  repoName: repo1
  options: ["--type=incr"]
YAML
  run retry_until 900 bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' get pg-backup '${name}' \
       -o jsonpath='{.status.state}' | grep -qx Succeeded"
  local rc=$status
  k -n "$HA_NS" delete pg-backup "$name" --ignore-not-found >/dev/null 2>&1 || true
  [ "$rc" -eq 0 ]
}
