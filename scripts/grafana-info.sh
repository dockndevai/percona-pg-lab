#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

k get ns "$MONITORING_NS" >/dev/null 2>&1 || die "monitoring stack not installed — run 'make obs-up'"

pw="$(k -n "$MONITORING_NS" get secret kps-grafana \
      -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || echo pglab)"

cat >&2 <<INFO

  Grafana      http://localhost:30300     admin / ${pw}
  Prometheus   http://localhost:30900
  MinIO        https://localhost:30901    pglabaccess / pglabsecretkey123

  Those ports are mapped from the kind control-plane node by kind/pg-lab.yaml.
  Start with the "Percona PostgreSQL — Cluster Health" dashboard.

INFO
