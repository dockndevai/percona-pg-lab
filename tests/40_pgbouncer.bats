#!/usr/bin/env bats
# Connection pooling: configuration reaches pgBouncer, the admin console is
# reachable, and multiplexing actually reduces PostgreSQL backends.

load helpers/common

setup_file() {
  require_cluster "$HA_NS" "$HA_CLUSTER"

  # The multiplexing tests need the pgbench dataset. Without it `pgbench -S`
  # exits immediately, no backends are opened, and the "pooled" assertion
  # passes for entirely the wrong reason — a false pass we actually shipped
  # once. Initialise it here so both tests measure the same real workload.
  export PGCLIENT_POD="pg-lab-client"
  ensure_client_pod "$HA_NS"
  local pw host
  pw="$(pguser_field "$HA_NS" "$HA_CLUSTER" password)"
  host="$(pguser_field "$HA_NS" "$HA_CLUSTER" host)"
  if ! k -n "$HA_NS" exec "$PGCLIENT_POD" -- env PGPASSWORD="$pw" PGSSLMODE=require \
       psql -h "$host" -U "$HA_CLUSTER" -d "$HA_CLUSTER" -tAXc \
       "select 1 from pg_class where relname='pgbench_accounts';" 2>/dev/null | grep -q 1; then
    k -n "$HA_NS" exec "$PGCLIENT_POD" -- env PGPASSWORD="$pw" PGSSLMODE=require \
      pgbench -h "$host" -U "$HA_CLUSTER" -d "$HA_CLUSTER" -i -s 5 --quiet >/dev/null 2>&1
  fi
}

teardown_file() {
  cleanup_client_pod "$HA_NS"
}

# Kill idle backends so a previous test's connections don't inflate the next
# test's count. server_idle_timeout is 180s, which is far longer than a suite.
drain_idle_backends() {
  local leader; leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  psql_on_pod "$HA_NS" "$leader" \
    "select pg_terminate_backend(pid) from pg_stat_activity
      where usename='${HA_CLUSTER}' and state='idle';" >/dev/null 2>&1 || true
  sleep 3
}

client_backends() {
  local leader; leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  psql_on_pod "$HA_NS" "$leader" \
    "select count(*) from pg_stat_activity
      where usename='${HA_CLUSTER}' and backend_type='client backend';"
}

# ---------------------------------------------------------------- configuration

@test "pgbouncer runs in the configured pool mode" {
  run sql_admin "$HA_NS" "$HA_CLUSTER" "SHOW CONFIG;"
  [ "$status" -eq 0 ]
  assert_contains "$output" "pool_mode|transaction"
}

@test "pool sizing from the CR reached pgbouncer" {
  # Compare against what the CR currently asks for, not a hardcoded literal.
  #
  # tests/70_lifecycle.bats deliberately changes default_pool_size and changes
  # it back; if it ever fails midway, the cluster is left drifted and a
  # hardcoded assertion here fails in a completely unrelated suite with a
  # confusing message. Asserting "the CR's value reached pgBouncer" is both
  # more robust and a more meaningful claim.
  local config
  config="$(sql_admin "$HA_NS" "$HA_CLUSTER" "SHOW CONFIG;")"

  local key
  for key in default_pool_size max_client_conn max_db_connections query_wait_timeout min_pool_size; do
    local want
    want="$(k -n "$HA_NS" get pg "$HA_CLUSTER" \
      -o jsonpath="{.spec.proxy.pgBouncer.config.global.${key}}")"
    [ -n "$want" ] || continue
    assert_contains "$config" "${key}|${want}" "CR asks for ${key}=${want}"
  done
}

@test "the admin console answers SHOW POOLS" {
  # This only works because admin_users, stats_users AND auth_dbname are set in
  # spec.proxy.pgBouncer.config.global. Without auth_dbname pgBouncer rejects
  # the connection with "cannot use the reserved pgbouncer database as an
  # auth_dbname". See docs/04-connection-pooling.md#admin-console
  run sql_admin "$HA_NS" "$HA_CLUSTER" "SHOW POOLS;"
  [ "$status" -eq 0 ]
  assert_contains "$output" "$HA_CLUSTER"
}

@test "the admin console answers SHOW STATS and SHOW SERVERS" {
  run sql_admin "$HA_NS" "$HA_CLUSTER" "SHOW STATS;"
  [ "$status" -eq 0 ]
  run sql_admin "$HA_NS" "$HA_CLUSTER" "SHOW SERVERS;"
  [ "$status" -eq 0 ]
}

@test "every pgbouncer replica routes to the primary" {
  # The [databases] section is a wildcard pointing at <cluster>-primary, so a
  # failover moves every pooler at once without a config change.
  run sql_admin "$HA_NS" "$HA_CLUSTER" "SHOW DATABASES;"
  [ "$status" -eq 0 ]
  assert_contains "$output" "${HA_CLUSTER}-primary"
}

# ------------------------------------------------------------------ behaviour

@test "queries routed through pgbouncer reach the primary" {
  run sql_pooled "$HA_NS" "$HA_CLUSTER" "select pg_is_in_recovery();"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "f" "pgbouncer should route writes to the primary, not a replica"
}

@test "idle clients are multiplexed onto far fewer postgres backends" {
  # THE point of connection pooling, and the one claim worth testing.
  #
  # 60 clients rate-limited to 240 tps means each client is idle most of the
  # time — which is what a real application connection pool looks like. Under
  # that shape pgBouncer hands one backend to many clients in turn.
  #
  # Note the deliberate choice of workload: at 100% duty cycle (no -R) every
  # client is always inside a transaction, so you genuinely need one backend
  # each and this ratio collapses to 1:1. See docs/04-connection-pooling.md
  drain_idle_backends

  local pw host peak=0 n
  pw="$(pguser_field "$HA_NS" "$HA_CLUSTER" password)"
  host="$(pguser_field "$HA_NS" "$HA_CLUSTER" pgbouncer-host)"
  ensure_client_pod "$HA_NS"

  k -n "$HA_NS" exec "$PGCLIENT_POD" -- env PGPASSWORD="$pw" PGSSLMODE=require \
    pgbench -h "$host" -U "$HA_CLUSTER" -d "$HA_CLUSTER" \
    -c 60 -j 4 -T 15 -R 240 -S --no-vacuum >/dev/null 2>&1 &
  local bench=$!

  for _ in $(seq 1 13); do
    n="$(last_line "$(client_backends)")"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > peak )) && peak=$n
    sleep 1
  done
  wait "$bench" || true

  echo "peak postgres backends for 60 pooled clients: ${peak}" >&3
  echo "$peak" > "${BATS_FILE_TMPDIR}/pooled_peak"

  # Both bounds matter. The upper bound is the actual claim: 60 clients must not
  # become 60 backends. The LOWER bound is what stops this passing when the
  # benchmark silently did nothing — a peak of 1 satisfies "fewer than 45" while
  # proving nothing at all, which is exactly how this test once passed against a
  # cluster with no pgbench tables in it.
  assert_le "$peak" 45 "expected multiplexing; 60 clients produced ${peak} backends"
  assert_ge "$peak" 5  "only ${peak} backends — the benchmark did not run"
}

@test "the same workload without pooling needs one backend per client" {
  # The control for the previous test. Without this, a broken measurement that
  # always reports a low number would pass silently.
  drain_idle_backends

  local pw host peak=0 n
  pw="$(pguser_field "$HA_NS" "$HA_CLUSTER" password)"
  host="$(pguser_field "$HA_NS" "$HA_CLUSTER" host)"     # <cluster>-primary, no pooler
  ensure_client_pod "$HA_NS"

  k -n "$HA_NS" exec "$PGCLIENT_POD" -- env PGPASSWORD="$pw" PGSSLMODE=require \
    pgbench -h "$host" -U "$HA_CLUSTER" -d "$HA_CLUSTER" \
    -c 60 -j 4 -T 15 -R 240 -S --no-vacuum >/dev/null 2>&1 &
  local bench=$!

  for _ in $(seq 1 13); do
    n="$(last_line "$(client_backends)")"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > peak )) && peak=$n
    sleep 1
  done
  wait "$bench" || true

  echo "peak postgres backends for 60 direct clients: ${peak}" >&3
  assert_ge "$peak" 50 "expected roughly one backend per direct client, saw ${peak}"

  # The comparison is the actual result. Assert it explicitly rather than
  # leaving a reader to eyeball two numbers in separate tests.
  #
  # The threshold is deliberately loose. Across runs on this lab the pooled
  # figure has ranged from 15 to 38 against a direct 60 — on an idle machine
  # pgbench holds its rate limit and few backends are needed; under contention
  # the request pattern gets burstier and more backends open at once. Both
  # outcomes demonstrate multiplexing; only one of them survives a "must halve"
  # assertion, and a flaky test is worse than a weaker one. What must never
  # happen is the pooled count approaching the direct count.
  if [[ -f "${BATS_FILE_TMPDIR}/pooled_peak" ]]; then
    local pooled; pooled="$(cat "${BATS_FILE_TMPDIR}/pooled_peak")"
    echo "multiplexing ratio: ${pooled} pooled vs ${peak} direct" >&3
    (( pooled * 5 <= peak * 4 )) || \
      { echo "pooled backends (${pooled}) not meaningfully below direct (${peak})" >&2; return 1; }
  fi

  drain_idle_backends
}

@test "pgbouncer survives losing one of its replicas" {
  # The Service fronts three poolers; killing one must not interrupt clients.
  local victim
  victim="$(k -n "$HA_NS" get pods -l postgres-operator.crunchydata.com/role=pgbouncer \
    -o jsonpath='{.items[0].metadata.name}')"
  k -n "$HA_NS" delete pod "$victim" --now >/dev/null

  # Retry the query itself rather than sleeping a fixed amount: the Service
  # needs a moment to drop the deleted endpoint, and how long depends on the
  # cluster, not on a number we guessed. (`retry_until ... true` would settle
  # nothing — it succeeds instantly.)
  run retry_until 120 sql_pooled "$HA_NS" "$HA_CLUSTER" "select 1;"
  [ "$status" -eq 0 ]

  # retry_until discards output, so read the value in a separate call.
  run sql_pooled "$HA_NS" "$HA_CLUSTER" "select 1;"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "1"

  # and the replica comes back
  run k -n "$HA_NS" wait --for=condition=Available deploy/${HA_CLUSTER}-pgbouncer --timeout=180s
  [ "$status" -eq 0 ]
}
