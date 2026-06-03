#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/validate/lib.sh
source "${SCRIPT_DIR}/lib.sh"

failed=0
schema_tmp_dir=""

validate_require_tool curl
validate_require_tool jsonschema
validate_select_tracked_regular_files "$@"

trap '[[ -z "${schema_tmp_dir}" ]] || rm -rf "${schema_tmp_dir}"' EXIT

schema_path() {
  local schema="$1"
  local output

  if [[ ! "${schema}" =~ ^https?:// ]]; then
    printf '%s\n' "${schema}"
    return 0
  fi

  if [[ -z "${schema_tmp_dir}" ]]; then
    schema_tmp_dir="$(mktemp -d)"
  fi

  output="${schema_tmp_dir}/$(basename "${schema}")"
  curl -fsSL --retry 3 "${schema}" -o "${output}"
  printf '%s\n' "${output}"
}

run_jsonschema() {
  local schema="$1"
  shift
  local files=("$@")
  local resolved_schema

  ((${#files[@]} > 0)) || return 0
  resolved_schema="$(schema_path "${schema}")"
  jsonschema validate "${resolved_schema}" "${files[@]}"
}

if validate_has_file apps/monitoring/kromgo/manifests/config.yaml; then
  if ! run_jsonschema \
    'https://raw.githubusercontent.com/home-operations/kromgo/0.14.0/config.schema.json' \
    apps/monitoring/kromgo/manifests/config.yaml; then
    failed=1
  fi
fi

if validate_has_file apps/external-dns/manifests/values.yaml; then
  if ! run_jsonschema \
    'https://raw.githubusercontent.com/kubernetes-sigs/external-dns/refs/tags/external-dns-helm-chart-1.21.1/charts/external-dns/values.schema.json' \
    apps/external-dns/manifests/values.yaml; then
    failed=1
  fi
fi

action_files=()
for path in "${VALIDATE_FILES[@]}"; do
  if [[ "${path}" =~ ^\.github/actions/.*/action\.ya?ml$ ]]; then
    action_files+=("${path}")
  fi
done

if ! run_jsonschema .github/schemas/github-action.json "${action_files[@]}"; then
  failed=1
fi

if ((failed == 0)) && \
  ! validate_has_file apps/monitoring/kromgo/manifests/config.yaml && \
  ! validate_has_file apps/external-dns/manifests/values.yaml && \
  ((${#action_files[@]} == 0)); then
  printf 'No JSON Schema target files to check.\n'
fi

exit "${failed}"
