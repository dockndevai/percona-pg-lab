#!/usr/bin/env bash
# Fail fast on a missing tool, and warn loudly before you run out of RAM
# halfway through a cluster bootstrap.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "preflight"

for t in docker kubectl helm kind; do need "$t"; done
ok "required tools present"

for t in psql pgbench bats; do
  if command -v "$t" >/dev/null 2>&1; then
    dim "    optional: $t found"
  elif [[ "$t" == bats ]]; then
    warn "bats not found — 'make test' will not run.  brew install bats-core"
  else
    warn "$t not found — 'make perf' analysis will not run.  brew install libpq"
  fi
done

docker info >/dev/null 2>&1 || die "docker daemon is not reachable"

# Everything here targets bash 3.2, because that is what macOS ships. This is
# informational rather than fatal — but if you are writing scripts for this
# repo on bash 4+, remember most users are not.
dim "    bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]} (scripts target 3.2 for macOS compatibility)"

# Docker VM capacity. The HA profile plus the monitoring stack wants roughly
# 3 CPU and 5Gi of *requests*; anything under 8Gi total is going to hurt.
mem_bytes="$(docker info --format '{{.MemTotal}}')"
cpus="$(docker info --format '{{.NCPU}}')"
mem_gib=$(( mem_bytes / 1024 / 1024 / 1024 ))
dim "    docker VM: ${cpus} CPU / ${mem_gib}Gi"

(( cpus >= 4 ))   || warn "only ${cpus} CPUs — the HA profile will be slow"
(( mem_gib >= 8 )) || warn "only ${mem_gib}Gi of RAM — expect OOMKills with the HA + monitoring stack. Raise Docker's memory limit."

# Other kind clusters are the usual reason this box runs out of memory.
others="$(kind get clusters 2>/dev/null | grep -v "^${KIND_CLUSTER}$" || true)"
if [[ -n "$others" ]]; then
  warn "other kind clusters are running and competing for the same Docker VM:"
  while read -r c; do
    [[ -z "$c" ]] && continue
    used="$(docker stats --no-stream --format '{{.MemUsage}}' "${c}-control-plane" 2>/dev/null || echo '?')"
    printf '        %-24s %s\n' "$c" "$used" >&2
  done <<< "$others"
  warn "free them with:  docker stop \$(docker ps -q --filter name=<cluster>-)"
fi

ok "preflight passed"
