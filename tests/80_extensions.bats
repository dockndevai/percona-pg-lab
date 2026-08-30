#!/usr/bin/env bats
# Extensions: available, preloaded, created, and actually functional.

load helpers/common

setup_file() {
  require_cluster "$HA_NS" "$HA_CLUSTER"
  local builtin
  builtin="$(k -n "$HA_NS" get pg "$HA_CLUSTER" -o jsonpath='{.spec.extensions.builtin}' 2>/dev/null)"
  [[ -n "$builtin" ]] || skip "extensions not enabled — run 'make extensions-up'"
}
teardown_file() { cleanup_client_pod "$HA_NS"; }

leader_pod() { current_leader "$HA_NS" "$HA_CLUSTER"; }

@test "shared_preload_libraries contains the one preload extension" {
  run psql_on_pod "$HA_NS" "$(leader_pod)" "show shared_preload_libraries;"
  [ "$status" -eq 0 ]
  assert_contains "$output" "pg_stat_statements"
}

@test "only one library is preloaded" {
  # Guards the operator limitation the profile is built around: v3.0.0 sets
  # shared_preload_libraries to exactly ONE library. If this ever returns more
  # than one, the operator has been fixed and extensions/extensions-patch.yaml
  # can enable more than one preload extension.
  run psql_on_pod "$HA_NS" "$(leader_pod)" "show shared_preload_libraries;"
  [ "$status" -eq 0 ]
  local n; n="$(last_line "$output" | tr ',' '\n' | grep -c .)"
  echo "preloaded libraries: $(last_line "$output")" >&3
  assert_equal "$n" "1" "operator behaviour changed — see extensions/extensions-patch.yaml"
}

@test "no parameter change is left pending a restart" {
  # If shared_preload_libraries is still pending_restart, the extensions are not
  # really loaded no matter what the CR says.
  run psql_on_pod "$HA_NS" "$(leader_pod)" \
    "select count(*) from pg_settings where pending_restart;"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "0"
}

@test "pg_stat_statements is installed and collecting" {
  run psql_on_pod "$HA_NS" "$(leader_pod)" \
    "select count(*) from pg_extension where extname='pg_stat_statements';" "$HA_CLUSTER"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "1"

  run psql_on_pod "$HA_NS" "$(leader_pod)" \
    "select count(*) >= 0 from pg_stat_statements;" "$HA_CLUSTER"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "t"
}

@test "pg_stat_statements is actually queryable, not merely installed" {
  # The distinction that matters. CREATE EXTENSION can succeed while the library
  # is not preloaded, leaving a row in pg_extension and a view that errors on
  # every query:
  #   ERROR: pg_stat_statements must be loaded via "shared_preload_libraries"
  run psql_on_pod "$HA_NS" "$(leader_pod)" \
    "select count(*) >= 0 from pg_stat_statements;" "$HA_CLUSTER"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "t"
}

@test "pg_stat_statements tuning was applied" {
  run psql_on_pod "$HA_NS" "$(leader_pod)" "show pg_stat_statements.max;"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "10000"
}

@test "pgvector works end to end" {
  # Note the SQL name is `vector`, not `pgvector`.
  run psql_on_pod "$HA_NS" "$(leader_pod)" \
    "select count(*) from pg_extension where extname='vector';" "$HA_CLUSTER"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "1"

  run psql_on_pod "$HA_NS" "$(leader_pod)" \
    "drop table if exists public.vec_probe;
     create table public.vec_probe(id serial primary key, e vector(3));
     insert into public.vec_probe(e) values ('[1,2,3]'), ('[4,5,6]');
     select id from public.vec_probe order by e <-> '[3,1,2]' limit 1;" "$HA_CLUSTER"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "1" "nearest-neighbour search returned the wrong row"
}

@test "extensions survived onto the replicas" {
  # Extensions are catalogue entries, so they replicate — but the *library* must
  # also be preloaded on each replica, which is a per-pod restart. If a replica
  # missed it, promoting to that replica breaks the extension.
  local replica
  replica="$(current_replicas "$HA_NS" "$HA_CLUSTER" | head -1)"
  [ -n "$replica" ]
  run psql_on_pod "$HA_NS" "$replica" "show shared_preload_libraries;"
  [ "$status" -eq 0 ]
  assert_contains "$output" "pg_stat_statements"
}
