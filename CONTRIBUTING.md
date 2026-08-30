# Contributing

Thanks for looking. The most valuable contribution to a repo like this is
"I followed the docs and it didn't work" — please open an issue with your
Kubernetes flavour and version.

## Development setup

```bash
brew install kubectl helm kind bats-core libpq shellcheck kubeconform
make preflight
```

Docker needs at least 8 GiB. `make preflight` warns if another kind cluster is
competing for the same VM, which is the usual cause of confusing failures.

```bash
make cluster-up && make operator-install && make ha-up
make test
```

## Before opening a PR

```bash
make lint        # shellcheck, YAML parse, kustomize build, kubeconform, bats parse
make test        # against a live cluster
```

CI runs the same `make lint` plus a `dev-standalone` smoke test on a kind
cluster.

## Principles

**Nothing is documented as working unless it was observed working.** Every
number in `docs/` came from a run on a real cluster. If you add a claim, add the
command that demonstrates it — ideally as a bats assertion.

**Document the failure, not just the fix.** `docs/11-troubleshooting.md` is
organised around the symptom you would actually see first, because that is what
you have when you are debugging. A fix without the symptom that led to it is much
less useful.

**Comments explain *why*.** The manifests are full of ordinary Kubernetes fields;
what is not obvious is why a value was chosen, or what breaks with the obvious
alternative. `clusters/ha/cluster.yaml` explains why anti-affinity is `required`
rather than `preferred`, and that is the kind of comment worth adding.

**Prefer honest numbers to flattering ones.** The performance results include the
case where PgBouncer is *slower*, because omitting it would make the rest
misleading.

## Adding a cluster profile

1. Create `clusters/<name>/` with `cluster.yaml` and `kustomization.yaml`.
2. Write the CR out in full. These are deliberately standalone rather than
   kustomize overlays on a shared base — a reader should be able to understand a
   whole topology from one file, and CR list-merge semantics make overlays a
   foot-gun (`instances` and `repos` get replaced wholesale, not merged).
3. Add `<name>-up` / `<name>-down` targets to the `Makefile`.
4. Add a bats suite that skips itself when the profile is not deployed.
5. Document it in `docs/03-topologies.md`, including what it is *not* good for.

## Adding a test suite

```bash
tests/NN_name.bats     # NN orders execution; see the existing files
```

```bash
load helpers/common

setup_file() { require_cluster "$HA_NS" "$HA_CLUSTER"; }
teardown_file() { cleanup_client_pod "$HA_NS"; }

@test "something specific and falsifiable" {
  run sql_pooled "$HA_NS" "$HA_CLUSTER" "select 1;"
  [ "$status" -eq 0 ]
  assert_scalar "$output" "1"
}
```

Helpers live in `tests/helpers/common.bash`: `sql_pooled`, `sql_direct`,
`sql_admin`, `psql_on_pod`, `current_leader`, `retry_until`, and the
`assert_*` family.

**Target bash 3.2.** macOS still ships bash 3.2 as `/bin/bash`, and
`#!/usr/bin/env bash` picks it up unless the contributor has installed a newer
one. `mapfile`, `readarray`, `declare -A` and `${var,,}` are all bash 4+ and
will break `make test` for a large fraction of users. We shipped a `mapfile`
once; it failed instantly on a stock Mac.

Three traps we already hit, so you do not have to:

- **Use `assert_scalar`, not `${output//[^0-9]/}`.** `psql` emits NOTICE lines
  and multi-line errors; stripping non-digits from an error message produces a
  number and a nonsense assertion.
- **`run bash -c "..."` forks a shell that never sourced the helpers.** Call
  helper functions directly, or inline the `kubectl` command.
- **Variables set inside `run` do not survive it.** bats runs the command in a
  subshell. Call the function directly if you need its side effects.

## Pinned versions

All in `scripts/lib.sh`. Bump there and in the cluster manifests together, then
re-run the full suite — image tags appear in both places on purpose, so that a
manifest is readable standalone.

## Code of conduct

Be decent. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
