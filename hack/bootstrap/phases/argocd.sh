#!/usr/bin/env bash

wait_crd applications.argoproj.io
wait_crd applicationsets.argoproj.io
wait_crd appprojects.argoproj.io

render="${TMP_DIR}/argocd.yaml"
render_kustomize_app apps/argocd > "$render"

if ! crd_exists ciliumnetworkpolicies.cilium.io; then
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
