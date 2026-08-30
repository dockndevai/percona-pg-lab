# percona-pg-lab

A working lab for running **PostgreSQL and PgBouncer on Kubernetes** with the
[Percona Operator for PostgreSQL](https://github.com/percona/percona-postgresql-operator) —
covering the whole lifecycle, not just `kubectl apply`.

Every manifest here has been deployed, every claim measured, and every failure
mode in [docs/11-troubleshooting.md](docs/11-troubleshooting.md) actually hit
while building it. Where something does not work, the docs say so.

```bash
make cluster-up        # 4-node kind cluster
make operator-install  # Percona operator v3.0.0, cluster-wide
make ha-up             # 3x PostgreSQL + 3x PgBouncer, synchronous replication
make test              # the bats suite
```

---

## What this covers

Start at [docs/00-index.md](docs/00-index.md), or jump straight in:

| Topic | Where |
|---|---|
| Architecture, what the operator actually creates | [docs/01-architecture.md](docs/01-architecture.md) |
| Quickstart from zero | [docs/02-quickstart.md](docs/02-quickstart.md) |
| Standalone / HA / DR topologies and when each is wrong | [docs/03-topologies.md](docs/03-topologies.md) |
| **Connection pooling: sizing, pool modes, what pooling does and does not buy** | [docs/04-connection-pooling.md](docs/04-connection-pooling.md) |
| PostgreSQL tuning through Patroni | [docs/05-postgres-tuning.md](docs/05-postgres-tuning.md) |
| Backup, PITR, and cross-cluster DR | [docs/06-backup-restore-pitr.md](docs/06-backup-restore-pitr.md) |
| Observability: Prometheus, Grafana, exporters, PMM | [docs/07-observability.md](docs/07-observability.md) |
| Extensions and plugins | [docs/08-extensions.md](docs/08-extensions.md) |
| Day-2 operations: scale, upgrade, switchover, pause | [docs/09-lifecycle-operations.md](docs/09-lifecycle-operations.md) |
| Measured performance results | [docs/10-performance-results.md](docs/10-performance-results.md) |
| **Troubleshooting: the failures we actually hit** | [docs/11-troubleshooting.md](docs/11-troubleshooting.md) |

## Topologies

| Profile | Shape | For |
|---|---|---|
| [`dev-standalone`](clusters/dev-standalone) | 1 PostgreSQL, 1 PgBouncer, local backup repo | Laptop development, CI |
| [`ha`](clusters/ha) | 3 PostgreSQL (one per node, synchronous), 3 PgBouncer, dedicated repo host | Production shape |
| [`dr-standby`](clusters/dr-standby) | Separate cluster replaying WAL from object storage | Cross-region disaster recovery |

## Two results worth knowing before you start

**1. Connection pooling buys you backends, not throughput — and eventually it
buys you staying up at all.**

Measured on this lab, `pgbench -S`, HA profile (`max_connections: 200`,
3 poolers × `default_pool_size: 25`):

| Clients | Duty cycle | Direct | Via PgBouncer |
|---:|---|---|---|
| 60 | idle-heavy (rate-limited) | 60 backends | **15–38 backends**, same tps |
| 100 | idle-heavy | 100 backends | **28 backends**, same tps |
| 40 | saturated | 40 backends | 40 backends, ~3% slower |
| **300** | either | **fails: `max_connections exceeded`** | **serves it**, 74 backends |

Three things fall out of that table:

- At 100% duty cycle every client is always inside a transaction, so there is
  nothing to multiplex and PgBouncer only adds a hop. Benchmarks that test only
  that shape are where "PgBouncer made it slower" comes from.
- With idle clients — what a real application connection pool looks like — the
  backend count collapses by 3–4× at equal throughput.
- At 300 clients the direct connection does not get slower, it **stops working**.
  That is the wall a pooler exists to keep you away from.

Full table, method, and caveats: [docs/10-performance-results.md](docs/10-performance-results.md).

**2. Archive-based DR has an RPO measured in minutes, not milliseconds.**

The standby in [`dr-standby`](clusters/dr-standby) replays WAL from object
storage, so it is always at least one WAL segment behind — measured at ~70s
steady-state here. That is the correct trade for surviving the loss of an entire
region, but it is not streaming replication and should not be documented as
such. See [docs/06-backup-restore-pitr.md](docs/06-backup-restore-pitr.md#rpo).

## Requirements

`docker` (8 GiB+ allocated), `kubectl`, `helm` 3, `kind`, and `bats-core` for the
tests. `make preflight` checks all of it and warns about other kind clusters
competing for the same Docker VM.

## Layout

```
clusters/      PerconaPGCluster manifests, one directory per topology
operator/      operator Helm values
observability/ kube-prometheus-stack values, exporter sidecars, alerts, dashboards
backup/        MinIO (S3 target), pgBackRest repo config, backup/restore samples
extensions/    builtin and custom extension configuration
perf/          pgbench sweep harness and its report generator
tests/         bats suites
scripts/       every make target's implementation
docs/          the guides
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Issues and PRs welcome — especially
"this didn't work on my cluster", which is the most useful kind of report for a
repo like this.

## Licence

Apache-2.0. Not affiliated with or endorsed by Percona.
