#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/validate/lib.sh
source "${SCRIPT_DIR}/lib.sh"

validate_require_tool shellcheck
validate_select_tracked_regular_files "$@"
validate_keep_extensions sh bash bats
validate_skip_if_empty shell

shellcheck_jobs="${SHELLCHECK_JOBS:-}"
if [[ -z "${shellcheck_jobs}" ]]; then
  shellcheck_jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
fi
if [[ -z "${shellcheck_jobs}" ]]; then
  shellcheck_jobs="$(sysctl -n hw.ncpu 2>/dev/null || true)"
fi
if [[ ! "${shellcheck_jobs}" =~ ^[1-9][0-9]*$ ]]; then
  shellcheck_jobs=4
fi

shellcheck_batch_size="${SHELLCHECK_BATCH_SIZE:-4}"
if [[ ! "${shellcheck_batch_size}" =~ ^[1-9][0-9]*$ ]]; then
  shellcheck_batch_size=4
fi

printf '%s\0' "${VALIDATE_FILES[@]}" |
  xargs -0 -n "${shellcheck_batch_size}" -P "${shellcheck_jobs}" shellcheck -x
