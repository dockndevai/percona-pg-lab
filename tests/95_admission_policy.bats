#!/usr/bin/env bats
# ValidatingAdmissionPolicy: every rule must reject what it claims to, and
# nothing else.
#
# Both halves matter. A policy that denies everything passes a naive "did it
# reject?" test while making the cluster unusable — so each suite starts by
# asserting a valid manifest is still ACCEPTED.
#
# All checks are server dry-run: admission runs, nothing is persisted.

load helpers/common

POLICY_NS_DEV="policy-test-dev"
POLICY_NS_PROD="policy-test-prod"

setup_file() {
  k get validatingadmissionpolicy percona-pg-baseline >/dev/null 2>&1 \
    || skip "admission policies not installed — run 'make policy-install'"

  # Two namespaces: one plain, one labelled as production. The prod policy binds
  # by LABEL, so this is also a test that the binding selector works.
  k get ns "$POLICY_NS_DEV"  >/dev/null 2>&1 || k create ns "$POLICY_NS_DEV"  >/dev/null
  k get ns "$POLICY_NS_PROD" >/dev/null 2>&1 || k create ns "$POLICY_NS_PROD" >/dev/null
  k label ns "$POLICY_NS_PROD" percona-pg-lab.io/environment=prod --overwrite >/dev/null
  k label ns "$POLICY_NS_DEV"  percona-pg-lab.io/environment-  >/dev/null 2>&1 || true
}

teardown_file() {
  k delete ns "$POLICY_NS_DEV" "$POLICY_NS_PROD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# admit <namespace> <fixture> — server dry-run; succeeds only if admitted.
admit() {
  k -n "$1" apply --dry-run=server -f "${REPO_ROOT}/policy/testdata/$2" 2>&1
}

assert_denied() {
  local ns="$1" fixture="$2" needle="$3" out
  out="$(admit "$ns" "$fixture")" || true
  if [[ "$out" != *"denied request"* ]]; then
    echo "expected ${fixture} to be DENIED in ${ns}, but it was admitted" >&2
    echo "  output: ${out}" >&2
    return 1
  fi
  if [[ -n "$needle" && "$out" != *"$needle"* ]]; then
    echo "${fixture} was denied, but not for the expected reason" >&2
    echo "  wanted message containing: ${needle}" >&2
    echo "  got: ${out}" >&2
    return 1
  fi
}

assert_admitted() {
  local ns="$1" fixture="$2" out
  out="$(admit "$ns" "$fixture")" || true
  if [[ "$out" == *"denied request"* ]]; then
    echo "FALSE POSITIVE: ${fixture} should be admitted in ${ns}" >&2
    echo "  ${out}" >&2
    return 1
  fi
}

# ------------------------------------------------------------------ baseline

@test "policies are installed and compiled without type errors" {
  # A CEL type-check warning means the expression may silently no-op at runtime.
  # Worth failing on: a policy that does nothing is worse than no policy,
  # because you believe you are protected.
  for p in percona-pg-baseline percona-pg-production; do
    run k get validatingadmissionpolicy "$p" \
      -o jsonpath='{.status.typeChecking.expressionWarnings[*].fieldRef}'
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "type-check warnings on ${p}: ${output}" >&2; return 1; }
  done
}

@test "a valid cluster is admitted" {
  assert_admitted "$POLICY_NS_DEV" valid-dev.yaml
}

@test "rejects a topologySpreadConstraint that duplicates the operator's" {
  assert_denied "$POLICY_NS_DEV" bad-topology-spread.yaml "topologySpreadConstraints duplicates"
}

@test "rejects a backup repo with no retention policy" {
  assert_denied "$POLICY_NS_DEV" bad-no-retention.yaml "retention policy"
}

@test "rejects admin_users without auth_dbname" {
  assert_denied "$POLICY_NS_DEV" bad-admin-no-authdb.yaml "auth_dbname"
}

@test "rejects the reserved 'monitor' username" {
  assert_denied "$POLICY_NS_DEV" bad-monitor-user.yaml "reserved username"
}

@test "rejects two extensions that both need preloading" {
  assert_denied "$POLICY_NS_DEV" bad-two-preloads.yaml "preloads"
}

@test "rejects a hand-set shared_preload_libraries" {
  assert_denied "$POLICY_NS_DEV" bad-manual-preload.yaml "shared_preload_libraries"
}

# ------------------------------------------------------------------ sidecars
#
# Sidecars are arbitrary containers embedded in the CR, so "who can edit a
# PerconaPGCluster" is effectively "who can run a pod next to the database".
# Pod Security Standards would catch most of this at POD admission — these rules
# catch it on the CR, so the error reaches whoever ran kubectl apply.

@test "a correctly hardened sidecar is admitted" {
  assert_admitted "$POLICY_NS_DEV" valid-sidecar.yaml
}

@test "rejects a privileged sidecar" {
  assert_denied "$POLICY_NS_DEV" bad-sidecar-privileged.yaml "privileged sidecar"
}

@test "rejects a sidecar with no securityContext" {
  assert_denied "$POLICY_NS_DEV" bad-sidecar-no-seccontext.yaml "every sidecar needs securityContext"
}

@test "rejects a sidecar that allows privilege escalation" {
  assert_denied "$POLICY_NS_DEV" bad-sidecar-privesc.yaml "allowPrivilegeEscalation: false"
}

@test "rejects runAsNonRoot without a numeric runAsUser" {
  # Not a theoretical rule: both Prometheus exporter images declare USER by
  # name, and the kubelet refuses to start such a container when it cannot
  # verify the name is non-root.
  assert_denied "$POLICY_NS_DEV" bad-sidecar-nonnumeric-user.yaml "numeric runAsUser"
}

@test "rejects hostPath in sidecarVolumes" {
  assert_denied "$POLICY_NS_DEV" bad-sidecar-hostpath.yaml "hostPath"
}

# ---------------------------------------------------------------- production

@test "a valid production cluster is admitted in a prod namespace" {
  assert_admitted "$POLICY_NS_PROD" valid-prod.yaml
}

@test "production rules do NOT apply to an unlabelled namespace" {
  # The binding selects on the namespace label. If this fails, the selector is
  # wrong and every environment just inherited production's constraints.
  assert_admitted "$POLICY_NS_DEV" prod-one-instance.yaml
}

@test "production rejects fewer than three instances" {
  assert_denied "$POLICY_NS_PROD" prod-one-instance.yaml "at least 3 PostgreSQL instances"
}

@test "production rejects a cluster without synchronous_mode" {
  assert_denied "$POLICY_NS_PROD" prod-no-sync.yaml "synchronous_mode"
}

@test "production rejects synchronous_commit=off" {
  assert_denied "$POLICY_NS_PROD" prod-sync-commit-off.yaml "synchronous_commit=off"
}

@test "production rejects a PVC-only backup configuration" {
  assert_denied "$POLICY_NS_PROD" prod-no-offcluster-repo.yaml "off-cluster backup repository"
}

@test "production rejects instances without resource limits" {
  assert_denied "$POLICY_NS_PROD" prod-no-limits.yaml "resources.limits"
}

@test "production rejects preferred-only anti-affinity" {
  assert_denied "$POLICY_NS_PROD" prod-preferred-affinity.yaml "requiredDuringScheduling"
}

@test "production rejects spec.pause" {
  assert_denied "$POLICY_NS_PROD" prod-paused.yaml "scales every workload"
}
