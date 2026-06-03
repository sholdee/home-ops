#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/validate/lib.sh
source "${SCRIPT_DIR}/lib.sh"

failed=0
scan_dir=""

validate_require_tool gitleaks
validate_select_tracked_regular_files "$@"
validate_skip_if_empty tracked

trap '[[ -z "${scan_dir}" ]] || rm -rf "${scan_dir}"' EXIT

scan_dir="$(mktemp -d)"
for path in "${VALIDATE_FILES[@]}"; do
  mkdir -p "${scan_dir}/$(dirname "${path}")"
  cp -p "${path}" "${scan_dir}/${path}"
done

if ! gitleaks --no-banner --redact=100 --exit-code 1 --log-level warn dir "${scan_dir}"; then
  failed=1
fi

exit "${failed}"
