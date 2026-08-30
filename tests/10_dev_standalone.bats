#!/usr/bin/env bats
# The minimal profile: one instance, one pooler, and the basics working.

load helpers/common

setup_file() { require_cluster "$DEV_NS" "$DEV_CLUSTER"; }
teardown_file() { cleanup_client_pod "$DEV_NS"; }

@test "one postgres instance and one pgbouncer are ready" {
  run k -n "$DEV_NS" get pg "$DEV_CLUSTER" -o jsonpath='{.status.postgres.ready}'
  assert_equal "$output" "1"
  run k -n "$DEV_NS" get pg "$DEV_CLUSTER" -o jsonpath='{.status.pgbouncer.ready}'
  assert_equal "$output" "1"
}

@test "the single instance is the primary" {
  # With replicas: 1 there is nobody to fail over to, so the sole member must be
  # the leader. If it is ever a replica, Patroni has lost its leader lease and
  # the cluster is read-only.
  local leader; leader="$(current_leader "$DEV_NS" "$DEV_CLUSTER")"
  [ -n "$leader" ]
}

@test "dev-specific tuning is applied" {
  local leader; leader="$(current_leader "$DEV_NS" "$DEV_CLUSTER")"
  run psql_on_pod "$DEV_NS" "$leader" "show synchronous_commit;"
  # off is deliberate in dev and is exactly what makes it unsuitable for
  # anything real — see docs/05-postgres-tuning.md#durability
  assert_scalar "$output" "off"
  run psql_on_pod "$DEV_NS" "$leader" "show max_connections;"
  assert_scalar "$output" "100"
}

@test "CRUD round-trips through pgbouncer" {
  run sql_pooled "$DEV_NS" "$DEV_CLUSTER" \
    "create table if not exists dev_smoke(id serial primary key, v text);"
  [ "$status" -eq 0 ]
  run sql_pooled "$DEV_NS" "$DEV_CLUSTER" "insert into dev_smoke(v) values ('x');"
  [ "$status" -eq 0 ]
  run sql_pooled "$DEV_NS" "$DEV_CLUSTER" "select count(*) from dev_smoke where v='x';"
  assert_scalar_ge "$output" 1
  run sql_pooled "$DEV_NS" "$DEV_CLUSTER" "delete from dev_smoke where v='x';"
  [ "$status" -eq 0 ]
}

@test "the pgbouncer admin console is reachable" {
  run sql_admin "$DEV_NS" "$DEV_CLUSTER" "SHOW POOLS;"
  [ "$status" -eq 0 ]
  assert_contains "$output" "$DEV_CLUSTER"
}

@test "an initial backup was taken automatically" {
  # The operator takes a replica-create backup on cluster creation. If this is
  # empty, the backup path is broken and you would only find out when you
  # needed it.
  run k -n "$DEV_NS" exec "statefulset/${DEV_CLUSTER}-repo-host" -c pgbackrest -- \
    pgbackrest --stanza=db --repo=1 info
  [ "$status" -eq 0 ]
  assert_contains "$output" "status: ok"
}
