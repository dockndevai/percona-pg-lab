#!/usr/bin/env bash
# Static checks: shell linting, YAML parsing, and Kubernetes manifest validation.
# Same checks CI runs, so you can find problems before pushing.
#
# Note: no comment line in this file may begin with the linter's own name — it
# would be parsed as a malformed directive (SC1073) and fail the run.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail=0

log "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # SC1091: we source lib.sh by a path shellcheck cannot follow at lint time.
  if shellcheck -x -e SC1091 "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/perf/*.sh; then
    ok "shellcheck clean"
  else
    fail=1
  fi
else
  warn "shellcheck not installed — skipping (brew install shellcheck)"
fi

log "yaml parse"
if python3 -c 'import yaml' 2>/dev/null; then
  bad=0
  while IFS= read -r f; do
    python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" "$f" 2>/dev/null \
      || { echo "  invalid YAML: ${f#"$REPO_ROOT"/}" >&2; bad=1; }
  done < <(find "$REPO_ROOT" -name '*.yaml' -not -path '*/.git/*')
  if (( bad )); then fail=1; else ok "all YAML parses"; fi
else
  warn "pyyaml not installed — skipping (pip install pyyaml)"
fi

log "kustomize build"
for d in "${REPO_ROOT}"/clusters/*/; do
  [[ -f "${d}kustomization.yaml" ]] || continue
  if kubectl kustomize "$d" >/dev/null 2>&1; then
    ok "$(basename "$d") builds"
  else
    echo "  kustomize build failed: $(basename "$d")" >&2; fail=1
  fi
done

log "manifest schema validation"
if command -v kubeconform >/dev/null 2>&1; then
  # Only complete manifests. Deliberately excluded:
  #   *-patch.yaml            strategic-merge fragments, no apiVersion/kind
  #   */values.yaml           Helm values, not Kubernetes objects
  #   dashboards/*.json       Grafana dashboards
  # -ignore-missing-schemas lets custom resources (PerconaPGCluster, PodMonitor,
  # PrometheusRule) through while still checking every core type strictly.
  manifests=(
    "${REPO_ROOT}/backup/minio.yaml"
    "${REPO_ROOT}/backup/backup-repo2.yaml"
    "${REPO_ROOT}/observability/kube-prometheus-stack/servicemonitors.yaml"
    "${REPO_ROOT}/observability/kube-prometheus-stack/prometheus-rules.yaml"
    "${REPO_ROOT}/clusters/upgrade-demo/upgrade.yaml"
  )
  # NetworkPolicies are core types, so kubeconform validates them strictly.
  # The API_SERVER_* placeholders are substituted at install time, so lint a
  # rendered copy rather than the template.
  tmpnp="$(mktemp -d)"
  for f in "${REPO_ROOT}"/policy/netpol/*.yaml; do
    sed -e 's#API_SERVER_CIDR#10.0.0.1/32#'  -e 's#API_SERVER_PORT#6443#' \
        -e 's#API_SERVICE_CIDR#10.96.0.1/32#' -e 's#API_SERVICE_PORT#443#' \
        "$f" > "${tmpnp}/$(basename "$f")"
  done
  manifests+=("${tmpnp}"/*.yaml)
  if kubeconform -strict -ignore-missing-schemas -summary "${manifests[@]}"; then
    ok "kubeconform clean"
  else
    fail=1
  fi

  rm -rf "${tmpnp:-/nonexistent}"

  # Rendered kustomize output is a complete manifest set, so validate that too.
  for d in "${REPO_ROOT}"/clusters/*/; do
    [[ -f "${d}kustomization.yaml" ]] || continue
    kubectl kustomize "$d" 2>/dev/null \
      | kubeconform -strict -ignore-missing-schemas -summary - \
      || { echo "  kubeconform failed for $(basename "$d")" >&2; fail=1; }
  done
else
  warn "kubeconform not installed — skipping (brew install kubeconform)"
fi

log "environment overlays"
"${REPO_ROOT}/scripts/env-render.sh" >/dev/null 2>&1 && ok "all environments render and pass policy" || fail=1

log "bats syntax"
if command -v bats >/dev/null 2>&1; then
  bats --count "${REPO_ROOT}"/tests/*.bats >/dev/null && ok "all bats files parse" || fail=1
else
  warn "bats not installed — skipping"
fi

(( fail == 0 )) || die "lint failed"
ok "lint passed"
