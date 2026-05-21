# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
REPO_ROOT="$ROOT"

# shellcheck source=hack/bootstrap/lib/repo-facts.sh
source "${ROOT}/hack/bootstrap/lib/repo-facts.sh"

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
  bootstrap_repo_k3s_version
}

repo_cluster_cidr() {
  bootstrap_repo_cluster_cidr
}

repo_kube_proxy_replacement() {
  bootstrap_repo_kube_proxy_replacement
}

repo_apiserver_endpoint() {
  bootstrap_repo_apiserver_endpoint
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
