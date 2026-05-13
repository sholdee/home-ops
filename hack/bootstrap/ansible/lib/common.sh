#!/usr/bin/env bash
# shellcheck shell=bash

ansible_log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

ansible_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

ansible_require_tool() {
  command -v "$1" >/dev/null 2>&1 || ansible_die "required tool not found: $1"
}

ansible_bool() {
  [[ "${1:-}" == true ]]
}
