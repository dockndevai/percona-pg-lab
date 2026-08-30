# Tuning PostgreSQL under the operator

## There is exactly one place to put settings

```yaml
spec:
  patroni:
    dynamicConfiguration:
      postgresql:
        parameters:
          shared_buffers: 256MB
```

Not `postgresql.conf`. Not `ALTER SYSTEM`. Patroni owns the configuration and
reconciles it from the distributed configuration store, so anything you write
directly is reverted on the next reconcile — sometimes minutes later, which
makes it look like it worked.

Verify what actually landed, from SQL:

```bash
scripts/connect.sh ha --direct -c 'show shared_buffers;'
```

`tests/20_ha.bats` asserts three of these values on every run, which is what
stops a silently-dropped parameter from going unnoticed.

## Patroni settings vs PostgreSQL settings

A distinction that costs people real time. Two different levels live under
`dynamicConfiguration`:

```yaml
dynamicConfiguration:
  synchronous_mode: true          # Patroni (DCS) level
  synchronous_node_count: 1       # Patroni
  failsafe_mode: true             # Patroni
  postgresql:
    parameters:
      synchronous_commit: "on"    # PostgreSQL
```

Putting `synchronous_mode` under `postgresql.parameters` does not error. It is
simply ignored, and you get asynchronous replication while believing otherwise.

Notably, **do not set `synchronous_standby_names` yourself.** Patroni manages it,
and hand-setting it fights the failover logic.

---

## The parameters that matter, and why

The `ha` profile's values are sized against a 1 GiB container limit. Scale them
with your actual limit, not with the node's memory.

### Memory

| Parameter | `ha` value | Reasoning |
|---|---|---|
| `shared_buffers` | `256MB` | ~25% of the container limit. Going much above 40% starts competing with the OS page cache, which is also caching your data. |
| `effective_cache_size` | `768MB` | Not an allocation — a *hint* to the planner about total cache. Set it to roughly the limit; too low pushes the planner toward sequential scans. |
| `work_mem` | `4MB` | Per sort/hash **per node per connection**. A single query with several sorts across 50 connections can multiply this alarmingly. Keep it small globally and raise it per-session for known-heavy queries. |
| `maintenance_work_mem` | `64MB` | Used by `VACUUM`, index builds. Safe to make larger than `work_mem` because few run concurrently. |

### Connections

```yaml
max_connections: "200"
superuser_reserved_connections: "5"
```

Deliberately modest, because PgBouncer exists so this number can stay small.
Every backend costs 5–10 MB before doing any work, plus a slot in every snapshot.
Raising `max_connections` to make a connection error go away removes the
protection, not the problem. See
[04-connection-pooling.md](04-connection-pooling.md#why-not-just-raise-max_connections).

The reserved connections matter more than they look: without them, a saturated
cluster locks *you* out at exactly the moment you need `psql` to fix it.

### Durability

```yaml
synchronous_commit: "on"     # ha
synchronous_commit: "off"    # dev-standalone
```

With `synchronous_mode` on, `on` means a commit does not return until the
synchronous standby has flushed the WAL. That is the guarantee that makes
`tests/30_failover.bats` able to assert zero data loss.

`off` is the single largest write-throughput win available and loses recent
commits on an OS crash. It is set in the dev profile precisely so the contrast is
visible, and it is never appropriate for real data.

### Replication

| Parameter | Value | Note |
|---|---|---|
| `max_wal_senders` | `10` | One per standby plus headroom for `pg_basebackup` and backups. |
| `wal_keep_size` | `512MB` | How much WAL to retain for a briefly-disconnected standby. Too small forces a full rebuild from the repo. |
| `hot_standby_feedback` | `on` | Stops the primary vacuuming rows a standby query still needs. The cost: a long query on a standby delays vacuum on the *primary* and can drive transaction-ID age up. Watch `pg_database_xid_age` — there is an alert for it. |

### WAL and checkpoints

```yaml
checkpoint_timeout: "15min"
checkpoint_completion_target: "0.9"
max_wal_size: 1GB
wal_compression: "on"
```

`checkpoint_completion_target: 0.9` spreads checkpoint writes over 90% of the
interval instead of the 0.5 default, which turns a periodic write stall into a
gentle background hum. This is close to a free win and is the first thing to
change on a default install.

`wal_compression: on` costs CPU and reduces WAL volume — which on Kubernetes also
means less archive traffic to object storage and a smaller RPO gap for the DR
standby.

### Autovacuum

```yaml
autovacuum_vacuum_scale_factor: "0.05"    # default 0.2
autovacuum_analyze_scale_factor: "0.02"   # default 0.1
autovacuum_naptime: "30s"
```

More aggressive than default because a pooled workload concentrates churn onto a
few hot tables. The defaults wait until 20% of a table is dead — on a large busy
table that is an enormous, disruptive vacuum instead of many small ones.

### Observability

```yaml
track_io_timing: "on"
log_min_duration_statement: "1000"
log_checkpoints: "on"
log_lock_waits: "on"
log_autovacuum_min_duration: "0"
```

`track_io_timing` has measurable but small overhead and is what makes
`pg_stat_statements` able to distinguish "slow because of I/O" from "slow because
of CPU". Worth it.

---

## Failover timing

```yaml
patroni:
  syncPeriodSeconds: 10
  leaderLeaseDurationSeconds: 30
```

These drive the container probes by documented formulas:

```
timeoutSeconds   = syncPeriodSeconds / 2                        = 5s
periodSeconds    = syncPeriodSeconds                            = 10s
failureThreshold = leaderLeaseDurationSeconds / syncPeriodSeconds = 3
```

Worst-case detection is therefore about 30 seconds; measured promotion on this
lab was 9 seconds from a forced kill.

Shortening these speeds up failover and makes *spurious* failovers more likely —
a node under memory pressure that misses three probes gets its healthy primary
demoted. On constrained or noisy infrastructure, lengthen rather than shorten.

---

## Which changes need a restart

Some parameters apply on reload; others are `pending_restart`. Ask PostgreSQL
rather than guessing:

```sql
select name, setting, pending_restart from pg_settings where pending_restart;
```

Restart-requiring parameters include `shared_buffers`, `max_connections`,
`max_worker_processes`, and `max_wal_senders`. The operator rolls instances one
at a time, replicas before the primary, so the write outage is one leader
handover rather than a full outage — but it is not zero. Batch such changes.

---

## Per-profile summary

| Parameter | `dev-standalone` | `ha` | `dr-standby` |
|---|---|---|---|
| `shared_buffers` | 256MB | 256MB | 256MB |
| `max_connections` | 100 | 200 | 100 |
| `synchronous_commit` | **off** | on | (recovery) |
| `synchronous_mode` | — | true | — |
| `hot_standby_feedback` | — | on | on |
| `log_min_duration_statement` | 500ms | 1000ms | — |
