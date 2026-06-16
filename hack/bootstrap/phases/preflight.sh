#!/usr/bin/env bash

tools=(bash kubectl helm kustomize yq jq git drydock)
if ! bool "$SEED_SECRET_STDIN"; then
  tools+=(op)
fi

for tool in "${tools[@]}"; do
  require_tool "$tool"
done

# drydock renders every bootstrap app; require the version with the cert-manager
# leaderelection fix (#152) and the capability/scope/serialization hardening.
require_drydock_version 0.2.1

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

if [[ "$BOOTSTRAP_PROFILE" =~ ^lima-(apps|longhorn)$ && "${BOOTSTRAP_LIMA:-false}" != true ]]; then
  die "${BOOTSTRAP_PROFILE} profile is only supported through the Lima bootstrap harness"
fi

if [[ "$BOOTSTRAP_PROFILE" =~ ^lima-(apps|longhorn)$ && "${BOOTSTRAP_LIMA:-false}" == true ]] && ! bool "$DRY_RUN"; then
  min_nodes=3
  min_cpu=3
  min_memory_gib=5
  min_storage_gib=100
  if [[ "$BOOTSTRAP_PROFILE" == lima-longhorn ]]; then
    min_nodes=4
    min_memory_gib=3
    min_storage_gib=60
  fi

  node_inventory="$(kubectl_cmd get nodes -o json)"
  schedulable_nodes="$(
    jq '
      [
        .items[]
        | select(.spec.unschedulable != true)
        | select(([.spec.taints[]? | select(.effect == "NoSchedule" or .effect == "NoExecute")] | length) == 0)
      ] | length
    ' <<<"$node_inventory"
  )"
  large_nodes="$(
    jq --argjson min_cpu "$min_cpu" --argjson min_memory_kib "$((min_memory_gib * 1024 * 1024))" '
      def cpu_cores:
        if test("m$") then (sub("m$"; "") | tonumber) / 1000
        else tonumber
        end;
      [
        .items[]
        | select(.spec.unschedulable != true)
        | select(([.spec.taints[]? | select(.effect == "NoSchedule" or .effect == "NoExecute")] | length) == 0)
        | select((.status.allocatable.cpu | cpu_cores) >= $min_cpu)
        | select((.status.allocatable.memory | sub("Ki$"; "") | tonumber) >= $min_memory_kib)
      ] | length
    ' <<<"$node_inventory"
  )"
  storage_nodes="$(
    jq --argjson min_storage_bytes "$((min_storage_gib * 1024 * 1024 * 1024))" '
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
        | select((.status.allocatable["ephemeral-storage"] | quantity_bytes) >= $min_storage_bytes)
      ] | length
    ' <<<"$node_inventory"
  )"
  [[ "$schedulable_nodes" -ge "$min_nodes" ]] ||
    die "${BOOTSTRAP_PROFILE} profile requires at least ${min_nodes} schedulable nodes; found ${schedulable_nodes}"
  [[ "$large_nodes" -ge "$min_nodes" ]] ||
    die "${BOOTSTRAP_PROFILE} profile requires at least ${min_nodes} schedulable nodes with >=${min_cpu} CPU and >=${min_memory_gib}Gi allocatable memory; found ${large_nodes}"
  [[ "$storage_nodes" -ge "$min_nodes" ]] ||
    die "${BOOTSTRAP_PROFILE} profile requires at least ${min_nodes} schedulable nodes with >=${min_storage_gib}Gi allocatable ephemeral storage; found ${storage_nodes}"
fi

if ! bool "$YES"; then
  printf 'Proceed with bootstrap against this cluster? Type yes: '
  read -r answer
  [[ "$answer" == yes ]] || die "confirmation declined"
fi
