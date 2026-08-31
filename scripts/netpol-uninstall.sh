#!/usr/bin/env bash
# Remove network policies. Deletes default-deny FIRST so the namespace is never
# left denying traffic with nothing to permit it.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ns="${1:-$HA_NS}"
log "removing network policies from ${ns}"
k -n "$ns" delete networkpolicy default-deny --ignore-not-found
k -n "$ns" delete -f "${REPO_ROOT}/policy/netpol/10-shared.yaml"    --ignore-not-found 2>/dev/null || true
for name in postgres-instances pgbouncer pgbackrest-repo-host cluster-jobs-and-clients allow-dns; do
  k -n "$ns" delete networkpolicy "$name" --ignore-not-found
done
ok "network policies removed from ${ns}"
