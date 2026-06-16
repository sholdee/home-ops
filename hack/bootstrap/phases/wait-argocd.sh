#!/usr/bin/env bash

# shellcheck source=hack/bootstrap/lima/apps.sh
source "${BOOTSTRAP_DIR}/lima/apps.sh"
# shellcheck source=hack/bootstrap/lima/longhorn.sh
source "${BOOTSTRAP_DIR}/lima/longhorn.sh"

wait_statefulset argocd argocd-application-controller
wait_deployment argocd argocd-server
wait_deployment argocd argocd-repo-server
wait_deployment argocd argocd-applicationset-controller

wait_application_synced() {
  local app="$1"
  local status
  for _ in $(seq 1 60); do
    status="$(kubectl_cmd -n argocd get "application/${app}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    if [[ "$status" == Synced ]]; then
      return 0
    fi
    sleep 5
  done

  kubectl_cmd -n argocd describe "application/${app}" || true
  die "timed out waiting for ArgoCD application/${app} to sync"
}

wait_application_ready() {
  local app="$1"
  local sync health
  for _ in $(seq 1 60); do
    sync="$(kubectl_cmd -n argocd get "application/${app}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl_cmd -n argocd get "application/${app}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [[ "$sync" == Synced && "$health" == Healthy ]]; then
      return 0
    fi
    sleep 5
  done

  kubectl_cmd -n argocd describe "application/${app}" || true
  die "timed out waiting for ArgoCD application/${app} to become Synced/Healthy"
}

wait_application_operation_healthy() {
  local app="$1"
  local phase health
  for _ in $(seq 1 60); do
    phase="$(kubectl_cmd -n argocd get "application/${app}" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    health="$(kubectl_cmd -n argocd get "application/${app}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [[ "$phase" == Succeeded && "$health" == Healthy ]]; then
      return 0
    fi
    sleep 5
  done

  kubectl_cmd -n argocd describe "application/${app}" || true
  die "timed out waiting for ArgoCD application/${app} to complete sync and become Healthy"
}

refresh_applications() {
  kubectl_cmd -n argocd annotate applications.argoproj.io \
    "$@" \
    argocd.argoproj.io/refresh=hard \
    --overwrite
}

wait_cilium_ready_for_k3s_apps() {
  kubectl_cmd -n argocd get application/cilium >/dev/null
  refresh_applications cilium
  wait_application_synced cilium
  wait_certificate_ready kube-system hubble-server-certs
  wait_certificate_ready kube-system hubble-relay-client-certs
  if bool "${BOOTSTRAP_RESTART_CILIUM_FOR_HUBBLE_CERTS:-false}"; then
    log "restarting Cilium and Hubble relay to load reissued Hubble certs"
    kubectl_cmd -n kube-system rollout restart daemonset/cilium
    kubectl_cmd -n kube-system rollout restart deployment/hubble-relay
    kubectl_cmd -n kube-system rollout status daemonset/cilium --timeout=240s
    kubectl_cmd -n kube-system rollout status deployment/hubble-relay --timeout=240s
  fi
  wait_application_ready cilium
}

wait_platform_applications_for_k3s_apps() {
  local apps=(dragonfly-operator snapshot-controller grafana-operator longhorn reloader volsync)
  log "refreshing explicit platform applications before applying applicationset/k3s-apps"
  refresh_applications "${apps[@]}"
  local app
  for app in "${apps[@]}"; do
    wait_application_operation_healthy "$app"
  done
}

wait_snapshot_controller() {
  if crd_exists volumesnapshotclasses.snapshot.storage.k8s.io &&
    crd_exists volumesnapshotcontents.snapshot.storage.k8s.io &&
    crd_exists volumesnapshots.snapshot.storage.k8s.io &&
    kubectl_cmd -n kube-system get deployment/snapshot-controller >/dev/null 2>&1; then
    log "snapshot controller already exists; waiting for readiness"
    wait_deployment kube-system snapshot-controller
    return
  fi

  kubectl_cmd -n argocd get application/snapshot-controller >/dev/null
  refresh_applications snapshot-controller
  wait_application_operation_healthy snapshot-controller
  wait_crd volumesnapshotclasses.snapshot.storage.k8s.io
  wait_crd volumesnapshotcontents.snapshot.storage.k8s.io
  wait_crd volumesnapshots.snapshot.storage.k8s.io
  wait_deployment kube-system snapshot-controller
}

apply_k3s_apps_appset() {
  local render appset lima_appset
  local stage="${1:-full}"
  render="${TMP_DIR}/argocd-k3s-apps-render.yaml"
  appset="${TMP_DIR}/argocd-k3s-apps.yaml"
  drydock_app argocd > "$render"
  yq '
    select(
      .apiVersion == "argoproj.io/v1alpha1" and
      .kind == "ApplicationSet" and
      .metadata.name == "k3s-apps"
    )
  ' "$render" > "$appset"
  [[ -s "$appset" ]] || die "failed to render ApplicationSet/k3s-apps"
  if [[ "$BOOTSTRAP_PROFILE" == lima-apps ]]; then
    lima_appset="${TMP_DIR}/argocd-k3s-apps-lima-${stage}.yaml"
    write_lima_apps_appset "$appset" "$lima_appset" "$stage"
    appset="$lima_appset"
  fi
  apply_file "$appset"
}

if bool "$DRY_RUN"; then
  log "dry-run: skip wait for applicationset/k3s-apps"
elif [[ "$BOOTSTRAP_PROFILE" == foundation ]]; then
  log "foundation profile: skip wait for applicationset/k3s-apps"
  kubectl_cmd -n argocd get application/dragonfly-operator >/dev/null
  log "refresh foundation ArgoCD applications"
  kubectl_cmd -n argocd annotate applications.argoproj.io \
    dragonfly-operator \
    argocd.argoproj.io/refresh=hard \
    --overwrite
  wait_cilium_ready_for_k3s_apps
  wait_application_ready dragonfly-operator
elif [[ "$BOOTSTRAP_PROFILE" == lima-longhorn ]]; then
  log "lima-longhorn profile: wait for Cilium and Longhorn without applying applicationset/k3s-apps"
  kubectl_cmd -n argocd get application/dragonfly-operator >/dev/null
  kubectl_cmd -n argocd get application/longhorn >/dev/null
  log "refresh Lima Longhorn profile ArgoCD applications"
  refresh_applications dragonfly-operator snapshot-controller longhorn
  wait_cilium_ready_for_k3s_apps
  wait_application_ready dragonfly-operator
  wait_application_operation_healthy snapshot-controller
  wait_application_operation_healthy longhorn
  log "waiting for snapshot controller and applying Longhorn lifecycle test storage classes"
  wait_snapshot_controller
  apply_lima_longhorn_storage_manifests
  log "applying Lima Longhorn checksum workload"
  apply_lima_longhorn_workload
  wait_lima_longhorn_workload_ready
  wait_lima_longhorn_volume_healthy || die "timed out waiting for Lima Longhorn checksum volume to become healthy"
elif [[ "$BOOTSTRAP_PROFILE" == lima-apps ]]; then
  lima_workloads_released=false
  log "waiting for Cilium and explicit operators before applying sanitized applicationset/k3s-apps"
  wait_cilium_ready_for_k3s_apps
  wait_platform_applications_for_k3s_apps
  log "waiting for snapshot controller before VolSync restore workloads"
  wait_snapshot_controller
  log "applying Lima safety admission policies"
  apply_lima_apps_safety_policies
  if lima_apps_workloads_released; then
    lima_workloads_released=true
    log "existing Lima workload applications detected; applying full sanitized applicationset/k3s-apps without infra narrowing"
    apply_k3s_apps_appset
  else
    log "applying sanitized infra applicationset/k3s-apps for lima-apps"
    apply_k3s_apps_appset infra
  fi
  kubectl_cmd -n argocd get applicationset/k3s-apps >/dev/null
  for app in cert-manager cnpg-system envoy-gateway-system external-secrets gateway kube-system longhorn-system; do
    wait_application_operation_healthy "$app"
  done
  if [[ "$lima_workloads_released" == false ]]; then
    log "applying sanitized workload applicationset/k3s-apps for lima-apps"
    apply_k3s_apps_appset
    kubectl_cmd -n argocd get applicationset/k3s-apps >/dev/null
  fi
elif ! crd_exists ciliumnetworkpolicies.cilium.io; then
  log "CiliumNetworkPolicy CRD absent; skip wait for real-cluster applicationset/k3s-apps"
else
  log "waiting for Cilium, Hubble certs, and platform applications before applying applicationset/k3s-apps"
  wait_cilium_ready_for_k3s_apps
  wait_platform_applications_for_k3s_apps
  log "waiting for snapshot controller before VolSync restore workloads"
  wait_snapshot_controller
  log "applying applicationset/k3s-apps after platform prerequisites are ready"
  apply_k3s_apps_appset
  kubectl_cmd -n argocd get applicationset/k3s-apps >/dev/null
fi
