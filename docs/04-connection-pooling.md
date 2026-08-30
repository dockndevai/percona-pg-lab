# Connection pooling with PgBouncer

The operator ships PgBouncer as `spec.proxy.pgBouncer`, and it is the entry
point every client should use. This guide covers what it buys you, how to size
it, which pool mode to pick, and how to see inside it.

---

## What pooling actually buys you

Not throughput. Fewer PostgreSQL backends.

Every PostgreSQL backend is an OS process costing roughly 5–10 MB of private
memory before it does any work, plus a slot in every snapshot the system takes.
Past a few hundred, you pay for them in lock contention and snapshot cost on
*every* query, including the ones from idle connections doing nothing.

PgBouncer lets many client connections share few backends. Crucially, that
sharing only happens **while a client is idle**. Measured on this lab
(`pgbench -S`, HA profile, `max_connections: 200`, 3 poolers ×
`default_pool_size: 25`):

| Clients | Duty cycle | Backends direct | Backends pooled | Throughput |
|---:|---|---:|---:|---|
| 40 | saturated | 40 | 40 | direct ~3% faster |
| 50 | rate-limited | 50 | **19** | equal |
| 60 | rate-limited | 60 | **15–38** | equal |
| 100 | rate-limited | 100 | **28** | equal |
| **300** | either | **connection refused** | **74** | pooled serves it |

Read the first row carefully. With every client permanently inside a
transaction there is nothing to multiplex — PgBouncer needs a backend per busy
client just as a direct connection does, and the only measurable difference is
the extra network hop.

The rate-limited rows are what a real application looks like: a connection pool
of 50–100, most of them idle between requests. Same throughput, a fraction of
the backends.

Note the range on the 60-client row. On an idle machine `pgbench` holds its rate
limit cleanly and 15 backends suffice; under contention the request pattern gets
burstier and more open at once. Both demonstrate multiplexing — but it is worth
knowing that the ratio you get depends on how evenly your traffic arrives, not
just on how many clients you have.

The last row is the one that matters most. At 300 clients the direct connection
does not get slower — it **fails**:

```
FATAL: remaining connection slots are reserved for roles with the SUPERUSER attribute
pgbench: error: could not create connection for client 271
```

PgBouncer served the same 300 clients on 74 backends. That is not an
optimisation, it is the difference between working and not working, and it is
the real reason to deploy a pooler.

> If you benchmark PgBouncer with an unthrottled `pgbench` and conclude it
> "doesn't help", you have measured row one and drawn a conclusion about row
> two.

### Why not just raise `max_connections`?

Because the cost is not the connection limit, it is the backends. Raising
`max_connections` to 5000 does not make 5000 backends affordable; it just
removes the error that was protecting you. The HA profile deliberately keeps
`max_connections: 200` *because* PgBouncer is in front of it.

---

## Pool modes

Set with `spec.proxy.pgBouncer.config.global.pool_mode`.

| Mode | Backend released | Safe with |
|---|---|---|
| `session` | when the client disconnects | everything |
| `transaction` | at each `COMMIT`/`ROLLBACK` | most applications |
| `statement` | after every statement | autocommit-only workloads |

`transaction` is the default in every profile here, and the right answer for
most web applications. What it costs you:

| Feature | `session` | `transaction` |
|---|---|---|
| `SET` / session GUCs outside a transaction | works | **unreliable** |
| `LISTEN` / `NOTIFY` | works | **broken** |
| Session-level advisory locks | works | **broken** |
| `WITH HOLD` cursors | works | **broken** |
| Temporary tables across transactions | works | **broken** |
| `SET LOCAL`, transaction-scoped anything | works | works |
| Protocol-level prepared statements | works | works¹ |

¹ PgBouncer ≥ 1.21 tracks protocol-level prepared statements in transaction
mode. `PREPARE`/`EXECUTE` as *SQL* is still session state and still breaks.

The failure mode is nasty because it is intermittent: your `SET timezone` works
whenever the pooler happens to hand you the same backend, and silently does not
when it does not. Under light load you may never see it. Test at concurrency.

**If you need session semantics**, do not switch the whole cluster to
`session` — that throws away the multiplexing you deployed PgBouncer for. Point
the small number of session-dependent clients at `<cluster>-primary` directly
and leave everything else pooled.

---

## Sizing

Four numbers, and they must be derived in this order.

```
max_client_conn      how many clients may connect to ONE pooler
default_pool_size    backends ONE pooler opens per (database, user)
max_db_connections   ceiling on backends per database, per pooler
max_connections      PostgreSQL's own limit
```

The constraint that matters:

```
pgbouncer_replicas × default_pool_size  <  max_connections − superuser_reserved_connections
```

**Each replica pools independently.** Three poolers with `default_pool_size: 25`
can open 75 backends between them, not 25. This is the single most common sizing
mistake, and it only shows up under load — exactly when you can least afford it.

The `ha` profile:

```
3 poolers × 25 default_pool_size = 75 backends worst case
max_connections 200 − 5 reserved = 195 available
75 < 195 ✓  with room for replication, backups and a human with psql
```

`max_client_conn: 1000` is per pooler, so the cluster accepts up to 3000 client
connections while never exceeding 75 backends. That ratio is the product.

### The other two knobs

`query_wait_timeout: 60` — how long a client waits for a backend before failing.
Without it, a saturated pool becomes an unbounded queue: PostgreSQL looks
perfectly healthy, `pg_stat_statements` shows fast queries, and your users see
timeouts. Set it, and alert on `pgbouncer_pools_client_waiting_connections > 0`.

`server_login_retry: 2` — how long PgBouncer waits before retrying a backend
connection after a failure. The 15s default is a long time to add to a failover
that Patroni finished in 9 seconds.

---

## The admin console

`SHOW POOLS` is how you find out whether your sizing is right. Getting to it
takes three settings that are **not** in Percona's documentation, and the
default install cannot reach it at all.

```yaml
proxy:
  pgBouncer:
    config:
      global:
        admin_users: ha-cluster
        stats_users: ha-cluster
        auth_dbname: ha-cluster     # <- the non-obvious one
```

Two independent things block you otherwise:

1. The operator forces `client_tls_sslmode = require`, so you must connect with
   `sslmode=require`. A default `prefer` negotiation fails confusingly.
2. The operator writes a wildcard `[databases] * = host=<cluster>-primary` entry
   together with a global `auth_user`. Connecting to the reserved `pgbouncer`
   database then makes PgBouncer try to resolve `auth_dbname` to `pgbouncer`
   itself, which it refuses:

   ```
   ERROR cannot use the reserved "pgbouncer" database as an auth_dbname
   FATAL: bouncer config error
   ```

   Setting `auth_dbname` to a real database fixes it.

Then:

```bash
scripts/connect.sh ha --admin -c 'SHOW POOLS;'
```

```
 database   |    user     | cl_active | cl_waiting | sv_active | sv_idle | pool_mode
------------+-------------+-----------+------------+-----------+---------+------------
 ha-cluster | ha-cluster  |        12 |          0 |        12 |       3 | transaction
```

What to look at:

- **`cl_waiting > 0`** — clients queueing for a backend. Either raise
  `default_pool_size`, or find the query holding backends open. This is latency
  your database-side metrics cannot see.
- **`sv_active` at `default_pool_size`** — the pool is the bottleneck.
- **`maxwait`** — longest current wait, in seconds. Should be 0.

`SHOW STATS`, `SHOW SERVERS`, `SHOW CLIENTS` and `SHOW DATABASES` are also
available. The same credentials are what `pgbouncer_exporter` uses — see
[07-observability.md](07-observability.md).

---

## Changing pool configuration

PgBouncer config is not a restart. The path is:

```
CR patch → ConfigMap (immediate)
         → file in pod (kubelet sync, 20–60s observed)
         → SIGHUP from the pgbouncer-config sidecar
```

Budget about 90 seconds, and confirm rather than assume:

```bash
scripts/connect.sh ha --admin -c 'SHOW CONFIG;' | grep pool_mode
```

Note the layering. The operator generates `~postgres-operator.ini` containing:

```ini
[pgbouncer]
%include /etc/pgbouncer/pgbouncer.ini   ; your overrides — read FIRST
[pgbouncer]
...operator + spec.config.global...     ; read SECOND, therefore WINS
```

Because the include is evaluated first, you cannot override anything the
operator sets by writing to the included file — only add keys it does not set.
Anything in `spec.proxy.pgBouncer.config.global` is merged into the operator's
own section and does take effect. There is an escape hatch — annotate the
ConfigMap with `pgv2.percona.com/override-config=true` — but then you own the
whole file forever.

---

## Failure modes worth knowing

**Double pooling.** Your application framework almost certainly has its own
connection pool. An app pool of 50 per replica across 10 replicas is 500 client
connections before PgBouncer sees anything. Shrink the app-side pool: with
PgBouncer in transaction mode, connections are cheap to acquire, so the app pool
should be small and the pooler should do the work.

**Health checks that open a connection per probe.** At `periodSeconds: 5` across
many replicas this is a surprising amount of churn. Reuse a connection or probe
something cheaper.

**Assuming PgBouncer load-balances reads.** It does not. The `[databases]` entry
points at `<cluster>-primary`, so everything goes to the primary. For read
scaling, point read-only clients at `<cluster>-replicas`, which is a real
ClusterIP Service over the standbys. Verified in `tests/20_ha.bats`.

**Assuming a pooled connection survives a failover transparently.** It does not;
in-flight transactions fail. What PgBouncer gives you is that the *connection
string* stays valid and the next attempt succeeds — measured at under a second
after promotion in `tests/30_failover.bats`. Applications still need retry logic.
