#!/usr/bin/env bash
# Print ready-to-paste MCP client configuration pointed at this lab.
#
# The generated config is deliberately read-only and namespace-scoped. See
# docs/12-mcp-server.md for the progression to read-write and why you should
# not point admin mode at anything you care about.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PKG="@dockndevai/mcp-percona-pg"
NS_LIST="${HA_NS},${DEV_NS},${DR_NS}"

# Only advertise namespaces that actually exist, so the allowlist matches reality.
present=()
for ns in "$HA_NS" "$DEV_NS" "$DR_NS"; do
  k get ns "$ns" >/dev/null 2>&1 && present+=("$ns")
done
if (( ${#present[@]} )); then
  NS_LIST="$(IFS=,; echo "${present[*]}")"
else
  warn "none of ${HA_NS}/${DEV_NS}/${DR_NS} exist yet — run 'make ha-up' first"
fi

log "MCP config for ${KUBE_CONTEXT} (namespaces: ${NS_LIST})"

cat <<CLAUDE_CODE

── Claude Code ────────────────────────────────────────────────────────────────

claude mcp add percona-pg-lab \\
  -e PERCONA_MODE=read-only \\
  -e PERCONA_CONTEXT=${KUBE_CONTEXT} \\
  -e PERCONA_NAMESPACE=${HA_NS} \\
  -e PERCONA_NAMESPACE_ALLOWLIST=${NS_LIST} \\
  -- npx -y ${PKG}

── Claude Desktop · Cursor · Windsurf ─────────────────────────────────────────
  claude_desktop_config.json | .cursor/mcp.json | ~/.codeium/windsurf/mcp_config.json

{
  "mcpServers": {
    "percona-pg-lab": {
      "command": "npx",
      "args": ["-y", "${PKG}"],
      "env": {
        "PERCONA_MODE": "read-only",
        "PERCONA_CONTEXT": "${KUBE_CONTEXT}",
        "PERCONA_NAMESPACE": "${HA_NS}",
        "PERCONA_NAMESPACE_ALLOWLIST": "${NS_LIST}"
      }
    }
  }
}

── Codex CLI ──────────────────────────────────────────────────────────────────
  ~/.codex/config.toml

[mcp_servers.percona-pg-lab]
command = "npx"
args = ["-y", "${PKG}"]
env = { PERCONA_MODE = "read-only", PERCONA_CONTEXT = "${KUBE_CONTEXT}", PERCONA_NAMESPACE = "${HA_NS}", PERCONA_NAMESPACE_ALLOWLIST = "${NS_LIST}" }

CLAUDE_CODE

dim "    PERCONA_CONTEXT is pinned on purpose: without it the server follows your"
dim "    current kube-context, so switching context to look at production takes the"
dim "    agent with you."
dim ""
dim "    To let it make changes, add PERCONA_MODE=read-write and start with"
dim "    PERCONA_DRY_RUN=true — see docs/12-mcp-server.md"
