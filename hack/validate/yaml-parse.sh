#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/validate/lib.sh
source "${SCRIPT_DIR}/lib.sh"

failed=0

validate_require_tool yq
validate_select_yaml_files "$@"
validate_skip_if_empty YAML

for path in "${VALIDATE_FILES[@]}"; do
  if ! yq eval '.' "${path}" >/dev/null; then
    printf 'ERROR: YAML parse failed: %s\n' "${path}" >&2
    failed=1
  fi
done

exit "${failed}"
