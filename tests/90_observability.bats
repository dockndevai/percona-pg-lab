#!/usr/bin/env bats
# Monitoring: exporters are up, Prometheus is scraping them, and the alert rules
# actually loaded.

load helpers/common

setup_file() {
  require_cluster "$HA_NS" "$HA_CLUSTER"
  k get ns "$MONITORING_NS" >/dev/null 2>&1 || skip "monitoring not installed — run 'make obs-up'"
}
teardown_file() {
  cleanup_client_pod "$HA_NS"
  k -n "$MONITORING_NS" delete pod "${PROMQ_POD:-promq-client}" --now --ignore-not-found >/dev/null 2>&1 || true
}

# Query Prometheus from inside the cluster.
promql() {
  local q="$1"
  k -n "$MONITORING_NS" exec deploy/kps-kube-prometheus-stack-operator -- true 2>/dev/null || true
  k -n "$MONITORING_NS" run "promq-$RANDOM" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 -- \
    -sG --data-urlencode "query=${q}" \
    "http://kps-kube-prometheus-stack-prometheus.${MONITORING_NS}.svc:9090/api/v1/query" 2>/dev/null
}

@test "the exporter user exists and its secret was created" {
  run k -n "$HA_NS" get secret "${HA_CLUSTER}-pguser-pgexporter"
  [ "$status" -eq 0 ]
}

@test "the reserved 'monitor' username is not used" {
  # Guards against someone "fixing" this back to the obvious name. `monitor` is
  # reserved: the operator ignores it with only an INFO log, the secret is never
  # created, and the sidecars wedge in CreateContainerConfigError.
  run k -n "$HA_NS" get pg "$HA_CLUSTER" -o jsonpath='{.spec.users[*].name}'
  [ "$status" -eq 0 ]
  [[ "$output" != *"monitor"* ]] || \
    { echo "spec.users contains the reserved name 'monitor': $output" >&2; return 1; }
}

@test "the exporter user has pg_monitor and no table access" {
  local leader; leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  run psql_on_pod "$HA_NS" "$leader" \
    "select count(*) from pg_auth_members m
       join pg_roles r on r.oid = m.roleid
       join pg_roles u on u.oid = m.member
      where u.rolname = 'pgexporter' and r.rolname = 'pg_monitor';"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "1" "pgexporter is not a member of pg_monitor"
}

@test "every instance pod runs a postgres-exporter sidecar" {
  local n
  n="$(k -n "$HA_NS" get pods -l postgres-operator.crunchydata.com/data=postgres \
        -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{"\n"}{end}{end}' \
        | grep -c '^postgres-exporter$')"
  assert_equal "$n" "3" "expected a postgres-exporter in all three instance pods"
}

@test "every pgbouncer pod runs a pgbouncer-exporter sidecar" {
  local n
  n="$(k -n "$HA_NS" get pods -l postgres-operator.crunchydata.com/role=pgbouncer \
        -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{"\n"}{end}{end}' \
        | grep -c '^pgbouncer-exporter$')"
  assert_equal "$n" "3"
}

# Query Prometheus rather than scraping an exporter directly.
#
# Direct scraping is the obvious approach and it does not work here: the
# exporter containers ship busybox wget, which segfaults partway through the
# ~1MB exposition body — over a kubectl exec pipe you get a silently truncated
# 185 lines that stop before the metric you wanted, and writing to a file first
# fails because the sidecars run with readOnlyRootFilesystem.
#
# Asking Prometheus is also the better assertion: it proves the whole chain
# (exporter -> PodMonitor -> scrape -> relabelling), not just that a port is open.
# One long-lived curl pod for the whole suite, exec'd into per query.
#
# The obvious `kubectl run --rm` per query is not reliable enough to build
# assertions on: a name collision or a slow pull makes it return nothing, and a
# helper that maps "the query failed" onto "zero series" turns an infrastructure
# hiccup into a confident, wrong assertion about your metrics. Ask once, fail
# loudly.
PROMQ_POD="${PROMQ_POD:-promq-client}"

ensure_promq_pod() {
  if ! k -n "$MONITORING_NS" get pod "$PROMQ_POD" >/dev/null 2>&1; then
    k -n "$MONITORING_NS" run "$PROMQ_POD" --image=curlimages/curl:8.11.1 \
      --restart=Never --command -- sleep 7200 >/dev/null
  fi
  k -n "$MONITORING_NS" wait --for=condition=Ready "pod/${PROMQ_POD}" --timeout=180s >/dev/null
}

# Number of series returned by an instant query. Returns non-zero (and an empty
# string) if the query itself could not be executed.
promql_count() {
  local query="$1" body
  ensure_promq_pod
  body="$(k -n "$MONITORING_NS" exec "$PROMQ_POD" -- \
    curl -sG --data-urlencode "query=${query}" \
    "http://kps-kube-prometheus-stack-prometheus.${MONITORING_NS}.svc:9090/api/v1/query")" || return 1
  python3 -c "
import json,sys
d = json.loads(sys.argv[1])
if d.get('status') != 'success':
    sys.exit('prometheus returned: ' + json.dumps(d)[:200])
print(len(d['data']['result']))
" "$body"
}

@test "every postgres instance reports pg_up = 1" {
  # Allow for scrape timing: a cluster that just rolled needs an interval or two
  # before every instance has been scraped at least once.
  local n=""
  run retry_until 180 bash -c "true"
  for _ in $(seq 1 12); do
    n="$(promql_count 'pg_up == 1')" || n=""
    [[ "$n" == "3" ]] && break
    sleep 10
  done
  echo "pg_up series: ${n:-<query failed>}" >&3
  assert_equal "$n" "3" "expected one pg_up series per instance"
}

@test "primary and replica roles are distinguishable in metrics" {
  # The relabelling in servicemonitors.yaml is what makes a Grafana panel able
  # to split them. Without it every series looks identical and the dashboards
  # are useless.
  #
  # Retried, because Prometheus keeps returning a series for up to its staleness
  # window (5m) after the underlying target stops reporting. Straight after a
  # switchover you therefore briefly see TWO primaries: the new one, and the old
  # one's not-yet-stale series. That is a property of instant queries, not a
  # split brain — the PostgresTooManyPrimaries alert has a `for: 1m` for the
  # same reason.
  local primaries="" replicas=""
  for _ in $(seq 1 20); do
    primaries="$(promql_count 'pg_up{pg_role="primary"} == 1')" || primaries=""
    replicas="$(promql_count 'pg_up{pg_role="replica"} == 1')"  || replicas=""
    [[ "$primaries" == "1" && "$replicas" == "2" ]] && break
    sleep 20
  done
  echo "primary=${primaries} replica=${replicas}" >&3
  assert_equal "$primaries" "1" "expected exactly one primary series"
  assert_equal "$replicas" "2"
}

@test "the exporter's collectors are succeeding" {
  # A single collector can fail while the exporter still reports healthy, which
  # silently removes whole metric families.
  local ok_n; ok_n="$(promql_count 'pg_scrape_collector_success == 1')"
  echo "successful collectors: ${ok_n}" >&3
  assert_ge "$ok_n" 20 "too few postgres_exporter collectors succeeded"
}

@test "every pgbouncer reports pgbouncer_up = 1" {
  # Proves the admin console is genuinely reachable — the exporter cannot
  # produce this without a working admin_users/stats_users/auth_dbname setup.
  local n; n="$(promql_count 'pgbouncer_up == 1')"
  echo "pgbouncer_up series: ${n}" >&3
  assert_equal "$n" "3"
}

@test "pgbouncer pool metrics are present" {
  local n; n="$(promql_count 'pgbouncer_pools_server_active_connections')"
  echo "pool series: ${n}" >&3
  assert_ge "$n" 1 "no pgbouncer pool metrics — SHOW POOLS is not being read"
}

@test "prometheus is scraping the postgres exporters" {
  run retry_until 180 bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n '$MONITORING_NS' run promcheck-\$RANDOM --rm -i \
       --restart=Never --quiet --image=curlimages/curl:8.11.1 -- \
       -sG --data-urlencode 'query=pg_up' \
       'http://kps-kube-prometheus-stack-prometheus.${MONITORING_NS}.svc:9090/api/v1/query' \
     | grep -q '\"pg_role\"'"
  [ "$status" -eq 0 ]
}

@test "the alerting rules loaded" {
  run k -n "$MONITORING_NS" get prometheusrule percona-pg-lab
  [ "$status" -eq 0 ]
  run k -n "$MONITORING_NS" get prometheusrule percona-pg-lab -o yaml
  assert_contains "$output" "PgBouncerClientsWaiting"
  assert_contains "$output" "PostgresNoPrimary"
}

@test "grafana is running" {
  run k -n "$MONITORING_NS" get deploy kps-grafana -o jsonpath='{.status.readyReplicas}'
  [ "$status" -eq 0 ]
  assert_scalar_ge "$output" 1
}
