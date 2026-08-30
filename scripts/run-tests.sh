#!/usr/bin/env bash
# Run the bats suites in dependency order.
#
#   scripts/run-tests.sh                       # everything that applies
#   scripts/run-tests.sh 20_ha.bats            # just one suite
#   TAP=1 scripts/run-tests.sh                 # TAP output for CI
#
# Suites skip themselves when their profile isn't deployed, so this is safe to
# run at any point.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need bats

cd "${REPO_ROOT}/tests" || die "cannot enter tests directory"

if (( $# > 0 )); then
  suites=("$@")
else
  # `mapfile` is bash 4+ and macOS still ships bash 3.2 as /bin/bash, so
  # `make test` with no arguments died with "mapfile: command not found" for
  # anyone who had not installed a newer bash. Portable equivalent:
  suites=()
  while IFS= read -r f; do
    suites+=("$f")
  done < <(find . -maxdepth 1 -name '*.bats' -exec basename {} \; | sort)
fi

(( ${#suites[@]} )) || die "no test suites found"

log "running ${#suites[@]} suite(s) against ${KUBE_CONTEXT}"

args=(--print-output-on-failure)
[[ "${TAP:-0}" == "1" ]] && args+=(--formatter tap13)
[[ "${VERBOSE:-0}" == "1" ]] && args+=(--verbose-run)

bats "${args[@]}" "${suites[@]}"
