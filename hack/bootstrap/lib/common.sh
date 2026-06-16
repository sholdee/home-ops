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

# Verify the drydock on PATH is at least the given version. The bootstrap renders
# every app with drydock (lib/render.sh drydock_app); a stale binary -- e.g. a
# Homebrew install shadowing the mise-pinned one -- silently mis-renders, most
# dangerously cert-manager's leaderelection RBAC into the wrong namespace (fixed in
# drydock v0.2.1 / #152). Fail fast at preflight rather than break cert-manager mid-run.
require_drydock_version() {
  local required="$1" found
  found="$(drydock version 2>/dev/null | awk '/^version:/{print $2}' | sed 's/^v//')"
  [[ -n "$found" ]] || die "could not determine drydock version (need >= v${required})"
  if [[ "$(printf '%s\n%s\n' "$required" "$found" | sort -V | head -n1)" != "$required" ]]; then
    die "drydock >= v${required} required (cert-manager leaderelection fix #152); found v${found}. Run under mise (mise.toml pins it) or upgrade the drydock on PATH."
  fi
}

bool() {
  [[ "${1:-}" == true ]]
}

join_by() {
  local IFS="$1"
  shift
  echo "$*"
}
