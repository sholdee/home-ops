#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/reimage-reboot.sh [options] NODE

Reboot a staged Raspberry Pi into one-shot tryboot reimage mode.

Options:
  --profile NAME   Node lifecycle profile: live or lima. Defaults to live.
  --context NAME   Kubernetes context. Defaults to the profile context.
  --force          Skip only the Kubernetes-node-absent check.
  --yes            Skip confirmation prompt.
  -h, --help       Show help.
EOF
}

profile=live
context=""
force=false
yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="$2"
      shift 2
      ;;
    --context)
      context="$2"
      shift 2
      ;;
    --force)
      force=true
      shift
      ;;
    --yes)
      yes=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      node_die "unknown argument: $1"
      ;;
    *)
      if [[ -n "${node_name:-}" ]]; then
        node_die "only one node may be provided"
      fi
      node_name="$1"
      shift
      ;;
  esac
done

[[ -n "${node_name:-}" ]] || node_die "NODE is required"
node_validate_profile "$profile"
context="${context:-$(node_context_for_profile "$profile")}"

node_require_tool "$NODE_YQ_BIN"
node_require_tool "$NODE_JQ_BIN"
node_require_tool ansible

IFS=$'\t' read -r inventory_node inventory_role < <(node_resolve_inventory_node "$profile" "$node_name")
case "$inventory_role" in
  master|node)
    ;;
  absent)
    node_die "node is not present in ${profile} inventory: ${node_name}"
    ;;
  conflict)
    node_die "node is present in multiple ${profile} inventory groups: ${node_name}"
    ;;
  *)
    node_die "could not resolve inventory role for node: ${node_name}"
    ;;
esac

kubernetes_node="$(node_expected_kubernetes_node_name "$profile" "$inventory_node" "$node_name")"
if node_bool "$force"; then
  node_warn "force enabled; skipping Kubernetes node-absent check for ${kubernetes_node}"
else
  node_require_tool "$NODE_KUBECTL_BIN"
  node_assert_api_reachable "$context"
  if node_has_resource "$context" "node/${kubernetes_node}"; then
    node_die "Kubernetes node still exists; run just node-delete ${kubernetes_node} before tryboot reimage"
  fi
fi

node_reimage_assert_staged "$profile" "$inventory_node" "$kubernetes_node"
node_confirm "$yes" "reboot ${inventory_node} into tryboot reimage"

node_log "rebooting ${inventory_node} with one-shot tryboot flag"
node_run_remote_shell "$(node_ansible_inventory_file "$profile")" "$inventory_node" \
  "nohup sh -c 'sleep 1; reboot \"0 tryboot\"' >/dev/null 2>&1 &" >/dev/null
node_log "tryboot reboot scheduled: ${inventory_node}"
