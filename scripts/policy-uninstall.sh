#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
log "removing admission policies"
k delete -f "${REPO_ROOT}/policy/vap-production.yaml" --ignore-not-found
k delete -f "${REPO_ROOT}/policy/vap-baseline.yaml"   --ignore-not-found
ok "admission policies removed"
