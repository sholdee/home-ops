#!/usr/bin/env bash

overlay="${TMP_DIR}/argocd-dependencies"
mkdir -p "$overlay"
write_argocd_dependencies_overlay "$overlay"

render="${TMP_DIR}/argocd-dependencies.yaml"
kustomize build --load-restrictor LoadRestrictionsNone "$overlay" > "$render"
apply_file "$render"

wait_secret argocd argocd-dragonfly-auth

if bool "$DRY_RUN"; then
  log "dry-run: skip Dragonfly workload readiness"
else
  kubectl_cmd -n argocd wait --for=condition=Ready pod -l app=dragonfly --timeout=240s || {
    log "Dragonfly pod readiness by label failed; dumping pods"
    kubectl_cmd -n argocd get pods
    die "Dragonfly did not become ready"
  }
fi
