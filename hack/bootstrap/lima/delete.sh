#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/lima/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

lima_require_common_tools

lima_stop_tunnel ""

deleted_any=false
for _ in $(seq 1 5); do
  found=false
  instances="$(
    {
      lima_instance_names
      lima_cluster_instance_names
    } | sort -u
  )"

  while IFS= read -r instance; do
    [[ -n "$instance" ]] || continue
    if lima_instance_exists "$instance"; then
      found=true
      deleted_any=true
      lima_log "deleting Lima instance ${instance}"
      limactl delete --force "$instance"
    fi
  done <<<"$instances"

  if [[ "$found" == false ]]; then
    if [[ "$deleted_any" == false ]]; then
      lima_log "no Lima instances found for ${LIMA_CLUSTER_NAME}"
    fi
    exit 0
  fi

  sleep 1
done

remaining="$(lima_cluster_instance_names)"
[[ -z "$remaining" ]] || lima_die "failed to delete Lima instances: ${remaining//$'\n'/, }"
