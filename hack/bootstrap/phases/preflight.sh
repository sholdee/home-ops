#!/usr/bin/env bash

tools=(bash kubectl helm kustomize yq jq git)
if ! bool "$SEED_SECRET_STDIN"; then
  tools+=(op)
fi

for tool in "${tools[@]}"; do
  require_tool "$tool"
done

for path in \
  apps/argocd/kustomization.yaml \
  apps/argocd/manifests/apps.yaml \
  apps/external-secrets/kustomization.yaml \
  apps/cert-manager/kustomization.yaml; do
  [[ -f "${REPO_ROOT}/${path}" ]] || die "missing expected repo file: ${path}"
done

print_target_cluster
write_inventory

log "repo root: ${REPO_ROOT}"
log "profile: ${BOOTSTRAP_PROFILE}"
log "dry-run: ${DRY_RUN}"
log "field manager: ${FIELD_MANAGER}"
log "report dir: ${REPORT_DIR}"
log "phases: ${PHASES[*]}"

if ! bool "$YES"; then
  printf 'Proceed with bootstrap against this cluster? Type yes: '
  read -r answer
  [[ "$answer" == yes ]] || die "confirmation declined"
fi
