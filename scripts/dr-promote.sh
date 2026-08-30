#!/usr/bin/env bash
# Promote the DR standby into an independent, writable primary.
#
# THE IMPORTANT PART: promotion and repository detachment happen in ONE patch.
#
# The standby shares repo2-path with the source cluster — that is how it reads
# the backups. But every PostgreSQL instance runs with archive_mode=on, so the
# moment this cluster is promoted it forks onto a new timeline and starts
# archive-push-ing its own WAL into the SOURCE cluster's stanza.
#
# The result is a repository containing two divergent lineages. Nothing errors.
# `pgbackrest info` still says "status: ok". But the next standby you build from
# that repository restores the *promoted* cluster's timeline and then waits
# forever for WAL the real primary will never produce:
#
#     LOG:  waiting for WAL to become available at 0/1E000018
#
# while the operator cheerfully reports state=ready. We hit exactly this while
# building the lab; see docs/11-troubleshooting.md#poisoned-stanza
#
# So: repoint the repository in the same operation that promotes.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

k -n "$DR_NS" get pg "$DR_CLUSTER" >/dev/null 2>&1 || die "DR cluster not deployed — run 'make dr-up'"

enabled="$(k -n "$DR_NS" get pg "$DR_CLUSTER" -o jsonpath='{.spec.standby.enabled}')"
[[ "$enabled" == "true" ]] || die "${DR_CLUSTER} is not in standby mode (standby.enabled=${enabled})"

dr_pod() {
  k -n "$DR_NS" get pods -l postgres-operator.crunchydata.com/data=postgres \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

before_tl="$(psql_on_pod "$DR_NS" "$(dr_pod)" \
  "select timeline_id from pg_control_checkpoint();" | tr -d '[:space:]')"
log "standby timeline before promotion: ${before_tl}"

OWN_REPO_PATH="/pgbackrest/${DR_NS}/${DR_CLUSTER}/repo2"

log "promoting and detaching from the source repository in one patch"
dim "    standby.enabled : true -> false"
dim "    repo2-path      : $(k -n "$DR_NS" get pg "$DR_CLUSTER" -o jsonpath='{.spec.backups.pgbackrest.global.repo2-path}') -> ${OWN_REPO_PATH}"

k -n "$DR_NS" patch pg "$DR_CLUSTER" --type merge -p "$(cat <<JSON
{
  "spec": {
    "standby": {"enabled": false},
    "backups": {"pgbackrest": {"global": {"repo2-path": "${OWN_REPO_PATH}"}}}
  }
}
JSON
)"

log "waiting for the cluster to leave recovery"
deadline=$(( SECONDS + 600 )); r=""
while (( SECONDS < deadline )); do
  pod="$(dr_pod)"
  if [[ -n "$pod" ]]; then
    r="$(psql_on_pod "$DR_NS" "$pod" "select pg_is_in_recovery();" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$r" == "f" ]] && { ok "promoted after ${SECONDS}s"; break; }
  fi
  printf '\r%s    in_recovery=%-6s %3ds%s' "$C_DIM" "${r:-?}" "$SECONDS" "$C_OFF" >&2
  sleep 5
done
printf '\n' >&2
[[ "$r" == "f" ]] || die "still in recovery after 600s"

after_tl="$(psql_on_pod "$DR_NS" "$(dr_pod)" \
  "select timeline_id from pg_control_checkpoint();" | tr -d '[:space:]')"
log "timeline after promotion: ${after_tl} (was ${before_tl})"

log "verifying the promoted cluster accepts writes"
# Into `postgres`, not the cluster-named database: while this cluster was a
# standby it was read-only, so the operator had no opportunity to create its own
# database. That happens shortly after promotion, not at the instant of it.
psql_on_pod "$DR_NS" "$(dr_pod)" \
  "create table if not exists promoted_probe(at timestamptz default now());
   insert into promoted_probe default values;
   select count(*) from promoted_probe;"

ok "${DR_CLUSTER} is an independent primary, archiving to ${OWN_REPO_PATH}"
cat >&2 <<NEXT

  Next steps for a real promotion:
    1. Take a full backup — the new repository has no base backup yet:
         kubectl -n ${DR_NS} apply -f backup/backup-repo2.yaml   (edit pgCluster)
    2. Repoint applications at ${DR_CLUSTER}-pgbouncer.${DR_NS}.svc
    3. Scale it up — the DR profile runs a single instance, so it has no HA yet.
    4. The old cluster is NOT a standby of this one. Re-establishing replication
       in the other direction means rebuilding it from a fresh backup.

NEXT
