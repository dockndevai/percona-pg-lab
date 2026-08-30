# Security

## This is a lab

This repository is a teaching and experimentation environment. It deliberately
contains configuration that is **not safe for production**:

* Hard-coded MinIO credentials (`pglabaccess` / `pglabsecretkey123`)
* A self-signed MinIO certificate with `repo2-storage-verify-tls: "n"`
* A fixed Grafana admin password (`pglab`)
* `synchronous_commit: off` in the `dev-standalone` profile
* Services exposed via NodePort with no authentication in front of them

Do not copy these values into a real cluster. Where a setting is unsafe, the
manifest says so in a comment next to it.

## What we do get right, and you should too

* No private keys are committed. `scripts/minio-up.sh` generates the MinIO
  certificate at deploy time.
* The monitoring user is granted `pg_monitor` and no database access, and the
  operator's `pg_hba` rule restricts it to loopback.
* Exporter sidecars run with `readOnlyRootFilesystem`, `runAsNonRoot`,
  `allowPrivilegeEscalation: false` and all capabilities dropped.

## Reporting a vulnerability

If you find a security issue in this repository's own content, please open an
issue. For vulnerabilities in the Percona Operator itself, report them to
[Percona](https://www.percona.com/security) rather than here.
