#!/usr/bin/env bash

wait_crd applications.argoproj.io
wait_crd applicationsets.argoproj.io
wait_crd appprojects.argoproj.io

render="${TMP_DIR}/argocd.yaml"
render_kustomize_app apps/argocd > "$render"

prepare_hubble_takeover() {
  log "applying Hubble cert-manager issuer chain before Cilium takeover"
  apply_file "${REPO_ROOT}/apps/kube-system/cilium/manifests/hubble/certificates.yaml"
  wait_certificate_ready kube-system cilium-hubble-ca
  BOOTSTRAP_RESTART_CILIUM_FOR_HUBBLE_CERTS=false
  if delete_secret_unless_cert_manager_issuer kube-system hubble-server-certs cilium-hubble-ca; then
    BOOTSTRAP_RESTART_CILIUM_FOR_HUBBLE_CERTS=true
  fi
  if delete_secret_unless_cert_manager_issuer kube-system hubble-relay-client-certs cilium-hubble-ca; then
    BOOTSTRAP_RESTART_CILIUM_FOR_HUBBLE_CERTS=true
  fi
  export BOOTSTRAP_RESTART_CILIUM_FOR_HUBBLE_CERTS
}

if [[ "$BOOTSTRAP_PROFILE" == foundation ]]; then
  log "foundation profile: applying ArgoCD with only explicit foundation applications"
  prepare_hubble_takeover

  filtered="${TMP_DIR}/argocd-foundation.yaml"
  yq '
    select(
      .apiVersion != "argoproj.io/v1alpha1" or
      .kind != "ApplicationSet"
    ) |
    select(
      .apiVersion != "argoproj.io/v1alpha1" or
      .kind != "Application" or
      (
        .metadata.name == "cilium" or
        .metadata.name == "dragonfly-operator"
      )
    ) |
    select(
      .apiVersion != "gateway.networking.k8s.io/v1" or
      .kind != "HTTPRoute"
    )
  ' "$render" > "$filtered"
  render="$filtered"
  foundation_filtered="${TMP_DIR}/argocd-foundation-values.yaml"
  yq '
    (
      . |
      select(.apiVersion == "argoproj.io/v1alpha1" and .kind == "Application" and .metadata.name == "dragonfly-operator") |
      .spec.source.helm.valuesObject.serviceMonitor.enabled
    ) = false |
    (
      . |
      select(.apiVersion == "argoproj.io/v1alpha1" and .kind == "Application" and .metadata.name == "dragonfly-operator") |
      .spec.source.helm.valuesObject.grafanaDashboard.enabled
    ) = false
  ' "$render" > "$foundation_filtered"
  render="$foundation_filtered"
  if [[ "${BOOTSTRAP_LIMA:-false}" == true ]]; then
    log "Lima profile: keeping Cilium masquerading enabled for user-mode networking"
    lima_filtered="${TMP_DIR}/argocd-foundation-lima.yaml"
    yq '
      (
        . |
        select(.apiVersion == "argoproj.io/v1alpha1" and .kind == "Application" and .metadata.name == "cilium") |
        .spec.source.helm.valuesObject.enableIPv4Masquerade
      ) = true |
      (
        . |
        select(.apiVersion == "argoproj.io/v1alpha1" and .kind == "Application" and .metadata.name == "cilium") |
        .spec.source.helm.valuesObject.bpf.masquerade
      ) = true
    ' "$render" > "$lima_filtered"
    render="$lima_filtered"
  fi
elif crd_exists ciliumnetworkpolicies.cilium.io; then
  log "applying ArgoCD without ApplicationSet/k3s-apps until Cilium is ready"
  prepare_hubble_takeover
  filtered="${TMP_DIR}/argocd-before-k3s-apps.yaml"
  yq '
    select(
      .apiVersion != "argoproj.io/v1alpha1" or
      .kind != "ApplicationSet" or
      .metadata.name != "k3s-apps"
    )
  ' "$render" > "$filtered"
  render="$filtered"
elif ! crd_exists ciliumnetworkpolicies.cilium.io; then
  log "CiliumNetworkPolicy CRD absent; omitting real-cluster-only ArgoCD resources from local apply"
  filtered="${TMP_DIR}/argocd-no-cilium.yaml"
  yq '
    select(.apiVersion != "cilium.io/v2") |
    select(
      .apiVersion != "argoproj.io/v1alpha1" or
      .kind != "ApplicationSet" or
      .metadata.name != "k3s-apps"
    ) |
    select(
      .apiVersion != "argoproj.io/v1alpha1" or
      .kind != "Application" or
      (
        .metadata.name != "cilium" and
        .metadata.name != "cilium-preflight" and
        .metadata.name != "crd-schema-publisher" and
        .metadata.name != "longhorn"
      )
    )
  ' "$render" > "$filtered"
  render="$filtered"
fi

apply_file "$render"
log "canonical ArgoCD app applied"
