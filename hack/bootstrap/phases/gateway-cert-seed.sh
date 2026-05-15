#!/usr/bin/env bash

case "$BOOTSTRAP_PROFILE" in
  foundation|lima-longhorn)
    log "${BOOTSTRAP_PROFILE} profile: skip gateway cert seed"
    ;;
  *)

    ensure_namespace gateway

    render="${TMP_DIR}/gateway-cert-seed-render.yaml"
    seed="${TMP_DIR}/gateway-cert-seed.yaml"

    render_kustomize_app apps/gateway > "$render"
    yq '
  select(
    (.apiVersion == "external-secrets.io/v1" and .kind == "ClusterSecretStore" and .metadata.name == "gateway-cert-backups") or
    (
      .apiVersion == "external-secrets.io/v1" and
      .kind == "ExternalSecret" and
      (
        .metadata.name == "external-wildcard-restore" or
        .metadata.name == "mgmt-wildcard-restore" or
        .metadata.name == "guest-wildcard-restore"
      )
    )
  )
' "$render" > "$seed"

    [[ -s "$seed" ]] || die "failed to render gateway cert seed resources"

    apply_file "$seed"
    save_render_if_safe gateway-cert-seed "$seed"

    wait_clustersecretstore_ready gateway-cert-backups
    wait_secret_keys gateway external-wildcard tls.crt tls.key
    wait_secret_keys gateway mgmt-wildcard tls.crt tls.key
    wait_secret_keys gateway guest-wildcard tls.crt tls.key
    ;;
esac
