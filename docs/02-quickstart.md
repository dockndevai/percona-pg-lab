# Quickstart

From nothing to a highly-available PostgreSQL cluster with connection pooling.

## Prerequisites

```bash
brew install kubectl helm kind bats-core libpq
```

Docker Desktop needs **at least 8 GiB** allocated. Check everything at once:

```bash
make preflight
```

It verifies the tools, reports the Docker VM's CPU and memory, and warns if
another kind cluster is competing for the same VM — the usual cause of mystery
OOMKills halfway through a bootstrap.

## Three commands

```bash
make cluster-up         # 4-node kind cluster, pre-pulls the database images
make operator-install   # Percona operator 3.0.0, cluster-wide
make ha-up              # 3x PostgreSQL + 3x PgBouncer
```

`make ha-up` blocks until the cluster reports `state: ready`. Expect roughly
**5 minutes** once images are cached, longer on the first run — the PostgreSQL
image alone is about 1 GB.

```bash
make status
```

```
ha  (ns=pg-ha)  state=ready  postgres=3/3  pgbouncer=3/3
  ha-cluster-instance1-g9w2-0            Running   pg-lab-worker3   replica
  ha-cluster-instance1-vhv7-0            Running   pg-lab-worker2   replica
  ha-cluster-instance1-vnpw-0            Running   pg-lab-worker    primary
  ha-cluster-pgbouncer-b6958c9fc-9nbd9   Running   pg-lab-worker3   pgbouncer
  ...
```

## Connect

```bash
make psql                          # interactive, through PgBouncer
scripts/connect.sh ha -c 'select version();'
scripts/connect.sh ha --direct     # bypass the pooler, straight to the primary
scripts/connect.sh ha --admin      # the PgBouncer admin console
```

`connect.sh` runs `psql` from a pod *inside* the cluster, so no port-forward is
needed and the latency you measure is realistic.

To wire up your own application, take the URI the operator generated:

```bash
kubectl -n pg-ha get secret ha-cluster-pguser-ha-cluster \
  -o jsonpath='{.data.pgbouncer-uri}' | base64 -d
```

Use `pgbouncer-uri`, not `uri`. It survives failover unchanged.

> **One surprise worth knowing immediately:** tables you create as the
> application user land in a schema named after that user, not in `public`,
> because `spec.autoCreateUserSchema` defaults to true. See
> [11-troubleshooting.md](11-troubleshooting.md#tables-land-in-a-per-user-schema-not-public).

## Verify it

```bash
make test
```

Suites skip themselves when their profile is not deployed, so this is safe at
any point. With just the HA profile up you get the operator, HA and PgBouncer
suites — 28 assertions covering replication, placement, pool configuration and
connection multiplexing.

## Break it on purpose

```bash
make failover
```

Force-kills the current leader and measures how long until writes succeed again
*through PgBouncer* — which is what your application actually experiences.

```
==> current primary: ha-cluster-instance1-vnpw-0
  ✓ new primary elected after 9s: ha-cluster-instance1-vhv7-0
  ✓ writes recovered 1s after the election
```

## Then

```bash
make obs-up      # Prometheus, Grafana, exporters, alerts
make perf        # pgbench sweep, regenerates docs/10-performance-results.md
make minio-up && scripts/s3-repo-up.sh && make dr-up   # DR standby
```

## Clean up

```bash
make down        # remove all database profiles and monitoring
make nuke        # also delete the kind cluster
```

## If something goes wrong

The CR status is often unhelpful when reconciliation is broken. Start here:

```bash
kubectl -n pg-operator logs deploy/pg-operator --tail=200 | grep -i error
```

Then [11-troubleshooting.md](11-troubleshooting.md), which documents every
failure we hit building this.
