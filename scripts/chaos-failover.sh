#!/usr/bin/env bash
# Kill the current Patroni leader and measure how long the cluster takes to
# accept writes again *through pgBouncer* — which is the number your
# application actually experiences.
#
#   scripts/chaos-failover.sh            # delete the leader pod
#   scripts/chaos-failover.sh --switchover  # graceful, operator-driven handover
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ns="$HA_NS"; cluster="$HA_CLUSTER"
mode="${1:-crash}"

leader="$(current_leader "$ns" "$cluster")"
[[ -n "$leader" ]] || die "no primary found in ${ns}/${cluster} — is the cluster ready?"
log "current primary: ${leader}"

if [[ "$mode" == "--switchover" ]]; then
  # Via patronictl, NOT spec.patroni.switchover.
  #
  # The CR field exists and is accepted, but on operator v3.0.0 setting
  # `switchover: {enabled: true}` — with or without targetInstance — produced no
  # switchover and no operator log entry at all, over five minutes. patronictl
  # is the path that actually works.
  #
  # And the candidate is not free: with synchronous_mode on, Patroni refuses to
  # promote anything other than the current synchronous standby:
  #     Switchover failed, details: 412, candidate name does not match with sync_standby
  # which is correct — the async replica may be behind, and switching to it
  # would be a data-loss event dressed up as a planned operation.
  # See docs/09-lifecycle-operations.md#switchover-vs-failover
  sync_standby="$(psql_on_pod "$ns" "$leader" \
    "select application_name from pg_stat_replication where sync_state='sync' limit 1;" \
    | tr -d '[:space:]')"
  [[ -n "$sync_standby" ]] || die "no synchronous standby to switch over to"
  log "requesting a graceful switchover to ${sync_standby}"
  k -n "$ns" exec "$leader" -c database -- \
    patronictl -c /etc/patroni/~postgres-operator_cluster.yaml switchover "${cluster}-ha" \
    --leader "$leader" --candidate "$sync_standby" --force
else
  log "deleting the primary pod (simulating a node/pod loss)"
  k -n "$ns" delete pod "$leader" --now >/dev/null
fi

start=$SECONDS
new=""
while (( SECONDS - start < 180 )); do
  new="$(current_leader "$ns" "$cluster")"
  if [[ -n "$new" && "$new" != "$leader" ]]; then
    ok "new primary elected after $((SECONDS - start))s: ${new}"
    break
  fi
  printf '\r%s    waiting for election… %ds%s' "$C_DIM" "$((SECONDS - start))" "$C_OFF" >&2
  sleep 1
done
printf '\n' >&2
[[ -n "$new" && "$new" != "$leader" ]] || die "no new primary after 180s"

# The election is only half the story. What matters is when pgBouncer starts
# routing writes to the new primary again.
log "probing writes through pgBouncer until they succeed"
pw="$(pguser_field "$ns" "$cluster" password)"
host="$(pguser_field "$ns" "$cluster" pgbouncer-host)"
wstart=$SECONDS
until k -n "$ns" run "probe-$RANDOM" --rm -i --restart=Never --quiet --image="$PG_IMAGE" \
        --env="PGPASSWORD=${pw}" --env="PGSSLMODE=require" --command -- \
        psql -h "$host" -U "$cluster" -d "$cluster" -tAc \
        "create table if not exists failover_probe(t timestamptz); insert into failover_probe values (now());" \
        >/dev/null 2>&1; do
  (( SECONDS - wstart > 180 )) && die "writes did not recover within 180s"
  sleep 2
done
ok "writes recovered $((SECONDS - wstart))s after the election"
dim "    total client-visible outage ≈ $((SECONDS - start))s"

k -n "$ns" get pods -L postgres-operator.crunchydata.com/role
