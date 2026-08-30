#!/usr/bin/env bats
# Day-2 operations: scaling, configuration changes, switchover, pause.
#
# Each test restores the cluster to its starting shape so the suite can run in
# any order and leave the cluster usable for the next one.

load helpers/common

setup_file() { require_cluster "$HA_NS" "$HA_CLUSTER"; }
teardown_file() {
  cleanup_client_pod "$HA_NS"
  retry_until 600 bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' get pg '$HA_CLUSTER' \
       -o jsonpath='{.status.state}' | grep -qx ready" || true
}

@test "pgbouncer scales out and back" {
  # Cheap to scale and independent of the database, which is why it is the right
  # dial to reach for under connection pressure.
  k -n "$HA_NS" patch pg "$HA_CLUSTER" --type merge \
    -p '{"spec":{"proxy":{"pgBouncer":{"replicas":4}}}}' >/dev/null

  run retry_until 300 bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' get pg '$HA_CLUSTER' \
       -o jsonpath='{.status.pgbouncer.ready}' | grep -qx 4"
  [ "$status" -eq 0 ]

  # Each pooler holds its OWN pool, so this just raised the worst-case backend
  # count from 3x to 4x default_pool_size. See docs/04-connection-pooling.md
  run sql_pooled "$HA_NS" "$HA_CLUSTER" "select 1;"
  assert_scalar "$output" "1"

  k -n "$HA_NS" patch pg "$HA_CLUSTER" --type merge \
    -p '{"spec":{"proxy":{"pgBouncer":{"replicas":3}}}}' >/dev/null
  run retry_until 300 bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' get pg '$HA_CLUSTER' \
       -o jsonpath='{.status.pgbouncer.ready}' | grep -qx 3"
  [ "$status" -eq 0 ]
}

@test "a dynamic postgresql parameter applies without a restart" {
  local before after
  before="$(last_line "$(psql_on_pod "$HA_NS" "$(current_leader "$HA_NS" "$HA_CLUSTER")" \
    "show log_min_duration_statement;")")"

  k -n "$HA_NS" patch pg "$HA_CLUSTER" --type merge \
    -p '{"spec":{"patroni":{"dynamicConfiguration":{"postgresql":{"parameters":{"log_min_duration_statement":"1500"}}}}}}' >/dev/null

  run retry_until 300 bash -c \
    "pod=\$(kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' get pods \
       -l postgres-operator.crunchydata.com/role=primary -o jsonpath='{.items[0].metadata.name}') && \
     kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' exec \"\$pod\" -c database -- \
       psql -U postgres -tAXc 'show log_min_duration_statement' | tr -d '[:space:]' | grep -qx 1500ms"
  [ "$status" -eq 0 ]

  # Dynamic means no restart is pending afterwards.
  run psql_on_pod "$HA_NS" "$(current_leader "$HA_NS" "$HA_CLUSTER")" \
    "select count(*) from pg_settings where pending_restart;"
  assert_scalar "$output" "0"

  k -n "$HA_NS" patch pg "$HA_CLUSTER" --type merge \
    -p "{\"spec\":{\"patroni\":{\"dynamicConfiguration\":{\"postgresql\":{\"parameters\":{\"log_min_duration_statement\":\"${before%ms}\"}}}}}}" >/dev/null
}

@test "a pgbouncer config change propagates and takes effect" {
  # Not a restart — ConfigMap sync plus SIGHUP. Observed at 20-60s.
  k -n "$HA_NS" patch pg "$HA_CLUSTER" --type merge \
    -p '{"spec":{"proxy":{"pgBouncer":{"config":{"global":{"default_pool_size":"30"}}}}}}' >/dev/null

  # Poll through the shared client pod, NOT scripts/connect.sh. connect.sh
  # creates a throwaway pod per invocation, which is fine interactively and
  # pathological in a retry loop: at one attempt every 2s for 240s it spawns
  # pods faster than they can start, and the test times out having mostly
  # measured pod scheduling.
  local found=0
  for _ in $(seq 1 24); do
    if sql_admin "$HA_NS" "$HA_CLUSTER" "SHOW CONFIG;" 2>/dev/null \
       | grep -qE 'default_pool_size\|30'; then
      found=1; break
    fi
    sleep 10
  done

  k -n "$HA_NS" patch pg "$HA_CLUSTER" --type merge \
    -p '{"spec":{"proxy":{"pgBouncer":{"config":{"global":{"default_pool_size":"25"}}}}}}' >/dev/null

  assert_equal "$found" "1" "default_pool_size=30 never reached pgbouncer"
}

@test "a graceful switchover moves the leader without losing writes" {
  # Driven through patronictl rather than spec.patroni.switchover: on operator
  # v3.0.0 the CR field is accepted and then does nothing at all — no leader
  # change and no operator log entry, verified over five minutes with and
  # without targetInstance.
  local leader sync_standby
  leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"

  # Synchronous mode constrains the candidate to the current sync standby.
  # Anything else is rejected with "412, candidate name does not match with
  # sync_standby" — correctly, since the async replica may be behind.
  sync_standby="$(last_line "$(psql_on_pod "$HA_NS" "$leader" \
    "select application_name from pg_stat_replication where sync_state='sync' limit 1;")")"
  [ -n "$sync_standby" ]
  echo "switching ${leader} -> ${sync_standby}" >&3

  sql_pooled "$HA_NS" "$HA_CLUSTER" \
    "create table if not exists switch_witness(id int primary key);
     insert into switch_witness values (1) on conflict do nothing;" >/dev/null

  run k -n "$HA_NS" exec "$leader" -c database -- \
    patronictl -c /etc/patroni/~postgres-operator_cluster.yaml switchover "${HA_CLUSTER}-ha" \
    --leader "$leader" --candidate "$sync_standby" --force
  [ "$status" -eq 0 ]

  run retry_until 300 bash -c \
    "[ \"\$(kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' get pods \
       -l postgres-operator.crunchydata.com/role=primary \
       -o jsonpath='{.items[0].metadata.name}')\" = '${sync_standby}' ]"
  [ "$status" -eq 0 ]

  # Leader identity, not the timeline, is the assertion here.
  #
  # pg_control_checkpoint() reports the last *checkpoint* (a restartpoint on a
  # standby), so it lags — reading it from the promotion target immediately
  # afterwards returned a LOWER timeline than the old leader's. That makes it a
  # fine signal for a failover, where pod names recur and you have nothing else,
  # and a bad one here, where we named the candidate ourselves and the
  # `retry_until` above has already confirmed it holds the primary role.
  #
  # patronictl's TL column is the reliable read if you want the number.
  run k -n "$HA_NS" exec "$sync_standby" -c database -- \
    patronictl -c /etc/patroni/~postgres-operator_cluster.yaml list
  [ "$status" -eq 0 ]
  echo "$output" | grep -E 'Leader|Sync Standby' >&3 || true

  # Two steps on purpose. retry_until discards the command's output (it only
  # cares whether it succeeded), so capturing $output from it yields an empty
  # string and a confusing "a committed row was lost" failure for a row that is
  # perfectly intact. Wait for the pooler to route again, THEN read the value.
  run retry_until 180 sql_pooled "$HA_NS" "$HA_CLUSTER" "select 1;"
  [ "$status" -eq 0 ]

  run sql_pooled "$HA_NS" "$HA_CLUSTER" "select count(*) from switch_witness where id=1;"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "1" "a committed row was lost across a graceful switchover"
}

@test "synchronous mode rejects switching to an async replica" {
  # Documents the constraint the previous test works around, and guards it:
  # if this ever succeeds, planned switchovers have become a potential
  # data-loss event.
  local leader async
  leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  async="$(last_line "$(psql_on_pod "$HA_NS" "$leader" \
    "select application_name from pg_stat_replication where sync_state='async' limit 1;")")"
  [ -n "$async" ] || skip "no async replica to test against"

  run k -n "$HA_NS" exec "$leader" -c database -- \
    patronictl -c /etc/patroni/~postgres-operator_cluster.yaml switchover "${HA_CLUSTER}-ha" \
    --leader "$leader" --candidate "$async" --force
  assert_contains "$output" "does not match with sync_standby"
}

@test "pause scales the cluster down and resume brings it back" {
  [[ "${RUN_PAUSE:-0}" == "1" ]] || skip "set RUN_PAUSE=1 to run the pause/resume test"

  k -n "$HA_NS" patch pg "$HA_CLUSTER" --type merge -p '{"spec":{"pause":true}}' >/dev/null
  run retry_until 420 bash -c \
    "[ \"\$(kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' get pods \
       -l postgres-operator.crunchydata.com/data=postgres --no-headers 2>/dev/null | wc -l | tr -d ' ')\" = 0 ]"
  [ "$status" -eq 0 ]

  # PVCs must survive a pause, or it is a delete with extra steps.
  local pvcs
  pvcs="$(k -n "$HA_NS" get pvc --no-headers | wc -l | tr -d ' ')"
  assert_ge "$pvcs" 1 "pause destroyed the volumes"

  k -n "$HA_NS" patch pg "$HA_CLUSTER" --type merge -p '{"spec":{"pause":false}}' >/dev/null
  run retry_until 900 bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' get pg '$HA_CLUSTER' \
       -o jsonpath='{.status.state}' | grep -qx ready"
  [ "$status" -eq 0 ]

  run sql_pooled "$HA_NS" "$HA_CLUSTER" "select count(*) from switch_witness;"
  [ "$status" -eq 0 ]
}
