# Documentation index

Read in order for a walkthrough, or jump to what you need.

| | Guide | What it answers |
|---|---|---|
| 01 | [Architecture](01-architecture.md) | What does the operator actually create, and what are all these Services and Secrets called? |
| 02 | [Quickstart](02-quickstart.md) | How do I get a working HA cluster in three commands? |
| 03 | [Topologies](03-topologies.md) | Standalone, HA, or DR — which do I want, and what does each *not* protect me from? |
| 04 | [Connection pooling](04-connection-pooling.md) | How do I size PgBouncer, which pool mode, and what does pooling actually buy? |
| 05 | [PostgreSQL tuning](05-postgres-tuning.md) | Where do settings go, and why these values? |
| 06 | [Backup, PITR, DR](06-backup-restore-pitr.md) | How do I take backups, recover to a point in time, and run a DR site? |
| 07 | [Observability](07-observability.md) | How do I see what the cluster is doing? |
| 08 | [Extensions](08-extensions.md) | How do I install and use extensions? |
| 09 | [Day-2 operations](09-lifecycle-operations.md) | Scaling, config changes, switchover, major upgrades, pause. |
| 10 | [Performance results](10-performance-results.md) | Measured numbers, and how to reproduce them. |
| 11 | [Troubleshooting](11-troubleshooting.md) | It broke. What now? |
| 12 | [MCP server](12-mcp-server.md) | How do I let an AI agent operate this — safely? |
| 13 | [Cloud Kubernetes](13-cloud-kubernetes.md) | What changes on EKS, GKE or AKS? |
| 14 | [CI/CD promotion](14-cicd-promotion.md) | How do I get a change from dev to prod without breaking prod? |
| 15 | [Admission policies](15-admission-policies.md) | How do I make the rules impossible to bypass? |
| 16 | [Network & security](16-network-and-security.md) | Can PostgreSQL reach the internet? What else should I lock down? |

> **One page is not verified the way the rest are.**
> [13-cloud-kubernetes](13-cloud-kubernetes.md) is reasoned from the operator's
> CRD and provider documentation rather than measured on a cloud cluster, and it
> says so at the top. Everything else here was observed on a running cluster.

## If you are in a hurry

Three things in this repo took the longest to work out and are the most likely
to bite you:

1. **[A promoted DR standby poisons the source repository](11-troubleshooting.md#poisoned-stanza-a-standby-restores-reports-ready-and-never-replicates)**
   — every signal stays green while replication silently stops.
2. **[Connection pooling helps in proportion to how idle your clients are](04-connection-pooling.md#what-pooling-actually-buys-you)**
   — benchmark it wrong and you will conclude it does nothing.
3. **[Application tables land in a per-user schema, not `public`](11-troubleshooting.md#tables-land-in-a-per-user-schema-not-public)**
   — and migration tools that assume otherwise will build a second, empty set.
