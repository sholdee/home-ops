#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/validate/lib.sh
source "${SCRIPT_DIR}/lib.sh"

validate_require_tool oxfmt
validate_select_tracked_regular_files "$@"
validate_keep_extensions \
  js jsx ts tsx mjs cjs \
  json jsonc json5 \
  yaml yml toml \
  html htm css scss less \
  md mdx graphql gql
validate_skip_if_empty oxfmt-supported

oxfmt --check "${VALIDATE_FILES[@]}"
