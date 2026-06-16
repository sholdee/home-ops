#!/usr/bin/env bats
# shellcheck shell=bash
# bats test_tags=network

load '../helpers/common.bash'

setup_file() {
  require_tools yq kustomize
  if [[ "${BOOTSTRAP_SKIP_NETWORK_TESTS:-}" == "1" ]]; then
    skip "BOOTSTRAP_SKIP_NETWORK_TESTS=1: skipping network-dependent render-parity tests"
  fi
}

setup() {
  tmp="$BATS_TEST_TMPDIR"
}

run_parity() {
  local app="$1"
  local raw_cmd="$2"
  # Clean up any stale charts before the run
  rm -rf "${ROOT}/apps/${app}/charts"
  run env REPO_ROOT="$ROOT" \
    bash "${ROOT}/hack/bootstrap/tests/render-parity.sh" "$app" "$raw_cmd"
  # Clean up charts extracted by the raw render
  rm -rf "${ROOT}/apps/${app}/charts"
}

@test "external-secrets render parity: drydock matches raw kustomize build" {
  run_parity "external-secrets" \
    "kustomize build --enable-helm '${ROOT}/apps/external-secrets'"
  assert_success
}

@test "cert-manager render parity: drydock matches raw kustomize build (minus hook resources)" {
  run_parity "cert-manager" \
    "kustomize build --enable-helm '${ROOT}/apps/cert-manager'"
  assert_success
}

@test "gateway render parity: drydock matches raw kustomize build (GatewayClass/ClusterSecretStore cluster-scoped)" {
  run_parity "gateway" \
    "kustomize build --enable-helm '${ROOT}/apps/gateway'"
  assert_success
}

@test "argocd render parity: drydock matches raw kustomize build" {
  run_parity "argocd" \
    "kustomize build --enable-helm '${ROOT}/apps/argocd'"
  assert_success
}

@test "dragonfly-operator render parity: drydock matches helm template" {
  local values_file
  values_file="$(mktemp "${tmp}/dragonfly-operator-values.XXXXXX.yaml")"
  env REPO_ROOT="$ROOT" \
    bash -c "source '${ROOT}/hack/bootstrap/lib/render.sh'; write_app_values dragonfly-operator '${values_file}'"
  run_parity "dragonfly-operator" \
    "env REPO_ROOT='${ROOT}' bash -c \"source '${ROOT}/hack/bootstrap/lib/render.sh'; helm_template_app dragonfly-operator '${values_file}'\""
  assert_success
}
