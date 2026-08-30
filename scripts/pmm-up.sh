#!/usr/bin/env bash
# OPTIONAL: install PMM 3 Server and point the HA cluster's PMM clients at it.
#
# PMM is Percona's native monitoring path and the only one the operator supports
# out of the box (spec.pmm). It is opt-in here purely because PMM Server wants
# roughly 4 GiB on its own, which does not coexist comfortably with an HA
# cluster and kube-prometheus-stack on a laptop.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PMM_NS="${PMM_NS:-pmm}"
PMM_CHART_VERSION="${PMM_CHART_VERSION:-1.9.1}"     # -> PMM Server 3.9.1

k -n "$HA_NS" get pg "$HA_CLUSTER" >/dev/null 2>&1 || die "run 'make ha-up' first"

mem_gib=$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
(( mem_gib >= 12 )) || warn "PMM Server wants ~4Gi and Docker has ${mem_gib}Gi total — expect pressure"

log "installing PMM Server ${PMM_CHART_VERSION} into ${PMM_NS}"
helm repo add percona https://percona.github.io/percona-helm-charts/ >/dev/null 2>&1 || true
helm repo update percona >/dev/null

helm --kube-context "$KUBE_CONTEXT" upgrade --install pmm percona/pmm \
  --version "$PMM_CHART_VERSION" \
  --namespace "$PMM_NS" --create-namespace \
  --set service.type=ClusterIP \
  --set storage.size=8Gi \
  --wait --timeout 20m

log "waiting for PMM Server to answer"
retry_n() { local n="$1"; shift; for _ in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 10; done; return 1; }
retry_n 60 k -n "$PMM_NS" exec deploy/pmm -- curl -sk https://127.0.0.1/v1/readyz \
  || die "PMM Server did not become ready"

# PMM 3 authenticates agents with a service-account token. PMM 2 used API keys
# and is end-of-life; if you find a guide using api-key, it is out of date.
log "creating a service account token for the operator"
admin_pw="$(k -n "$PMM_NS" get secret pmm-secret -o jsonpath='{.data.PMM_ADMIN_PASSWORD}' 2>/dev/null | base64 -d || echo admin)"

token="$(k -n "$PMM_NS" exec deploy/pmm -- bash -c "
  set -e
  sa=\$(curl -sk -u 'admin:${admin_pw}' -X POST https://127.0.0.1/graph/api/serviceaccounts \
        -H 'Content-Type: application/json' \
        -d '{\"name\":\"pg-lab-$RANDOM\",\"role\":\"Admin\",\"isDisabled\":false}' | sed -n 's/.*\"id\":\([0-9]*\).*/\1/p')
  curl -sk -u 'admin:${admin_pw}' -X POST \"https://127.0.0.1/graph/api/serviceaccounts/\${sa}/tokens\" \
       -H 'Content-Type: application/json' -d '{\"name\":\"pg-lab-token\"}' \
    | sed -n 's/.*\"key\":\"\([^\"]*\)\".*/\1/p'
" 2>/dev/null || true)"

[[ -n "$token" ]] || die "could not mint a PMM service account token — check 'kubectl -n ${PMM_NS} logs deploy/pmm'"

k -n "$HA_NS" create secret generic "${HA_CLUSTER}-pmm-secret" \
  --from-literal=PMM_SERVER_TOKEN="$token" \
  --dry-run=client -o yaml | k apply -f -
ok "token stored in ${HA_CLUSTER}-pmm-secret"

log "enabling the PMM client sidecar on ${HA_CLUSTER}"
# This rewrites the instance StatefulSets, so all three pods roll.
k -n "$HA_NS" patch pg "$HA_CLUSTER" --type merge -p "$(cat <<JSON
{
  "spec": {
    "pmm": {
      "enabled": true,
      "image": "docker.io/percona/pmm-client:3.7.1",
      "secret": "${HA_CLUSTER}-pmm-secret",
      "serverHost": "pmm-service.${PMM_NS}.svc"
    }
  }
}
JSON
)"

sleep 20
wait_cluster_ready "$HA_NS" "$HA_CLUSTER" 900

ok "PMM is collecting from ${HA_CLUSTER}"
cat >&2 <<INFO

  Reach the PMM UI with a port-forward (it is not exposed on a NodePort):

    kubectl -n ${PMM_NS} port-forward svc/pmm-service 8443:443
    open https://localhost:8443     admin / ${admin_pw}

  Remove it again with:  make pmm-down

INFO
