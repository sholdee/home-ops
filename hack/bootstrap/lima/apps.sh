#!/usr/bin/env bash
# shellcheck shell=bash

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
    - op: remove
      path: /spec/plugins
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
    - op: remove
      path: /spec/plugins
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

lima_apps_workloads_released() {
  local paths

  if kubectl_cmd -n argocd get application/hass >/dev/null 2>&1 ||
    kubectl_cmd -n argocd get application/powerdns >/dev/null 2>&1; then
    return 0
  fi

  paths="$(
    kubectl_cmd -n argocd get applicationset/k3s-apps \
      -o jsonpath='{range .spec.generators[0].git.directories[*]}{.path}{"\n"}{end}' 2>/dev/null || true
  )"
  grep -Eq '^apps/(hass|powerdns)$' <<<"$paths"
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
  name: lima-deny-cnpg-active-plugins
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["postgresql.cnpg.io"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["clusters"]
  validations:
    - expression: "!has(object.spec.plugins) || object.spec.plugins.size() == 0"
      message: "lima-apps bootstrap allows CNPG recovery through externalClusters but forbids active Cluster plugins"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: lima-deny-cnpg-active-plugins
spec:
  policyName: lima-deny-cnpg-active-plugins
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
  kubectl_cmd delete validatingadmissionpolicybinding/lima-deny-cnpg-wal-archiver --ignore-not-found
  kubectl_cmd delete validatingadmissionpolicy/lima-deny-cnpg-wal-archiver --ignore-not-found
  apply_file "$policies"
  save_render_if_safe lima-apps-safety-policies "$policies"
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
    .spec.syncPolicy.applicationsSync = "create-update" |
    .spec.template.spec.source.kustomize.patches = load(strenv(LIMA_APPSET_PATCHES))
  ' "$input" > "$output"

  if [[ -n "${LIMA_APPSET_TARGET_REVISION:-}" ]]; then
    LIMA_APPSET_TARGET_REVISION="$LIMA_APPSET_TARGET_REVISION" yq -i '
      .spec.generators[0].git.revision = strenv(LIMA_APPSET_TARGET_REVISION) |
      .spec.template.spec.source.targetRevision = strenv(LIMA_APPSET_TARGET_REVISION)
    ' "$output"
  fi
}
