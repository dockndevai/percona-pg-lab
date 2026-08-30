# Troubleshooting

Every entry here is a failure that actually happened while building this lab,
with the symptom you would see first and how it was diagnosed. They are ordered
roughly by how long they took to work out.

---

## The first thing to check, always

The CR status tells you almost nothing when reconciliation is broken. The
operator log tells you everything:

```bash
kubectl -n pg-operator logs deploy/pg-operator --tail=500 | grep -i error
```

A cluster stuck in `state: initializing` with no pods and no events on the CR is
*always* worth this command before anything else.

---

## Poisoned stanza: a standby restores, reports ready, and never replicates

**Symptom.** A newly created DR standby reaches `state: ready`, `pgbackrest info`
says `status: ok`, and `pg_last_wal_replay_lsn()` never moves. The PostgreSQL
log repeats:

```
LOG:  waiting for WAL to become available at 0/1E000018
```

**Diagnosis.** Compare timelines on both sides:

```bash
# on the standby
psql -U postgres -tAc 'select timeline_id from pg_control_checkpoint();'   # -> 8
# on the real primary
psql -U postgres -tAc 'select timeline_id from pg_control_checkpoint();'   # -> 6
```

The standby is *ahead* of the primary, which is impossible for a real standby.

**Cause.** A previously promoted standby was still pointed at the source
cluster's `repo2-path`. Every PostgreSQL instance runs with `archive_mode=on`,
so once promoted it forked to a new timeline and began archiving its own WAL
into the shared stanza:

```
wal archive min/max (18): 000000060000000000000012/00000008000000000000001D
                          ^^^^^^^^ primary       ^^^^^^^^ promoted standby
```

The next standby built from that repository restores the newest backup — which
belongs to the promoted cluster — and then waits for WAL only that cluster could
produce.

This is nasty because every individual signal is green: `recovery_target_timeline`
is already `latest`, the `restore_command` is correct, pgBackRest reports `ok`,
and the operator reports `ready`.

**Fix.** Never let a promoted cluster keep the source repository path.
`scripts/dr-promote.sh` sets `standby.enabled: false` and `repo2-path` in a
single patch for exactly this reason. Giving the standby an *additional* local
repo does not help — `archive-push` writes to every configured repo.

To recover a repository that is already poisoned:

```bash
scripts/dr-repo-clean.sh      # wipes repo2 and takes a fresh full backup
```

---

## Duplicate topologySpreadConstraints stop reconciliation dead

**Symptom.** `PerconaPGCluster` sits at `state: initializing` indefinitely. PVCs
exist. There are **no pods and no StatefulSets**, and no events on the CR.

**Diagnosis.** Only visible in the operator log:

```
failed to create typed patch object (pg-ha/ha-cluster-instance1-g9w2;
apps/v1, Kind=StatefulSet): .spec.template.spec.topologySpreadConstraints:
duplicate entries for key [topologyKey="topology.kubernetes.io/zone",
whenUnsatisfiable="ScheduleAnyway"]
```

**Cause.** The operator already injects two spread constraints on every instance
StatefulSet:

| maxSkew | topologyKey | whenUnsatisfiable |
|---|---|---|
| 1 | `kubernetes.io/hostname` | `ScheduleAnyway` |
| 1 | `topology.kubernetes.io/zone` | `ScheduleAnyway` |

Server-side apply keys this list by `(topologyKey, whenUnsatisfiable)`, so adding
your own with the same pair is a merge-key collision and the whole reconcile
aborts.

**Fix.** Rely on the injected defaults, or use a different `whenUnsatisfiable`.
For a hard guarantee of one instance per node, use `podAntiAffinity` with
`requiredDuringSchedulingIgnoredDuringExecution` instead — spread constraints
with `ScheduleAnyway` only nudge the scheduler. See `clusters/ha/cluster.yaml`.

---

## Tables land in a per-user schema, not `public`

**Symptom.** You create a table as the application user, then connect as
`postgres` and it "does not exist".

```
ERROR:  relation "sync_probe" does not exist
```

**Diagnosis.**

```sql
select schemaname, tablename, tableowner from pg_tables where tablename = 'sync_probe';
--  ha-cluster | sync_probe | ha-cluster
```

**Cause.** `spec.autoCreateUserSchema` defaults to **true** and is not present in
the upstream sample CR, so it is invisible unless you go looking. The operator
creates a schema named after each user, and PostgreSQL's default `search_path`
is `"$user", public`. An unqualified `CREATE TABLE` therefore lands in the
per-user schema. Connecting as `postgres` yields a different `search_path` and
the table appears to vanish.

**Why it matters beyond confusion.** Migration tools that assume `public` will
happily create a second, empty set of tables next to your real ones.

**Fix — pick one deliberately:**

```yaml
spec:
  autoCreateUserSchema: false          # tables go to public
```
```yaml
spec:
  users:
    - name: appuser
      grantPublicSchemaAccess: true    # keep the schema, allow public too
```
```sql
ALTER ROLE appuser SET search_path = public;
```

---

## Cannot reach the pgBouncer admin console

**Symptom.**

```
FATAL:  bouncer config error
FATAL:  SSL required
```

**Cause.** Two independent blockers. The operator forces
`client_tls_sslmode = require`, and it writes a wildcard `[databases]` entry plus
a global `auth_user` — so connecting to the reserved `pgbouncer` database makes
PgBouncer resolve `auth_dbname` to `pgbouncer` itself:

```
ERROR cannot use the reserved "pgbouncer" database as an auth_dbname
```

**Fix.**

```yaml
proxy:
  pgBouncer:
    config:
      global:
        admin_users: ha-cluster
        stats_users: ha-cluster
        auth_dbname: ha-cluster   # must name a REAL database
```

and connect with `sslmode=require`. Full detail in
[04-connection-pooling.md](04-connection-pooling.md#the-admin-console).

---

## Failing backup Job on a standby cluster

**Symptom.** A standby cluster is healthy and replaying, but a backup Job
retries forever:

```
ERROR: [056]: unable to find primary cluster - cannot proceed
HINT: are all available clusters in recovery?
```

**Cause.** The operator schedules a `replica-create` pgBackRest job on every new
cluster. A standby has no primary, so it can never succeed.

**Fix.** Restrict the replica-create method on the standby:

```yaml
spec:
  patroni:
    createReplicaMethods:
      - basebackup
```

The operator then stops creating the job. There is no knob for this under
`backups.pgbackrest.jobs` — that block only carries pod-spec fields.

---

## pgBouncer config changes appear not to apply

**Not a bug, just latency.** The path is CR → ConfigMap (immediate) → file in pod
(kubelet sync, **20–60s observed**) → `SIGHUP` from the `pgbouncer-config`
sidecar. Budget ~90 seconds, then verify rather than assume:

```bash
scripts/connect.sh ha --admin -c 'SHOW CONFIG;' | grep pool_mode
```

If a setting *never* appears, check you are not trying to override something the
operator sets itself — the generated file evaluates your include **before** its
own section, so the operator always wins. See
[04-connection-pooling.md](04-connection-pooling.md#changing-pool-configuration).

---

## `role=master` selects nothing

The role label value is **`primary`**, not `master`:

```bash
kubectl get pods -l postgres-operator.crunchydata.com/role=primary
```

Plenty of Crunchy-era blog posts still say `master`. That selector returns an
empty list with no error, which then quietly breaks whatever script depends on
it.

---

## "Failover took 0 seconds" — it did not

`kubectl delete pod <primary>` sends `SIGTERM`, which Patroni catches and turns
into a **graceful handover**: it demotes itself and passes the leader key on
before exiting. That is a switchover, not a failure.

To test actual failure:

```bash
kubectl delete pod <primary> --force --grace-period=0
```

Measured on this lab: timeline advanced in 9s, writes through pgBouncer resumed
within 1s of that, no committed rows lost.

Also note: **pod names are not a failover signal.** Each instance is its own
single-replica StatefulSet, so a killed pod is recreated with the identical name
and can win the next election. Use the timeline instead:

```sql
select timeline_id from pg_control_checkpoint();
```

```bash
patronictl -c /etc/patroni/~postgres-operator_cluster.yaml history
patronictl -c /etc/patroni/~postgres-operator_cluster.yaml list
```

---

## pgBackRest cannot reach MinIO

pgBackRest speaks S3 over **HTTPS only** — there is no plain-HTTP mode. MinIO
must serve TLS. `scripts/minio-up.sh` generates a self-signed certificate and the
clusters set `repo2-storage-verify-tls: "n"`.

Also set `repo2-s3-uri-style: path` for MinIO. Real AWS S3 wants `host`; getting
this wrong produces DNS failures for `<bucket>.<endpoint>`.

---

## A standby never finds the primary's backups

`repo2-path` must be **byte-identical** on both clusters. A typo does not error —
pgBackRest simply initialises an empty stanza, and you get a cluster that comes
up ready and holds none of your data.

Verify it really restored, rather than trusting `ready`:

```bash
kubectl -n pg-dr exec <standby-pod> -c database -- \
  psql -U postgres -d <source-db> -tAc \
  "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema');"
```

---

## PVC resize does nothing on kind

kind's default `standard` StorageClass (`rancher.io/local-path`) has
`allowVolumeExpansion: false`. Growing `dataVolumeClaimSpec` is silently
ineffective. This is a kind limitation, not an operator one.

---

## Everything is slow / pods are OOMKilled

Usually another kind cluster competing for the same Docker VM.

```bash
make preflight                                  # warns about this explicitly
docker stop $(docker ps -q --filter name=<other-cluster>-)
```

The lab profiles are sized for roughly 3 CPU and 5 GiB of *requests* with HA plus
monitoring. Below 8 GiB allocated to Docker, expect trouble.

---

## The `monitor` username is reserved

**Symptom.** An exporter sidecar sits in `CreateContainerConfigError` forever:

```
Error: secret "ha-cluster-pguser-monitor" not found
```

**Cause.** The operator ships a `pg_hba` rule that looks like an open invitation:

```
host  all  monitor  127.0.0.1  scram-sha-256
host  all  monitor  ::1        scram-sha-256
host  all  monitor  all        reject
```

But `monitor` is **reserved**. Declaring it under `spec.users` does nothing —
the operator logs this at INFO and moves on:

```
INFO  monitor user is reserved, it'll be ignored.
```

No error, no CR condition, no event. The secret is simply never created. That
`pg_hba` entry belongs to PMM's own client.

**Fix.** Name the exporter user something else — this lab uses `pgexporter` —
and connect over TLS, because an ordinary user matches the final rule
(`hostssl all all all scram-sha-256`) rather than the loopback-plaintext one:

```yaml
users:
  - name: pgexporter
    options: "pg_monitor"
```
```yaml
env:
  - name: DATA_SOURCE_URI
    value: "127.0.0.1:5432/postgres?sslmode=require"   # require, not disable
```

`tests/90_observability.bats` asserts that `spec.users` never contains `monitor`,
so nobody "fixes" this back to the obvious name.

---

## Exporter sidecars fail with "non-numeric user (nobody)"

**Symptom.**

```
Error: container has runAsNonRoot and image has non-numeric user (nobody),
cannot verify user is non-root
```

**Cause.** Both Prometheus community exporter images declare `USER nobody` — a
*name*, not a UID. With `runAsNonRoot: true` and no `runAsUser`, the kubelet
cannot prove the name is not root, so it refuses to start the container.

**Fix.** Give it a numeric UID alongside `runAsNonRoot`:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  runAsGroup: 65534
```

---

## A failed backup leaves a Job retrying forever

**Symptom.** A namespace filling with `ha-cluster-backup-xxxx` pods in `Error`,
long after the underlying problem was fixed.

**Cause.** A `PerconaPGBackup` that failed keeps its Job retrying. The operator
does not garbage-collect them, so a backup that failed against (say) a missing
stanza keeps failing against the now-working one.

**Fix.** Delete the failed `PerconaPGBackup` objects:

```bash
kubectl -n pg-ha get pg-backup
kubectl -n pg-ha delete pg-backup <name>
kubectl -n pg-ha delete pods --field-selector=status.phase==Failed
```

`scripts/dr-repo-clean.sh` does this automatically.

---

## `stanza-create` after wiping a repository

If you empty a pgBackRest repository out of band, restarting the repo host is
**not** enough — the operator only runs `stanza-create` at cluster-creation time.
The next backup fails with:

```
ERROR: [055]: unable to load info file '.../backup.info'
HINT: has a stanza-create been performed?
```

Run it yourself. Note it operates on every configured repo and *rejects*
`--repo=N`:

```bash
kubectl -n pg-ha exec sts/ha-cluster-repo-host -c pgbackrest -- \
  pgbackrest --stanza=db stanza-create
```

---

## Exporter DSN breaks on a generated password

**Symptom.** `pgbouncer_exporter` starts and immediately dies:

```
level=ERROR msg="failed to create connector"
  error="parse \"postgres://ha-cluster:@[N/MY4[@D*7k^tXLiAy?f>q@127.0.0.1:5432/pgbouncer?sslmode=require\":
  missing ']' in host"
```

**Cause.** `spec.users[].password.type` defaults to `ASCII`, which generates
passwords containing `@ [ ] / ? :` — every one of which is structural in a
`postgres://` URL. The exporter takes its DSN as a URL, so the password
terminates the userinfo section early and the rest is parsed as a hostname.

**Fix.** For any user whose password ends up inside a URL, ask for an
alphanumeric one:

```yaml
users:
  - name: pgexporter
    password:
      type: AlphaNumeric
```

URL-encoding the password in shell is possible but fragile — removing the class
of characters is not.

**Changing `password.type` does not rotate an existing password.** The operator
only generates one when the Secret has none. To force it:

```bash
kubectl -n pg-ha delete secret ha-cluster-pguser-pgexporter
# the operator recreates it within ~60s, using the new type
```

That is also the rotation procedure in general, and it means the application
must re-read its credentials — so it is not free.

---

## A replica is stuck "in archive recovery"

**Symptom.** The cluster sits at `state: initializing` with `2/3` ready.
`patronictl list` shows one member with a lag that never shrinks:

```
| ha-cluster-instance1-vnpw-0 | Replica | in archive recovery | 6 | 0/2F000000 | 64 |
```

**Diagnosis.** The replica's own PostgreSQL log, not the operator log:

```bash
kubectl -n pg-ha exec <pod> -c database -- \
  sh -c 'ls -t /pgdata/pg18/log/*.log | head -1 | xargs tail -30'
```

```
FATAL:  highest timeline 6 of the primary is behind recovery timeline 7
LOG:    waiting for WAL to become available at 0/2F000018
```

**Cause.** The replica is on a timeline the current leader never took — usually
because it was briefly promoted during a rolling restart and the cluster then
settled on a different leader. PostgreSQL cannot reconcile a diverged timeline;
the replica waits for WAL that will never exist.

**Fix.** Let Patroni rebuild it automatically:

```yaml
spec:
  patroni:
    removeDataDirectoryOnDivergedTimelines: true
```

This is set in `clusters/ha/cluster.yaml`. Note what it means: the diverged
replica's data directory is **destroyed** and rebuilt from the leader. For a
replica that is correct — its data is unreachable by definition. Do not assume
the same is safe for a former primary you might want to examine.

To recover one that is already wedged:

```bash
kubectl -n pg-ha exec <any-healthy-pod> -c database -- \
  patronictl -c /etc/patroni/~postgres-operator_cluster.yaml \
  reinit ha-cluster-ha <stuck-pod-name> --force
```

Note the odd argument order: the Patroni *scope* (`<cluster>-ha`) comes first,
then the member name.

---

## `spec.users[].options` cannot grant role membership

**Symptom.** You declare a metrics user with `pg_monitor` and it does not have
it. Replication-lag panels stay blank and `pg_stat_activity` hides other
sessions' query text, while the exporter reports perfectly healthy.

```sql
select r.rolname from pg_auth_members m
  join pg_roles r on r.oid = m.roleid
  join pg_roles u on u.oid = m.member
 where u.rolname = 'pgexporter';
-- (0 rows)
```

**Cause.** `options` is applied as `ALTER ROLE` **attributes** — `SUPERUSER`,
`CREATEDB`, `LOGIN` and friends. Role *membership* is not an attribute, so both
of these are accepted silently and do nothing:

```yaml
options: "pg_monitor"           # no effect
options: "IN ROLE pg_monitor"   # also no effect
```

No error, no log line. Worse, `options` is only applied when the role is
**created** — editing it on an existing user does nothing either.

**Fix.** Issue the grant explicitly. It is idempotent:

```bash
kubectl -n pg-ha exec <primary-pod> -c database -- \
  psql -U postgres -c 'GRANT pg_monitor TO pgexporter;'
```

`scripts/obs-up.sh` does this, and `tests/90_observability.bats` asserts the
membership exists so a silent regression is caught.

---

## Tests that pass for the wrong reason

Two worth knowing about, because both bit us:

**A benchmark that did not run.** `tests/40_pgbouncer.bats` asserts that 60
pooled clients produce *fewer than* 45 backends. On a freshly rebuilt cluster the
`pgbench_*` tables did not exist, so `pgbench` exited instantly, no backends were
opened, and a peak of **1** satisfied the assertion. The test now also asserts a
*lower* bound, and initialises the dataset in `setup_file`.

The general lesson: any assertion of the form "fewer than N" needs a companion
assertion that the work actually happened.

**Racing the operator.** `repo1 exists and holds a valid backup` failed against a
perfectly healthy repository, because "cluster ready" and "first backup
finished" are different moments. It now waits for `status: ok` rather than
sampling once.

---

## Only one extension gets preloaded

**Symptom.** You enable several extensions under `spec.extensions.builtin` and
only one appears. The others produce:

```
ERROR:  pg_stat_statements must be loaded via "shared_preload_libraries"
```

even though the CR says `pg_stat_statements: true`.

**Cause.** In operator v3.0.0, `spec.extensions.builtin` sets
`shared_preload_libraries` to exactly **one** library. It does not build a list.
The others are silently skipped — no error, no event, no CR condition.

**Fix.** Enable one preload-requiring extension. `pgvector` needs no preloading
and can be enabled alongside. Full detail and the measurements in
[08-extensions.md](08-extensions.md#only-one-preload-extension-at-a-time).

Setting `shared_preload_libraries` yourself under
`patroni.dynamicConfiguration` does not help: the operator appends to it and
then overwrites it on the next reconcile.

---

## `SHOW shared_preload_libraries` lies right after a change

It returns the **running** value, which stays stale until PostgreSQL restarts.
Checked too early it shows the old list, making it look as though the operator
ignored your change. We chased that for a while.

```sql
select name, setting, pending_restart from pg_settings
 where name = 'shared_preload_libraries';
```

`pending_restart = t` means staged, not applied. Wait for `f`.

---

## `spec.patroni.switchover` does nothing

**Symptom.** You set it, the CR accepts it, and no switchover happens.

```yaml
spec:
  patroni:
    switchover:
      enabled: true
      type: Switchover
```

**Observed on operator v3.0.0:** no leader change and no operator log entry at
all, over five minutes, with and without `targetInstance`.

**Fix.** Drive it through `patronictl`:

```bash
kubectl -n pg-ha exec <leader-pod> -c database -- \
  patronictl -c /etc/patroni/~postgres-operator_cluster.yaml \
  switchover ha-cluster-ha --leader <leader-pod> --candidate <sync-standby> --force
```

The first argument is the Patroni **scope** (`<cluster>-ha`), not the cluster
name — a common source of "cluster not found".

---

## `candidate name does not match with sync_standby`

```
Switchover failed, details: 412, candidate name does not match with sync_standby
```

Not a bug. With `synchronous_mode: true`, Patroni will only promote the current
**synchronous** standby. The async replica may be behind, so promoting it would
be a data-loss event disguised as a planned operation.

```sql
select application_name, sync_state from pg_stat_replication;
```

Use the row where `sync_state = 'sync'` as your candidate.

---

## Prometheus briefly shows two primaries

**Not a split brain.** Prometheus keeps returning a series for up to its
staleness window (5 minutes by default) after the target stops reporting it. For
a few minutes after a switchover or failover you therefore see both the new
primary's series and the old one's:

```promql
count(pg_up{pg_role="primary"} == 1)   -- 2, briefly
```

This is why `PostgresTooManyPrimaries` has `for: 1m` rather than firing
instantly, and why `tests/90_observability.bats` retries this assertion.

To check the truth right now, ask Kubernetes or Patroni, not Prometheus:

```bash
kubectl -n pg-ha get pods -l postgres-operator.crunchydata.com/role=primary
```

---

## `pg_control_checkpoint()` reports a stale timeline

It reflects the last **checkpoint** — a *restartpoint* on a standby — so it lags.
Reading the timeline from a freshly promoted node can return a *lower* number
than the node it was promoted from.

It is still the right signal for detecting that a **failover** happened, because
pod names recur and you have nothing better. It is the wrong signal immediately
after a **switchover**, where you named the candidate and can simply check who
holds the primary role.

For a reliable current timeline, use Patroni:

```bash
patronictl -c /etc/patroni/~postgres-operator_cluster.yaml list   # TL column
```
