#!/usr/bin/env bash
# Wipe and rebuild the shared pgBackRest repository used for DR.
#
# You need this when the repository has been poisoned with a divergent timeline
# — typically because a standby was promoted while still pointed at the source
# cluster's repo2-path. Symptom: a freshly built standby restores, reports
# ready, and then never advances its replay LSN.
#
# Destructive: every backup in repo2 is deleted and a new full backup is taken.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

k get ns "$MINIO_NS" >/dev/null 2>&1 || die "MinIO is not deployed"

warn "this deletes EVERY backup in the repo2 bucket"
if [[ "${FORCE:-0}" != "1" ]]; then
  read -r -p "  type 'yes' to continue: " reply
  [[ "$reply" == "yes" ]] || die "aborted"
fi

log "emptying the pgbackrest bucket"
# shellcheck disable=SC2016  # $MINIO_ROOT_* must expand inside the pod, not here
k -n "$MINIO_NS" exec deploy/minio -- sh -c '
  mc --insecure alias set local https://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null &&
  mc --insecure rb --force local/pgbackrest >/dev/null 2>&1;
  mc --insecure mb --ignore-existing local/pgbackrest >/dev/null &&
  echo "bucket recreated"'

log "removing failed backup objects from the wiped repo"
# A PerconaPGBackup that failed against the old repository keeps its Job
# retrying forever, filling the namespace with Error pods long after the
# underlying problem is fixed. The operator does not garbage-collect them.
for b in $(k -n "$HA_NS" get pg-backup -o json 2>/dev/null \
           | python3 -c "
import json,sys
for i in json.load(sys.stdin).get('items', []):
    if i.get('status', {}).get('state') == 'Failed':
        print(i['metadata']['name'])" 2>/dev/null); do
  dim "    deleting failed backup ${b}"
  k -n "$HA_NS" delete pg-backup "$b" --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
done
k -n "$HA_NS" delete pods --field-selector=status.phase==Failed >/dev/null 2>&1 || true

log "re-creating the pgBackRest stanza"
# Restarting the repo host is NOT enough — the operator only runs stanza-create
# when it thinks the stanza is missing at cluster-creation time, so after an
# out-of-band wipe you have to do it yourself. Without this the next backup
# fails with:
#   ERROR: [055]: unable to load info file '.../backup.info'
#   HINT: has a stanza-create been performed?
# Note stanza-create operates on every configured repo and rejects --repo=N.
k -n "$HA_NS" exec "statefulset/${HA_CLUSTER}-repo-host" -c pgbackrest -- \
  pgbackrest --stanza=db stanza-create
ok "stanza created"

log "taking a fresh full backup from the true primary"
"${REPO_ROOT}/scripts/backup.sh" repo2 full

ok "repo2 rebuilt from ${HA_NS}/${HA_CLUSTER}"
