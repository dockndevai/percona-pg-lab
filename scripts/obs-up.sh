#!/usr/bin/env bash
# Install the monitoring stack and wire the HA cluster's exporters into it.
#
# Order matters: the exporter sidecars need the `monitor` user to exist, and the
# PodMonitors need the Prometheus operator's CRDs to exist. Doing this in the
# wrong order leaves you with silently-unscraped targets.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

k -n "$HA_NS" get pg "$HA_CLUSTER" >/dev/null 2>&1 || die "run 'make ha-up' first"

log "installing kube-prometheus-stack into ${MONITORING_NS}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

helm --kube-context "$KUBE_CONTEXT" upgrade --install kps \
  prometheus-community/kube-prometheus-stack \
  --namespace "$MONITORING_NS" --create-namespace \
  --values "${REPO_ROOT}/observability/kube-prometheus-stack/values.yaml" \
  --wait --timeout 15m

# NOTE: the exporter sidecars are NOT patched in here. They live in
# clusters/ha/cluster.yaml alongside everything else that defines the cluster.
#
# They used to be a separate merge patch, and that was a mistake worth
# recording: `instances`, `proxy` and `users` are lists, so a merge patch has to
# restate each of them in full. Two copies of the same block drifted apart
# within an afternoon, and the patch silently reverted resource limits that had
# been tuned in the base manifest. One definition, in one place.
log "checking the exporter sidecars are present"
if ! k -n "$HA_NS" get pg "$HA_CLUSTER" \
     -o jsonpath='{.spec.instances[0].sidecars[*].name}' | grep -q postgres-exporter; then
  die "the HA cluster has no postgres-exporter sidecar — re-apply it with 'make ha-up'"
fi
retry() { local n="$1"; shift; for _ in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }
retry 60 k -n "$HA_NS" get secret "${HA_CLUSTER}-pguser-pgexporter" \
  || die "the pgexporter secret is missing — check: kubectl -n ${OPERATOR_NS} logs deploy/pg-operator | grep -i user"
ok "exporters present"

log "granting pg_monitor to the exporter user"
# Must be done here, not in the CR. spec.users[].options sets ALTER ROLE
# *attributes* at creation time; role membership is not an attribute, so
# `options: "pg_monitor"` is accepted and silently does nothing. Without this
# grant the exporter still scrapes, but pg_stat_activity hides other sessions'
# query text and pg_stat_replication is empty — so replication lag panels stay
# blank for no visible reason.
leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
[[ -n "$leader" ]] || die "no primary found in ${HA_NS}/${HA_CLUSTER}"
psql_on_pod "$HA_NS" "$leader" "GRANT pg_monitor TO pgexporter;" >/dev/null
ok "pg_monitor granted"

log "applying PodMonitors and alerting rules"
k -n "$MONITORING_NS" apply -f "${REPO_ROOT}/observability/kube-prometheus-stack/servicemonitors.yaml"
k -n "$MONITORING_NS" apply -f "${REPO_ROOT}/observability/kube-prometheus-stack/prometheus-rules.yaml"

log "loading Grafana dashboards"
for f in "${REPO_ROOT}"/observability/dashboards/*.json; do
  [[ -e "$f" ]] || continue
  name="$(basename "$f" .json)"
  k -n "$MONITORING_NS" create configmap "dashboard-${name}" \
    --from-file="$(basename "$f")=${f}" \
    --dry-run=client -o yaml \
    | k label -f - --local --dry-run=client -o yaml grafana_dashboard=1 \
    | k apply -f -
done

ok "observability stack is up"
"${REPO_ROOT}/scripts/grafana-info.sh"
