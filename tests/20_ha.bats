#!/usr/bin/env bats
# The HA topology: three Patroni members, one leader, synchronous replication,
# and placement that actually survives losing a node.

load helpers/common

setup_file() {
  require_cluster "$HA_NS" "$HA_CLUSTER"
}

teardown_file() {
  cleanup_client_pod "$HA_NS"
}

@test "cluster reports three ready postgres instances" {
  run k -n "$HA_NS" get pg "$HA_CLUSTER" -o jsonpath='{.status.postgres.ready}'
  assert_equal "$output" "3"
  run k -n "$HA_NS" get pg "$HA_CLUSTER" -o jsonpath='{.status.postgres.size}'
  assert_equal "$output" "3"
}

@test "cluster reports three ready pgbouncer replicas" {
  run k -n "$HA_NS" get pg "$HA_CLUSTER" -o jsonpath='{.status.pgbouncer.ready}'
  assert_equal "$output" "3"
}

@test "exactly one pod carries the primary role" {
  # bats `run` executes in the current shell, so sourced helpers are available
  # — but `run bash -c "..."` would fork a shell that has never sourced them.
  local leaders
  leaders="$(k -n "$HA_NS" get pods \
    -l "postgres-operator.crunchydata.com/cluster=${HA_CLUSTER},postgres-operator.crunchydata.com/role=primary" \
    -o jsonpath='{.items[*].metadata.name}')"
  assert_equal "$(wc -w <<< "$leaders" | tr -d ' ')" "1" "expected exactly one primary, got: '${leaders}'"
}

@test "two standbys are streaming" {
  local leader; leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  run psql_on_pod "$HA_NS" "$leader" \
    "select count(*) from pg_stat_replication where state='streaming';"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "2"
}

@test "exactly one standby is synchronous" {
  # synchronous_node_count: 1 means one confirmed sync standby and the rest
  # async. If this is 0, synchronous_mode silently isn't in effect.
  local leader; leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  run psql_on_pod "$HA_NS" "$leader" \
    "select count(*) from pg_stat_replication where sync_state='sync';"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "1"
}

@test "replication lag is under one second" {
  local leader; leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  run psql_on_pod "$HA_NS" "$leader" \
    "select coalesce(ceil(extract(epoch from max(replay_lag))),0)::int from pg_stat_replication;"
  [ "$status" -eq 0 ]
  assert_scalar_le "$output" 1 "replication lag too high"
}

@test "no two postgres pods share a node" {
  # This is what requiredDuringScheduling anti-affinity buys. If it regresses to
  # 'preferred', this test is the only thing that will tell you.
  local nodes
  nodes="$(k -n "$HA_NS" get pods -l postgres-operator.crunchydata.com/data=postgres \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | grep -c .)"
  assert_equal "$nodes" "3" "postgres pods are not spread across three nodes"
}

@test "tuned patroni parameters reached postgresql" {
  local leader; leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  run psql_on_pod "$HA_NS" "$leader" "show shared_buffers;"
  assert_equal "$output" "256MB"
  run psql_on_pod "$HA_NS" "$leader" "show synchronous_commit;"
  assert_equal "$output" "on"
  run psql_on_pod "$HA_NS" "$leader" "show max_connections;"
  assert_equal "$output" "200"
}

@test "writes and reads round-trip through pgbouncer" {
  run sql_pooled "$HA_NS" "$HA_CLUSTER" \
    "create table if not exists ha_smoke(id serial primary key, note text, at timestamptz default now());"
  [ "$status" -eq 0 ]
  run sql_pooled "$HA_NS" "$HA_CLUSTER" "insert into ha_smoke(note) values ('hello') returning id;"
  [ "$status" -eq 0 ]
  run sql_pooled "$HA_NS" "$HA_CLUSTER" "select count(*) from ha_smoke where note='hello';"
  [ "$status" -eq 0 ]
  assert_scalar_ge "$output" 1
}

@test "a committed write is visible on the synchronous standby" {
  # With synchronous_commit=on the commit does not return until the sync
  # standby has flushed it, so this must be true immediately and without
  # polling. If it ever isn't, your durability guarantee is a fiction.
  sql_pooled "$HA_NS" "$HA_CLUSTER" \
    "create table if not exists sync_probe(id int primary key);" >/dev/null
  sql_pooled "$HA_NS" "$HA_CLUSTER" \
    "insert into sync_probe values (1) on conflict do nothing;" >/dev/null

  local leader sync_pod
  leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  sync_pod="$(psql_on_pod "$HA_NS" "$leader" \
    "select application_name from pg_stat_replication where sync_state='sync' limit 1;")"
  [ -n "$sync_pod" ]

  # Two things must be named explicitly here, and both bite people:
  #  1. psql_on_pod connects to the "postgres" database by default, but the
  #     application data lives in the database named after the cluster.
  #  2. The operator auto-creates a schema named after the user
  #     (spec.autoCreateUserSchema, default true). PostgreSQL's default
  #     search_path is "$user", public — so an unqualified CREATE TABLE by the
  #     app user lands in that per-user schema, NOT in public. Connecting as
  #     postgres gives a different search_path and the table "does not exist".
  #     See docs/11-troubleshooting.md#tables-land-in-a-per-user-schema
  run psql_on_pod "$HA_NS" "$sync_pod" \
    "select count(*) from \"${HA_CLUSTER}\".sync_probe where id=1;" "$HA_CLUSTER"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "1" "sync standby is missing a committed row"
}

@test "the application user's tables live in its own schema, not public" {
  # Guards the assumption the previous test depends on, and documents the
  # behaviour that surprises people migrating an existing app.
  local leader; leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  run psql_on_pod "$HA_NS" "$leader" \
    "select schemaname from pg_tables where tablename='sync_probe';" "$HA_CLUSTER"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "$HA_CLUSTER" "expected the table in the per-user schema"
}

@test "the replicas service only resolves to standbys" {
  # Reading from <cluster>-replicas must never hit the primary, or your
  # read-your-writes assumptions break in surprising ways.
  local svc_ips pod_ips
  svc_ips="$(k -n "$HA_NS" get endpoints "${HA_CLUSTER}-replicas" \
    -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' | sort)"
  pod_ips="$(k -n "$HA_NS" get pods -l postgres-operator.crunchydata.com/role=replica \
    -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | sort)"
  assert_equal "$svc_ips" "$pod_ips" "replicas Service endpoints do not match the replica pods"
}
