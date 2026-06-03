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

shellcheck -x "${VALIDATE_FILES[@]}"
