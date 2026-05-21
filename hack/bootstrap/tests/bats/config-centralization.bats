#!/usr/bin/env bats
# shellcheck shell=bash

load '../helpers/common.bash'

setup_file() {
  require_tools yq
}

runtime_shell_files() {
  find "${ROOT}/hack/bootstrap" \
    -path "${ROOT}/hack/bootstrap/.out" -prune -o \
    -path "${ROOT}/hack/bootstrap/tests" -prune -o \
    -type f -name '*.sh' -print
}

runtime_files_without_inventory_or_tests() {
  find "${ROOT}/hack/bootstrap" \
    -path "${ROOT}/hack/bootstrap/.out" -prune -o \
    -path "${ROOT}/hack/bootstrap/tests" -prune -o \
    -path "${ROOT}/hack/bootstrap/ansible/inventory" -prune -o \
    -type f \( -name '*.sh' -o -name '*.yml' -o -name '*.yaml' -o -name '*.j2' \) -print
  printf '%s\n' "${ROOT}/justfile"
}

assert_scan_has_no_matches() {
  local pattern="$1"
  local file
  local failed=false
  while IFS= read -r file; do
    if grep -nE -- "$pattern" "$file"; then
      failed=true
    fi
  done
  [[ "$failed" == false ]]
}

@test "repo fact helpers derive core bootstrap values from manifests" {
  run bootstrap_repo_k3s_version
  assert_success
  assert_output_matches '^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$'

  run bootstrap_repo_cilium_tag
  assert_success
  assert_output_matches '^v[0-9]+\.[0-9]+\.[0-9]+$'

  run bootstrap_repo_cluster_cidr
  assert_success
  assert_output_matches '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'

  run bootstrap_repo_kube_proxy_replacement
  assert_success
  assert_output_matches '^(true|false)$'

  run bootstrap_repo_apiserver_endpoint
  assert_success
  assert_output_matches '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

@test "runtime code does not hardcode a K3s upgrade version" {
  run env ROOT="$ROOT" bash -c "$(declare -f runtime_files_without_inventory_or_tests assert_scan_has_no_matches); runtime_files_without_inventory_or_tests | assert_scan_has_no_matches 'v1\\.[0-9]+\\.[0-9]+\\+k3s[0-9]+'"
  assert_success
}

@test "runtime code keeps live API endpoint values in inventory or derived facts" {
  run env ROOT="$ROOT" bash -c "$(declare -f runtime_files_without_inventory_or_tests assert_scan_has_no_matches); runtime_files_without_inventory_or_tests | assert_scan_has_no_matches '192\\.168\\.99\\.77'"
  assert_success
}

@test "Lima runtime default cluster name is centralized outside public just recipes and tests" {
  run env ROOT="$ROOT" bash -c "$(declare -f runtime_files_without_inventory_or_tests assert_scan_has_no_matches); runtime_files_without_inventory_or_tests | grep -v '/hack/bootstrap/lib/config.sh$' | grep -v '/justfile$' | assert_scan_has_no_matches 'home-ops-k3s-test'"
  assert_success
}

@test "runtime shell keeps K3s base paths in shared config" {
  run env ROOT="$ROOT" bash -c "$(declare -f runtime_shell_files assert_scan_has_no_matches); runtime_shell_files | grep -v '/hack/bootstrap/lib/config.sh$' | assert_scan_has_no_matches '/(etc|var/lib)/rancher/k3s'"
  assert_success
}
