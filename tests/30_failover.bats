#!/usr/bin/env bats
# Automatic failover: kill the leader, prove Patroni promoted a standby, prove
# no committed data was lost, and prove clients recover through pgBouncer
# without any connection-string change.

load helpers/common

setup_file() {
  require_cluster "$HA_NS" "$HA_CLUSTER"
  export STATE_DIR="$BATS_FILE_TMPDIR"
}

teardown_file() {
  cleanup_client_pod "$HA_NS"
  retry_until 300 bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' get pg '$HA_CLUSTER' \
       -o jsonpath='{.status.state}' | grep -qx ready" || true
}

# The PostgreSQL timeline increments on every promotion, so it is the only
# unambiguous evidence that a failover actually happened.
#
# Pod *names* are not: each instance is its own single-replica StatefulSet, so a
# killed pod is recreated with the identical name and can legitimately win the
# next election. Asserting "the leader's name changed" produces both false
# passes and false failures.
timeline_of_leader() {
  local leader; leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  [[ -n "$leader" ]] || { echo ""; return 0; }
  psql_on_pod "$HA_NS" "$leader" "select timeline_id from pg_control_checkpoint();" 2>/dev/null || true
}

@test "seed a durable row before the failover" {
  run sql_pooled "$HA_NS" "$HA_CLUSTER" \
    "create table if not exists failover_witness(id int primary key, at timestamptz default now());"
  [ "$status" -eq 0 ]
  run sql_pooled "$HA_NS" "$HA_CLUSTER" \
    "insert into failover_witness(id) values (1) on conflict do nothing;"
  [ "$status" -eq 0 ]
  run sql_pooled "$HA_NS" "$HA_CLUSTER" "select count(*) from failover_witness where id=1;"
  assert_scalar "$output" "1"

  # Hand state to the next test — each bats test is its own process.
  last_line "$(timeline_of_leader)" > "${BATS_FILE_TMPDIR}/timeline_before"
  current_leader "$HA_NS" "$HA_CLUSTER"  > "${BATS_FILE_TMPDIR}/leader_before"
  echo "timeline before: $(cat "${BATS_FILE_TMPDIR}/timeline_before")" >&3
}

@test "force-killing the primary promotes a standby (timeline advances)" {
  local old before after elapsed=0
  old="$(cat "${BATS_FILE_TMPDIR}/leader_before")"
  before="$(cat "${BATS_FILE_TMPDIR}/timeline_before")"
  [ -n "$old" ]; [ -n "$before" ]
  echo "killing primary: ${old} (timeline ${before})" >&3

  # --force --grace-period=0, deliberately.
  #
  # A plain `kubectl delete pod` sends SIGTERM, Patroni catches it and performs
  # a graceful *handover*: it demotes itself and passes the leader key on before
  # exiting. Failover then looks instantaneous, which is a lovely number and
  # completely misleading — it is not what losing a node looks like. Forcing the
  # delete skips the handover so a new leader must win by lease expiry, which is
  # the path that actually matters.
  # See docs/09-lifecycle-operations.md#switchover-vs-failover
  k -n "$HA_NS" delete pod "$old" --force --grace-period=0 >/dev/null 2>&1 || true

  # Patroni's leader lease is 30s with a 10s poll, so allow 3x that.
  while (( elapsed < 240 )); do
    after="$(last_line "$(timeline_of_leader)")"
    if [[ "$after" =~ ^[0-9]+$ ]] && (( after > before )); then break; fi
    sleep 3; elapsed=$(( elapsed + 3 ))
  done

  echo "timeline after: ${after:-<none>} (took ${elapsed}s)" >&3
  echo "new primary:    $(current_leader "$HA_NS" "$HA_CLUSTER")" >&3
  [[ "$after" =~ ^[0-9]+$ ]]
  assert_ge "$after" "$(( before + 1 ))" "timeline did not advance — no promotion happened"
}

@test "writes recover through pgbouncer without changing the connection string" {
  # pgBouncer's [databases] entry points at the <cluster>-primary Service, so
  # the failover is invisible to the client's DSN. What we measure here is how
  # long until it actually works again.
  local start=$SECONDS
  run retry_until 240 sql_pooled "$HA_NS" "$HA_CLUSTER" \
    "insert into failover_witness(id) values (2) on conflict do nothing;"
  [ "$status" -eq 0 ]
  echo "writes recovered $(( SECONDS - start ))s after the kill" >&3
}

@test "the committed pre-failover row survived" {
  # synchronous_mode with synchronous_node_count=1 means the promoted standby
  # had already flushed this row. If this fails, the durability configuration
  # is not doing what the CR claims.
  run sql_pooled "$HA_NS" "$HA_CLUSTER" "select count(*) from failover_witness where id=1;"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "1" "a committed row was lost across the failover"
}

@test "patronictl reports a healthy cluster after the failover" {
  # patronictl is the operator-facing source of truth — when it and Kubernetes
  # disagree about who is primary, believe patronictl.
  local leader; leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  run k -n "$HA_NS" exec "$leader" -c database -- \
    patronictl -c /etc/patroni/~postgres-operator_cluster.yaml list
  [ "$status" -eq 0 ]
  assert_contains "$output" "Leader"

  # Sync Standby is asserted with a retry, not inline. Immediately after a
  # promotion the new leader exists but Patroni has not yet designated a
  # replacement synchronous standby, so a single sample sees Leader + Replica
  # and nothing else. That is a healthy cluster mid-convergence, not a broken
  # one — the dedicated test below measures the same thing and is the real
  # assertion; this one just should not fail while waiting for it.
  run retry_until 180 bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' exec '${leader}' -c database -- \
       patronictl -c /etc/patroni/~postgres-operator_cluster.yaml list | grep -q 'Sync Standby'"
  [ "$status" -eq 0 ]
}

@test "patroni's history records the promotion" {
  # The audit trail for every failover. Written asynchronously after the
  # promotion, so allow for it rather than sampling once — an empty table here
  # was our own race, not a missing record.
  local leader; leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  run retry_until 180 bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' exec '${leader}' -c database -- \
       patronictl -c /etc/patroni/~postgres-operator_cluster.yaml history \
     | grep -q 'no recovery target specified'"
  [ "$status" -eq 0 ]
}

@test "the cluster returns to three healthy members" {
  run retry_until 480 bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' get pg '$HA_CLUSTER' \
       -o jsonpath='{.status.postgres.ready}' | grep -qx 3"
  [ "$status" -eq 0 ]

  local leader; leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  run retry_until 300 bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' exec '$leader' -c database -- \
       psql -U postgres -tAXc \"select count(*) from pg_stat_replication where state='streaming'\" \
       | tr -d '[:space:]' | grep -qx 2"
  [ "$status" -eq 0 ]
}

@test "synchronous replication is re-established after the failover" {
  local leader; leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  run retry_until 180 bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' exec '$leader' -c database -- \
       psql -U postgres -tAXc \"select count(*) from pg_stat_replication where sync_state='sync'\" \
       | tr -d '[:space:]' | grep -qx 1"
  [ "$status" -eq 0 ]
}
