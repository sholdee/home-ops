#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/lima/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=hack/bootstrap/lima/longhorn.sh
source "${SCRIPT_DIR}/longhorn.sh"

lima_require_common_tools
lima_require_tool kubectl
lima_require_tool nc
lima_require_tool jq

mkdir -p "$LIMA_OUT_DIR"
lima_start_apiserver_tunnel >/dev/null
kubeconfig="$(lima_prepare_kubeconfig)"
profile="${LIMA_VALIDATE_PROFILE:-foundation}"

kubectl_lima() {
  kubectl --kubeconfig "$kubeconfig" "$@"
}

fail_if_exists() {
  local description="$1"
  shift
  if kubectl_lima "$@" >/dev/null 2>&1; then
    lima_die "forbidden ${profile} resource exists: ${description}"
  fi
}

fail_if_crd_instances_exist() {
  local crd="$1"
  local resource="$2"
  if kubectl_lima get "crd/${crd}" >/dev/null 2>&1 &&
    [[ -n "$(kubectl_lima get "$resource" -A -o name 2>/dev/null || true)" ]]; then
    lima_die "forbidden ${profile} resource instances exist: ${resource}"
  fi
}

fail_if_json_query_matches() {
  local description="$1"
  local resource="$2"
  local query="$3"
  local json
  json="$(kubectl_lima get "$resource" -A -o json 2>/dev/null || true)"
  [[ -z "$json" ]] && return
  if jq -e "$query" <<<"$json" >/dev/null; then
    lima_die "forbidden ${description}"
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

require_argocd_app_exists() {
  local app="$1"
  kubectl_lima -n argocd get "application/${app}" >/dev/null ||
    lima_die "expected application/${app} to exist"
}

require_secret_keys() {
  local namespace="$1"
  local name="$2"
  shift 2
  local key
  for key in "$@"; do
    kubectl_lima -n "$namespace" get "secret/${name}" -o json |
      jq -e --arg key "$key" '.data[$key] // empty' >/dev/null ||
      lima_die "expected secret/${namespace}/${name} to contain ${key}"
  done
}

require_gateway_annotation_absent() {
  local gateway="$1"
  local value
  value="$(
    kubectl_lima -n gateway get "gateway/${gateway}" \
      -o jsonpath='{.metadata.annotations.cert-manager\.io/cluster-issuer}' 2>/dev/null || true
  )"
  [[ -z "$value" ]] || lima_die "gateway/${gateway} still has cert-manager cluster issuer annotation"
}

wait_application_operation_succeeded() {
  local app="$1"
  local deadline phase
  deadline=$((SECONDS + ${LIMA_VALIDATE_APP_WAIT_SECONDS:-1800}))
  while ((SECONDS < deadline)); do
    phase="$(kubectl_lima -n argocd get "application/${app}" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    case "$phase" in
      Succeeded)
        return 0
        ;;
      Failed | Error)
        kubectl_lima -n argocd describe "application/${app}" || true
        lima_die "application/${app} sync operation ended with phase ${phase}"
        ;;
    esac
    sleep 10
  done

  kubectl_lima -n argocd describe "application/${app}" || true
  lima_die "timed out waiting for application/${app} sync operation to succeed"
}

wait_argocd_app_ready() {
  local app="$1"
  local deadline health sync
  deadline=$((SECONDS + ${LIMA_VALIDATE_APP_WAIT_SECONDS:-1800}))
  while ((SECONDS < deadline)); do
    sync="$(kubectl_lima -n argocd get "application/${app}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl_lima -n argocd get "application/${app}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [[ "$sync" == Synced && "$health" == Healthy ]]; then
      return 0
    fi
    sleep 10
  done

  kubectl_lima -n argocd describe "application/${app}" || true
  lima_die "timed out waiting for application/${app} to become Synced/Healthy"
}

lima_pod_health_report() {
  kubectl_lima get pods -A -o json | jq -r '
    def statuses:
      ((.status.initContainerStatuses // []) + (.status.containerStatuses // []));
    def pod_ready:
      any(.status.conditions[]?; .type == "Ready" and .status == "True");
    def status_text:
      if .state.waiting then
        "waiting:" + (.state.waiting.reason // "unknown")
      elif .state.terminated then
        if ((.state.terminated.exitCode // 0) == 0 and (.state.terminated.reason // "") == "Completed") then
          empty
        else
          "terminated:" + (.state.terminated.reason // "unknown") + ":exit=" + ((.state.terminated.exitCode // 0) | tostring)
        end
      elif .ready != true then
        "running:not-ready"
      else
        empty
      end;

    .items[]
    | select(.status.phase != "Succeeded")
    | . as $pod
    | [
        statuses[]?
        | status_text
      ] as $status_problems
    | (
        if .status.phase == "Running" and (pod_ready | not) then
          ($status_problems + ["pod:not-ready"])
        else
          $status_problems
        end
      ) as $problems
    | select(
        (.status.phase != "Running") or
        ($problems | length > 0)
      )
    | [
        $pod.metadata.namespace,
        $pod.metadata.name,
        $pod.status.phase,
        ($problems | join(","))
      ]
    | @tsv
  '
}

wait_lima_apps_pods_clean() {
  local deadline stable_checks report
  deadline=$((SECONDS + ${LIMA_VALIDATE_APP_WAIT_SECONDS:-1800}))
  stable_checks=0
  while ((SECONDS < deadline)); do
    report="$(lima_pod_health_report)"
    if [[ -z "$report" ]]; then
      stable_checks=$((stable_checks + 1))
      if ((stable_checks >= 3)); then
        return 0
      fi
    else
      stable_checks=0
    fi
    sleep 10
  done

  report="$(lima_pod_health_report)"
  printf '%s\n' "$report" >&2
  kubectl_lima get pods -A -o wide >&2 || true
  kubectl_lima get events -A --sort-by=.lastTimestamp >&2 || true
  lima_die "timed out waiting for lima-apps pods to become Running/Ready or Succeeded"
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

lima_log "validating ${profile} ArgoCD scope"
kubectl_lima -n argocd get applications.argoproj.io
require_argocd_app_ready cilium
require_argocd_app_ready dragonfly-operator

if [[ "$profile" == foundation ]]; then
  fail_if_exists "ApplicationSet/k3s-apps" -n argocd get applicationset/k3s-apps

  for app in powerdns hass external-dns velero volsync longhorn crd-schema-publisher; do
    fail_if_exists "Application/${app}" -n argocd get "application/${app}"
  done

  fail_if_crd_instances_exist scheduledbackups.postgresql.cnpg.io scheduledbackups.postgresql.cnpg.io
  fail_if_crd_instances_exist objectstores.barmancloud.cnpg.io objectstores.barmancloud.cnpg.io
  fail_if_crd_instances_exist replicationsources.volsync.backube replicationsources.volsync.backube
  fail_if_crd_instances_exist schedules.velero.io schedules.velero.io
  fail_if_exists "Deployment/external-dns" -n external-dns get deployment/external-dns
elif [[ "$profile" == lima-longhorn ]]; then
  fail_if_exists "ApplicationSet/k3s-apps" -n argocd get applicationset/k3s-apps
  require_argocd_app_ready longhorn

  for app in powerdns hass external-dns velero volsync crd-schema-publisher grafana-operator reloader longhorn-system; do
    fail_if_exists "Application/${app}" -n argocd get "application/${app}"
  done

  kubectl_lima get crd \
    volumesnapshotclasses.snapshot.storage.k8s.io \
    volumesnapshotcontents.snapshot.storage.k8s.io \
    volumesnapshots.snapshot.storage.k8s.io >/dev/null
  kubectl_lima -n kube-system rollout status deployment/snapshot-controller --timeout=180s

  fail_if_crd_instances_exist pushsecrets.external-secrets.io pushsecrets.external-secrets.io
  fail_if_crd_instances_exist clusterpushsecrets.external-secrets.io clusterpushsecrets.external-secrets.io
  fail_if_crd_instances_exist replicationsources.volsync.backube replicationsources.volsync.backube
  fail_if_crd_instances_exist scheduledbackups.postgresql.cnpg.io scheduledbackups.postgresql.cnpg.io
  fail_if_crd_instances_exist backups.postgresql.cnpg.io backups.postgresql.cnpg.io
  fail_if_crd_instances_exist schedules.velero.io schedules.velero.io
  fail_if_crd_instances_exist backups.velero.io backups.velero.io
  fail_if_json_query_matches "Longhorn backup RecurringJob exists" recurringjobs.longhorn.io \
    '[.items[] | select(.spec.task == "backup")] | length > 0'
  lima_longhorn_validate_workload || lima_die "Lima Longhorn checksum workload validation failed"
  wait_lima_apps_pods_clean
elif [[ "$profile" == lima-apps ]]; then
  kubectl_lima -n argocd get applicationset/k3s-apps >/dev/null
  for app in cert-manager cnpg-system envoy-gateway-system external-secrets gateway hass kube-system longhorn-system powerdns; do
    require_argocd_app_exists "$app"
  done
  for app in cert-manager cnpg-system envoy-gateway-system external-secrets gateway hass kube-system longhorn-system powerdns; do
    wait_application_operation_succeeded "$app"
  done
  for app in cert-manager cnpg-system envoy-gateway-system external-secrets gateway hass kube-system longhorn-system powerdns; do
    wait_argocd_app_ready "$app"
  done
  for app in argocd crd-schema-publisher external-dns renovate system-upgrade velero adguard headlamp hivemq mealie monitoring portainer unifi; do
    fail_if_exists "Application/${app}" -n argocd get "application/${app}"
  done

  require_secret_keys gateway external-wildcard tls.crt tls.key
  require_secret_keys gateway mgmt-wildcard tls.crt tls.key
  require_secret_keys gateway guest-wildcard tls.crt tls.key
  require_gateway_annotation_absent external-gateway
  require_gateway_annotation_absent envoy-gateway
  require_gateway_annotation_absent guest-gateway

  kubectl_lima get crd \
    volumesnapshotclasses.snapshot.storage.k8s.io \
    volumesnapshotcontents.snapshot.storage.k8s.io \
    volumesnapshots.snapshot.storage.k8s.io >/dev/null
  kubectl_lima -n kube-system rollout status deployment/snapshot-controller --timeout=180s

  fail_if_exists "ExternalSecret/cert-manager/cloudflare-api-token-secret" \
    -n cert-manager get externalsecret.external-secrets.io/cloudflare-api-token-secret
  fail_if_exists "Secret/cert-manager/cloudflare-api-token-secret" \
    -n cert-manager get secret/cloudflare-api-token-secret
  fail_if_exists "ClusterIssuer/cloudflare" \
    get clusterissuer.cert-manager.io/cloudflare

  fail_if_crd_instances_exist pushsecrets.external-secrets.io pushsecrets.external-secrets.io
  fail_if_crd_instances_exist clusterpushsecrets.external-secrets.io clusterpushsecrets.external-secrets.io
  fail_if_crd_instances_exist replicationsources.volsync.backube replicationsources.volsync.backube
  fail_if_crd_instances_exist scheduledbackups.postgresql.cnpg.io scheduledbackups.postgresql.cnpg.io
  fail_if_crd_instances_exist backups.postgresql.cnpg.io backups.postgresql.cnpg.io
  fail_if_crd_instances_exist orders.acme.cert-manager.io orders.acme.cert-manager.io
  fail_if_crd_instances_exist challenges.acme.cert-manager.io challenges.acme.cert-manager.io
  fail_if_crd_instances_exist schedules.velero.io schedules.velero.io
  fail_if_crd_instances_exist backups.velero.io backups.velero.io
  fail_if_crd_instances_exist dnsendpoints.externaldns.k8s.io dnsendpoints.externaldns.k8s.io
  fail_if_json_query_matches "Longhorn backup RecurringJob exists" recurringjobs.longhorn.io \
    '[.items[] | select(.spec.task == "backup")] | length > 0'
  fail_if_json_query_matches "CNPG active Cluster plugin exists" clusters.postgresql.cnpg.io \
    '[.items[] | select((.spec.plugins // []) | length > 0)] | length > 0'
  wait_lima_apps_pods_clean
else
  lima_die "unknown validation profile: ${profile}"
fi

lima_log "${profile} Lima validation passed"
