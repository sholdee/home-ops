#!/usr/bin/env bats
# shellcheck shell=bash

load '../helpers/common.bash'

setup_file() {
  require_tools yq
}

setup() {
  tmp="$BATS_TEST_TMPDIR"
  TMP_DIR="$tmp"
  source "$ROOT/hack/bootstrap/lima/apps.sh"
  source "$ROOT/hack/bootstrap/lima/longhorn.sh"
}

assert_files_equal() {
  local expected="$1"
  local actual="$2"
  run diff -u "$expected" "$actual"
  assert_success
}

@test "lima app directories render stable infra and full allowlists" {
  local expected actual

  expected="$tmp/expected-infra.yaml"
  actual="$tmp/actual-infra.yaml"
  cat > "$expected" <<'EOF'
- path: apps/cert-manager
- path: apps/cnpg-system
- path: apps/envoy-gateway-system
- path: apps/external-secrets
- path: apps/gateway
- path: apps/kube-system
- path: apps/longhorn-system
EOF
  write_lima_apps_directories "$actual" infra
  assert_files_equal "$expected" "$actual"

  expected="$tmp/expected-full.yaml"
  actual="$tmp/actual-full.yaml"
  cat > "$expected" <<'EOF'
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
  write_lima_apps_directories "$actual" full
  assert_files_equal "$expected" "$actual"
}

@test "lima app kustomize patches keep the expected safety target set" {
  local patches expected_targets actual_targets

  patches="$tmp/patches.yaml"
  expected_targets="$tmp/expected-targets.txt"
  actual_targets="$tmp/actual-targets.txt"
  write_lima_apps_kustomize_patches "$patches"

  cat > "$expected_targets" <<'EOF'
external-secrets.io	v1alpha1	PushSecret	-	-
external-secrets.io	v1alpha1	ClusterPushSecret	-	-
external-secrets.io	v1	ExternalSecret	cloudflare-api-token-secret	-
cert-manager.io	v1	ClusterIssuer	cloudflare	-
volsync.backube	v1alpha1	ReplicationSource	-	-
postgresql.cnpg.io	v1	ScheduledBackup	-	-
postgresql.cnpg.io	v1	Backup	-	-
velero.io	v1	Backup	-	-
velero.io	v1	Schedule	-	-
longhorn.io	v1beta2	RecurringJob	every-day-keep-7-days	-
apps	v1	DaemonSet	kube-vip-ds	kube-system
gateway.networking.k8s.io	v1	Gateway	external-gateway	-
gateway.networking.k8s.io	v1	Gateway	envoy-gateway	-
gateway.networking.k8s.io	v1	Gateway	guest-gateway	-
postgresql.cnpg.io	v1	Cluster	hass-db2	-
postgresql.cnpg.io	v1	Cluster	powerdns-db	-
EOF
  yq -r '.[] | [.target.group // "-", .target.version // "-", .target.kind // "-", .target.name // "-", .target.namespace // "-"] | join("\t")' "$patches" > "$actual_targets"
  assert_files_equal "$expected_targets" "$actual_targets"
  assert_file_not_contains "$patches" '/spec/plugins/0/isWALArchiver'
  assert_file_contains "$patches" 'path: /spec/plugins'
  assert_file_contains "$patches" 'source: barman-cloud'
  assert_file_contains "$patches" 'name: powerdns-db-app-user'
}

@test "lima app safety policies render the expected fail-closed guards" {
  local policies expected_names actual_names

  policies="$tmp/policies.yaml"
  expected_names="$tmp/expected-policy-names.txt"
  actual_names="$tmp/actual-policy-names.txt"
  write_lima_apps_safety_policies "$policies"

  cat > "$expected_names" <<'EOF'
lima-deny-external-writers
lima-deny-cnpg-active-plugins
lima-deny-longhorn-backup-jobs
EOF
  yq -rN 'select(.kind == "ValidatingAdmissionPolicy") | .metadata.name' "$policies" > "$actual_names"
  assert_files_equal "$expected_names" "$actual_names"
  assert_file_contains "$policies" 'resources: ["pushsecrets", "clusterpushsecrets"]'
  assert_file_contains "$policies" 'resources: ["replicationsources"]'
  assert_file_contains "$policies" 'resources: ["backups", "scheduledbackups"]'
  assert_file_contains "$policies" 'object.spec.plugins.size() == 0'
  assert_file_contains "$policies" "object.spec.task != 'backup'"
}

@test "lima appset render injects stable directories patches and revision overrides" {
  local appset expected actual

  appset="$tmp/appset.yaml"
  expected="$tmp/expected.yaml"
  actual="$tmp/actual.yaml"
  LIMA_APPSET_TARGET_REVISION=test-branch write_lima_apps_appset \
    "$ROOT/apps/argocd/manifests/app-set.yaml" "$appset" infra

  [[ "$(yq -r '.spec.syncPolicy.applicationsSync' "$appset")" == "create-update" ]]
  [[ "$(yq -r '.spec.generators[0].git.revision' "$appset")" == "test-branch" ]]
  [[ "$(yq -r '.spec.template.spec.source.targetRevision' "$appset")" == "test-branch" ]]

  write_lima_apps_directories "$expected" infra
  yq -P '.' "$expected" > "$expected.norm"
  yq -P '.spec.generators[0].git.directories' "$appset" > "$actual"
  assert_files_equal "$expected.norm" "$actual"

  write_lima_apps_kustomize_patches "$expected"
  yq -P '.' "$expected" > "$expected.norm"
  yq -P '.spec.template.spec.source.kustomize.patches' "$appset" > "$actual"
  assert_files_equal "$expected.norm" "$actual"
}

@test "lima longhorn workload render uses retain storage and a checksum loop" {
  local workload

  workload="$tmp/lima-longhorn-workload.yaml"
  write_lima_longhorn_workload "$workload"

  [[ "$(yq -r 'select(.kind == "PersistentVolumeClaim") | .spec.storageClassName' "$workload")" == "longhorn-retain" ]]
  [[ "$(yq -r 'select(.kind == "PersistentVolumeClaim") | .spec.resources.requests.storage' "$workload")" == "1Gi" ]]
  [[ "$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$workload")" == "docker.io/library/busybox:1.37.0" ]]
  assert_file_contains "$workload" 'sha256sum -c data.sha256'
  assert_file_contains "$workload" 'home-ops-longhorn-'
}
