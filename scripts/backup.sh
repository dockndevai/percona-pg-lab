#!/usr/bin/env bash
# Take an on-demand backup and wait for it to finish.
#   scripts/backup.sh              # full backup to repo1
#   scripts/backup.sh repo2        # full backup to the S3 repo
#   scripts/backup.sh repo1 incr   # incremental
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

repo="${1:-repo1}"
type="${2:-full}"
name="manual-${repo}-${type}-$(k get --raw /api/v1 >/dev/null 2>&1 && date +%s)"

log "requesting a ${type} backup of ${HA_CLUSTER} to ${repo}"
cat <<YAML | k -n "$HA_NS" apply -f -
apiVersion: pgv2.percona.com/v2
kind: PerconaPGBackup
metadata:
  name: ${name}
spec:
  pgCluster: ${HA_CLUSTER}
  repoName: ${repo}
  options:
    - --type=${type}
YAML

log "waiting for backup ${name}"
deadline=$(( SECONDS + 900 )); state=""
while (( SECONDS < deadline )); do
  state="$(k -n "$HA_NS" get pg-backup "$name" -o jsonpath='{.status.state}' 2>/dev/null || true)"
  case "$state" in
    Succeeded) ok "backup ${name} succeeded"; break ;;
    Failed)    k -n "$HA_NS" get pg-backup "$name" -o yaml | tail -30 >&2
               die "backup ${name} failed" ;;
  esac
  printf '\r%s    state=%-12s %3ds%s' "$C_DIM" "${state:-<none>}" "$SECONDS" "$C_OFF" >&2
  sleep 5
done
printf '\n' >&2
[[ "$state" == "Succeeded" ]] || die "backup did not finish in time (state=${state:-<none>})"

log "pgbackrest info for ${repo}"
k -n "$HA_NS" exec "statefulset/${HA_CLUSTER}-repo-host" -c pgbackrest -- \
  pgbackrest --stanza=db --repo="${repo#repo}" info
