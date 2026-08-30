#!/usr/bin/env bash
# Shared helpers for every script in this repo.
# Source it, don't execute it:  source "$(dirname "$0")/lib.sh"

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# --- Cluster / namespace conventions -----------------------------------------
export KIND_CLUSTER="${KIND_CLUSTER:-pg-lab}"
export KUBE_CONTEXT="${KUBE_CONTEXT:-kind-${KIND_CLUSTER}}"

export OPERATOR_NS="${OPERATOR_NS:-pg-operator}"
export DEV_NS="${DEV_NS:-pg-dev}"
export HA_NS="${HA_NS:-pg-ha}"
export DR_NS="${DR_NS:-pg-dr}"
export MINIO_NS="${MINIO_NS:-pg-backup}"
export MONITORING_NS="${MONITORING_NS:-monitoring}"

export DEV_CLUSTER="${DEV_CLUSTER:-dev-cluster}"
export HA_CLUSTER="${HA_CLUSTER:-ha-cluster}"
export DR_CLUSTER="${DR_CLUSTER:-dr-cluster}"

# --- Pinned upstream versions ------------------------------------------------
# Bump these in one place. See docs/09-lifecycle-operations.md#upgrading-the-operator
export OPERATOR_VERSION="${OPERATOR_VERSION:-3.0.0}"
export PG_IMAGE="${PG_IMAGE:-docker.io/percona/percona-distribution-postgresql:18.3-2}"
export PGBOUNCER_IMAGE="${PGBOUNCER_IMAGE:-docker.io/percona/percona-pgbouncer:1.25.1-1}"
export PGBACKREST_IMAGE="${PGBACKREST_IMAGE:-docker.io/percona/percona-pgbackrest:2.58.0-1}"
export POSTGRES_EXPORTER_IMAGE="${POSTGRES_EXPORTER_IMAGE:-quay.io/prometheuscommunity/postgres-exporter:v0.17.1}"
export PGBOUNCER_EXPORTER_IMAGE="${PGBOUNCER_EXPORTER_IMAGE:-quay.io/prometheuscommunity/pgbouncer-exporter:v0.11.0}"

# --- Output ------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_DIM=$'\033[2m';    C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_OFF=""
fi

log()  { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*" >&2; }
ok()   { printf '%s  ✓%s %s\n' "$C_GRN" "$C_OFF" "$*" >&2; }
warn() { printf '%s  !%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s  ✗%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
dim()  { printf '%s%s%s\n'     "$C_DIM" "$*" "$C_OFF" >&2; }

# --- kubectl bound to our context --------------------------------------------
k() { kubectl --context "$KUBE_CONTEXT" "$@"; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

# Wait until a PerconaPGCluster reports state=ready.
# usage: wait_cluster_ready <namespace> <name> [timeout_seconds]
wait_cluster_ready() {
  local ns="$1" name="$2" timeout="${3:-900}"
  local deadline=$(( SECONDS + timeout )) state=""
  log "waiting for PerconaPGCluster ${ns}/${name} to become ready (timeout ${timeout}s)"
  while (( SECONDS < deadline )); do
    state="$(k -n "$ns" get pg "$name" -o jsonpath='{.status.state}' 2>/dev/null || true)"
    if [[ "$state" == "ready" ]]; then
      ok "cluster ${ns}/${name} is ready"
      return 0
    fi
    printf '\r%s    state=%-12s %3ds elapsed%s' "$C_DIM" "${state:-<none>}" "$SECONDS" "$C_OFF" >&2
    sleep 5
  done
  printf '\n' >&2
  k -n "$ns" get pods -o wide >&2 || true
  die "timed out waiting for ${ns}/${name} (last state: ${state:-<none>})"
}

# Name of the Secret holding credentials for the default application user.
# The operator names it <cluster>-pguser-<user>.
pguser_secret() { echo "$1-pguser-$1"; }

# Read one key out of the app user's Secret.
# usage: pguser_field <namespace> <cluster> <key>
pguser_field() {
  local ns="$1" cluster="$2" key="$3"
  k -n "$ns" get secret "$(pguser_secret "$cluster")" \
    -o "jsonpath={.data.${key}}" | base64 -d
}

# Pod name of the current Patroni leader.
# NOTE the role label value is "primary" (not "master") in operator v3.
# Returns the empty string (and exit 0) when there is no leader — which is a
# normal, transient state during a failover. Callers must check for emptiness
# rather than rely on the exit code; a non-zero return here would abort any
# caller running under `set -e`, including every bats test.
current_leader() {
  local ns="$1" cluster="$2"
  k -n "$ns" get pods \
    -l "postgres-operator.crunchydata.com/cluster=${cluster},postgres-operator.crunchydata.com/role=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# Pod names of the streaming standbys, one per line.
current_replicas() {
  local ns="$1" cluster="$2"
  k -n "$ns" get pods \
    -l "postgres-operator.crunchydata.com/cluster=${cluster},postgres-operator.crunchydata.com/role=replica" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

# Run SQL on a specific instance pod as the postgres superuser over the local
# socket. Bypasses pgBouncer *and* the network, so it still works while the
# cluster is mid-failover.
# usage: psql_on_pod <namespace> <pod> <sql> [database]
# NOTE the database defaults to "postgres", NOT to the application database.
# Application tables live in the database named after the cluster, so pass it
# explicitly when you are checking application data.
psql_on_pod() {
  local ns="$1" pod="$2" sql="$3" db="${4:-postgres}"
  k -n "$ns" exec "$pod" -c database -- psql -U postgres -d "$db" -tAXc "$sql"
}
