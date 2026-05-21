#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/lima/profile-env.sh PROFILE COMMAND [ARG...]

Apply Lima profile defaults, preserving any caller-provided environment
overrides, then exec COMMAND.

Profiles:
  lima-longhorn
  lima-apps
EOF
}

[[ $# -ge 2 ]] || {
  usage >&2
  exit 2
}

profile="$1"
shift

set_default() {
  local name="$1"
  local value="$2"
  if [[ -z "${!name+x}" ]]; then
    export "${name}=${value}"
  fi
}

case "$profile" in
  lima-longhorn)
    set_default LIMA_SERVER_COUNT 3
    set_default LIMA_AGENT_COUNT 1
    set_default LIMA_K3S_MASTER_TAINT false
    set_default LIMA_SERVER_CPUS 3
    set_default LIMA_AGENT_CPUS 3
    set_default LIMA_SERVER_MEMORY_GIB 4
    set_default LIMA_AGENT_MEMORY_GIB 4
    set_default LIMA_DISK_GIB 80
    set_default LIMA_VALIDATE_APP_WAIT_SECONDS 2400
    ;;
  lima-apps)
    set_default LIMA_SERVER_COUNT 3
    set_default LIMA_AGENT_COUNT 1
    set_default LIMA_K3S_MASTER_TAINT false
    set_default LIMA_SERVER_CPUS 3
    set_default LIMA_AGENT_CPUS 3
    set_default LIMA_SERVER_MEMORY_GIB 5
    set_default LIMA_AGENT_MEMORY_GIB 5
    set_default LIMA_DISK_GIB 120
    set_default LIMA_VALIDATE_APP_WAIT_SECONDS 3600
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    printf 'ERROR: unknown Lima profile: %s\n' "$profile" >&2
    exit 2
    ;;
esac

exec "$@"
