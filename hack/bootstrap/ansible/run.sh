#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/ansible/run.sh [options]

Options:
  --profile NAME          Inventory profile: live or lima. Defaults to live.
  --inventory-source DIR  Source inventory directory.
  --inventory-dir DIR     Existing/generated inventory directory.
  --skip-render           Use --inventory-dir as-is.
  --skip-prereqs          Do not run the home-ops node prerequisite playbook.
  --skip-site             Do not run k3s-ansible site.yml.
  --skip-import           Do not import the fetched kubeconfig.
  --kube-bootstrap        Run hack/bootstrap/bootstrap.sh --profile full after Ansible.
  --plan                  Render inventory and print summary only.
  --yes                   Skip live confirmation prompts.
  -h, --help              Show help.
EOF
}

profile="live"
source_dir=""
inventory_dir=""
skip_render=false
skip_prereqs=false
skip_site=false
skip_import=false
kube_bootstrap=false
plan=false
yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="$2"
      shift 2
      ;;
    --inventory-source)
      source_dir="$2"
      shift 2
      ;;
    --inventory-dir)
      inventory_dir="$2"
      shift 2
      ;;
    --skip-render)
      skip_render=true
      shift
      ;;
    --skip-prereqs)
      skip_prereqs=true
      shift
      ;;
    --skip-site)
      skip_site=true
      shift
      ;;
    --skip-import)
      skip_import=true
      shift
      ;;
    --kube-bootstrap)
      kube_bootstrap=true
      shift
      ;;
    --plan)
      plan=true
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
    *)
      ansible_die "unknown argument: $1"
      ;;
  esac
done

case "$profile" in
  live)
    source_dir="${source_dir:-$BOOTSTRAP_ANSIBLE_LIVE_INVENTORY_DIR}"
    ;;
  lima)
    [[ -n "$source_dir" || "$skip_render" == true ]] || ansible_die "--inventory-source is required for lima unless --skip-render is used"
    ;;
  *)
    ansible_die "unknown Ansible bootstrap profile: ${profile}"
    ;;
esac

inventory_dir="${inventory_dir:-$(ansible_inventory_dir "$profile")}"
inventory_file="${inventory_dir}/hosts.yml"

ansible_require_tool yq
ansible_require_tool jq

if ! ansible_bool "$skip_render"; then
  ansible_render_inventory "$profile" "$source_dir" "$inventory_dir"
fi

if ansible_bool "$plan"; then
  ansible_print_summary "$profile" "$inventory_dir"
  exit 0
fi

ansible_require_tool ansible-playbook
ansible_require_tool ansible-galaxy
if ! ansible_bool "$skip_import" || ansible_bool "$kube_bootstrap"; then
  ansible_require_tool kubectl
fi

if [[ "$profile" == live ]]; then
  ansible_require_tool op
  ansible_require_tool openssl
  ansible_require_tool ssh
  ansible_confirm_live_run "$yes" "$inventory_dir" "$kube_bootstrap"
  K3S_TOKEN="$(ansible_prepare_live_token "$inventory_dir")"
  export K3S_TOKEN
fi

if ! ansible_bool "$skip_prereqs"; then
  ansible_run_prereqs "$inventory_file"
fi

ansible_install_collections

if ! ansible_bool "$skip_site"; then
  ansible_run_site "$inventory_file"
fi

if ! ansible_bool "$skip_import"; then
  ansible_import_kubeconfig "$profile"
fi

if ansible_bool "$kube_bootstrap"; then
  kubeconfig="$(ansible_kubeconfig_file "$profile")"
  ansible_log "running home-ops Kubernetes bootstrap through ${kubeconfig}"
  "${BOOTSTRAP_DIR}/bootstrap.sh" \
    --repo "$REPO_ROOT" \
    --kubeconfig "$kubeconfig" \
    --profile full \
    --yes
fi
