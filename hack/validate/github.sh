#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/validate/lib.sh
source "${SCRIPT_DIR}/lib.sh"

failed=0

validate_require_tool actionlint
validate_require_tool zizmor
validate_select_tracked_regular_files "$@"

workflow_files=()
zizmor_files=()
for path in "${VALIDATE_FILES[@]}"; do
  case "${path}" in
    .github/workflows/*.yaml|.github/workflows/*.yml)
      workflow_files+=("${path}")
      zizmor_files+=("${path}")
      ;;
    .github/actions/*/action.yaml|.github/actions/*/action.yml)
      zizmor_files+=("${path}")
      ;;
  esac
done

if ((${#workflow_files[@]} > 0)); then
  if ! actionlint "${workflow_files[@]}"; then
    failed=1
  fi
fi

if ((${#zizmor_files[@]} > 0)); then
  if ! zizmor --offline --strict-collection --min-severity high --min-confidence high "${zizmor_files[@]}"; then
    failed=1
  fi
fi

if ((${#workflow_files[@]} == 0 && ${#zizmor_files[@]} == 0)); then
  printf 'No GitHub workflow/action files to check.\n'
fi

exit "${failed}"
