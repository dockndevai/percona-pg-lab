# Topologies

Three profiles, three different sets of trade-offs. Run one at a time on a
laptop — see the resource notes at the bottom.

| Profile | PostgreSQL | PgBouncer | Backup repo | Survives |
|---|---|---|---|---|
| [`dev-standalone`](../clusters/dev-standalone) | 1 | 1 | PVC | nothing |
| [`ha`](../clusters/ha) | 3, synchronous | 3 | PVC + repo host | node loss |
| [`dr-standby`](../clusters/dr-standby) | 1, read-only | 1 | shared S3, read | loss of the whole source cluster |

---

## dev-standalone

```bash
make dev-up
```

One instance, one pooler, a local pgBackRest repo. Ready in about four and a
half minutes from a cold image cache, well under a minute once warm.

**What it is for:** laptop development, CI, "does this migration apply?".

**What it is not for:** anything you would miss. A single instance means Patroni
has nobody to promote. Losing the pod means downtime until it reschedules;
losing the PVC means restoring from backup. Both are recoverable, neither is
automatic.

It ships `synchronous_commit: off`, which is the largest single write-throughput
win available and completely unacceptable in production — an OS crash loses
recent commits. It is here to make the difference visible when you compare it to
the `ha` profile.

---

## ha

```bash
make ha-up
```

Three instances under Patroni with one synchronous standby, three poolers, and a
dedicated pgBackRest repo host. This is the production shape.

### What makes it highly available

**One instance per node, enforced.** The upstream sample uses
`preferredDuringSchedulingIgnoredDuringExecution`, which lets Kubernetes
colocate two PostgreSQL pods under pressure — quietly removing the availability
you thought you had bought. This profile uses `required`:

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            postgres-operator.crunchydata.com/cluster: ha-cluster
            postgres-operator.crunchydata.com/data: postgres
        topologyKey: kubernetes.io/hostname
```

A pod that cannot be placed stays `Pending` and visible, which is the failure
you want. `tests/20_ha.bats` asserts all three land on distinct nodes.

Do **not** add a `topologySpreadConstraint` for zone or hostname with
`ScheduleAnyway` — the operator already injects both, and a duplicate silently
breaks reconciliation. See
[11-troubleshooting.md](11-troubleshooting.md#duplicate-topologyspreadconstraints-stop-reconciliation-dead).

**Synchronous replication with a fallback.**

```yaml
patroni:
  dynamicConfiguration:
    synchronous_mode: true
    synchronous_mode_strict: false
    synchronous_node_count: 1
```

These are Patroni DCS settings and belong at this level, *not* under
`postgresql.parameters`. Patroni maintains `synchronous_standby_names` itself and
refuses to promote a standby that was not in sync — which is what turns
"probably no data loss" into "no data loss".

`synchronous_mode_strict: false` means that if the last standby dies, the primary
degrades to asynchronous rather than blocking every write. Set it to `true` when
correctness outranks uptime; understand that you are choosing to stop serving.

Verified live:

```
application_name | ha-cluster-instance1-vhv7-0 | streaming | sync
application_name | ha-cluster-instance1-g9w2-0 | streaming | async
```

### Read/write split

The operator creates two Services worth knowing:

| Service | Type | Points at |
|---|---|---|
| `<cluster>-primary` | headless | the current leader |
| `<cluster>-replicas` | ClusterIP | the standbys only |
| `<cluster>-pgbouncer` | ClusterIP | the poolers, which route to `-primary` |

PgBouncer does **not** load-balance reads onto standbys. Send read-only traffic
to `<cluster>-replicas` explicitly. `tests/20_ha.bats` asserts that Service's
endpoints never include the primary.

### Measured failover

Force-killing the leader (`--force --grace-period=0`, which skips Patroni's
graceful handover):

| | |
|---|---|
| Timeline advanced | 9s |
| Writes resumed through PgBouncer | <1s after that |
| Committed rows lost | 0 |
| Back to 3/3 healthy with sync re-established | ~2 min |

A plain `kubectl delete pod` produces a *graceful handover* instead and looks
instantaneous. That is a switchover, not a failure — see
[09-lifecycle-operations.md](09-lifecycle-operations.md#switchover-vs-failover).

---

## dr-standby

```bash
make minio-up
scripts/s3-repo-up.sh     # adds repo2 (S3) to the HA cluster
make dr-up
```

A separate cluster, in a separate namespace, that continuously replays the
source cluster's WAL out of shared object storage. It never connects to the
primary — the pgBackRest repository is the only coupling.

That indirection is the entire point. Streaming replication needs a reachable
primary; an object store does not. This topology survives the source cluster's
namespace, nodes, and (in a real deployment) region being gone.

**The trade is RPO.** This is archive-based replication, so the standby is always
at least one WAL segment behind — the segment currently being written has not
been archived yet. Measured here: ~70s steady-state from commit to visible on the
standby, after forcing a segment switch. Anything claiming sub-second lag for
this topology is describing streaming replication, not this.

**Two things must line up exactly**, or the standby comes up `ready` holding none
of your data:

1. `repo2-path` — byte-identical on both clusters
2. `postgresVersion` — a standby cannot replay WAL across a major version

**Promotion is one-way.**

```bash
make dr-promote
```

`scripts/dr-promote.sh` sets `standby.enabled: false` **and** repoints
`repo2-path` in a single patch. That second half is not optional: a promoted
cluster still has `archive_mode=on`, so if it keeps the source repository path it
starts writing its own divergent timeline into the shared stanza and quietly
breaks every future standby built from it. We hit exactly that while building
this lab —
[11-troubleshooting.md](11-troubleshooting.md#poisoned-stanza-a-standby-restores-reports-ready-and-never-replicates).

---

## Running these on a laptop

Approximate *requests*, not limits:

| Running | CPU | Memory |
|---|---|---|
| `dev-standalone` | ~0.4 | ~0.7 GiB |
| `ha` | ~1.1 | ~2.0 GiB |
| `ha` + `dr-standby` + MinIO | ~1.5 | ~3.0 GiB |
| …plus the monitoring stack | ~2.0 | ~4.5 GiB |

Give Docker at least 8 GiB. `make preflight` checks this and warns about other
kind clusters competing for the same VM — the usual cause of mystery OOMKills.

The profiles are designed to run one at a time; `make down` clears them all while
leaving the kind cluster in place.
