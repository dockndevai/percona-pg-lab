#!/usr/bin/env bash
# One screen showing everything the lab currently has running.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

hr() { printf '%s%s%s\n' "$C_DIM" "$(printf '─%.0s' {1..76})" "$C_OFF"; }

printf '\n%sOPERATOR%s\n' "$C_BLU" "$C_OFF"; hr
k -n "$OPERATOR_NS" get deploy pg-operator -o custom-columns=\
NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:'.spec.template.spec.containers[0].image' 2>/dev/null \
  || echo "  not installed"

for entry in "dev-standalone ${DEV_NS} ${DEV_CLUSTER}" "ha ${HA_NS} ${HA_CLUSTER}" "dr-standby ${DR_NS} ${DR_CLUSTER}"; do
  read -r profile ns cluster <<< "$entry"
  k get ns "$ns" >/dev/null 2>&1 || continue
  k -n "$ns" get pg "$cluster" >/dev/null 2>&1 || continue

  state="$(k -n "$ns" get pg "$cluster" -o jsonpath='{.status.state}')"
  pgready="$(k -n "$ns" get pg "$cluster" -o jsonpath='{.status.postgres.ready}/{.status.postgres.size}')"
  pgbready="$(k -n "$ns" get pg "$cluster" -o jsonpath='{.status.pgbouncer.ready}/{.status.pgbouncer.size}')"

  printf '\n%s%s%s  (ns=%s)  state=%s  postgres=%s  pgbouncer=%s\n' \
    "$C_BLU" "$profile" "$C_OFF" "$ns" "$state" "$pgready" "$pgbready"
  hr
  k -n "$ns" get pods -o custom-columns=\
NAME:.metadata.name,READY:'.status.containerStatuses[*].ready',STATUS:.status.phase,NODE:.spec.nodeName,\
ROLE:'.metadata.labels.postgres-operator\.crunchydata\.com/role' --no-headers 2>/dev/null | sed 's/^/  /'
done

printf '\n%sMONITORING%s\n' "$C_BLU" "$C_OFF"; hr
if k get ns "$MONITORING_NS" >/dev/null 2>&1; then
  k -n "$MONITORING_NS" get pods --no-headers 2>/dev/null | awk '{printf "  %-52s %s\n", $1, $3}'
else
  echo "  not installed  (make obs-up)"
fi

printf '\n%sNODE PRESSURE%s\n' "$C_BLU" "$C_OFF"; hr
k top nodes 2>/dev/null | sed 's/^/  /' || echo "  metrics-server not installed"
echo
