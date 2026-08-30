#!/usr/bin/env bash
# Install the ValidatingAdmissionPolicies and label the environment namespaces.
#
# These are cluster-scoped and take effect immediately for every namespace that
# matches a binding. Read policy/*.yaml before running this against a cluster
# that already has PerconaPGClusters in it — see the dry-run below.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ValidatingAdmissionPolicy is GA in admissionregistration.k8s.io/v1 from
# Kubernetes 1.30. On anything older these resources do not exist.
k api-resources --api-group=admissionregistration.k8s.io 2>/dev/null \
  | grep -q validatingadmissionpolicies \
  || die "this cluster has no ValidatingAdmissionPolicy support (needs Kubernetes 1.30+)"

if [[ "${1:-}" == "--check" ]]; then
  log "checking existing clusters against the policies WITHOUT installing them"
  warn "this only reports; nothing is changed"
  fail=0
  while read -r ns name; do
    [[ -z "$ns" ]] && continue
    out="$(k -n "$ns" get pg "$name" -o yaml 2>/dev/null | k apply --dry-run=server -f - 2>&1 || true)"
    if grep -q "denied request" <<<"$out"; then
      echo "  ✗ ${ns}/${name}" >&2
      grep -oE "denied request:.*" <<<"$out" | fold -w 100 -s | sed 's/^/      /' >&2
      fail=1
    else
      ok "${ns}/${name}"
    fi
  done < <(k get pg -A --no-headers 2>/dev/null | awk '{print $1, $2}')
  (( fail == 0 )) || die "existing clusters would be rejected — fix them before installing"
  ok "every existing cluster satisfies the policies"
  exit 0
fi

log "installing admission policies"
k apply -f "${REPO_ROOT}/policy/vap-baseline.yaml"
k apply -f "${REPO_ROOT}/policy/vap-production.yaml"

# The production binding selects on this label, so a namespace only inherits
# production's constraints when it is explicitly marked as production.
log "labelling environment namespaces"
for pair in "app-dev:dev" "app-staging:staging" "app-prod:prod"; do
  ns="${pair%%:*}"; env="${pair##*:}"
  if k get ns "$ns" >/dev/null 2>&1; then
    k label ns "$ns" "percona-pg-lab.io/environment=${env}" --overwrite >/dev/null
    dim "    ${ns} → ${env}"
  fi
done

# The type checker is the only warning you get that an expression may silently
# do nothing at runtime. Treat a warning as a failure.
log "verifying the policies compiled"
sleep 5
for p in percona-pg-baseline percona-pg-production; do
  warnings="$(k get validatingadmissionpolicy "$p" \
    -o jsonpath='{.status.typeChecking.expressionWarnings[*].fieldRef}' 2>/dev/null || true)"
  if [[ -n "$warnings" ]]; then
    warn "${p} has CEL type-check warnings on: ${warnings}"
    warn "an expression that fails type-checking may evaluate to nothing at runtime"
  else
    ok "${p} compiled cleanly"
  fi
done

ok "admission policies active"
dim "    verify with:  scripts/run-tests.sh 95_admission_policy.bats"
dim "    remove with:  make policy-uninstall"
