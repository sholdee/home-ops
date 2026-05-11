#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

lima_require_common_tools

lima_stop_tunnel

for instance in $(lima_instance_names); do
  if lima_instance_exists "$instance"; then
    lima_log "deleting Lima instance ${instance}"
    limactl delete --force "$instance"
  else
    lima_log "Lima instance absent: ${instance}"
  fi
done
