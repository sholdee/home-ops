#!/usr/bin/env bats
# shellcheck shell=bash

load '../helpers/common.bash'

setup_file() {
  require_tools yq
}

setup() {
  tmp="$BATS_TEST_TMPDIR"
}

write_fake_cluster_tools() {
  cat > "${tmp}/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >>"${FAKE_COMMAND_LOG:?}"
if [[ "$*" == *" -f -"* ]]; then
  cat >/dev/null
fi
exit 0
EOF
  cat > "${tmp}/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >>"${FAKE_COMMAND_LOG:?}"
exit 0
EOF
  chmod +x "${tmp}/kubectl" "${tmp}/helm"
}

@test "k8s helpers construct kubectl and helm commands with selected context" {
  write_fake_cluster_tools
  local log_file
  log_file="${tmp}/commands.log"

  run env PATH="${tmp}:${PATH}" FAKE_COMMAND_LOG="$log_file" \
    KUBECONFIG_PATH=/tmp/kubeconfig KUBE_CONTEXT=test-context \
    bash -c "source '${ROOT}/hack/bootstrap/lib/common.sh'; source '${ROOT}/hack/bootstrap/lib/k8s.sh'; kubectl_cmd get pods; helm_cluster_cmd list -A"
  assert_success
  assert_file_contains "$log_file" 'kubectl --kubeconfig /tmp/kubeconfig --context test-context get pods'
  assert_file_contains "$log_file" 'helm --kubeconfig /tmp/kubeconfig --kube-context test-context list -A'
}

@test "apply helpers use server-side dry-run and force-conflicts for secret streams" {
  write_fake_cluster_tools
  local log_file
  log_file="${tmp}/commands.log"

  run env PATH="${tmp}:${PATH}" FAKE_COMMAND_LOG="$log_file" \
    KUBECONFIG_PATH=/tmp/kubeconfig KUBE_CONTEXT=test-context FIELD_MANAGER=argocd-controller DRY_RUN=true \
    bash -c "source '${ROOT}/hack/bootstrap/lib/common.sh'; source '${ROOT}/hack/bootstrap/lib/k8s.sh'; printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: test\n' | apply_stream; printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: test\n' | apply_secret_stream"
  assert_success
  assert_file_contains "$log_file" 'apply --server-side --dry-run=server --field-manager=argocd-controller -f -'
  assert_file_contains "$log_file" 'apply --server-side --force-conflicts --dry-run=server --field-manager=argocd-controller -f -'
}

@test "drydock_app builds the expected drydock command" {
  cat > "${tmp}/drydock" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*"
exit 0
EOF
  chmod +x "${tmp}/drydock"

  run env PATH="${tmp}:${PATH}" \
    REPO_ROOT="/repo" \
    BOOTSTRAP_DRYDOCK_CACHE="/cache" \
    bash -c "source '${ROOT}/hack/bootstrap/lib/render.sh'; drydock_app argocd"
  assert_success
  assert_output_contains "build app argocd"
  assert_output_contains "--output yaml"
  assert_output_contains "--path /repo"
  assert_output_contains "--git-cache-dir /cache/git"
  assert_output_contains "--chart-cache-dir /cache/charts"
  assert_output_contains "--remote-cache-dir /cache/remotes"
  assert_output_contains "--render-cache-dir /cache/render"
}

@test "require_drydock_version rejects a drydock older than the required floor" {
  cat > "${tmp}/drydock" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'version: v0.2.0\ncommit: deadbeef\n'
exit 0
EOF
  chmod +x "${tmp}/drydock"

  run env PATH="${tmp}:${PATH}" \
    bash -c "source '${ROOT}/hack/bootstrap/lib/common.sh'; require_drydock_version 0.2.1"
  assert_failure
  assert_output_contains "drydock >= v0.2.1 required"
}

@test "require_drydock_version accepts the required version and newer" {
  for ver in v0.2.1 v0.3.0 v0.10.0; do
    cat > "${tmp}/drydock" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'version: ${ver}\ncommit: deadbeef\n'
exit 0
EOF
    chmod +x "${tmp}/drydock"

    run env PATH="${tmp}:${PATH}" \
      bash -c "source '${ROOT}/hack/bootstrap/lib/common.sh'; require_drydock_version 0.2.1"
    assert_success
  done
}

@test "render helpers normalize Helm chart references and repo args" {
  run env REPO_ROOT="$ROOT" \
    bash -c "source '${ROOT}/hack/bootstrap/lib/render.sh'; helm_chart_ref oci://ghcr.io/example chart"
  assert_success
  [[ "$output" == "oci://ghcr.io/example/chart" ]]

  run env REPO_ROOT="$ROOT" \
    bash -c "source '${ROOT}/hack/bootstrap/lib/render.sh'; helm_chart_ref ghcr.io/example chart"
  assert_success
  [[ "$output" == "oci://ghcr.io/example/chart" ]]

  run env REPO_ROOT="$ROOT" \
    bash -c "source '${ROOT}/hack/bootstrap/lib/render.sh'; helm_chart_ref https://charts.example.test chart"
  assert_success
  [[ "$output" == "chart" ]]

  run env REPO_ROOT="$ROOT" \
    bash -c "source '${ROOT}/hack/bootstrap/lib/render.sh'; helm_repo_args https://charts.example.test"
  assert_success
  [[ "$output" == "$(printf -- '--repo\nhttps://charts.example.test')" ]]

  run env REPO_ROOT="$ROOT" \
    bash -c "source '${ROOT}/hack/bootstrap/lib/render.sh'; helm_repo_args oci://ghcr.io/example"
  assert_success
  [[ -z "$output" ]]
}

@test "render overlays preserve Dragonfly auth patch and chart-derived cert-manager values" {
  local overlay_dir
  overlay_dir="${tmp}/overlay"
  mkdir -p "$overlay_dir"

  run env REPO_ROOT="$ROOT" \
    bash -c "source '${ROOT}/hack/bootstrap/lib/render.sh'; write_argocd_dependencies_overlay '${overlay_dir}'"
  assert_success
  assert_file_contains "${overlay_dir}/kustomization.yaml" 'name: argocd-dragonfly-auth'
  assert_file_contains "${overlay_dir}/kustomization.yaml" 'key: redis-password'

  run env REPO_ROOT="$ROOT" \
    bash -c "source '${ROOT}/hack/bootstrap/lib/render.sh'; write_cert_manager_chart_overlay '${overlay_dir}'"
  assert_success
  assert_file_contains "${overlay_dir}/kustomization.yaml" 'name: cert-manager'
  assert_file_contains "${overlay_dir}/kustomization.yaml" 'valuesFile:'
}

@test "report helper refuses to persist secret-containing rendered manifests" {
  local report_dir manifest
  report_dir="${tmp}/report"
  manifest="${tmp}/secret.yaml"
  mkdir -p "${report_dir}/rendered"
  cat > "$manifest" <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: should-not-save
EOF

  run env REPORT_DIR="$report_dir" \
    bash -c "source '${ROOT}/hack/bootstrap/lib/common.sh'; source '${ROOT}/hack/bootstrap/lib/reports.sh'; save_render_if_safe secret-test '${manifest}'"
  assert_success
  assert_output_contains 'not saving render secret-test: contains Secret resources'
  [[ ! -e "${report_dir}/rendered/secret-test.yaml" ]]
}

@test "bootstrap phase filtering can run audit without running earlier phases" {
  local bootstrap_lib

  bootstrap_lib="${tmp}/bootstrap-lib.sh"
  sed '$d' "${ROOT}/hack/bootstrap/bootstrap.sh" |
    sed "s|^BOOTSTRAP_DIR=.*|BOOTSTRAP_DIR=\"${ROOT}/hack/bootstrap\"|" > "$bootstrap_lib"

  run bash -c "source '${bootstrap_lib}'; AUDIT_ONLY=false; ONLY_PHASE=audit; FROM_PHASE=''; if phase_selected audit; then echo audit=yes; else echo audit=no; fi; if phase_selected seed-secret; then echo seed=yes; else echo seed=no; fi"
  assert_success
  assert_output_contains 'audit=yes'
  assert_output_contains 'seed=no'

  run bash -c "source '${bootstrap_lib}'; AUDIT_ONLY=false; ONLY_PHASE=''; FROM_PHASE=external-secrets; if phase_selected cert-manager; then echo cert-manager=yes; else echo cert-manager=no; fi; if phase_selected external-secrets; then echo external-secrets=yes; else echo external-secrets=no; fi; if phase_selected argocd; then echo argocd=yes; else echo argocd=no; fi"
  assert_success
  assert_output_contains 'cert-manager=no'
  assert_output_contains 'external-secrets=yes'
  assert_output_contains 'argocd=yes'
}

@test "bootstrap profile validation accepts the Longhorn-focused Lima profile" {
  local bootstrap_lib

  bootstrap_lib="${tmp}/bootstrap-lib.sh"
  sed '$d' "${ROOT}/hack/bootstrap/bootstrap.sh" |
    sed "s|^BOOTSTRAP_DIR=.*|BOOTSTRAP_DIR=\"${ROOT}/hack/bootstrap\"|" > "$bootstrap_lib"

  run bash -c "source '${bootstrap_lib}'; FROM_PHASE=''; ONLY_PHASE=''; BOOTSTRAP_PROFILE=lima-longhorn; validate_phase_names"
  assert_success
}

@test "gateway cert seed skips profiles that do not apply gateway" {
  local profile

  for profile in foundation lima-longhorn; do
    run env BOOTSTRAP_PROFILE="$profile" \
      bash -c "log() { printf '%s\n' \"\$*\"; }; ensure_namespace() { printf 'unexpected namespace\n' >&2; return 1; }; source '${ROOT}/hack/bootstrap/phases/gateway-cert-seed.sh'"
    assert_success
    assert_output_contains "${profile} profile: skip gateway cert seed"
  done
}

@test "runbook phase list matches bootstrap phase order" {
  local bootstrap_lib expected actual

  bootstrap_lib="${tmp}/bootstrap-lib.sh"
  expected="${tmp}/expected-phases.txt"
  actual="${tmp}/actual-phases.txt"

  sed '$d' "${ROOT}/hack/bootstrap/bootstrap.sh" |
    sed "s|^BOOTSTRAP_DIR=.*|BOOTSTRAP_DIR=\"${ROOT}/hack/bootstrap\"|" > "$bootstrap_lib"

  run bash -c "source '${bootstrap_lib}'; printf '%s\n' \"\${PHASES[@]}\""
  assert_success
  printf '%s\n' "$output" > "$expected"

  awk '
    /^## Phases$/ { in_phases = 1; next }
    /^## / && in_phases { exit }
    in_phases && /^[0-9]+\. `/ {
      phase = $0
      sub(/^[0-9]+\. `/, "", phase)
      sub(/`.*/, "", phase)
      print phase
    }
  ' "${ROOT}/docs/cluster-operations.md" > "$actual"

  run diff -u "$expected" "$actual"
  assert_success
}
