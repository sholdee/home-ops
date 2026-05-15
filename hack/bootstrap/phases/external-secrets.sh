#!/usr/bin/env bash

charts_render="${TMP_DIR}/external-secrets-charts.yaml"
{
  cat "${REPO_ROOT}/apps/external-secrets/manifests/namespace.yaml"
  helm_template_kustomization_chart "${REPO_ROOT}/apps/external-secrets/kustomization.yaml" external-secrets
  helm_template_kustomization_chart "${REPO_ROOT}/apps/external-secrets/kustomization.yaml" connect
} > "$charts_render"
strategy_render="${TMP_DIR}/external-secrets-charts-strategy.yaml"
yq '(. | select(.kind == "Deployment" and .metadata.name == "onepassword-connect").spec.strategy) = {
  "type": "RollingUpdate",
  "rollingUpdate": {
    "maxSurge": 0,
    "maxUnavailable": 1
  }
}' "$charts_render" > "$strategy_render"
charts_render="$strategy_render"
apply_file "$charts_render"
save_render_if_safe external-secrets-charts "$charts_render"

wait_deployment external-secrets external-secrets
wait_secret_keys external-secrets external-secrets-webhook ca.crt tls.crt tls.key
wait_deployment external-secrets external-secrets-webhook
wait_deployment external-secrets external-secrets-cert-controller
wait_deployment external-secrets onepassword-connect

render="${TMP_DIR}/external-secrets.yaml"
render_kustomize_app apps/external-secrets > "$render"
apply_file "$render"
save_render_if_safe external-secrets "$render"

wait_clustersecretstore_ready onepassword-connect

cert_render="${TMP_DIR}/cert-manager-full.yaml"
render_kustomize_app apps/cert-manager > "$cert_render"
if [[ "$BOOTSTRAP_PROFILE" =~ ^lima-(apps|longhorn)$ ]]; then
  cert_lima_render="${TMP_DIR}/cert-manager-lima-apps.yaml"
  yq '
    select(
      (
        .apiVersion == "external-secrets.io/v1" and
        .kind == "ExternalSecret" and
        .metadata.name == "cloudflare-api-token-secret"
      ) | not
    ) |
    select(
      (
        .apiVersion == "cert-manager.io/v1" and
        .kind == "ClusterIssuer" and
        .metadata.name == "cloudflare"
      ) | not
    )
  ' "$cert_render" > "$cert_lima_render"
  cert_render="$cert_lima_render"
fi
apply_file "$cert_render"
log "full cert-manager app applied after External Secrets readiness"
