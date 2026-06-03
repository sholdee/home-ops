#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

VALIDATE_ROOT="$(git rev-parse --show-toplevel)"
cd "${VALIDATE_ROOT}"

VALIDATE_FILES=()

validate_require_tool() {
  local tool="$1"

  if ! command -v "${tool}" >/dev/null 2>&1; then
    printf 'ERROR: required tool not found: %s\n' "${tool}" >&2
    exit 127
  fi
}

validate_add_file() {
  local path="$1"
  local existing

  for existing in "${VALIDATE_FILES[@]}"; do
    [[ "${existing}" == "${path}" ]] && return 0
  done

  VALIDATE_FILES+=("${path}")
}

validate_normalize_path() {
  local path="$1"

  path="${path#./}"
  if [[ "${path}" == "${VALIDATE_ROOT}/"* ]]; then
    path="${path#"${VALIDATE_ROOT}/"}"
  fi

  printf '%s\n' "${path}"
}

validate_select_tracked_regular_files() {
  local path

  VALIDATE_FILES=()

  if (($# > 0)); then
    for path in "$@"; do
      [[ -n "${path}" ]] || continue
      path="$(validate_normalize_path "${path}")"
      [[ -f "${path}" && ! -L "${path}" ]] || continue
      if git ls-files --error-unmatch -- "${path}" >/dev/null 2>&1; then
        validate_add_file "${path}"
      fi
    done
    return 0
  fi

  while IFS= read -r -d '' path; do
    [[ -f "${path}" && ! -L "${path}" ]] || continue
    validate_add_file "${path}"
  done < <(git ls-files -z)
}

validate_keep_extensions() {
  local path
  local extension
  local kept=()

  for path in "${VALIDATE_FILES[@]}"; do
    for extension in "$@"; do
      if [[ "${path}" == *".${extension}" ]]; then
        kept+=("${path}")
        continue 2
      fi
    done
  done

  VALIDATE_FILES=("${kept[@]}")
}

validate_keep_matching() {
  local pattern="$1"
  local path
  local kept=()

  for path in "${VALIDATE_FILES[@]}"; do
    if [[ "${path}" =~ ${pattern} ]]; then
      kept+=("${path}")
    fi
  done

  VALIDATE_FILES=("${kept[@]}")
}

validate_drop_matching() {
  local pattern="$1"
  local path
  local kept=()

  for path in "${VALIDATE_FILES[@]}"; do
    if [[ ! "${path}" =~ ${pattern} ]]; then
      kept+=("${path}")
    fi
  done

  VALIDATE_FILES=("${kept[@]}")
}

validate_select_yaml_files() {
  validate_select_tracked_regular_files "$@"
  validate_keep_extensions yaml yml
}

validate_has_file() {
  local wanted="$1"
  local path

  for path in "${VALIDATE_FILES[@]}"; do
    [[ "${path}" == "${wanted}" ]] && return 0
  done

  return 1
}

validate_skip_if_empty() {
  local label="$1"

  if ((${#VALIDATE_FILES[@]} == 0)); then
    printf 'No %s files to check.\n' "${label}"
    exit 0
  fi
}

validate_run_git_grep() {
  local label="$1"
  local pattern="$2"
  local mode="${3:-extended}"
  local matches
  local status

  case "${mode}" in
    basic)
      matches="$(git grep -I -n "${pattern}" -- "${VALIDATE_FILES[@]}")" || status=$?
      ;;
    files)
      matches="$(git grep -I -l "${pattern}" -- "${VALIDATE_FILES[@]}")" || status=$?
      ;;
    extended)
      matches="$(git grep -I -n -E "${pattern}" -- "${VALIDATE_FILES[@]}")" || status=$?
      ;;
    *)
      printf 'ERROR: unknown git grep mode: %s\n' "${mode}" >&2
      exit 2
      ;;
  esac

  status="${status:-0}"
  if ((status == 0)); then
    printf 'ERROR: %s found:\n%s\n' "${label}" "${matches}" >&2
    return 1
  fi

  if ((status != 1)); then
    printf 'ERROR: git grep failed while checking %s\n' "${label}" >&2
    return "${status}"
  fi

  return 0
}

validate_is_text_file() {
  local path="$1"

  LC_ALL=C grep -Iq '' "${path}"
}
