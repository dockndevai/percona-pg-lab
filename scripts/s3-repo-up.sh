#!/usr/bin/env bash
# Attach the MinIO-backed pgBackRest repository (repo2) to the HA cluster.
# This is what makes cross-cluster DR possible; see docs/06-backup-restore-pitr.md
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

k get ns "$MINIO_NS" >/dev/null 2>&1 || die "MinIO is not deployed — run 'make minio-up' first"
k -n "$HA_NS" get pg "$HA_CLUSTER" >/dev/null 2>&1 || die "HA cluster not deployed — run 'make ha-up' first"

log "creating the pgBackRest S3 credential secret"
# pgBackRest reads *.conf files projected into its config directory. The keys
# are repo-scoped, so repo2-s3-key here matches `- name: repo2` in the CR.
k -n "$HA_NS" create secret generic pgbackrest-s3-creds \
  --from-literal=s3.conf="$(cat <<CONF
[global]
repo2-s3-key=pglabaccess
repo2-s3-key-secret=pglabsecretkey123
CONF
)" --dry-run=client -o yaml | k apply -f -

log "patching ${HA_CLUSTER} to add repo2"
k -n "$HA_NS" patch pg "$HA_CLUSTER" --type merge \
  --patch-file "${REPO_ROOT}/backup/s3-repo-patch.yaml"

log "waiting for the repo2 stanza to be created"
# The operator creates the stanza on the repo host; until it exists, backups to
# repo2 fail with "unable to load info file".
deadline=$(( SECONDS + 420 ))
while (( SECONDS < deadline )); do
  if k -n "$HA_NS" exec statefulset/"${HA_CLUSTER}-repo-host" -c pgbackrest -- \
       pgbackrest --stanza=db --repo=2 info >/dev/null 2>&1; then
    ok "repo2 stanza is live"
    k -n "$HA_NS" exec statefulset/"${HA_CLUSTER}-repo-host" -c pgbackrest -- \
      pgbackrest --stanza=db --repo=2 info || true
    exit 0
  fi
  sleep 10
done
warn "repo2 stanza did not come up in time — check:"
dim "    kubectl -n ${HA_NS} logs sts/${HA_CLUSTER}-repo-host -c pgbackrest"
exit 1
