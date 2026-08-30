#!/usr/bin/env bats
# Disaster recovery: a separate cluster, in a separate namespace, that replays
# the primary's WAL out of shared object storage — and can be promoted.
#
# The suite runs the full cycle and finishes by promoting, which is a one-way
# operation. Reset with:  make dr-down && make dr-up

load helpers/common

setup_file() {
  require_cluster "$HA_NS" "$HA_CLUSTER"
  require_cluster "$DR_NS" "$DR_CLUSTER"

  local enabled
  enabled="$(k -n "$DR_NS" get pg "$DR_CLUSTER" -o jsonpath='{.spec.standby.enabled}' 2>/dev/null)"
  [[ "$enabled" == "true" ]] || \
    skip "DR cluster is already promoted — reset with 'make dr-down && make dr-up'"
}

teardown_file() {
  cleanup_client_pod "$HA_NS"
}

dr_pod() {
  k -n "$DR_NS" get pods -l postgres-operator.crunchydata.com/data=postgres \
    -o jsonpath='{.items[0].metadata.name}'
}

@test "the standby is read-only" {
  run psql_on_pod "$DR_NS" "$(dr_pod)" "select pg_is_in_recovery();"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "t" "the DR cluster should be in recovery"
}

@test "the standby refuses writes" {
  # Against the `postgres` database, not the cluster-named one. While this
  # cluster is a standby it is read-only, so the operator has never been able to
  # create a database named after it — attempting the write there fails with
  # 'database "dr-cluster" does not exist', which is the right outcome for
  # entirely the wrong reason and would let a genuinely writable standby pass.
  run psql_on_pod "$DR_NS" "$(dr_pod)" "create table should_fail(id int);"
  [ "$status" -ne 0 ]
  assert_contains "$output" "read-only"
}

@test "the standby has no database of its own yet" {
  # Documents the behaviour the previous test has to work around: a standby
  # holds the SOURCE cluster's databases and none of its own.
  run psql_on_pod "$DR_NS" "$(dr_pod)" \
    "select count(*) from pg_database where datname='${DR_CLUSTER}';"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "0"
}

@test "the standby already holds the primary's databases and tables" {
  # Proves the standby restored from the primary's repo rather than silently
  # initialising an empty stanza — the failure mode a wrong repo2-path causes.
  run psql_on_pod "$DR_NS" "$(dr_pod)" \
    "select count(*) from pg_tables where schemaname = '${HA_CLUSTER}';" "$HA_CLUSTER"
  [ "$status" -eq 0 ]
  assert_scalar_ge "$output" 1 "standby has none of the primary's tables"
}

# Write a marker on the primary, force a WAL segment switch, and wait for it to
# appear on the standby. Returns the elapsed seconds via $REPLY_SECONDS.
_probe_replay() {
  local budget="$1"
  local marker="dr-probe-${RANDOM}${RANDOM}"
  local leader; leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"

  psql_on_pod "$HA_NS" "$leader" \
    "create table if not exists \"${HA_CLUSTER}\".dr_witness(id text primary key, at timestamptz default now());
     insert into \"${HA_CLUSTER}\".dr_witness(id) values ('${marker}');
     select pg_switch_wal();" "$HA_CLUSTER" >/dev/null

  local start=$SECONDS found=""
  while (( SECONDS - start < budget )); do
    found="$(last_line "$(psql_on_pod "$DR_NS" "$(dr_pod)" \
      "select count(*) from \"${HA_CLUSTER}\".dr_witness where id='${marker}';" \
      "$HA_CLUSTER" 2>/dev/null || true)")"
    [[ "$found" == "1" ]] && break
    sleep 5
  done
  REPLY_SECONDS=$(( SECONDS - start ))
  [[ "$found" == "1" ]]
}

@test "the standby catches up with the primary" {
  # A freshly-created standby starts from the last full backup and has to walk
  # forward through every WAL segment since. That catch-up is unbounded in
  # principle, so it gets a generous budget and its own test — measuring
  # steady-state RPO while the standby is still catching up is meaningless.
  #
  # Called directly rather than through `run`: bats runs the command in a
  # subshell, so REPLY_SECONDS set inside it would not survive.
  REPLY_SECONDS=0
  _probe_replay 900
  echo "initial catch-up: ${REPLY_SECONDS}s" >&3
}

@test "steady-state replication lag is bounded" {
  # Now that the standby is caught up, this is the real RPO: one WAL segment
  # switch plus the standby's restore_command polling interval.
  #
  # This is ARCHIVE-based replication, not streaming. Sub-second lag is not on
  # offer and any documentation claiming it for this topology is wrong.
  REPLY_SECONDS=0
  _probe_replay 300
  echo "steady-state replay lag: ${REPLY_SECONDS}s" >&3
  assert_le "$REPLY_SECONDS" 300 "steady-state replay lag exceeded 300s"
}

@test "promoting the standby makes it writable on a new timeline" {
  local before after
  before="$(last_line "$(psql_on_pod "$DR_NS" "$(dr_pod)" \
    "select timeline_id from pg_control_checkpoint();")")"

  # Go through scripts/dr-promote.sh rather than patching standby.enabled here.
  # The script promotes AND repoints repo2-path in one patch, and that second
  # half is the whole protection against poisoning the source repository. A test
  # that patches standby.enabled directly passes while leaving the repository
  # broken — which is exactly what happened the first time we wrote this.
  run "${REPO_ROOT}/scripts/dr-promote.sh"
  [ "$status" -eq 0 ]

  after="$(last_line "$(psql_on_pod "$DR_NS" "$(dr_pod)" \
    "select timeline_id from pg_control_checkpoint();")")"
  echo "timeline ${before} -> ${after}" >&3
  assert_ge "$after" "$(( before + 1 ))" "promotion did not advance the timeline"

  run psql_on_pod "$DR_NS" "$(dr_pod)" "select pg_is_in_recovery();"
  assert_scalar "$output" "f"
}

@test "promotion detached the cluster from the source repository" {
  # Without this, the promoted cluster keeps archive_mode=on pointed at the
  # SOURCE stanza and starts writing a divergent timeline into it. Every future
  # standby built from that repository then restores the wrong lineage and
  # silently never replicates.
  # See docs/11-troubleshooting.md#poisoned-stanza
  run k -n "$DR_NS" get pg "$DR_CLUSTER" \
    -o jsonpath='{.spec.backups.pgbackrest.global.repo2-path}'
  [ "$status" -eq 0 ]
  assert_equal "$output" "/pgbackrest/${DR_NS}/${DR_CLUSTER}/repo2" \
    "promoted cluster is still archiving into the source cluster's repo path"
}

@test "the promoted cluster accepts writes" {
  # Into the `postgres` database, not the cluster-named one: while this cluster
  # was a standby it was read-only, so the operator could not create its own
  # database. That happens only after promotion, and not instantly.
  run retry_until 180 psql_on_pod "$DR_NS" "$(dr_pod)" \
    "create table if not exists promoted_probe(at timestamptz default now());"
  [ "$status" -eq 0 ]
  run psql_on_pod "$DR_NS" "$(dr_pod)" \
    "insert into promoted_probe default values; select count(*) from promoted_probe;"
  [ "$status" -eq 0 ]
  assert_scalar_ge "$output" 1
}

@test "the promoted cluster still has the primary's data" {
  # A promotion that loses the data it was protecting is not a recovery.
  run psql_on_pod "$DR_NS" "$(dr_pod)" \
    "select count(*) from \"${HA_CLUSTER}\".dr_witness;" "$HA_CLUSTER"
  [ "$status" -eq 0 ]
  assert_scalar_ge "$output" 1
}
