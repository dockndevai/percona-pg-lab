#!/usr/bin/env bash
# Enable extensions on the HA cluster and create them in the application database.
#
# Two distinct steps, and conflating them is the usual source of confusion:
#   1. make the extension AVAILABLE (operator: image + shared_preload_libraries)
#   2. CREATE EXTENSION inside each database that wants it
# The operator does (1). Only you can do (2), per database.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

k -n "$HA_NS" get pg "$HA_CLUSTER" >/dev/null 2>&1 || die "run 'make ha-up' first"

log "enabling builtin extensions"
k -n "$HA_NS" patch pg "$HA_CLUSTER" --type merge \
  --patch-file "${REPO_ROOT}/extensions/extensions-patch.yaml"

log "waiting for the rolling restart (shared_preload_libraries needs one)"
# Give the operator a moment to notice before polling for ready, or we observe
# the *pre-change* ready state and continue too early.
sleep 20
wait_cluster_ready "$HA_NS" "$HA_CLUSTER" 900

leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"

# `SHOW shared_preload_libraries` returns the RUNNING value, which stays stale
# until PostgreSQL actually restarts. Checking it too early shows the old list
# and makes it look as though the operator ignored you — we chased that for a
# while. Wait for pending_restart to clear before believing anything.
log "waiting for shared_preload_libraries to be applied (not just staged)"
deadline=$(( SECONDS + 600 ))
while (( SECONDS < deadline )); do
  pending="$(psql_on_pod "$HA_NS" "$leader" \
    "select pending_restart from pg_settings where name='shared_preload_libraries';" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$pending" == "f" ]] && break
  leader="$(current_leader "$HA_NS" "$HA_CLUSTER")"
  sleep 10
done
log "effective shared_preload_libraries"
psql_on_pod "$HA_NS" "$leader" "show shared_preload_libraries;"

log "creating extensions in the ${HA_CLUSTER} database"
# Only the extensions the profile actually enables. The operator can preload
# exactly one library, so asking for pg_stat_monitor and pgaudit here as well
# just produces confusing failures — see extensions/extensions-patch.yaml.
for ext in pg_stat_statements vector; do
  if psql_on_pod "$HA_NS" "$leader" \
       "create extension if not exists \"${ext}\";" "$HA_CLUSTER" >/dev/null 2>&1; then
    ok "created ${ext}"
  else
    warn "could not create ${ext} — see 'select * from pg_available_extensions'"
  fi
done

log "installed extensions in ${HA_CLUSTER}"
psql_on_pod "$HA_NS" "$leader" \
  "select extname, extversion from pg_extension order by extname;" "$HA_CLUSTER"
