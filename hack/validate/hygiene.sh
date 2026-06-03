#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/validate/lib.sh
source "${SCRIPT_DIR}/lib.sh"

threshold_bytes=512000
failed=0

validate_require_tool git
validate_select_tracked_regular_files "$@"
validate_skip_if_empty tracked

if ! validate_run_git_grep 'trailing whitespace' '[[:blank:]]$'; then
  failed=1
fi

if ! validate_run_git_grep 'CRLF line endings' $'\r$' files; then
  failed=1
fi

if ! validate_run_git_grep 'merge conflict markers' '^(<{7}|>{7}|={7})([[:space:]]|$)|^\|{7}([[:space:]]|$)'; then
  failed=1
fi

large_files=()
missing_newline_files=()
for path in "${VALIDATE_FILES[@]}"; do
  size="$(wc -c <"${path}")"
  size="${size//[[:space:]]/}"
  if ((size > threshold_bytes)); then
    large_files+=("${path} (${size} bytes)")
  fi

  if [[ -s "${path}" ]] && validate_is_text_file "${path}"; then
    last_byte="$(tail -c 1 "${path}" | od -An -tx1 | tr -d '[:space:]')"
    if [[ "${last_byte}" != "0a" ]]; then
      missing_newline_files+=("${path}")
    fi
  fi
done

if ((${#large_files[@]} > 0)); then
  printf 'ERROR: tracked files exceed %s bytes:\n' "${threshold_bytes}" >&2
  printf '%s\n' "${large_files[@]}" >&2
  failed=1
fi

if ((${#missing_newline_files[@]} > 0)); then
  printf 'ERROR: text files missing final newline:\n' >&2
  printf '%s\n' "${missing_newline_files[@]}" >&2
  failed=1
fi

exit "${failed}"
