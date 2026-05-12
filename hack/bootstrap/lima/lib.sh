#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${BOOTSTRAP_DIR}/../.." && pwd)"

LIMA_CLUSTER_NAME="${LIMA_CLUSTER_NAME:-home-ops-k3s-test}"
BOOTSTRAP_ANSIBLE_BACKEND="${BOOTSTRAP_ANSIBLE_BACKEND:-home-ops}"
BOOTSTRAP_ANSIBLE_OUT_DIR="${BOOTSTRAP_ANSIBLE_OUT_DIR:-${BOOTSTRAP_DIR}/.out/ansible-lima}"
K3S_ANSIBLE_DIR="${K3S_ANSIBLE_DIR:-${REPO_ROOT}/../k3s-ansible}"
LIMA_OUT_DIR="${LIMA_OUT_DIR:-${BOOTSTRAP_DIR}/.out/lima-${LIMA_CLUSTER_NAME}}"
LIMA_SERVER_COUNT="${LIMA_SERVER_COUNT:-1}"
LIMA_AGENT_COUNT="${LIMA_AGENT_COUNT:-2}"
LIMA_K3S_MASTER_TAINT="${LIMA_K3S_MASTER_TAINT:-true}"
LIMA_CPUS="${LIMA_CPUS:-2}"
LIMA_MEMORY_GIB="${LIMA_MEMORY_GIB:-3}"
LIMA_SERVER_CPUS="${LIMA_SERVER_CPUS:-4}"
LIMA_SERVER_MEMORY_GIB="${LIMA_SERVER_MEMORY_GIB:-6}"
LIMA_AGENT_CPUS="${LIMA_AGENT_CPUS:-$LIMA_CPUS}"
LIMA_AGENT_MEMORY_GIB="${LIMA_AGENT_MEMORY_GIB:-$LIMA_MEMORY_GIB}"
LIMA_DISK_GIB="${LIMA_DISK_GIB:-30}"
LIMA_TEMPLATE="${LIMA_TEMPLATE:-template:ubuntu}"
LIMA_KUBECONFIG_PORT="${LIMA_KUBECONFIG_PORT:-16443}"
LIMA_KUBECONTEXT="${LIMA_KUBECONTEXT:-lima-${LIMA_CLUSTER_NAME}}"
LIMA_USER_KUBECONFIG="${LIMA_USER_KUBECONFIG:-${HOME}/.kube/config}"

if [[ ! "$LIMA_SERVER_COUNT" =~ ^[0-9]+$ || "$LIMA_SERVER_COUNT" -lt 1 ]]; then
  printf 'ERROR: LIMA_SERVER_COUNT must be a positive integer\n' >&2
  exit 1
fi

if [[ ! "$LIMA_AGENT_COUNT" =~ ^[0-9]+$ || "$LIMA_AGENT_COUNT" -lt 1 ]]; then
  printf 'ERROR: LIMA_AGENT_COUNT must be a positive integer\n' >&2
  exit 1
fi

case "$LIMA_K3S_MASTER_TAINT" in
  true|false)
    ;;
  *)
    printf 'ERROR: LIMA_K3S_MASTER_TAINT must be true or false\n' >&2
    exit 1
    ;;
esac

LIMA_SERVER_NAMES=()
for server_index in $(seq 1 "$LIMA_SERVER_COUNT"); do
  LIMA_SERVER_NAMES+=("${LIMA_CLUSTER_NAME}-server-${server_index}")
done
LIMA_SERVER_NAME="${LIMA_SERVER_NAMES[0]}"

LIMA_AGENT_NAMES=()
for agent_index in $(seq 1 "$LIMA_AGENT_COUNT"); do
  LIMA_AGENT_NAMES+=("${LIMA_CLUSTER_NAME}-agent-${agent_index}")
done

lima_log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

lima_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

lima_require_tool() {
  command -v "$1" >/dev/null 2>&1 || lima_die "required tool not found: $1"
}

lima_instance_names() {
  printf '%s\n' "${LIMA_SERVER_NAMES[@]}"
  printf '%s\n' "${LIMA_AGENT_NAMES[@]}"
}

lima_is_server_instance() {
  local instance="$1"
  local server
  for server in "${LIMA_SERVER_NAMES[@]}"; do
    [[ "$instance" == "$server" ]] && return 0
  done
  return 1
}

lima_cluster_instance_names() {
  limactl list --format='{{.Name}}' 2>/dev/null |
    grep -E "^${LIMA_CLUSTER_NAME}-(server|agent)-[0-9]+$" || true
}

lima_instance_exists() {
  limactl list --format='{{.Name}}' 2>/dev/null | grep -Fxq "$1"
}

lima_install_guest_prereqs() {
  local instance="$1"
  local attempt
  for attempt in $(seq 1 12); do
    lima_log "installing guest prerequisites on ${instance} (${attempt}/12)"
    if limactl shell --tty=false "$instance" -- sudo sh -lc '
      set -eu
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y open-iscsi nfs-common
      systemctl enable --now iscsid
    '; then
      return 0
    fi
    sleep 10
  done

  lima_die "failed to install guest prerequisites on ${instance}"
}

lima_require_common_tools() {
  lima_require_tool limactl
  lima_require_tool yq
  lima_require_tool jq
}

lima_ssh_option() {
  local instance="$1"
  local option="$2"
  limactl show-ssh --format=options "$instance" |
    awk -F= -v key="$option" '$1 == key {gsub(/^"|"$/, "", $2); print $2; exit}'
}

lima_ssh_config_file() {
  limactl list --format='{{.SSHConfigFile}}' "$1"
}

lima_guest_ip() {
  local instance="$1"
  # shellcheck disable=SC2016
  limactl shell --tty=false "$instance" -- sh -lc '
    ip -4 route get 1.1.1.1 |
      awk "{for (i = 1; i <= NF; i++) if (\$i == \"src\") {print \$(i + 1); exit}}"
  '
}

lima_guest_iface() {
  local instance="$1"
  # shellcheck disable=SC2016
  limactl shell --tty=false "$instance" -- sh -lc '
    ip -4 route show default |
      awk "{print \$5; exit}"
  '
}

lima_inventory_dir() {
  printf '%s\n' "${LIMA_OUT_DIR}/inventory"
}

lima_inventory_source_dir() {
  printf '%s\n' "${LIMA_OUT_DIR}/inventory-source"
}

lima_inventory_file() {
  printf '%s\n' "$(lima_inventory_dir)/hosts.yml"
}

lima_kubeconfig_file() {
  printf '%s\n' "${LIMA_OUT_DIR}/kubeconfig"
}

lima_raw_kubeconfig_file() {
  case "$BOOTSTRAP_ANSIBLE_BACKEND" in
    k3s-ansible)
      printf '%s\n' "${K3S_ANSIBLE_DIR}/kubeconfig"
      ;;
    home-ops)
      printf '%s\n' "${BOOTSTRAP_ANSIBLE_OUT_DIR}/kubeconfig-raw-lima"
      ;;
    *)
      lima_die "unknown Ansible backend: ${BOOTSTRAP_ANSIBLE_BACKEND}"
      ;;
  esac
}

lima_tunnel_pid_file() {
  printf '%s\n' "${LIMA_OUT_DIR}/apiserver-tunnel.pid"
}

lima_tunnel_port_open() {
  nc -z 127.0.0.1 "$LIMA_KUBECONFIG_PORT" >/dev/null 2>&1
}

lima_tunnel_pid_alive() {
  local pid pid_file
  pid_file="$(lima_tunnel_pid_file)"
  [[ -f "$pid_file" ]] || return 1
  pid="$(<"$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

lima_prepare_kubeconfig() {
  local raw_kubeconfig
  local kubeconfig
  raw_kubeconfig="$(lima_raw_kubeconfig_file)"
  kubeconfig="$(lima_kubeconfig_file)"
  [[ -f "$raw_kubeconfig" ]] || lima_die "missing kubeconfig from ${BOOTSTRAP_ANSIBLE_BACKEND} run: ${raw_kubeconfig}"
  mkdir -p "$LIMA_OUT_DIR"
  cp "$raw_kubeconfig" "$kubeconfig"
  LIMA_KUBECONTEXT="$LIMA_KUBECONTEXT" yq -i '
    .clusters[0].name = strenv(LIMA_KUBECONTEXT) |
    .users[0].name = strenv(LIMA_KUBECONTEXT) |
    .contexts[0].name = strenv(LIMA_KUBECONTEXT) |
    .contexts[0].context.cluster = strenv(LIMA_KUBECONTEXT) |
    .contexts[0].context.user = strenv(LIMA_KUBECONTEXT) |
    ."current-context" = strenv(LIMA_KUBECONTEXT)
  ' "$kubeconfig"
  kubectl --kubeconfig "$kubeconfig" config set-cluster "$LIMA_KUBECONTEXT" \
    --server="https://127.0.0.1:${LIMA_KUBECONFIG_PORT}" \
    --insecure-skip-tls-verify=true >/dev/null
  kubectl --kubeconfig "$kubeconfig" config unset "clusters.${LIMA_KUBECONTEXT}.certificate-authority-data" >/dev/null 2>&1 || true
  printf '%s\n' "$kubeconfig"
}

lima_existing_apiserver_tunnel_valid() {
  local raw_kubeconfig
  local kubeconfig
  raw_kubeconfig="$(lima_raw_kubeconfig_file)"
  [[ -f "$raw_kubeconfig" ]] || return 1
  kubeconfig="$(lima_prepare_kubeconfig)"
  kubectl --kubeconfig "$kubeconfig" get "node/lima-${LIMA_SERVER_NAME}" >/dev/null 2>&1
}

lima_start_apiserver_tunnel() {
  local pid pid_file ssh_config
  pid_file="$(lima_tunnel_pid_file)"
  if lima_tunnel_pid_alive && lima_tunnel_port_open; then
    cat "$pid_file"
    return 0
  fi
  if [[ -f "$pid_file" ]]; then
    rm -f "$pid_file"
  fi
  if lima_tunnel_port_open; then
    if lima_existing_apiserver_tunnel_valid; then
      lima_log "using verified existing API tunnel on 127.0.0.1:${LIMA_KUBECONFIG_PORT}"
      return 0
    fi
    lima_die "port 127.0.0.1:${LIMA_KUBECONFIG_PORT} is already in use and is not a verified Lima API tunnel"
  fi
  ssh_config="$(lima_ssh_config_file "$LIMA_SERVER_NAME")"
  [[ -f "$ssh_config" ]] || lima_die "missing Lima SSH config for ${LIMA_SERVER_NAME}: ${ssh_config}"
  mkdir -p "$LIMA_OUT_DIR"
  ssh -F "$ssh_config" -N \
    -L "127.0.0.1:${LIMA_KUBECONFIG_PORT}:127.0.0.1:6443" \
    "lima-${LIMA_SERVER_NAME}" &
  pid="$!"
  printf '%s\n' "$pid" > "$pid_file"
  for _ in $(seq 1 30); do
    if lima_tunnel_port_open; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 1
  done
  kill "$pid" >/dev/null 2>&1 || true
  lima_die "timed out waiting for API server tunnel on 127.0.0.1:${LIMA_KUBECONFIG_PORT}"
}

lima_stop_tunnel() {
  local pid="${1:-}"
  if [[ -z "$pid" && -f "$(lima_tunnel_pid_file)" ]]; then
    pid="$(<"$(lima_tunnel_pid_file)")"
  fi
  [[ -n "$pid" ]] || return 0
  kill "$pid" >/dev/null 2>&1 || true
  rm -f "$(lima_tunnel_pid_file)"
}

lima_import_kubeconfig() {
  local kubeconfig kubeconfig_env previous_context target tmp
  kubeconfig="$(lima_prepare_kubeconfig)"
  kubeconfig_env="${KUBECONFIG:-$LIMA_USER_KUBECONFIG}"
  target="${kubeconfig_env%%:*}"
  mkdir -p "$(dirname "$target")"
  touch "$target"
  chmod 0600 "$target" >/dev/null 2>&1 || true
  previous_context="$(kubectl --kubeconfig "$target" config current-context 2>/dev/null || true)"
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  KUBECONFIG="${kubeconfig}:${kubeconfig_env}" kubectl config view --flatten > "$tmp"
  if [[ -n "$previous_context" ]]; then
    kubectl --kubeconfig "$tmp" config use-context "$previous_context" >/dev/null
  fi
  chmod 0600 "$tmp"
  mv "$tmp" "$target"
  lima_log "imported kube context ${LIMA_KUBECONTEXT} into ${target}"
}

lima_install_host_kubecontext() {
  lima_require_tool kubectl
  lima_require_tool nc
  lima_start_apiserver_tunnel >/dev/null
  lima_import_kubeconfig
}
