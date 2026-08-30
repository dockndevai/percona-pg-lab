#!/usr/bin/env bash
# Install the Percona Operator for PostgreSQL in cluster-wide mode.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "installing percona pg-operator ${OPERATOR_VERSION} into ${OPERATOR_NS}"

helm repo add percona https://percona.github.io/percona-helm-charts/ >/dev/null 2>&1 || true
helm repo update percona >/dev/null

helm --kube-context "$KUBE_CONTEXT" upgrade --install pg-operator percona/pg-operator \
  --version "$OPERATOR_VERSION" \
  --namespace "$OPERATOR_NS" --create-namespace \
  --values "${REPO_ROOT}/operator/values.yaml" \
  --wait --timeout 10m

k -n "$OPERATOR_NS" rollout status deploy/pg-operator --timeout=5m
ok "operator ready"
dim "    CRDs: $(k get crd -o name | grep -c pgv2.percona.com) installed"
