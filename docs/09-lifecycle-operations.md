# Day-2 operations

## Scaling

```bash
kubectl -n pg-ha patch pg ha-cluster --type merge \
  -p '{"spec":{"instances":[{"name":"instance1","replicas":5}]}}'
```

`instances` is a list, so a merge patch replaces it wholesale — restate the whole
entry, not just the field you are changing. This is the most common way to
accidentally wipe out `resources` or `affinity`.

New members are built using `createReplicaMethods`, in order. `pgbackrest` first
means a new replica is seeded from the backup repository rather than by streaming
a full copy off the primary — much kinder to a production primary, and the reason
that ordering is the default in `clusters/ha`.

Scaling **down** removes the highest-ordinal instances. Their PVCs are *not*
deleted; that is deliberate, so a mistaken scale-down is recoverable.

Scaling PgBouncer is independent and much cheaper:

```bash
kubectl -n pg-ha patch pg ha-cluster --type merge \
  -p '{"spec":{"proxy":{"pgBouncer":{"replicas":5}}}}'
```

But remember each pooler holds its own pool: five replicas at
`default_pool_size: 25` is 125 backends, not 25. Re-check the sizing arithmetic
in [04-connection-pooling.md](04-connection-pooling.md#sizing) whenever you scale
poolers.

<a id="switchover-vs-failover"></a>

## Switchover vs failover

These are different operations that people routinely conflate, and conflating
them produces failover numbers that are far too good.

**Switchover** — planned, graceful. Patroni demotes the current leader, waits
for a standby to catch up fully, and hands the leader key over.

```bash
scripts/chaos-failover.sh --switchover
```

Two things about this are not obvious.

**`spec.patroni.switchover` did not work on operator v3.0.0.** The field exists
and is accepted:

```yaml
spec:
  patroni:
    switchover:
      enabled: true
      type: Switchover
      targetInstance: ha-cluster-instance1-5c2n   # optional
```

but setting it produced no switchover and no operator log entry at all, over
five minutes, with and without `targetInstance`. Use `patronictl` instead:

```bash
kubectl -n pg-ha exec <leader-pod> -c database -- \
  patronictl -c /etc/patroni/~postgres-operator_cluster.yaml \
  switchover ha-cluster-ha --leader <leader-pod> --candidate <sync-standby> --force
```

Note the Patroni *scope* (`<cluster>-ha`) is the first argument, not the cluster
name.

**With `synchronous_mode` on, the candidate is not your choice.** Patroni will
only promote the current synchronous standby:

```
Switchover failed, details: 412, candidate name does not match with sync_standby
```

That refusal is correct. The async replica may be behind, so switching to it
would be a data-loss event wearing the costume of a planned operation. Find the
right candidate first:

```sql
select application_name from pg_stat_replication where sync_state = 'sync';
```

`tests/70_lifecycle.bats` asserts both the working path and the refusal.

**Failover** — unplanned. The leader is gone and a standby wins by lease expiry.

```bash
scripts/chaos-failover.sh          # kubectl delete pod --force --grace-period=0
```

The distinction matters for testing. A plain `kubectl delete pod` sends
`SIGTERM`, which Patroni catches and turns into a graceful handover — so it
measures a switchover while looking like a crash test. Measured here: 0 seconds,
which is a lovely number and completely misleading.

Forcing the delete skips the handover. Measured on this lab:

| | Switchover | Forced failover |
|---|---|---|
| Detection | immediate | up to `leaderLeaseDurationSeconds` (30s) |
| Timeline advanced | ~0s | **9s** |
| Writes resume through PgBouncer | ~0s | **<1s after that** |
| Committed rows lost | 0 | **0** |

Zero data loss in both cases is a consequence of `synchronous_mode` with
`synchronous_node_count: 1`. Without it, the forced case can lose committed
transactions.

**Pod names are not a failover signal.** Each instance is its own single-replica
StatefulSet, so a killed pod is recreated with the identical name and may win the
next election. Use the timeline:

```sql
select timeline_id from pg_control_checkpoint();
```

```bash
patronictl -c /etc/patroni/~postgres-operator_cluster.yaml history
patronictl -c /etc/patroni/~postgres-operator_cluster.yaml list
```

## Configuration changes

All PostgreSQL settings go through `spec.patroni.dynamicConfiguration` — see
[05-postgres-tuning.md](05-postgres-tuning.md). Anything written directly to
`postgresql.conf` or via `ALTER SYSTEM` is reverted on the next reconcile.

Check what needs a restart:

```sql
select name, setting, pending_restart from pg_settings where pending_restart;
```

The operator rolls replicas first, then the primary, so the write outage is one
leader handover rather than a full outage — but it is not zero. Batch
restart-requiring changes.

PgBouncer config is different: no restart, but a propagation delay of roughly
90 seconds through ConfigMap sync and `SIGHUP`. Verify rather than assume:

```bash
scripts/connect.sh ha --admin -c 'SHOW CONFIG;' | grep pool_mode
```

## Major version upgrades

```yaml
apiVersion: pgv2.percona.com/v2
kind: PerconaPGUpgrade
metadata:
  name: upgrade-17-to-18
spec:
  postgresClusterName: dev-cluster
  image: docker.io/percona/percona-postgresql-operator:3.0.0-upgrade
  fromPostgresVersion: 17
  toPostgresVersion: 18
  toPostgresImage: docker.io/percona/percona-distribution-postgresql:18.3-2
  toPgBouncerImage: docker.io/percona/percona-pgbouncer:1.25.1-1
  toPgBackRestImage: docker.io/percona/percona-pgbackrest:2.58.0-1
```

This runs `pg_upgrade`, which means **downtime for the whole cluster**, not a
rolling upgrade. Before starting:

1. Take a full backup. `pg_upgrade` is in-place.
2. The cluster must be paused (`spec.pause: true`) — the operator handles this,
   but it is why the cluster is unavailable throughout.
3. `spec.postgresVersion` and `spec.image` on the cluster must be updated to the
   new version afterwards, or the operator will try to downgrade it back.
4. A DR standby cannot replay across a major version. Rebuild it after.

`clusters/upgrade-demo` provides a PG 17 cluster to try this against, so you are
not rehearsing on something you care about.

## Pause and resume

```yaml
spec:
  pause: true
```

Scales all workloads to zero while keeping the CR, PVCs and Secrets. Useful for
freeing a laptop without losing state.

`spec.unmanaged: true` is different and much sharper: the operator stops
reconciling entirely while leaving everything running. It is an escape hatch for
manual intervention, not a pause button — nothing is being repaired while it is
set.

## Deleting a cluster

```bash
kubectl -n pg-ha delete pg ha-cluster
```

**PVCs survive.** That is deliberate — an accidental `delete` should not destroy
your data. It also means a re-created cluster of the same name may adopt the old
volumes.

`scripts/profile.sh down` deletes the PVCs too, because this is a lab. In
production, delete them deliberately and separately.

## Upgrading the operator

```bash
helm upgrade pg-operator percona/pg-operator --version <new> \
  -n pg-operator -f operator/values.yaml
```

Bump `OPERATOR_VERSION` in [`scripts/lib.sh`](../scripts/lib.sh) and the image
tags in the cluster manifests together. `spec.crVersion` should match the
operator version; a mismatch is tolerated for one minor version but is not a
place to linger.

CRDs are **not** upgraded by `helm upgrade`. Apply them separately:

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/percona/percona-postgresql-operator/v<new>/deploy/crd.yaml
```

`--server-side` is required — these CRDs exceed the client-side annotation size
limit.
