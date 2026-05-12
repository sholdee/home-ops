#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

lima_require_common_tools

mkdir -p "$LIMA_OUT_DIR"

for instance in $(lima_instance_names); do
  if lima_instance_exists "$instance"; then
    lima_die "Lima instance already exists: ${instance}; run hack/bootstrap/lima/delete.sh first"
  fi
done

for instance in $(lima_instance_names); do
  cpus="$LIMA_AGENT_CPUS"
  memory_gib="$LIMA_AGENT_MEMORY_GIB"
  if lima_is_server_instance "$instance"; then
    cpus="$LIMA_SERVER_CPUS"
    memory_gib="$LIMA_SERVER_MEMORY_GIB"
  fi
  lima_log "creating Lima instance ${instance}"
  limactl start --tty=false \
    --name="$instance" \
    --cpus="$cpus" \
    --memory="$memory_gib" \
    --disk="$LIMA_DISK_GIB" \
    --network=lima:user-v2 \
    "$LIMA_TEMPLATE"
  lima_install_guest_prereqs "$instance"
done

"${SCRIPT_DIR}/inventory.sh"
