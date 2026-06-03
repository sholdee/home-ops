#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/validate/lib.sh
source "${SCRIPT_DIR}/lib.sh"

validate_require_tool kubeconform
validate_select_yaml_files "$@"
validate_drop_matching '(^\.github/|^hack/bootstrap/ansible/|^hack/bootstrap/kind-three-node\.yaml$|(^|/)values[^/]*\.ya?ml$|kromgo/manifests/config\.yaml$|^lefthook\.yml$|^\.(pre-commit-config|yamllint|markdownlint-cli2)\.yaml$)'
validate_skip_if_empty Kubernetes

kubeconform \
  -strict \
  -schema-location 'https://kube-schemas.shold.io/core/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -schema-location 'https://kube-schemas.shold.io/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  "${VALIDATE_FILES[@]}"
