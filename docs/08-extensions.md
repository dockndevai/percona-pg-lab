# Extensions and plugins

```bash
make extensions-up
```

> **`make ha-up` undoes this.** Extensions are applied as a patch on top of
> `clusters/ha/cluster.yaml`, which does not itself contain a `spec.extensions`
> block — so re-applying the profile removes them and the operator drops the
> extensions. Re-run `make extensions-up` afterwards. They are kept separate
> because enabling extensions triggers a rolling restart, and `make ha-up`
> should not do that implicitly.

## Two kinds

```yaml
spec:
  extensions:
    builtin:                 # shipped in the image, just toggled on
      pg_stat_statements: true
      pg_stat_monitor: true
      pg_audit: true
      pgvector: true
      pg_repack: false
    custom:                  # downloaded at pod start from object storage
      - name: pg_cron
        version: 1.6.1
    storage:
      type: s3
      bucket: pg-extensions
      endpoint: s3.eu-central-1.amazonaws.com
      region: eu-central-1
      secret:
        name: cluster1-extensions-secret
```

`builtin` extensions are already in the Percona Distribution image; the toggle
just makes them available. `custom` extensions are fetched from an object store
you provide and unpacked into the instance at startup — which means the pod
cannot start if the object store is unreachable. That is a new hard dependency in
your startup path; weigh it.

<a id="the-ordering-trap"></a>
<a id="only-one-preload-extension-at-a-time"></a>

## Only one preload extension at a time

This is the single most important thing to know about extensions on operator
v3.0.0, and it is not documented upstream.

**`spec.extensions.builtin` sets `shared_preload_libraries` to exactly ONE
library.** It does not build a list. Enable two extensions that both need
preloading and only one is installed — the other is skipped with no error, no
event, and no CR condition.

Measured, with `pg_audit`, `pg_stat_monitor` and `pg_stat_statements` all set
to `true`:

```
show shared_preload_libraries;
 pg_stat_monitor                    -- one library, not three

select extname from pg_extension;
 pg_stat_monitor | vector | plpgsql -- pg_stat_statements and pgaudit missing

select * from pg_stat_statements;
 ERROR:  pg_stat_statements must be loaded via "shared_preload_libraries"
```

With `pg_stat_statements` alone:

```
show shared_preload_libraries;
 pg_stat_statements

select count(*) from pg_stat_statements;   -- works
```

**Setting `shared_preload_libraries` yourself does not work around it.** The
operator appends to your value and then overwrites it on the next reconcile. We
watched it pass through

```
pg_stat_statements,pg_stat_monitor,pgaudit,pg_stat_monitor
```

before settling back to a single entry.

So: pick one. `pgvector` needs no preloading and can always be enabled alongside.
This lab ships `pg_stat_statements` + `pgvector`;
`tests/80_extensions.bats` asserts that exactly one library is preloaded, so if a
future operator release fixes this the test will tell you.

## The trap underneath it

Even for the extension that *does* get installed, there are two separate steps
and they fail differently:

```
1. spec.extensions.builtin        makes the library available (needs a RESTART)
2. CREATE EXTENSION               per database, by you
```

`CREATE EXTENSION` can succeed while the library is not loaded. You then have a
row in `pg_extension` and a view that errors on every query. Always check the
extension *works*, not that it exists:

```sql
select count(*) >= 0 from pg_stat_statements;   -- the real test
```

**And do not trust `SHOW shared_preload_libraries` immediately after a change.**
It returns the *running* value, which stays stale until PostgreSQL actually
restarts — so it shows the old list and looks as though the operator ignored
you. Wait for the restart to land:

```sql
select name, setting, pending_restart from pg_settings
 where name = 'shared_preload_libraries';
```

`scripts/extensions-up.sh` polls `pending_restart` for exactly this reason.

**Flipping a builtin from `true` to `false` DROPS the extension.** The list is
declarative, not additive.

## `CREATE EXTENSION` is per database

Nothing creates extensions for you. Each database needs its own:

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS vector;
```

Note `vector`, not `pgvector` — the extension's SQL name differs from the project
name, which trips people up regularly.

Check what is installed vs available:

```sql
select extname, extversion from pg_extension order by extname;
select name, default_version, installed_version
  from pg_available_extensions where installed_version is not null;
```

## The ones worth enabling

**`pg_stat_statements`** — normalised per-query-shape statistics. The foundation
of every "why is the database slow" investigation. Costs a little shared memory
and is worth it on every cluster.

```sql
select calls, round(mean_exec_time::numeric, 2) as ms, query
from pg_stat_statements order by total_exec_time desc limit 10;
```

Raise `pg_stat_statements.max` above the 5000 default on a pooled workload — many
distinct prepared-statement shapes evict entries faster than you would think.

**`pg_stat_monitor`** — Percona's richer alternative: time-bucketed aggregation,
histograms, percentiles, client IP. Verified working on this lab — but **not at
the same time as `pg_stat_statements`**, because of the one-library limit above.
Choose it when you need to know *when* something happened rather than just the
cumulative totals.

**`pgaudit`** — session and object audit logging. Also preload-requiring, so it
too competes for the single slot. If you need audit logging, it likely wins over
query statistics.

```yaml
pgaudit.log: "ddl"
```

Start with `ddl`. Setting it to `all` on a busy cluster produces more log volume
than you have disk, which is a genuinely common way to take a database down.

**`pgvector`** — vector similarity search.

```sql
CREATE EXTENSION vector;
CREATE TABLE items (id bigserial primary key, embedding vector(3));
INSERT INTO items (embedding) VALUES ('[1,2,3]'), ('[4,5,6]');
SELECT id, embedding <-> '[3,1,2]' AS distance FROM items ORDER BY distance LIMIT 5;
```

**`pg_repack`** — rebuilds a bloated table without holding a long exclusive lock.
No preload needed. Off by default here because it also wants a client binary.

## Extensions and connection pooling

Anything session-scoped interacts badly with `pool_mode: transaction`.
`pg_cron` runs in the background on the server and is unaffected, but extensions
that rely on session state, `LISTEN`/`NOTIFY`, or session-level advisory locks
will behave intermittently through a transaction-mode pooler. See the
compatibility table in
[04-connection-pooling.md](04-connection-pooling.md#pool-modes).

## Extensions and upgrades

A major-version upgrade must find every extension's library present in the *new*
image. Custom extensions have to be rebuilt for the new major version and
uploaded before the upgrade runs, or `pg_upgrade` fails partway through.
