#!/usr/bin/env bash

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

wait_cilium_ready_for_k3s_apps() {
  kubectl_cmd -n argocd get application/cilium >/dev/null
  kubectl_cmd -n argocd annotate applications.argoproj.io \
    cilium \
    argocd.argoproj.io/refresh=hard \
    --overwrite
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

apply_k3s_apps_appset() {
  local render appset
  render="${TMP_DIR}/argocd-k3s-apps-render.yaml"
  appset="${TMP_DIR}/argocd-k3s-apps.yaml"
  render_kustomize_app apps/argocd > "$render"
  yq '
    select(
      .apiVersion == "argoproj.io/v1alpha1" and
      .kind == "ApplicationSet" and
      .metadata.name == "k3s-apps"
    )
  ' "$render" > "$appset"
  [[ -s "$appset" ]] || die "failed to render ApplicationSet/k3s-apps"
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
elif ! crd_exists ciliumnetworkpolicies.cilium.io; then
  log "CiliumNetworkPolicy CRD absent; skip wait for real-cluster applicationset/k3s-apps"
else
  log "waiting for Cilium and Hubble certs before applying applicationset/k3s-apps"
  wait_cilium_ready_for_k3s_apps
  log "applying applicationset/k3s-apps after Cilium is ready"
  apply_k3s_apps_appset
  kubectl_cmd -n argocd get applicationset/k3s-apps >/dev/null
fi
