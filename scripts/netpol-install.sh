#!/usr/bin/env bash
# Install network policies for a PerconaPGCluster namespace.
#
#   scripts/netpol-install.sh [namespace]     # default: $HA_NS
#
# Order matters. The allow rules go on FIRST and default-deny LAST, so the
# namespace is never in a state where traffic is denied and nothing permits it
# again. Doing it the other way round on a live cluster causes a Patroni
# failover while you are still typing.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ns="${1:-$HA_NS}"
k get ns "$ns" >/dev/null 2>&1 || die "namespace ${ns} does not exist"

# --- verify the CNI actually enforces NetworkPolicy -------------------------
#
# The NetworkPolicy API exists on every cluster because it is part of core
# Kubernetes. Whether anything ENFORCES it is a property of the CNI, and several
# common ones do not. Creating policies against a CNI that ignores them is worse
# than creating none: you believe you are isolated and you are not.
if [[ "${SKIP_CNI_CHECK:-0}" != "1" ]]; then
  log "verifying the CNI enforces NetworkPolicy"
  probe_ns="netpol-preflight-$$"
  k create ns "$probe_ns" >/dev/null
  # shellcheck disable=SC2064
  trap "k delete ns '$probe_ns' --wait=false >/dev/null 2>&1 || true" RETURN

  k -n "$probe_ns" run probe --image=curlimages/curl:8.11.1 --restart=Never \
    --command -- sleep 300 >/dev/null
  k -n "$probe_ns" wait --for=condition=Ready pod/probe --timeout=180s >/dev/null

  cat <<YAML | k apply -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-all, namespace: ${probe_ns}}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
YAML
  sleep 8
  # `|| true` INSIDE the pod command, not outside. curl exits non-zero when the
  # connection is refused and also prints 000, so an outer `|| echo 000`
  # concatenates both into "000000" and the comparison silently never matches.
  code="$(k -n "$probe_ns" exec probe -- sh -c \
    'curl -s -o /dev/null -w "%{http_code}" -k --max-time 6 https://kubernetes.default.svc/healthz || true' 2>/dev/null)"
  code="$(tr -dc '0-9' <<< "$code" | tail -c 3)"

  if [[ "$code" == "000" ]]; then
    ok "NetworkPolicy is enforced by this CNI"
  else
    die "this CNI does NOT enforce NetworkPolicy (a deny-all pod still reached the API server, HTTP ${code}).
    Installing these policies would give you the appearance of isolation and none of it.
    Use a CNI that implements NetworkPolicy (Calico, Cilium), or run with SKIP_CNI_CHECK=1
    if you are deliberately staging manifests you will enforce elsewhere."
  fi
fi

# --- the API server, which Patroni needs as its DCS -------------------------
api_ip="$(k get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)"
api_port="$(k get endpoints kubernetes -n default -o jsonpath='{.subsets[0].ports[0].port}' 2>/dev/null)"
[[ -n "$api_ip" && -n "$api_port" ]] || die "could not determine the Kubernetes API endpoint"

# A /32 is the tightest correct answer for a single-endpoint API server. An HA
# control plane has several — widen deliberately rather than by accident.
api_cidr="${API_SERVER_CIDR:-${api_ip}/32}"

# The Service ClusterIP as well as the endpoint. In-cluster clients resolve
# kubernetes.default.svc to the ClusterIP, and whether a NetworkPolicy matches
# the pre- or post-DNAT address depends on the CNI. Allowing only the endpoint
# left the operator's backup Jobs timing out on 10.96.0.1:443 while PostgreSQL
# itself was unaffected — a partial outage that looks like a backup bug.
api_svc_ip="$(k get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')"
api_svc_port="$(k get svc kubernetes -n default -o jsonpath='{.spec.ports[0].port}')"
api_svc_cidr="${API_SERVICE_CIDR:-${api_svc_ip}/32}"

log "Kubernetes API (Patroni's DCS):"
dim "    endpoint  ${api_cidr}:${api_port}"
dim "    service   ${api_svc_cidr}:${api_svc_port}"

count="$(k get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[*].ip}' | wc -w | tr -d ' ')"
(( count > 1 )) && warn "the API server has ${count} endpoints; only the first is allowed. Set API_SERVER_CIDR to cover them all."

log "applying allow policies to ${ns}"
for f in "${REPO_ROOT}"/policy/netpol/[1-9]*.yaml; do
  sed -e "s#API_SERVER_CIDR#${api_cidr}#"      -e "s#API_SERVER_PORT#${api_port}#" \
      -e "s#API_SERVICE_CIDR#${api_svc_cidr}#" -e "s#API_SERVICE_PORT#${api_svc_port}#" "$f" \
    | k -n "$ns" apply -f -
done

log "applying default-deny LAST"
k -n "$ns" apply -f "${REPO_ROOT}/policy/netpol/00-default-deny.yaml"

ok "network policies applied to ${ns}"
k -n "$ns" get networkpolicy
dim ""
dim "    verify with:  scripts/run-tests.sh 96_network_policy.bats"
dim "    remove with:  scripts/netpol-uninstall.sh ${ns}"
