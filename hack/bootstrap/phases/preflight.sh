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

if [[ "$BOOTSTRAP_PROFILE" == lima-apps && "${BOOTSTRAP_LIMA:-false}" != true ]]; then
  die "lima-apps profile is only supported through the Lima bootstrap harness"
fi

if [[ "$BOOTSTRAP_PROFILE" == lima-apps && "${BOOTSTRAP_LIMA:-false}" == true ]] && ! bool "$DRY_RUN"; then
  node_inventory="$(kubectl_cmd get nodes -o json)"
  schedulable_workers="$(
    jq '
      [
        .items[]
        | select(.spec.unschedulable != true)
        | select(([.spec.taints[]? | select(.effect == "NoSchedule" or .effect == "NoExecute")] | length) == 0)
      ] | length
    ' <<<"$node_inventory"
  )"
  large_workers="$(
    jq '
      [
        .items[]
        | select(.spec.unschedulable != true)
        | select(([.spec.taints[]? | select(.effect == "NoSchedule" or .effect == "NoExecute")] | length) == 0)
        | select((.status.allocatable.cpu | tonumber) >= 4)
        | select((.status.allocatable.memory | sub("Ki$"; "") | tonumber) >= (5 * 1024 * 1024))
      ] | length
    ' <<<"$node_inventory"
  )"
  storage_workers="$(
    jq '
      def quantity_bytes:
        if test("Ki$") then (sub("Ki$"; "") | tonumber) * 1024
        elif test("Mi$") then (sub("Mi$"; "") | tonumber) * 1024 * 1024
        elif test("Gi$") then (sub("Gi$"; "") | tonumber) * 1024 * 1024 * 1024
        else tonumber
        end;
      [
        .items[]
        | select(.spec.unschedulable != true)
        | select(([.spec.taints[]? | select(.effect == "NoSchedule" or .effect == "NoExecute")] | length) == 0)
        | select((.status.allocatable["ephemeral-storage"] | quantity_bytes) >= (100 * 1024 * 1024 * 1024))
      ] | length
    ' <<<"$node_inventory"
  )"
  [[ "$schedulable_workers" -ge 3 ]] ||
    die "lima-apps profile requires at least 3 schedulable worker nodes; found ${schedulable_workers}"
  [[ "$large_workers" -ge 3 ]] ||
    die "lima-apps profile requires at least 3 schedulable workers with >=4 CPU and >=5Gi allocatable memory; found ${large_workers}"
  [[ "$storage_workers" -ge 3 ]] ||
    die "lima-apps profile requires at least 3 schedulable workers with >=100Gi allocatable ephemeral storage; found ${storage_workers}"
fi

if ! bool "$YES"; then
  printf 'Proceed with bootstrap against this cluster? Type yes: '
  read -r answer
  [[ "$answer" == yes ]] || die "confirmation declined"
fi
