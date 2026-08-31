#!/usr/bin/env bash
# Shared helpers for every bats suite.
#
# Design note: these deliberately shell out to kubectl/psql rather than using a
# Kubernetes client library. The assertions are then literally the commands an
# operator would type, which makes a failing test self-documenting.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib.sh
source "${REPO_ROOT}/scripts/lib.sh"

# --- assertions --------------------------------------------------------------

assert_equal() {
  local actual="$1" expected="$2" msg="${3:-}"
  if [[ "$actual" != "$expected" ]]; then
    echo "assertion failed${msg:+: $msg}" >&2
    echo "  expected: '${expected}'" >&2
    echo "  actual:   '${actual}'" >&2
    return 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "assertion failed${msg:+: $msg}" >&2
    echo "  expected to contain: '${needle}'" >&2
    echo "  actual:              '${haystack}'" >&2
    return 1
  fi
}

# assert_ge <actual> <minimum> [msg]  — numeric comparison with a useful message
assert_ge() {
  local actual="$1" min="$2" msg="${3:-}"
  if ! [[ "$actual" =~ ^-?[0-9]+$ ]]; then
    echo "assertion failed${msg:+: $msg}: '${actual}' is not an integer" >&2
    return 1
  fi
  if (( actual < min )); then
    echo "assertion failed${msg:+: $msg}: ${actual} < ${min}" >&2
    return 1
  fi
}

assert_le() {
  local actual="$1" max="$2" msg="${3:-}"
  if (( actual > max )); then
    echo "assertion failed${msg:+: $msg}: ${actual} > ${max}" >&2
    return 1
  fi
}

# --- skips -------------------------------------------------------------------

# Skip the whole suite unless the named cluster exists and is ready. Keeps
# `make test` usable when only some profiles are deployed.
require_cluster() {
  local ns="$1" cluster="$2"
  k get ns "$ns"           >/dev/null 2>&1 || skip "namespace ${ns} not present"
  k -n "$ns" get pg "$cluster" >/dev/null 2>&1 || skip "cluster ${ns}/${cluster} not deployed"
  local state
  state="$(k -n "$ns" get pg "$cluster" -o jsonpath='{.status.state}' 2>/dev/null)"
  [[ "$state" == "ready" ]] || skip "cluster ${ns}/${cluster} is '${state}', not ready"
}

# --- SQL ---------------------------------------------------------------------

# Run SQL through pgBouncer as the cluster's application user.
# usage: sql_pooled <ns> <cluster> <sql> [database]
sql_pooled() {
  local ns="$1" cluster="$2" sql="$3" db="${4:-$2}"
  local pw host
  pw="$(pguser_field "$ns" "$cluster" password)"
  host="$(pguser_field "$ns" "$cluster" pgbouncer-host)"
  _run_psql "$ns" "$pw" "$host" "$cluster" "$db" "$sql"
}

# Run SQL straight at the primary, bypassing the pool. Use this to prove that a
# behaviour difference really is pgBouncer's doing.
sql_direct() {
  local ns="$1" cluster="$2" sql="$3" db="${4:-$2}"
  local pw host
  pw="$(pguser_field "$ns" "$cluster" password)"
  host="$(pguser_field "$ns" "$cluster" host)"
  _run_psql "$ns" "$pw" "$host" "$cluster" "$db" "$sql"
}

# Query the pgBouncer admin console (SHOW POOLS / SHOW STATS / SHOW CLIENTS).
# Requires admin_users+stats_users+auth_dbname in spec.proxy.pgBouncer.config.global.
sql_admin() {
  local ns="$1" cluster="$2" sql="$3"
  local pw host
  pw="$(pguser_field "$ns" "$cluster" password)"
  host="$(pguser_field "$ns" "$cluster" pgbouncer-host)"
  _run_psql "$ns" "$pw" "$host" "$cluster" pgbouncer "$sql"
}

# Reuses a long-lived client pod so each assertion isn't paying pod-startup
# latency. The pod is created on demand and torn down by teardown_suite.
PGCLIENT_POD="${PGCLIENT_POD:-pg-lab-client}"

ensure_client_pod() {
  local ns="$1"
  if k -n "$ns" get pod "$PGCLIENT_POD" >/dev/null 2>&1; then
    local phase
    phase="$(k -n "$ns" get pod "$PGCLIENT_POD" -o jsonpath='{.status.phase}')"
    [[ "$phase" == "Running" ]] && return 0
    k -n "$ns" delete pod "$PGCLIENT_POD" --now >/dev/null 2>&1 || true
  fi
  # The securityContext is not optional decoration. A namespace enforcing the
  # `restricted` Pod Security Standard rejects a plain `kubectl run` outright:
  #   violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false,
  #   unrestricted capabilities, runAsNonRoot != true, seccompProfile
  # The operator's own pods already satisfy restricted, so it would be an odd
  # repository whose test tooling was the reason you could not enable it.
  # runAsUser 26 is the postgres UID in the Percona image.
  k -n "$ns" run "$PGCLIENT_POD" --image="$PG_IMAGE" --restart=Never \
    --override-type=strategic \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":26,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"'"$PGCLIENT_POD"'","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
    --command -- sleep 7200 >/dev/null
  k -n "$ns" wait --for=condition=Ready "pod/${PGCLIENT_POD}" --timeout=180s >/dev/null
}

_run_psql() {
  local ns="$1" pw="$2" host="$3" user="$4" db="$5" sql="$6"
  ensure_client_pod "$ns"
  # PGSSLMODE=require because the operator forces client_tls_sslmode=require.
  k -n "$ns" exec "$PGCLIENT_POD" -- \
    env PGPASSWORD="$pw" PGSSLMODE=require \
    psql -h "$host" -p 5432 -U "$user" -d "$db" -tAX -c "$sql"
}

cleanup_client_pod() {
  local ns="$1"
  k -n "$ns" delete pod "$PGCLIENT_POD" --now --ignore-not-found >/dev/null 2>&1 || true
}

# --- waiting -----------------------------------------------------------------

# retry_until <timeout_seconds> <command...>  — poll until the command succeeds
retry_until() {
  local timeout="$1"; shift
  local deadline=$(( SECONDS + timeout ))
  while (( SECONDS < deadline )); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "timed out after ${timeout}s waiting for: $*" >&2
  return 1
}

# --- output shaping ----------------------------------------------------------
#
# psql -tA still emits NOTICE/WARNING lines and, on failure, multi-line errors.
# Naively stripping non-digits from $output turns "ERROR: relation ... line 1"
# into a number and produces a nonsense assertion. Always funnel scalar results
# through these.

# Last non-empty line of a command's output, whitespace trimmed.
last_line() {
  local out="$1"
  printf '%s\n' "$out" | awk 'NF{line=$0} END{print line}' | tr -d '[:space:]'
}

# Assert that a command's output is exactly the expected scalar.
assert_scalar() {
  local out="$1" expected="$2" msg="${3:-}"
  assert_equal "$(last_line "$out")" "$expected" "$msg"
}

# Assert the scalar result is an integer >= min.
assert_scalar_ge() {
  local out="$1" min="$2" msg="${3:-}"
  assert_ge "$(last_line "$out")" "$min" "$msg"
}

assert_scalar_le() {
  local out="$1" max="$2" msg="${3:-}"
  local v; v="$(last_line "$out")"
  [[ "$v" =~ ^-?[0-9]+$ ]] || { echo "not an integer: '$v' ${msg}" >&2; return 1; }
  assert_le "$v" "$max" "$msg"
}
