#!/usr/bin/env bash

overlay="${TMP_DIR}/cert-manager-overlay"
mkdir -p "$overlay"
write_cert_manager_chart_overlay "$overlay"

render="${TMP_DIR}/cert-manager.yaml"
kustomize build --enable-helm --load-restrictor LoadRestrictionsNone "$overlay" > "$render"
apply_file "$render"
save_render_if_safe cert-manager "$render"

wait_deployment cert-manager cert-manager
wait_deployment cert-manager cert-manager-cainjector
wait_deployment cert-manager cert-manager-webhook
