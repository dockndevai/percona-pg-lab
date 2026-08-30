# percona-pg-lab — single entrypoint for every workflow in this repo.
#
#   make help          list every target
#   make up            cluster + operator + HA profile, end to end
#   make test          run the bats suite against whatever is deployed
#
# Every target is idempotent. Every target shells out to scripts/ so that the
# same thing works outside make (CI, or a copy-paste into your terminal).

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

KIND_CLUSTER   ?= pg-lab
KUBE_CONTEXT   ?= kind-$(KIND_CLUSTER)
export KIND_CLUSTER KUBE_CONTEXT

K := kubectl --context $(KUBE_CONTEXT)

##@ Help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	  /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""

##@ Cluster lifecycle

.PHONY: preflight
preflight: ## Check tooling and resource headroom before anything else
	@scripts/preflight.sh

.PHONY: cluster-up
cluster-up: preflight ## Create the 4-node kind cluster (idempotent)
	@scripts/cluster-up.sh

.PHONY: cluster-down
cluster-down: ## Delete the kind cluster entirely
	kind delete cluster --name $(KIND_CLUSTER)

.PHONY: operator-install
operator-install: ## Install the Percona PostgreSQL operator (cluster-wide)
	@scripts/operator-install.sh

.PHONY: up
up: cluster-up operator-install ha-up ## Full path: cluster + operator + HA profile

##@ Database profiles (run one at a time — see docs/03-topologies.md)

.PHONY: dev-up
dev-up: ## Deploy the single-instance dev profile into pg-dev
	@scripts/profile.sh up dev-standalone pg-dev dev-cluster

.PHONY: dev-down
dev-down: ## Remove the dev profile and its volumes
	@scripts/profile.sh down dev-standalone pg-dev dev-cluster

.PHONY: ha-up
ha-up: ## Deploy the 3-instance HA profile into pg-ha (drops extensions — see extensions-up)
	@scripts/profile.sh up ha pg-ha ha-cluster

.PHONY: ha-down
ha-down: ## Remove the HA profile and its volumes
	@scripts/profile.sh down ha pg-ha ha-cluster

.PHONY: minio-up
minio-up: ## Deploy MinIO as the S3 backup target (prerequisite for dr-up)
	@scripts/minio-up.sh

.PHONY: s3-repo
s3-repo: ## Attach the MinIO-backed pgBackRest repo (repo2) to the HA cluster
	@scripts/s3-repo-up.sh

.PHONY: dr-up
dr-up: ## Deploy the DR standby cluster into pg-dr (requires ha-up + minio-up + s3-repo)
	@scripts/dr-up.sh

.PHONY: dr-promote
dr-promote: ## Promote the DR standby to a writable primary
	@scripts/dr-promote.sh

.PHONY: dr-down
dr-down: ## Remove the DR standby profile
	@scripts/profile.sh down dr-standby pg-dr dr-cluster

.PHONY: dr-repo-clean
dr-repo-clean: ## DESTRUCTIVE: wipe and rebuild repo2 (fixes a poisoned stanza)
	@scripts/dr-repo-clean.sh

##@ Observability

.PHONY: obs-up
obs-up: ## Install kube-prometheus-stack + exporters + dashboards
	@scripts/obs-up.sh

.PHONY: obs-down
obs-down: ## Remove the monitoring stack
	helm --kube-context $(KUBE_CONTEXT) uninstall kps -n monitoring || true
	$(K) delete ns monitoring --ignore-not-found

.PHONY: grafana
grafana: ## Print the Grafana URL and admin password
	@scripts/grafana-info.sh

.PHONY: pmm-up
pmm-up: ## OPTIONAL: install PMM 3 server and point the HA cluster at it (~4Gi)
	@scripts/pmm-up.sh

.PHONY: pmm-down
pmm-down: ## Remove PMM
	helm --kube-context $(KUBE_CONTEXT) uninstall pmm -n pmm || true
	$(K) delete ns pmm --ignore-not-found

##@ Admission policies (see docs/15-admission-policies.md)

.PHONY: policy-install
policy-install: ## Install the ValidatingAdmissionPolicies and label env namespaces
	@scripts/policy-install.sh

.PHONY: policy-check
policy-check: ## Report which existing clusters would be rejected — changes nothing
	@scripts/policy-install.sh --check

.PHONY: policy-test
policy-test: ## Run the admission policy suite (17 assertions)
	@scripts/run-tests.sh 95_admission_policy.bats

.PHONY: policy-uninstall
policy-uninstall: ## Remove the admission policies
	@scripts/policy-uninstall.sh

##@ Environment promotion pipeline (see docs/14-cicd-promotion.md)

.PHONY: env-render
env-render: ## Render every environment overlay and validate it
	@scripts/env-render.sh

.PHONY: env-dev-up
env-dev-up: ## Deploy the dev environment overlay into app-dev
	$(K) get ns app-dev >/dev/null 2>&1 || $(K) create ns app-dev
	$(K) apply -k environments/dev
	$(K) -n app-dev wait --for=jsonpath='{.status.state}'=ready pg/app-pg --timeout=15m

.PHONY: env-dev-down
env-dev-down: ## Remove the dev environment overlay
	-$(K) delete -k environments/dev --ignore-not-found
	-$(K) -n app-dev delete pvc --all --ignore-not-found

##@ AI agent access (MCP)

.PHONY: mcp-config
mcp-config: ## Print MCP client config pointed at this lab (read-only)
	@scripts/mcp-config.sh

##@ Extensions

.PHONY: extensions-up
extensions-up: ## Enable the builtin extension set on the HA cluster (re-run after ha-up)
	@scripts/extensions-up.sh

##@ Backup / restore

.PHONY: backup
backup: ## Take an on-demand full backup of the HA cluster
	@scripts/backup.sh

.PHONY: pitr-demo
pitr-demo: ## End-to-end point-in-time-recovery demonstration (DESTRUCTIVE)
	@scripts/pitr-demo.sh

.PHONY: upgrade-demo-up
upgrade-demo-up: ## Deploy a PostgreSQL 17 cluster to rehearse a major upgrade on
	@scripts/profile.sh up upgrade-demo pg-upgrade upgrade-cluster

.PHONY: upgrade-demo-run
upgrade-demo-run: ## Run the 17 -> 18 major version upgrade (DOWNTIME, not rolling)
	$(K) -n pg-upgrade apply -f clusters/upgrade-demo/upgrade.yaml
	@echo "watch:  kubectl -n pg-upgrade get pg-upgrade upgrade-17-to-18 -w"

.PHONY: upgrade-demo-down
upgrade-demo-down: ## Remove the upgrade rehearsal cluster
	@scripts/profile.sh down upgrade-demo pg-upgrade upgrade-cluster

##@ Testing and benchmarking

.PHONY: test
test: ## Run the full bats suite (expects the relevant profiles to be up)
	@scripts/run-tests.sh

.PHONY: test-quick
test-quick: ## Run only the operator + HA suites
	@scripts/run-tests.sh 00_operator.bats 20_ha.bats

.PHONY: perf
perf: ## Run the pgbench sweep and regenerate docs/10-performance-results.md
	@perf/run-sweep.sh

.PHONY: lint
lint: ## shellcheck + yaml + manifest validation
	@scripts/lint.sh

##@ Utilities

.PHONY: psql
psql: ## Open an interactive psql session through pgBouncer on the HA cluster
	@scripts/connect.sh ha

.PHONY: status
status: ## Show everything the lab currently has deployed
	@scripts/status.sh

.PHONY: failover
failover: ## Kill the current primary and watch Patroni elect a new one
	@scripts/chaos-failover.sh

.PHONY: down
down: ## Remove all database profiles and monitoring, keep the kind cluster
	-$(MAKE) dr-down
	-$(MAKE) upgrade-demo-down
	-$(MAKE) ha-down
	-$(MAKE) dev-down
	-$(MAKE) obs-down
	-$(MAKE) pmm-down
	-$(K) delete ns pg-backup --ignore-not-found

.PHONY: nuke
nuke: cluster-down ## Delete absolutely everything including the kind cluster
	@echo "gone."
