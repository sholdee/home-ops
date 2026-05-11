#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

lima_require_common_tools
lima_require_tool kubectl
lima_require_tool nc

mkdir -p "$LIMA_OUT_DIR"
lima_start_apiserver_tunnel >/dev/null
kubeconfig="$(lima_prepare_kubeconfig)"

kubectl_lima() {
  kubectl --kubeconfig "$kubeconfig" "$@"
}

fail_if_exists() {
  local description="$1"
  shift
  if kubectl_lima "$@" >/dev/null 2>&1; then
    lima_die "forbidden foundation-test resource exists: ${description}"
  fi
}

fail_if_crd_instances_exist() {
  local crd="$1"
  local resource="$2"
  if kubectl_lima get "crd/${crd}" >/dev/null 2>&1 &&
    [[ -n "$(kubectl_lima get "$resource" -A -o name 2>/dev/null || true)" ]]; then
    lima_die "forbidden foundation-test resource instances exist: ${resource}"
  fi
}

require_argocd_app_ready() {
  local app="$1"
  local sync health
  sync="$(kubectl_lima -n argocd get "application/${app}" -o jsonpath='{.status.sync.status}')"
  health="$(kubectl_lima -n argocd get "application/${app}" -o jsonpath='{.status.health.status}')"
  if [[ "$sync" != Synced || "$health" != Healthy ]]; then
    lima_die "application/${app} is ${sync}/${health}; expected Synced/Healthy"
  fi
}

lima_log "validating cluster nodes"
kubectl_lima get nodes -o wide

lima_log "validating current Cilium BGP CRDs"
kubectl_lima get crd \
  ciliumbgpclusterconfigs.cilium.io \
  ciliumbgppeerconfigs.cilium.io \
  ciliumbgpadvertisements.cilium.io \
  ciliumloadbalancerippools.cilium.io >/dev/null

lima_log "server-side dry-run current home-ops Cilium BGP manifests"
kubectl_lima apply \
  --server-side \
  --dry-run=server \
  --field-manager=argocd-controller \
  -f "${REPO_ROOT}/apps/kube-system/cilium/manifests/CiliumBGPClusterConfig.yaml"

lima_log "validating foundation ArgoCD scope"
kubectl_lima -n argocd get applications.argoproj.io
require_argocd_app_ready cilium
require_argocd_app_ready dragonfly-operator
fail_if_exists "ApplicationSet/k3s-apps" -n argocd get applicationset/k3s-apps

for app in powerdns hass external-dns velero volsync longhorn crd-schema-publisher; do
  fail_if_exists "Application/${app}" -n argocd get "application/${app}"
done

fail_if_crd_instances_exist scheduledbackups.postgresql.cnpg.io scheduledbackups.postgresql.cnpg.io
fail_if_crd_instances_exist objectstores.barmancloud.cnpg.io objectstores.barmancloud.cnpg.io
fail_if_crd_instances_exist replicationsources.volsync.backube replicationsources.volsync.backube
fail_if_crd_instances_exist schedules.velero.io schedules.velero.io
fail_if_exists "Deployment/external-dns" -n external-dns get deployment/external-dns

lima_log "foundation Lima validation passed"
