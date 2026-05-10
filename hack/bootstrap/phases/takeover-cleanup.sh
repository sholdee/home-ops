#!/usr/bin/env bash

cleanup_release_storage() {
  local namespace="$1"
  local release="$2"
  log "checking Helm release storage for ${namespace}/${release}"
  if bool "$DRY_RUN"; then
    kubectl_cmd -n "$namespace" get secret -l "owner=helm,name=${release}" -o name || true
    kubectl_cmd -n "$namespace" get configmap -l "owner=helm,name=${release}" -o name || true
    return
  fi
  kubectl_cmd -n "$namespace" delete secret -l "owner=helm,name=${release}" --ignore-not-found
  kubectl_cmd -n "$namespace" delete configmap -l "owner=helm,name=${release}" --ignore-not-found
}

cleanup_release_storage kube-system cilium
cleanup_release_storage argocd argocd

log "takeover cleanup intentionally leaves chart-rendered labels and annotations intact"
