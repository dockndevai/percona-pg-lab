# `.claude/` — agent configuration for this repository

Two files, in two places, for two different reasons.

## `.mcp.json` (repository root, not here)

Project-scoped MCP servers. Claude Code reads this file **from the repository
root** — that is where `claude mcp add --scope project` writes it, so it lives
there rather than in this directory.

It registers [`mcp-percona-pg`](https://github.com/dockndevai/mcp-percona-pg)
against the local lab: context `kind-pg-lab`, namespaces `pg-ha,pg-dev,pg-dr`,
**read-only**. Anyone who clones the repo and runs the lab gets the same
scoped, non-destructive access without configuring anything.

Claude Code asks for approval before enabling MCP servers from a checked-in
`.mcp.json` — it is a file from a repository, and repositories can be
untrusted. That prompt is a feature; read the file before approving it.

Regenerate config for other clients, or for a non-default context:

```bash
make mcp-config
```

To let an agent make changes, do **not** edit `.mcp.json` — that is shared
with everyone who clones the repo. Add a local override instead:

```bash
claude mcp add percona-pg-rw --scope local \
  -e PERCONA_MODE=read-write -e PERCONA_DRY_RUN=true \
  -e PERCONA_CONTEXT=kind-pg-lab \
  -- npx -y @dockndevai/mcp-percona-pg
```

Start with `PERCONA_DRY_RUN=true` and read the patches it proposes. The full
progression, and the guards verified against this lab, are in
[docs/12-mcp-server.md](../docs/12-mcp-server.md).

## `settings.json` (this directory)

Project settings, checked in and shared.

- `enableAllProjectMcpServers` — approve the servers in `.mcp.json` without a
  per-session prompt. Remove this line if you would rather approve each time.
- `permissions.allow` — read-only inspection that should not need a prompt:
  `kubectl get/describe/logs` **against the `kind-pg-lab` context only**, the
  non-destructive `make` targets, lint tooling, and the MCP read tools.
- `permissions.deny` — things an agent should never do unprompted here:
  `make nuke`, `make dr-repo-clean` (wipes the backup repository),
  `kind delete`, and reading key material.

Note what the allowlist does *not* contain: `make ha-up`, `make down`,
`make perf`, anything that mutates a cluster, and any `kubectl` against a
context other than `kind-pg-lab`. Those still prompt. The pattern is
deliberate — allow inspection freely, ask before acting, and scope every
allowance to the disposable lab cluster.

`settings.local.json` in this directory is gitignored; put personal overrides
there rather than editing `settings.json`.
