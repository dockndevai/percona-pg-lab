# Performance harness

```bash
make perf                          # full sweep, regenerates docs/10-performance-results.md
QUICK=1 make perf                  # two client counts only, for a smoke test
DURATION=60 SCALE=50 make perf     # longer runs, larger dataset
```

## What it does

`run-sweep.sh` runs `pgbench` from a pod **inside** the cluster against the `ha`
profile, varying three things:

| Axis | Values |
|---|---|
| target | `direct` (`<cluster>-primary`) vs `pgbouncer` |
| clients | 10, 50, 100, 300 (or 10, 60 with `QUICK=1`) |
| rate | unlimited, and 240 tps |

For each combination it records tps, average latency, and — the number that
actually matters — the **peak count of `client backend` processes on the
primary** during the run.

`report.py` turns the CSV into `docs/10-performance-results.md`.

## Three deliberate choices

**In-cluster, not from the host.** Running `pgbench` on macOS against a kind
cluster adds the Docker network hop to every transaction. On a laptop that hop is
larger than the effect being measured, so host-side numbers say more about Docker
Desktop than about PostgreSQL.

**The rate axis exists on purpose.** At unlimited rate every client is inside a
transaction at all times, so pgBouncer has nothing to multiplex and its only
measurable contribution is one extra network hop. That is a real result, but it
is not the one that describes a real application — which is why the sweep also
runs a rate-limited pass where clients are idle between transactions. Reporting
only the first case is how "pgBouncer made it slower" gets written.

**Idle backends are drained between runs.** `server_idle_timeout` is 180s, far
longer than a run, so without draining each measurement inherits the previous
one's connections. We measured 80 backends for 40 clients before adding this —
the first sign that something was wrong with the harness, not the database.

```sql
select pg_terminate_backend(pid) from pg_stat_activity
 where usename = '<user>' and state = 'idle';
```

## Reading the output

`backends vs clients` in the generated table is the ratio to look at:

- **~1.0x** — no multiplexing. Either clients are saturated, or they are
  bypassing the pooler.
- **well below 1.0x** — the pooler is doing its job. On this lab, 60 rate-limited
  clients produced 15 backends, a 4x reduction at equal throughput.

## Caveats

`pgbench -S` is single-row primary-key lookups — the friendliest possible shape
for a pooler, because transactions are extremely short. A workload with long
transactions holds backends longer and multiplexes worse. That is a property of
your queries, not of pgBouncer, and it is why you should re-run this against
something resembling your own workload before drawing conclusions.

Raw CSVs are kept in `perf/results/` and are gitignored.
