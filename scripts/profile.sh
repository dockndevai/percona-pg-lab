#!/usr/bin/env bash
# Bring a cluster profile up or down.
#   scripts/profile.sh up   <dir> <namespace> <cluster>
#   scripts/profile.sh down <dir> <namespace> <cluster>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

action="${1:?usage: profile.sh <up|down> <dir> <namespace> <cluster>}"
dir="${2:?}"; ns="${3:?}"; cluster="${4:?}"
overlay="${REPO_ROOT}/clusters/${dir}"

case "$action" in
  up)
    k get ns "$ns" >/dev/null 2>&1 || k create ns "$ns"
    log "applying profile '${dir}' to ${ns}"
    k apply -k "$overlay"
    wait_cluster_ready "$ns" "$cluster" "${READY_TIMEOUT:-900}"
    k -n "$ns" get pods -o wide
    echo
    dim "    connect with:  scripts/connect.sh ${dir%%-*}"
    ;;
  down)
    log "removing profile '${dir}' from ${ns}"
    k delete -k "$overlay" --ignore-not-found --wait --timeout=5m || true
    # The operator does not garbage-collect PVCs — that is deliberate, so an
    # accidental `delete` doesn't destroy your data. In a lab we do want them gone.
    k -n "$ns" delete pvc --all --ignore-not-found >/dev/null 2>&1 || true
    ok "profile '${dir}' removed (PVCs deleted too)"
    ;;
  *) die "unknown action: $action" ;;
esac
