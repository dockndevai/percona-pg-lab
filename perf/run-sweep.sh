#!/usr/bin/env bash
# pgbench sweep comparing direct-to-primary against pgBouncer, across client
# counts and duty cycles, recording both throughput and the PostgreSQL backend
# count that produced it.
#
#   perf/run-sweep.sh                 # the default matrix
#   DURATION=30 perf/run-sweep.sh     # longer runs
#   QUICK=1 perf/run-sweep.sh         # a two-point smoke test
#
# Output: perf/results/sweep-<timestamp>.csv, plus a regenerated results table
# in docs/10-performance-results.md.
#
# Why the duty-cycle axis exists: at 100% duty cycle every client is always
# inside a transaction, so pooling cannot multiplex and its only measurable
# effect is the extra network hop. Benchmarks that test only that shape are
# where "pgBouncer made things slower" comes from. The rate-limited rows are
# the ones that resemble a real application.
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

NS="$HA_NS"; CLUSTER="$HA_CLUSTER"
SCALE="${SCALE:-10}"
DURATION="${DURATION:-20}"
RESULTS_DIR="${REPO_ROOT}/perf/results"
STAMP="$(date +%Y%m%d-%H%M%S)"
CSV="${RESULTS_DIR}/sweep-${STAMP}.csv"

k -n "$NS" get pg "$CLUSTER" >/dev/null 2>&1 || die "HA cluster not deployed — run 'make ha-up'"
mkdir -p "$RESULTS_DIR"

POOL_HOST="$(pguser_field "$NS" "$CLUSTER" pgbouncer-host)"
DIRECT_HOST="$(pguser_field "$NS" "$CLUSTER" host)"
PW="$(pguser_field "$NS" "$CLUSTER" password)"
POD=perf-client

# ---------------------------------------------------------------- client pod
ensure_pod() {
  if ! k -n "$NS" get pod "$POD" >/dev/null 2>&1; then
    # --requests/--limits were removed from `kubectl run`; use --overrides.
    # The client needs real CPU: if pgbench itself is throttled you measure the
    # benchmark harness rather than the database.
    # securityContext as well as resources: a namespace enforcing the
    # `restricted` Pod Security Standard rejects a plain `kubectl run`.
    k -n "$NS" run "$POD" --image="$PG_IMAGE" --restart=Never \
      --override-type=strategic \
      --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":26,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"'"$POD"'","resources":{"requests":{"cpu":"200m","memory":"128Mi"},"limits":{"cpu":"2","memory":"512Mi"}},"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
      --command -- sleep 86400 >/dev/null
  fi
  k -n "$NS" wait --for=condition=Ready "pod/${POD}" --timeout=300s >/dev/null
}

bench() { k -n "$NS" exec "$POD" -- env PGPASSWORD="$PW" PGSSLMODE=require pgbench "$@"; }

# --------------------------------------------------------------- measurement
leader() { current_leader "$NS" "$CLUSTER"; }

backends() {
  # `|| true` matters here. lib.sh sets `pipefail`, and once the direct target
  # exhausts max_connections this psql can itself fail to connect — which under
  # `set -e` kills the whole sweep at exactly the most interesting data point.
  # An unreadable sample should be skipped, not fatal.
  psql_on_pod "$NS" "$(leader)" \
    "select count(*) from pg_stat_activity
      where usename='${CLUSTER}' and backend_type='client backend';" 2>/dev/null \
    | tr -d '[:space:]' || true
}

# Idle backends linger for server_idle_timeout (180s), so without this every
# run inherits the previous run's connections and the numbers are nonsense.
drain() {
  psql_on_pod "$NS" "$(leader)" \
    "select pg_terminate_backend(pid) from pg_stat_activity
      where usename='${CLUSTER}' and state='idle';" >/dev/null 2>&1 || true
  sleep 3
}

# run_one <label> <host> <clients> <rate|0> <mode:ro|rw>
run_one() {
  local label="$1" host="$2" clients="$3" rate="$4" mode="$5"
  # Measurement code runs without -e: everything in here has an expected
  # failure mode and handles it explicitly, and an unexpected non-zero from a
  # sampling query must not take down the sweep.
  set +e
  drain

  local args=(-h "$host" -U "$CLUSTER" -d "$CLUSTER"
              -c "$clients" -j 4 -T "$DURATION" --no-vacuum)
  [[ "$mode" == "ro" ]] && args+=(-S)
  [[ "$rate" != "0" ]] && args+=(-R "$rate")

  local out peak=0 n rc=0
  # NOT `set -e` territory: a run is *expected* to fail once the client count
  # exceeds max_connections on the direct target. That failure is the single
  # most useful data point in the sweep — it is the wall a pooler exists to
  # keep you away from — so record it instead of aborting.
  bench "${args[@]}" > "${RESULTS_DIR}/.raw" 2>&1 &
  local pid=$!

  local samples=$(( DURATION > 6 ? DURATION - 4 : 3 ))
  for _ in $(seq 1 "$samples"); do
    n="$(backends)"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > peak )) && peak=$n
    sleep 1
  done
  wait "$pid" || rc=$?
  out="$(cat "${RESULTS_DIR}/.raw")"

  local tps lat note=""
  tps="$(grep -oE '^tps = [0-9.]+' <<< "$out" | head -1 | awk '{printf "%.0f", $3}')"
  lat="$(grep -oE 'latency average = [0-9.]+' <<< "$out" | head -1 | awk '{printf "%.3f", $4}')"

  if [[ -z "$tps" ]]; then
    tps=0; lat=0
    # PostgreSQL words this two different ways depending on whether the
    # superuser reserve is what you ran into:
    #   FATAL: sorry, too many clients already
    #   FATAL: remaining connection slots are reserved for roles with the
    #          SUPERUSER attribute
    # The second is what you actually hit when superuser_reserved_connections
    # is set, which it is in the ha profile.
    if grep -qiE 'too many clients|sorry, too many|remaining connection slots' <<< "$out"; then
      note="max_connections exceeded"
    elif (( rc != 0 )); then
      note="failed (rc=${rc})"
    else
      note="no result"
    fi
  fi
  : "${lat:=0}"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$label" "$mode" "$clients" "$rate" "$DURATION" "$tps" "$lat" "$peak" "$note" >> "$CSV"
  if [[ -n "$note" ]]; then
    printf '  %-10s %-3s c=%-4s rate=%-5s %sFAILED: %s%s\n' \
      "$label" "$mode" "$clients" "$rate" "$C_YEL" "$note" "$C_OFF" >&2
  else
    printf '  %-10s %-3s c=%-4s rate=%-5s tps=%-8s lat=%-8s backends=%s\n' \
      "$label" "$mode" "$clients" "$rate" "$tps" "$lat" "$peak" >&2
  fi
  set -e
  return 0
}

# --------------------------------------------------------------------- sweep
ensure_pod
log "initialising pgbench dataset (scale ${SCALE}) directly on the primary"
bench -h "$DIRECT_HOST" -U "$CLUSTER" -d "$CLUSTER" -i -s "$SCALE" --quiet 2>&1 | tail -1 >&2

echo "target,mode,clients,rate,duration_s,tps,latency_ms,peak_backends,note" > "$CSV"

# Overridable so a single case can be re-run in isolation, e.g.
#   CLIENT_COUNTS=300 RATES=0 MODES=ro perf/run-sweep.sh
if [[ -n "${CLIENT_COUNTS:-}" ]]; then
  read -r -a CLIENT_COUNTS <<< "$CLIENT_COUNTS"
elif [[ "${QUICK:-0}" == "1" ]]; then
  CLIENT_COUNTS=(10 60)
else
  CLIENT_COUNTS=(10 50 100 300)
fi
if [[ -n "${RATES:-}" ]]; then read -r -a RATES <<< "$RATES"; else RATES=(0 240); fi
if [[ -n "${MODES:-}" ]]; then read -r -a MODES <<< "$MODES"; else MODES=(ro rw); fi

log "sweep: clients=[${CLIENT_COUNTS[*]}] rates=[${RATES[*]}] duration=${DURATION}s"
# `|| warn` on every call, deliberately.
#
# A sweep is 32 measurements and any one of them can legitimately blow up — the
# direct target at 300 clients exhausts max_connections, which is the single
# most instructive point in the whole run. Letting that abort the script means
# you lose the 31 measurements that did work AND never see the interesting one.
# One bad measurement is a data point, not a fatal error.
failures=0
for mode in "${MODES[@]}"; do
  for c in "${CLIENT_COUNTS[@]}"; do
    for r in "${RATES[@]}"; do
      run_one pgbouncer "$POOL_HOST"   "$c" "$r" "$mode" \
        || { warn "measurement aborted: pgbouncer ${mode} c=${c} rate=${r}"; failures=$(( failures + 1 )); }
      run_one direct    "$DIRECT_HOST" "$c" "$r" "$mode" \
        || { warn "measurement aborted: direct ${mode} c=${c} rate=${r}"; failures=$(( failures + 1 )); }
    done
  done
done
(( failures == 0 )) || warn "${failures} measurement(s) aborted — see the CSV for what was captured"
drain
rm -f "${RESULTS_DIR}/.raw"

ok "results written to ${CSV#"$REPO_ROOT"/}"
python3 "${REPO_ROOT}/perf/report.py" "$CSV" > "${REPO_ROOT}/docs/10-performance-results.md"
ok "docs/10-performance-results.md regenerated"
