#!/usr/bin/env bats
# The operator itself: CRDs registered, controller healthy, cluster-wide scope.

load helpers/common

@test "all seven percona CRDs are established" {
  local expected=(
    perconapgbackups.pgv2.percona.com
    perconapgclusters.pgv2.percona.com
    perconapgrestores.pgv2.percona.com
    perconapgupgrades.pgv2.percona.com
    crunchybridgeclusters.upstream.pgv2.percona.com
    pgadmins.upstream.pgv2.percona.com
    postgresclusters.upstream.pgv2.percona.com
  )
  for crd in "${expected[@]}"; do
    run k get crd "$crd" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}'
    [ "$status" -eq 0 ]
    assert_equal "$output" "True" "CRD ${crd} not established"
  done
}

@test "operator deployment is available" {
  run k -n "$OPERATOR_NS" get deploy pg-operator -o jsonpath='{.status.readyReplicas}'
  [ "$status" -eq 0 ]
  assert_equal "$output" "1"
}

@test "operator runs the pinned image version" {
  run k -n "$OPERATOR_NS" get deploy pg-operator \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
  [ "$status" -eq 0 ]
  assert_contains "$output" "$OPERATOR_VERSION"
}

@test "operator is in cluster-wide mode" {
  # An empty WATCH_NAMESPACE means "watch everything", which is what lets one
  # operator manage pg-dev, pg-ha and pg-dr at once.
  run k -n "$OPERATOR_NS" get deploy pg-operator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="WATCH_NAMESPACE")].value}'
  [ "$status" -eq 0 ]
  assert_equal "$output" "" "WATCH_NAMESPACE should be empty for cluster-wide mode"

  run k get clusterrolebinding pg-operator
  [ "$status" -eq 0 ]
}

@test "operator log is free of reconciler errors" {
  # A stuck cluster usually shows up here long before it shows up in the CR
  # status — see docs/11-troubleshooting.md.
  run bash -c "k -n '$OPERATOR_NS' logs deploy/pg-operator --tail=500 2>/dev/null | grep -c 'Reconciler error' || true"
  [ "$status" -eq 0 ]
  assert_equal "${output//[^0-9]/}" "0" "operator log contains Reconciler errors"
}
