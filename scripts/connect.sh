#!/usr/bin/env bash
# Open a psql session against a lab cluster.
#
#   scripts/connect.sh ha                 # through pgBouncer (the normal path)
#   scripts/connect.sh ha --direct        # straight to the primary, bypassing the pool
#   scripts/connect.sh ha --admin         # the pgBouncer admin console
#   scripts/connect.sh ha -c 'select 1'   # non-interactive
#
# It runs psql inside the cluster from an ephemeral pod, so you do not need a
# port-forward and you measure realistic in-cluster latency.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

profile="${1:?usage: connect.sh <dev|ha|dr> [--direct|--admin] [psql args...]}"; shift || true

case "$profile" in
  dev) ns="$DEV_NS"; cluster="$DEV_CLUSTER" ;;
  ha)  ns="$HA_NS";  cluster="$HA_CLUSTER"  ;;
  dr)  ns="$DR_NS";  cluster="$DR_CLUSTER"  ;;
  *)   die "unknown profile '${profile}' (expected dev, ha or dr)" ;;
esac

mode="pooled"
case "${1:-}" in
  --direct) mode="direct"; shift ;;
  --admin)  mode="admin";  shift ;;
esac

pw="$(pguser_field "$ns" "$cluster" password)"
case "$mode" in
  pooled) host="$(pguser_field "$ns" "$cluster" pgbouncer-host)"; db="$cluster" ;;
  direct) host="$(pguser_field "$ns" "$cluster" host)";           db="$cluster" ;;
  admin)  host="$(pguser_field "$ns" "$cluster" pgbouncer-host)"; db=pgbouncer ;;
esac

dim "    ${mode} -> ${host}/${db}"

# sslmode=require: the operator forces client_tls_sslmode=require on pgBouncer,
# so a default 'prefer' negotiation against the admin console fails confusingly.
# --tty only when we actually have one: in a script or CI there is no terminal,
# and psql behaves differently (and worse) when told there is.
tty_flag=()
[[ -t 0 && -t 1 ]] && tty_flag=(--tty)

# --overrides is a strategic-merge patch over the pod kubectl generates, so we
# only need to state what differs: the securityContext. Command, env and args
# are left to the normal --command/--env flags rather than restated as JSON,
# which was both unreadable and easy to get subtly wrong.
#
# Without this, a namespace enforcing the `restricted` Pod Security Standard
# refuses the pod outright.
pod="psql-$RANDOM"
overrides="$(cat <<JSON
{"spec":{
  "securityContext":{"runAsNonRoot":true,"runAsUser":26,"seccompProfile":{"type":"RuntimeDefault"}},
  "containers":[{"name":"${pod}",
    "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}
JSON
)"

# --override-type=strategic, NOT kubectl's default.
#
# --overrides defaults to a JSON MERGE patch, which replaces the containers list
# wholesale: the generated command and env are silently discarded and the
# container starts as a bare PostgreSQL image, failing with "Database is
# uninitialized". It is the same list-replacement trap as a strategic-merge
# patch on a CR — it recurs. `strategic` merges by container name.
#
# ${arr[@]+"${arr[@]}"} rather than "${arr[@]}": on bash 3.2 — which is what
# macOS ships — expanding an empty array under `set -u` is an "unbound variable"
# error, not an empty expansion.
k -n "$ns" run "$pod" --rm -i ${tty_flag[@]+"${tty_flag[@]}"} --restart=Never --quiet \
  --image="$PG_IMAGE" \
  --env="PGPASSWORD=${pw}" --env="PGSSLMODE=require" \
  --override-type=strategic \
  --overrides="$overrides" \
  --command -- psql -h "$host" -p 5432 -U "$cluster" -d "$db" "$@"
