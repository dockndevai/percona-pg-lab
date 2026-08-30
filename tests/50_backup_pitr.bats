#!/usr/bin/env bats
# Backup and point-in-time recovery.
#
# The PITR test is slow (it takes the cluster down and replaces its data
# directory) and is gated behind RUN_PITR=1 so that `make test` stays usable.

load helpers/common

setup_file() { require_cluster "$HA_NS" "$HA_CLUSTER"; }
teardown_file() { cleanup_client_pod "$HA_NS"; }

repo_info() {
  k -n "$HA_NS" exec "statefulset/${HA_CLUSTER}-repo-host" -c pgbackrest -- \
    pgbackrest --stanza=db --repo="$1" info
}

@test "repo1 exists and holds a valid backup" {
  # The operator takes a replica-create backup shortly after the cluster comes
  # up, but "cluster ready" and "first backup finished" are not the same moment.
  # Racing them makes this test flap on a freshly built cluster, reporting
  #   status: error (no valid backups)
  # for a repository that is working perfectly.
  run retry_until 600 bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' exec \
       'statefulset/${HA_CLUSTER}-repo-host' -c pgbackrest -- \
       pgbackrest --stanza=db --repo=1 info | grep -q 'status: ok'"
  [ "$status" -eq 0 ]

  run repo_info 1
  [ "$status" -eq 0 ]
  assert_contains "$output" "status: ok"
  assert_contains "$output" "full backup:"
}

@test "WAL archiving is succeeding" {
  # failed_count > 0 means WAL is not reaching the repository. The cluster keeps
  # running and looks healthy right up until you need a recovery you cannot do.
  local leader; leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  run psql_on_pod "$HA_NS" "$leader" "select failed_count from pg_stat_archiver;"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "0" "pg_stat_archiver reports failed WAL pushes"

  run psql_on_pod "$HA_NS" "$leader" \
    "select case when last_archived_wal is null then 0 else 1 end from pg_stat_archiver;"
  assert_scalar "$output" "1" "nothing has ever been archived"
}

@test "retention is configured on every repo" {
  # Without retention pgBackRest never expires anything and the repository fills
  # up silently. This is a config assertion because the failure takes weeks to
  # appear and then arrives as a full disk.
  run k -n "$HA_NS" get pg "$HA_CLUSTER" -o jsonpath='{.spec.backups.pgbackrest.global}'
  [ "$status" -eq 0 ]
  assert_contains "$output" "repo1-retention-full"
}

@test "an on-demand backup completes" {
  local name="bats-backup-${RANDOM}"
  cat <<YAML | k -n "$HA_NS" apply -f - >/dev/null
apiVersion: pgv2.percona.com/v2
kind: PerconaPGBackup
metadata:
  name: ${name}
spec:
  pgCluster: ${HA_CLUSTER}
  repoName: repo1
  options: ["--type=incr"]
YAML

  run retry_until 900 bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n '$HA_NS' get pg-backup '${name}' \
       -o jsonpath='{.status.state}' | grep -qx Succeeded"
  [ "$status" -eq 0 ]

  k -n "$HA_NS" delete pg-backup "$name" --ignore-not-found >/dev/null 2>&1 || true
}

@test "the S3 repo holds a backup when configured" {
  local repos
  repos="$(k -n "$HA_NS" get pg "$HA_CLUSTER" -o jsonpath='{.spec.backups.pgbackrest.repos[*].name}')"
  [[ "$repos" == *repo2* ]] || skip "repo2 not configured — run scripts/s3-repo-up.sh"

  run repo_info 2
  [ "$status" -eq 0 ]
  assert_contains "$output" "status: ok"
}

@test "point-in-time recovery lands on the target" {
  # Destructive and slow: the cluster is taken down and its data directory
  # replaced. Opt in with RUN_PITR=1.
  [[ "${RUN_PITR:-0}" == "1" ]] || skip "set RUN_PITR=1 to run the destructive PITR test"

  run "${REPO_ROOT}/scripts/pitr-demo.sh" repo1
  [ "$status" -eq 0 ]
  assert_contains "$output" "row 1 present, row 2 gone"
}
