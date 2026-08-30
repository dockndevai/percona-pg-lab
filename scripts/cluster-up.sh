#!/usr/bin/env bash
# Create the kind cluster if it isn't already there, then pre-pull the large
# database images onto every node so that the first `make ha-up` isn't ten
# minutes of docker pull.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  ok "kind cluster '${KIND_CLUSTER}' already exists"
else
  log "creating kind cluster '${KIND_CLUSTER}' (1 control-plane + 3 workers)"
  kind create cluster --config "${REPO_ROOT}/kind/pg-lab.yaml" --wait 180s
fi

k get nodes -L topology.kubernetes.io/zone

# Pulling once on the host and side-loading beats pulling four times inside kind.
if [[ "${SKIP_PRELOAD:-0}" != "1" ]]; then
  log "pre-pulling database images (first run takes a few minutes)"
  for img in "$PG_IMAGE" "$PGBOUNCER_IMAGE" "$PGBACKREST_IMAGE"; do
    if docker image inspect "$img" >/dev/null 2>&1; then
      dim "    cached: $img"
    else
      dim "    pulling: $img"
      docker pull -q "$img" >/dev/null
    fi
    kind load docker-image --name "$KIND_CLUSTER" "$img" >/dev/null 2>&1 || \
      warn "could not side-load $img — nodes will pull it themselves"
  done
  ok "images staged on all nodes"
fi
