#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/validate/lib.sh
source "${SCRIPT_DIR}/lib.sh"

playbooks=(
  hack/bootstrap/ansible/home-ops/site.yml
  hack/bootstrap/ansible/home-ops/host-services.yml
  hack/bootstrap/ansible/home-ops/control-plane-finalize.yml
  hack/bootstrap/ansible/home-ops/control-plane-join.yml
  hack/bootstrap/ansible/home-ops/worker-finalize.yml
  hack/bootstrap/ansible/home-ops/worker-join.yml
  hack/bootstrap/ansible/playbooks/disable-kube-proxy.yml
  hack/bootstrap/ansible/playbooks/home-ops-prereqs.yml
)

should_run=1

validate_require_tool ansible-lint
if (($# > 0)); then
  should_run=0
  validate_select_yaml_files "$@"
  for path in "${VALIDATE_FILES[@]}"; do
    if [[ "${path}" =~ ^hack/bootstrap/ansible/(home-ops|playbooks)/.*\.ya?ml$ ]]; then
      should_run=1
      break
    fi
  done
fi

if ((should_run == 0)); then
  printf 'No Ansible playbook files to check.\n'
  exit 0
fi

ansible-lint --offline "${playbooks[@]}"
