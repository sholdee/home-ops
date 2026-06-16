#!/usr/bin/env bash

namespace="$(app_value dragonfly-operator '.spec.destination.namespace')"
ensure_namespace "$namespace"

render="${TMP_DIR}/dragonfly-operator.yaml"
drydock_app dragonfly-operator > "$render"
if [[ "$BOOTSTRAP_PROFILE" == foundation ]]; then
  log "foundation profile: dropping Dragonfly operator monitoring and dashboard resources"
  # drydock renders the chart's monitoring/dashboard resources (gated on chart values,
  # not cluster capability), but the foundation profile has no Prometheus/Grafana
  # operator. Drop the exact set helm omits when serviceMonitor.enabled=false and
  # grafanaDashboard.enabled=false: the ServiceMonitor, GrafanaDashboard, the dashboard
  # ConfigMap, and the metrics-reader ClusterRoleBinding.
  yq -i '
    select(
      .kind != "ServiceMonitor" and
      .kind != "GrafanaDashboard" and
      (.kind != "ConfigMap" or .metadata.name != "dashboard-dragonfly-operator-grafana-dashboard") and
      (.kind != "ClusterRoleBinding" or .metadata.name != "dragonfly-operator-metrics-reader-clusterrolebinding")
    )
  ' "$render"
fi
apply_file "$render"
save_render_if_safe dragonfly-operator "$render"

wait_crd dragonflies.dragonflydb.io
wait_deployment "$namespace" dragonfly-operator
