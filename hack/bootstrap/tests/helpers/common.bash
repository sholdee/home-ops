# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || {
      echo "missing tool: $tool" >&2
      return 1
    }
  done
}

repo_k3s_version() {
  yq -r '
    select(.kind == "Plan" and .metadata.name == "k3s-server") |
    .spec.version
  ' "${ROOT}/apps/system-upgrade/manifests/plan.yaml"
}

repo_cluster_cidr() {
  yq -r '
    select(.kind == "Application" and .metadata.name == "cilium") |
    .spec.source.helm.valuesObject.ipam.operator.clusterPoolIPv4PodCIDRList |
    .[0] // .
  ' "${ROOT}/apps/argocd/manifests/apps.yaml"
}

repo_kube_proxy_replacement() {
  yq -r '
    select(.kind == "Application" and .metadata.name == "cilium") |
    .spec.source.helm.valuesObject.kubeProxyReplacement
  ' "${ROOT}/apps/argocd/manifests/apps.yaml"
}

repo_apiserver_endpoint() {
  yq -r '
    .spec.template.spec.containers[] |
    select(.name == "kube-vip") |
    .env[] |
    select(.name == "address") |
    .value
  ' "${ROOT}/apps/kube-system/kube-vip/manifests/daemonset.yaml"
}

assert_success() {
  if [[ "$status" -ne 0 ]]; then
    printf 'expected success, got status %s\n' "$status" >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
}

assert_failure() {
  if [[ "$status" -eq 0 ]]; then
    printf 'expected failure, got success\n' >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
}

assert_output_contains() {
  local needle="$1"
  if ! grep -Fq -- "$needle" <<<"$output"; then
    printf 'expected output to contain: %s\n' "$needle" >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
}

assert_output_not_contains() {
  local needle="$1"
  if grep -Fq -- "$needle" <<<"$output"; then
    printf 'expected output not to contain: %s\n' "$needle" >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
}

assert_output_matches() {
  local pattern="$1"
  if ! grep -Eq -- "$pattern" <<<"$output"; then
    printf 'expected output to match: %s\n' "$pattern" >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    printf 'expected %s to contain: %s\n' "$file" "$needle" >&2
    sed -n '1,160p' "$file" >&2 || true
    return 1
  fi
}

assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$file"; then
    printf 'expected %s not to contain: %s\n' "$file" "$needle" >&2
    sed -n '1,160p' "$file" >&2 || true
    return 1
  fi
}

assert_file_matches() {
  local file="$1"
  local pattern="$2"
  if ! grep -Eq -- "$pattern" "$file"; then
    printf 'expected %s to match: %s\n' "$file" "$pattern" >&2
    sed -n '1,160p' "$file" >&2 || true
    return 1
  fi
}
