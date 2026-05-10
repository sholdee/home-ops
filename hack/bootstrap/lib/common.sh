#!/usr/bin/env bash

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

log_phase() {
  log "phase: $1"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

bool() {
  [[ "${1:-}" == true ]]
}

join_by() {
  local IFS="$1"
  shift
  echo "$*"
}
