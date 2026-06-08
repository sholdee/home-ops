#!/usr/bin/env bash
set -euo pipefail

bootstrap_test_jobs() {
  local jobs
  jobs="${BOOTSTRAP_TEST_JOBS:-}"
  if [[ -z "$jobs" ]]; then
    if command -v nproc >/dev/null 2>&1; then
      jobs="$(nproc)"
    elif command -v sysctl >/dev/null 2>&1 && jobs="$(sysctl -n hw.ncpu 2>/dev/null)" && [[ -n "$jobs" ]]; then
      :
    else
      jobs=4
    fi
  fi

  if ! [[ "$jobs" =~ ^[0-9]+$ ]] || ((jobs < 1)); then
    printf 'invalid BOOTSTRAP_TEST_JOBS: %s\n' "$jobs" >&2
    return 1
  fi
  if ((jobs > 8)); then
    jobs=8
  fi
  printf '%s\n' "$jobs"
}

run_shellcheck() {
  local jobs
  jobs="$(bootstrap_test_jobs)"
  local files=(
    hack/bootstrap/bootstrap.sh
    hack/bootstrap/lib/*.sh
    hack/bootstrap/phases/*.sh
    hack/bootstrap/tests/*.sh
    hack/bootstrap/tests/bats/*.bats
    hack/bootstrap/tests/helpers/*.bash
    hack/bootstrap/lima/*.sh
    hack/bootstrap/ansible/*.sh
    hack/bootstrap/ansible/lib/*.sh
    hack/bootstrap/nodes/*.sh
    hack/bootstrap/nodes/lib/*.sh
  )

  printf 'running ShellCheck with %s jobs\n' "$jobs" >&2
  printf '%s\0' "${files[@]}" | xargs -0 -n 1 -P "$jobs" shellcheck -x
}

run_bats() {
  local jobs
  jobs="$(bootstrap_test_jobs)"

  printf 'running Bats with %s jobs\n' "$jobs" >&2
  bats --jobs "$jobs" --parallel-binary-name rush hack/bootstrap/tests/bats
}

case "${1:-all}" in
  shellcheck)
    run_shellcheck
    ;;
  bats)
    run_bats
    ;;
  all)
    run_shellcheck
    run_bats
    ;;
  *)
    printf 'usage: %s [shellcheck|bats|all]\n' "$0" >&2
    exit 2
    ;;
esac
