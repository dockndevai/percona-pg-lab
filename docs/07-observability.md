# Observability

The operator's native monitoring path is PMM. There is no built-in Prometheus
endpoint. This lab therefore ships two tracks:

| Track | Command | Cost |
|---|---|---|
| Prometheus + Grafana + exporter sidecars (default) | `make obs-up` | ~0.5 CPU / 1.5 GiB |
| PMM 3 (Percona-native, optional) | `make pmm-up` | ~4 GiB for the server alone |

---

## The default track

```bash
make obs-up
make grafana        # prints URLs and the admin password
```

| | |
|---|---|
| Grafana | http://localhost:30300 — `admin` / `pglab` |
| Prometheus | http://localhost:30900 |

Those ports are mapped from the kind control-plane node by
[`kind/pg-lab.yaml`](../kind/pg-lab.yaml).

### Exporters run as sidecars, not a central Deployment

`postgres_exporter` is an `instances[].sidecars` entry and `pgbouncer_exporter` a
`proxy.pgBouncer.sidecars` entry, both declared directly in
[`clusters/ha/cluster.yaml`](../clusters/ha/cluster.yaml). They are full
container specs, so `env`, `ports` and `securityContext` all work.

Sidecars rather than one central scraper, because a central scraper behind a
Service round-robins: it cannot tell the primary from a replica, and it cannot
reach each pooler's own admin console. Both distinctions are the whole point.

They live in the cluster manifest rather than in a separate patch applied by
`make obs-up`, and that is a deliberate correction. `instances`, `proxy` and
`users` are lists, so a strategic-merge patch has to restate each of them in
full — which means two copies of the same block. Ours drifted within an
afternoon and the patch silently reverted resource limits that had been tuned in
the base manifest. One definition, in one place.

### The metrics user must NOT be called `monitor`

Inspecting `pg_hba` on a stock cluster shows what looks like an invitation:

```
host  all  monitor  127.0.0.1  scram-sha-256
host  all  monitor  ::1        scram-sha-256
host  all  monitor  all        reject
```

A monitoring account that can only ever connect from inside the pod. Except
`monitor` is a **reserved** username — declaring it under `spec.users` does
nothing at all:

```
INFO  monitor user is reserved, it'll be ignored.
```

No error, no CR condition, no event, no Secret. The sidecar then wedges in
`CreateContainerConfigError` forever. That `pg_hba` entry belongs to PMM's own
client. So the account is called `pgexporter`:

```yaml
users:
  - name: pgexporter
    options: "pg_monitor"     # read every statistics view, no table data
    password:
      type: AlphaNumeric      # see below
    # no `databases:` — it connects to `postgres` and reads cluster-wide views
```

An ordinary user does not match the loopback-plaintext rule, so it falls through
to the final one — `hostssl all all all scram-sha-256` — and must use TLS even
over loopback:

```yaml
env:
  - name: DATA_SOURCE_URI
    value: "127.0.0.1:5432/postgres?sslmode=require"
  - name: DATA_SOURCE_USER
    valueFrom: {secretKeyRef: {name: ha-cluster-pguser-pgexporter, key: user}}
  - name: DATA_SOURCE_PASS
    valueFrom: {secretKeyRef: {name: ha-cluster-pguser-pgexporter, key: password}}
```

`password.type: AlphaNumeric` is not cosmetic. The default `ASCII` generator
produces passwords containing `@ [ ] / ? :`, all structural in a `postgres://`
URL — which is how `pgbouncer_exporter` takes its DSN. With the default it dies
at startup:

```
parse "postgres://ha-cluster:@[N/MY4[@D*7k^tXLiAy?f>q@127.0.0.1:5432/pgbouncer?...":
missing ']' in host
```

Changing the type does **not** rotate an existing password; delete the Secret and
the operator regenerates it.

Also give both exporter sidecars a numeric `runAsUser`. Their images declare
`USER nobody` — a name — and `runAsNonRoot: true` without a numeric UID makes the
kubelet refuse to start them.

The pgBouncer exporter is the opposite: it needs `sslmode=require` even over
loopback, because the operator forces `client_tls_sslmode=require` on the pooler.
It also needs the admin console to be reachable at all, which takes
`admin_users`, `stats_users` **and** `auth_dbname` — see
[04-connection-pooling.md](04-connection-pooling.md#the-admin-console).

### Scraping

`PodMonitor`, not `ServiceMonitor`. The instance pods sit behind a headless
Service that resolves to whichever pod is currently primary, so a ServiceMonitor
would scrape a moving target and lose per-instance identity.

Relabelling carries the operator's own labels into every series, so a panel can
split primary from replica:

```yaml
relabelings:
  - sourceLabels: [__meta_kubernetes_pod_label_postgres_operator_crunchydata_com_role]
    targetLabel: pg_role
```

**If nothing is being scraped**, the cause is almost always these three values,
which are set in [`observability/kube-prometheus-stack/values.yaml`](../observability/kube-prometheus-stack/values.yaml):

```yaml
serviceMonitorSelectorNilUsesHelmValues: false
podMonitorSelectorNilUsesHelmValues: false
ruleSelectorNilUsesHelmValues: false
```

Without them, Prometheus only picks up monitors carrying its own Helm release
labels and silently ignores everything in other namespaces.

### Changing a sidecar rolls the cluster

Editing `instances[].sidecars` rewrites the StatefulSet, so all three instances
restart one at a time, including a leader handover. Budget several minutes and
do not do it during a benchmark.

Watch out for one consequence: a restarted replica can come back **in archive
recovery** rather than streaming, replaying from pgBackRest before it catches up.
`patronictl list` shows it as `in archive recovery` with a shrinking lag, and
`status.postgres.ready` stays below `size` throughout. That is normal. What is
*not* normal is a lag that never shrinks — see
[11-troubleshooting.md](11-troubleshooting.md#a-replica-is-stuck-in-archive-recovery).

---

## Alerts

[`observability/kube-prometheus-stack/prometheus-rules.yaml`](../observability/kube-prometheus-stack/prometheus-rules.yaml).
Alertmanager is disabled, so these fire visibly in Prometheus rather than paging.

The ones worth understanding:

**`PostgresNoPrimary`** — the condition that actually causes an outage. A cluster
can have every pod `Running` and still be unwritable if no member holds the
leader lease. Pod-level health checks will not tell you this.

**`PgBouncerClientsWaiting`** — the most useful pooling alert there is. Clients
queueing for a backend is latency your database-side metrics cannot see:
`pg_stat_statements` will show perfectly healthy query times while users time
out. Either raise `default_pool_size` or find the query holding backends open.

**`PostgresInstanceDown`** — fires per instance, so during a normal failover you
should expect exactly one for about a minute. Two at once on a three-node
cluster means you have lost quorum.

**`PostgresTransactionIDWraparoundRisk`** — slow-moving and catastrophic;
PostgreSQL shuts down to protect itself at 2 billion. 200 million is early enough
to fix calmly. Usual causes: a long-running transaction, an abandoned replication
slot, or `hot_standby_feedback` holding back the xmin horizon — note that the HA
profile turns that on deliberately.

**`PostgresConnectionsNearLimit`** — on a cluster that has PgBouncer in front of
it, suspect clients bypassing the pooler before you suspect genuine load.

---

## What to watch

| Question | Metric |
|---|---|
| Is there a primary? | `count(pg_up{pg_role="primary"} == 1)` |
| How far behind are the standbys? | `pg_stat_replication_pg_wal_lsn_diff` |
| Are clients queueing for a backend? | `pgbouncer_pools_client_waiting_connections` |
| Is the pool the bottleneck? | `pgbouncer_pools_server_active_connections` vs `default_pool_size` |
| Are we near `max_connections`? | `pg_stat_activity_count / pg_settings_max_connections` |
| Is the cache working? | `blks_hit / (blks_hit + blks_read)` |
| Is autovacuum keeping up? | `pg_database_xid_age` |

The backend count is the one to put on a wall. It is what decides whether you run
out of connections, and it is the number connection pooling exists to control —
see [10-performance-results.md](10-performance-results.md).

---

## PMM (optional)

```bash
make pmm-up
```

PMM is Percona's own stack and integrates through `spec.pmm`:

```yaml
pmm:
  enabled: true
  image: docker.io/percona/pmm-client:3.7.1
  secret: ha-cluster-pmm-secret
  serverHost: monitoring-service
```

It gives you Percona's query analytics and dashboards without writing any of the
above yourself. It is opt-in here purely because PMM Server wants roughly 4 GiB
on its own, which does not coexist comfortably with an HA cluster on a laptop.

PMM 3 authenticates with a service-account token (PMM 2 used API keys and is
end-of-life). Put it in the referenced Secret as `PMM_SERVER_TOKEN`.

`make pmm-down` removes it.
