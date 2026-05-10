#!/usr/bin/env bash

apply_crds_from_chart() {
  local name="$1"
  local chart="$2"
  local repo="$3"
  local version="$4"
  local namespace="${5:-default}"
  local values_file="${6:-}"
  local output="${TMP_DIR}/${name}-crds.yaml"
  log "rendering CRDs for ${name}"
  helm_show_crds "$chart" "$repo" "$version" > "$output"
  if [[ ! -s "$output" ]]; then
    log "helm show crds returned no CRDs for ${name}; rendering chart templates instead"
    helm_template_crds "$name" "$chart" "$repo" "$version" "$namespace" "$values_file" > "$output"
  fi
  [[ -s "$output" ]] || die "no CRDs rendered for ${name}"
  apply_file "$output"
  save_render_if_safe "${name}-crds" "$output"
}

if ! crd_exists httproutes.gateway.networking.k8s.io; then
  envoy_chart="$(chart_value "${REPO_ROOT}/apps/envoy-gateway-system/kustomization.yaml" gateway-helm '.name')"
  envoy_repo="$(chart_value "${REPO_ROOT}/apps/envoy-gateway-system/kustomization.yaml" gateway-helm '.repo')"
  envoy_version="$(chart_value "${REPO_ROOT}/apps/envoy-gateway-system/kustomization.yaml" gateway-helm '.version')"
  apply_crds_from_chart gateway-api "$envoy_chart" "$envoy_repo" "$envoy_version" envoy-gateway-system
  wait_crd httproutes.gateway.networking.k8s.io
else
  log "Gateway API CRDs already present"
fi

prom_chart="$(chart_value "${REPO_ROOT}/apps/monitoring/kustomization.yaml" kube-prometheus-stack '.name')"
prom_repo="$(chart_value "${REPO_ROOT}/apps/monitoring/kustomization.yaml" kube-prometheus-stack '.repo')"
prom_version="$(chart_value "${REPO_ROOT}/apps/monitoring/kustomization.yaml" kube-prometheus-stack '.version')"
apply_crds_from_chart prometheus-operator "$prom_chart" "$prom_repo" "$prom_version" monitoring
wait_crd servicemonitors.monitoring.coreos.com
wait_crd podmonitors.monitoring.coreos.com

eso_chart="$(chart_value "${REPO_ROOT}/apps/external-secrets/kustomization.yaml" external-secrets '.name')"
eso_repo="$(chart_value "${REPO_ROOT}/apps/external-secrets/kustomization.yaml" external-secrets '.repo')"
eso_version="$(chart_value "${REPO_ROOT}/apps/external-secrets/kustomization.yaml" external-secrets '.version')"
apply_crds_from_chart external-secrets "$eso_chart" "$eso_repo" "$eso_version" external-secrets "${REPO_ROOT}/apps/external-secrets/manifests/values.yaml"
wait_crd clustersecretstores.external-secrets.io
wait_crd externalsecrets.external-secrets.io
wait_crd passwords.generators.external-secrets.io

grafana_chart="$(app_value grafana-operator '.spec.source.chart')"
grafana_repo="$(app_value grafana-operator '.spec.source.repoURL')"
grafana_version="$(app_value grafana-operator '.spec.source.targetRevision')"
apply_crds_from_chart grafana-operator "$grafana_chart" "$grafana_repo" "$grafana_version" grafana-operator
wait_crd grafanadashboards.grafana.integreatly.org

argocd_chart="$(chart_value "${REPO_ROOT}/apps/argocd/kustomization.yaml" argo-cd '.name')"
argocd_repo="$(chart_value "${REPO_ROOT}/apps/argocd/kustomization.yaml" argo-cd '.repo')"
argocd_version="$(chart_value "${REPO_ROOT}/apps/argocd/kustomization.yaml" argo-cd '.version')"
apply_crds_from_chart argocd "$argocd_chart" "$argocd_repo" "$argocd_version" argocd
wait_crd applications.argoproj.io
wait_crd applicationsets.argoproj.io
wait_crd appprojects.argoproj.io
