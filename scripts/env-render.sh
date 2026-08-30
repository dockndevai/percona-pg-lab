#!/usr/bin/env bash
# Render and validate every environment overlay.
#
# This is the pull-request gate from docs/14-cicd-promotion.md: it needs no
# cluster, runs in seconds, and catches most of what goes wrong before anything
# is applied anywhere.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail=0
for dir in "${REPO_ROOT}"/environments/*/; do
  env_name="$(basename "$dir")"
  [[ "$env_name" == "base" ]] && continue
  [[ -f "${dir}kustomization.yaml" ]] || continue

  if ! rendered="$(kubectl kustomize "$dir" 2>&1)"; then
    echo "  ✗ ${env_name}: kustomize build failed" >&2
    printf '      %s\n' "${rendered//$'\n'/$'\n      '}" >&2
    fail=1; continue
  fi

  if command -v kubeconform >/dev/null 2>&1; then
    printf '%s' "$rendered" | kubeconform -strict -ignore-missing-schemas - >/dev/null 2>&1 \
      || { echo "  ✗ ${env_name}: kubeconform failed" >&2; fail=1; continue; }
  fi

  # Policy checks. A schema validator cannot catch a bad idea, so encode the
  # rules that actually matter for this pipeline.
  summary="$(printf '%s' "$rendered" | python3 -c "
import sys, yaml
d = yaml.safe_load(sys.stdin)
sp = d['spec']
env = '${env_name}'
errs = []

insts = sp['instances'][0]['replicas']
repos = [r['name'] for r in sp['backups']['pgbackrest']['repos']]
sync  = sp.get('patroni', {}).get('dynamicConfiguration', {}).get('synchronous_mode', False)
scommit = sp['patroni']['dynamicConfiguration']['postgresql']['parameters'].get('synchronous_commit')
glob = sp['backups']['pgbackrest'].get('global', {})

if env == 'prod':
    if insts < 3:  errs.append(f'prod needs >=3 instances, has {insts}')
    if not sync:   errs.append('prod needs synchronous_mode: true')
    if not any('s3' in r or 'gcs' in r or 'azure' in r
               for r in sp['backups']['pgbackrest']['repos']):
        errs.append('prod needs an off-cluster backup repo — a PVC-only prod has no DR')
if env != 'dev' and scommit == 'off':
    errs.append(f'synchronous_commit=off is only acceptable in dev, not {env}')
for r in repos:
    if f'{r}-retention-full' not in glob:
        errs.append(f'{r} has no retention policy — the volume will fill silently')

print('ERRORS:' + '|'.join(errs) if errs else
      f'OK:instances={insts} pgbouncer={sp[\"proxy\"][\"pgBouncer\"][\"replicas\"]} '
      f'repos={\",\".join(repos)} sync={sync}')
" 2>&1)"

  if [[ "$summary" == ERRORS:* ]]; then
    echo "  ✗ ${env_name}" >&2
    tr '|' '\n' <<< "${summary#ERRORS:}" | sed 's/^/      /' >&2
    fail=1
  else
    printf '  %s✓%s %-9s %s\n' "$C_GRN" "$C_OFF" "$env_name" "${summary#OK:}" >&2
  fi
done

(( fail == 0 )) || die "environment validation failed"
ok "all environment overlays render and pass policy"
