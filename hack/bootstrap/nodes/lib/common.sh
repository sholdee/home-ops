# shellcheck shell=bash

node_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

node_warn() {
  printf 'WARN: %s\n' "$*" >&2
}

node_log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

node_require_tool() {
  command -v "$1" >/dev/null 2>&1 || node_die "required tool not found: $1"
}

node_bool() {
  [[ "${1:-}" == true ]]
}

node_confirm() {
  local yes="$1"
  local expected="$2"

  if node_bool "$yes"; then
    return
  fi

  printf 'Type "%s" to continue: ' "$expected" >&2
  local answer
  read -r answer
  [[ "$answer" == "$expected" ]] || node_die "confirmation failed"
}


node_contains_line() {
  local needle="$1"
  shift
  local value
  for value in "$@"; do
    [[ "$value" == "$needle" ]] && return 0
  done
  return 1
}

node_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

node_extract_block() {
  local begin="$1"
  local end="$2"
  awk -v begin="$begin" -v end="$end" '
    $0 == begin {inside = 1; next}
    $0 == end {inside = 0}
    inside {print}
  '
}

node_filter_ansible_probe_output() {
  local host="$1"
  awk -v host="$host" '
    $0 == host " | CHANGED | rc=0 >>" {next}
    $0 == host " | SUCCESS | rc=0 >>" {next}
    /^\[WARNING\]: / {next}
    {print}
  '
}
