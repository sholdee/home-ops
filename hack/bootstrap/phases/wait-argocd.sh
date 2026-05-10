#!/usr/bin/env bash

wait_statefulset argocd argocd-application-controller
wait_deployment argocd argocd-server
wait_deployment argocd argocd-repo-server
wait_deployment argocd argocd-applicationset-controller

if bool "$DRY_RUN"; then
  log "dry-run: skip wait for applicationset/k3s-apps"
elif ! crd_exists ciliumnetworkpolicies.cilium.io; then
  log "CiliumNetworkPolicy CRD absent; skip wait for real-cluster applicationset/k3s-apps"
else
  kubectl_cmd -n argocd get applicationset/k3s-apps >/dev/null
fi
