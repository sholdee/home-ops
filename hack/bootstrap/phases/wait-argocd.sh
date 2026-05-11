#!/usr/bin/env bash

wait_statefulset argocd argocd-application-controller
wait_deployment argocd argocd-server
wait_deployment argocd argocd-repo-server
wait_deployment argocd argocd-applicationset-controller

wait_application_synced() {
  local app="$1"
  local status
  for _ in $(seq 1 60); do
    status="$(kubectl_cmd -n argocd get "application/${app}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    if [[ "$status" == Synced ]]; then
      return 0
    fi
    sleep 5
  done

  kubectl_cmd -n argocd describe "application/${app}" || true
  die "timed out waiting for ArgoCD application/${app} to sync"
}

wait_application_ready() {
  local app="$1"
  local sync health
  for _ in $(seq 1 60); do
    sync="$(kubectl_cmd -n argocd get "application/${app}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl_cmd -n argocd get "application/${app}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [[ "$sync" == Synced && "$health" == Healthy ]]; then
      return 0
    fi
    sleep 5
  done

  kubectl_cmd -n argocd describe "application/${app}" || true
  die "timed out waiting for ArgoCD application/${app} to become Synced/Healthy"
}

wait_application_operation_healthy() {
  local app="$1"
  local phase health
  for _ in $(seq 1 60); do
    phase="$(kubectl_cmd -n argocd get "application/${app}" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    health="$(kubectl_cmd -n argocd get "application/${app}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [[ "$phase" == Succeeded && "$health" == Healthy ]]; then
      return 0
    fi
    sleep 5
  done

  kubectl_cmd -n argocd describe "application/${app}" || true
  die "timed out waiting for ArgoCD application/${app} to complete sync and become Healthy"
}

refresh_applications() {
  kubectl_cmd -n argocd annotate applications.argoproj.io \
    "$@" \
    argocd.argoproj.io/refresh=hard \
    --overwrite
}

wait_cilium_ready_for_k3s_apps() {
  kubectl_cmd -n argocd get application/cilium >/dev/null
  refresh_applications cilium
  wait_application_synced cilium
  wait_certificate_ready kube-system hubble-server-certs
  wait_certificate_ready kube-system hubble-relay-client-certs
  if bool "${BOOTSTRAP_RESTART_CILIUM_FOR_HUBBLE_CERTS:-false}"; then
    log "restarting Cilium and Hubble relay to load reissued Hubble certs"
    kubectl_cmd -n kube-system rollout restart daemonset/cilium
    kubectl_cmd -n kube-system rollout restart deployment/hubble-relay
    kubectl_cmd -n kube-system rollout status daemonset/cilium --timeout=240s
    kubectl_cmd -n kube-system rollout status deployment/hubble-relay --timeout=240s
  fi
  wait_application_ready cilium
}

wait_platform_applications_for_k3s_apps() {
  local apps=(dragonfly-operator grafana-operator longhorn reloader volsync)
  log "refreshing explicit platform applications before applying applicationset/k3s-apps"
  refresh_applications "${apps[@]}"
  local app
  for app in "${apps[@]}"; do
    wait_application_operation_healthy "$app"
  done
}

write_lima_apps_kustomize_patches() {
  local output="$1"
  cat > "$output" <<'EOF'
- target:
    group: external-secrets.io
    version: v1alpha1
    kind: PushSecret
  patch: |-
    apiVersion: external-secrets.io/v1alpha1
    kind: PushSecret
    metadata:
      name: ignored
    $patch: delete
- target:
    group: external-secrets.io
    version: v1alpha1
    kind: ClusterPushSecret
  patch: |-
    apiVersion: external-secrets.io/v1alpha1
    kind: ClusterPushSecret
    metadata:
      name: ignored
    $patch: delete
- target:
    group: external-secrets.io
    version: v1
    kind: ExternalSecret
    name: cloudflare-api-token-secret
  patch: |-
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: cloudflare-api-token-secret
    $patch: delete
- target:
    group: cert-manager.io
    version: v1
    kind: ClusterIssuer
    name: cloudflare
  patch: |-
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: cloudflare
    $patch: delete
- target:
    group: volsync.backube
    version: v1alpha1
    kind: ReplicationSource
  patch: |-
    apiVersion: volsync.backube/v1alpha1
    kind: ReplicationSource
    metadata:
      name: ignored
    $patch: delete
- target:
    group: postgresql.cnpg.io
    version: v1
    kind: ScheduledBackup
  patch: |-
    apiVersion: postgresql.cnpg.io/v1
    kind: ScheduledBackup
    metadata:
      name: ignored
    $patch: delete
- target:
    group: postgresql.cnpg.io
    version: v1
    kind: Backup
  patch: |-
    apiVersion: postgresql.cnpg.io/v1
    kind: Backup
    metadata:
      name: ignored
    $patch: delete
- target:
    group: velero.io
    version: v1
    kind: Backup
  patch: |-
    apiVersion: velero.io/v1
    kind: Backup
    metadata:
      name: ignored
    $patch: delete
- target:
    group: velero.io
    version: v1
    kind: Schedule
  patch: |-
    apiVersion: velero.io/v1
    kind: Schedule
    metadata:
      name: ignored
    $patch: delete
- target:
    group: longhorn.io
    version: v1beta2
    kind: RecurringJob
    name: every-day-keep-7-days
  patch: |-
    apiVersion: longhorn.io/v1beta2
    kind: RecurringJob
    metadata:
      name: every-day-keep-7-days
    $patch: delete
- target:
    group: apps
    version: v1
    kind: DaemonSet
    name: kube-vip-ds
    namespace: kube-system
  patch: |-
    apiVersion: apps/v1
    kind: DaemonSet
    metadata:
      name: kube-vip-ds
      namespace: kube-system
    $patch: delete
- target:
    group: gateway.networking.k8s.io
    version: v1
    kind: Gateway
    name: external-gateway
  patch: |-
    - op: remove
      path: /metadata/annotations/cert-manager.io~1cluster-issuer
- target:
    group: gateway.networking.k8s.io
    version: v1
    kind: Gateway
    name: envoy-gateway
  patch: |-
    - op: remove
      path: /metadata/annotations/cert-manager.io~1cluster-issuer
- target:
    group: gateway.networking.k8s.io
    version: v1
    kind: Gateway
    name: guest-gateway
  patch: |-
    - op: remove
      path: /metadata/annotations/cert-manager.io~1cluster-issuer
- target:
    group: postgresql.cnpg.io
    version: v1
    kind: Cluster
    name: hass-db2
  patch: |-
    - op: replace
      path: /spec/plugins/0/isWALArchiver
      value: false
- target:
    group: postgresql.cnpg.io
    version: v1
    kind: Cluster
    name: powerdns-db
  patch: |-
    - op: replace
      path: /spec/bootstrap
      value:
        recovery:
          source: barman-cloud
          database: powerdns
          owner: powerdns
          secret:
            name: powerdns-db-app-user
    - op: replace
      path: /spec/plugins/0/isWALArchiver
      value: false
EOF
}

write_lima_apps_directories() {
  local output="$1"
  local stage="$2"

  case "$stage" in
    infra)
      cat > "$output" <<'EOF'
- path: apps/cert-manager
- path: apps/cnpg-system
- path: apps/envoy-gateway-system
- path: apps/external-secrets
- path: apps/gateway
- path: apps/kube-system
- path: apps/longhorn-system
EOF
      ;;
    full)
      cat > "$output" <<'EOF'
- path: apps/cert-manager
- path: apps/cnpg-system
- path: apps/envoy-gateway-system
- path: apps/external-secrets
- path: apps/gateway
- path: apps/hass
- path: apps/kube-system
- path: apps/longhorn-system
- path: apps/powerdns
EOF
      ;;
    *)
      die "unknown Lima appset stage: ${stage}"
      ;;
  esac
}

write_lima_apps_safety_policies() {
  local output="$1"
  cat > "$output" <<'EOF'
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: lima-deny-external-writers
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["external-secrets.io"]
        apiVersions: ["v1alpha1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pushsecrets", "clusterpushsecrets"]
      - apiGroups: ["acme.cert-manager.io"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["orders", "challenges"]
      - apiGroups: ["volsync.backube"]
        apiVersions: ["v1alpha1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["replicationsources"]
      - apiGroups: ["postgresql.cnpg.io"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["backups", "scheduledbackups"]
      - apiGroups: ["velero.io"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["backups", "schedules"]
      - apiGroups: ["externaldns.k8s.io"]
        apiVersions: ["v1alpha1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["dnsendpoints"]
  validations:
    - expression: "false"
      message: "lima-apps bootstrap forbids external writer resources"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: lima-deny-external-writers
spec:
  policyName: lima-deny-external-writers
  validationActions: [Deny]
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: lima-deny-cnpg-wal-archiver
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["postgresql.cnpg.io"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["clusters"]
  validations:
    - expression: "!has(object.spec.plugins) || !object.spec.plugins.exists(p, has(p.isWALArchiver) && p.isWALArchiver == true)"
      message: "lima-apps bootstrap allows CNPG recovery but forbids WAL archiving"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: lima-deny-cnpg-wal-archiver
spec:
  policyName: lima-deny-cnpg-wal-archiver
  validationActions: [Deny]
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: lima-deny-longhorn-backup-jobs
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["longhorn.io"]
        apiVersions: ["v1beta2"]
        operations: ["CREATE", "UPDATE"]
        resources: ["recurringjobs"]
  validations:
    - expression: "!has(object.spec.task) || object.spec.task != 'backup'"
      message: "lima-apps bootstrap forbids Longhorn backup recurring jobs"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: lima-deny-longhorn-backup-jobs
spec:
  policyName: lima-deny-longhorn-backup-jobs
  validationActions: [Deny]
EOF
}

apply_lima_apps_safety_policies() {
  local policies
  policies="${TMP_DIR}/lima-apps-safety-policies.yaml"
  write_lima_apps_safety_policies "$policies"
  apply_file "$policies"
  save_render_if_safe lima-apps-safety-policies "$policies"
}

apply_external_snapshotter() {
  local snapshotter
  if crd_exists volumesnapshotclasses.snapshot.storage.k8s.io &&
    crd_exists volumesnapshotcontents.snapshot.storage.k8s.io &&
    crd_exists volumesnapshots.snapshot.storage.k8s.io &&
    kubectl_cmd -n kube-system get deployment/snapshot-controller >/dev/null 2>&1; then
    log "external snapshotter already exists; waiting for readiness"
    wait_deployment kube-system snapshot-controller
    return
  fi

  snapshotter="${TMP_DIR}/external-snapshotter.yaml"
  render_kustomize_app apps/kube-system/external-snapshotter > "$snapshotter"
  apply_file "$snapshotter"
  save_render_if_safe external-snapshotter "$snapshotter"
  wait_crd volumesnapshotclasses.snapshot.storage.k8s.io
  wait_crd volumesnapshotcontents.snapshot.storage.k8s.io
  wait_crd volumesnapshots.snapshot.storage.k8s.io
  wait_deployment kube-system snapshot-controller
}

write_lima_apps_appset() {
  local input="$1"
  local output="$2"
  local stage="${3:-full}"
  local directories patches
  directories="${TMP_DIR}/lima-apps-${stage}-directories.yaml"
  patches="${TMP_DIR}/lima-apps-kustomize-patches.yaml"
  write_lima_apps_directories "$directories" "$stage"
  write_lima_apps_kustomize_patches "$patches"
  LIMA_APPSET_DIRECTORIES="$directories" LIMA_APPSET_PATCHES="$patches" yq '
    .spec.generators[0].git.directories = load(strenv(LIMA_APPSET_DIRECTORIES)) |
    .spec.template.spec.source.kustomize.patches = load(strenv(LIMA_APPSET_PATCHES))
  ' "$input" > "$output"

  if [[ -n "${LIMA_APPSET_TARGET_REVISION:-}" ]]; then
    LIMA_APPSET_TARGET_REVISION="$LIMA_APPSET_TARGET_REVISION" yq -i '
      .spec.generators[0].git.revision = strenv(LIMA_APPSET_TARGET_REVISION) |
      .spec.template.spec.source.targetRevision = strenv(LIMA_APPSET_TARGET_REVISION)
    ' "$output"
  fi
}

apply_k3s_apps_appset() {
  local render appset lima_appset
  local stage="${1:-full}"
  render="${TMP_DIR}/argocd-k3s-apps-render.yaml"
  appset="${TMP_DIR}/argocd-k3s-apps.yaml"
  render_kustomize_app apps/argocd > "$render"
  yq '
    select(
      .apiVersion == "argoproj.io/v1alpha1" and
      .kind == "ApplicationSet" and
      .metadata.name == "k3s-apps"
    )
  ' "$render" > "$appset"
  [[ -s "$appset" ]] || die "failed to render ApplicationSet/k3s-apps"
  if [[ "$BOOTSTRAP_PROFILE" == lima-apps ]]; then
    lima_appset="${TMP_DIR}/argocd-k3s-apps-lima-${stage}.yaml"
    write_lima_apps_appset "$appset" "$lima_appset" "$stage"
    appset="$lima_appset"
  fi
  apply_file "$appset"
}

if bool "$DRY_RUN"; then
  log "dry-run: skip wait for applicationset/k3s-apps"
elif [[ "$BOOTSTRAP_PROFILE" == foundation ]]; then
  log "foundation profile: skip wait for applicationset/k3s-apps"
  kubectl_cmd -n argocd get application/dragonfly-operator >/dev/null
  log "refresh foundation ArgoCD applications"
  kubectl_cmd -n argocd annotate applications.argoproj.io \
    dragonfly-operator \
    argocd.argoproj.io/refresh=hard \
    --overwrite
  wait_cilium_ready_for_k3s_apps
  wait_application_ready dragonfly-operator
elif [[ "$BOOTSTRAP_PROFILE" == lima-apps ]]; then
  log "waiting for Cilium and explicit operators before applying sanitized applicationset/k3s-apps"
  wait_cilium_ready_for_k3s_apps
  wait_platform_applications_for_k3s_apps
  log "applying external snapshotter before VolSync restore workloads"
  apply_external_snapshotter
  log "applying Lima safety admission policies"
  apply_lima_apps_safety_policies
  log "applying sanitized infra applicationset/k3s-apps for lima-apps"
  apply_k3s_apps_appset infra
  kubectl_cmd -n argocd get applicationset/k3s-apps >/dev/null
  for app in cert-manager cnpg-system envoy-gateway-system external-secrets gateway kube-system longhorn-system; do
    wait_application_operation_healthy "$app"
  done
  log "applying sanitized workload applicationset/k3s-apps for lima-apps"
  apply_k3s_apps_appset
  kubectl_cmd -n argocd get applicationset/k3s-apps >/dev/null
elif ! crd_exists ciliumnetworkpolicies.cilium.io; then
  log "CiliumNetworkPolicy CRD absent; skip wait for real-cluster applicationset/k3s-apps"
else
  log "waiting for Cilium, Hubble certs, and platform applications before applying applicationset/k3s-apps"
  wait_cilium_ready_for_k3s_apps
  wait_platform_applications_for_k3s_apps
  log "applying external snapshotter before VolSync restore workloads"
  apply_external_snapshotter
  log "applying applicationset/k3s-apps after platform prerequisites are ready"
  apply_k3s_apps_appset
  kubectl_cmd -n argocd get applicationset/k3s-apps >/dev/null
fi
