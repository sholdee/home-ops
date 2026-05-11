#!/usr/bin/env bash

namespace="$(app_value dragonfly-operator '.spec.destination.namespace')"
ensure_namespace "$namespace"

values="${TMP_DIR}/dragonfly-operator-values.yaml"
render="${TMP_DIR}/dragonfly-operator.yaml"
write_app_values dragonfly-operator "$values"
if [[ "$BOOTSTRAP_PROFILE" == foundation ]]; then
  log "foundation profile: disabling Dragonfly operator monitoring and dashboard resources"
  yq -i '
    .serviceMonitor.enabled = false |
    .grafanaDashboard.enabled = false
  ' "$values"
fi
helm_template_app dragonfly-operator "$values" > "$render"
apply_file "$render"
save_render_if_safe dragonfly-operator "$render"

wait_crd dragonflies.dragonflydb.io
wait_deployment "$namespace" dragonfly-operator
