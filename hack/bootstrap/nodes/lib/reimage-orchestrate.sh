# shellcheck shell=bash

NODE_REIMAGE_BUILD_SCHEMA="home-ops.node-reimage-build/v1"
NODE_REIMAGE_SERVE_SCHEMA="home-ops.node-reimage-serve/v1"
NODE_REIMAGE_APPLY_SCHEMA="home-ops.node-reimage-apply/v1"
NODE_REIMAGE_CLEANUP_SCHEMA="home-ops.node-reimage-cleanup/v1"
NODE_REIMAGE_BUILDER_NAME="${NODE_REIMAGE_BUILDER_NAME:-home-ops-rpi-image-builder}"
NODE_REIMAGE_BUILDER_CPUS="${NODE_REIMAGE_BUILDER_CPUS:-6}"
NODE_REIMAGE_BUILDER_MEMORY_GIB="${NODE_REIMAGE_BUILDER_MEMORY_GIB:-8}"
NODE_REIMAGE_BUILDER_DISK_GIB="${NODE_REIMAGE_BUILDER_DISK_GIB:-120}"
NODE_REIMAGE_BUILDER_TEMPLATE="${NODE_REIMAGE_BUILDER_TEMPLATE:-template:debian-13}"
NODE_REIMAGE_BUILDER_MODE="${NODE_REIMAGE_BUILDER_MODE:-auto}"
NODE_REIMAGE_DEFAULT_PORT="${NODE_REIMAGE_DEFAULT_PORT:-18080}"
NODE_REIMAGE_SSH_DOWN_TIMEOUT_SECONDS="${NODE_REIMAGE_SSH_DOWN_TIMEOUT_SECONDS:-180}"
NODE_REIMAGE_SSH_UP_TIMEOUT_SECONDS="${NODE_REIMAGE_SSH_UP_TIMEOUT_SECONDS:-1800}"
NODE_REIMAGE_STAGE_BIN="${NODE_REIMAGE_STAGE_BIN:-${NODE_SCRIPT_DIR}/reimage-stage.sh}"
NODE_REIMAGE_REBOOT_BIN="${NODE_REIMAGE_REBOOT_BIN:-${NODE_SCRIPT_DIR}/reimage-reboot.sh}"
NODE_REFRESH_SSH_HOST_KEY_BIN="${NODE_REFRESH_SSH_HOST_KEY_BIN:-${NODE_SCRIPT_DIR}/refresh-ssh-host-key.sh}"

node_reimage_node_dir() {
  local profile="$1"
  local inventory_node="$2"
  printf '%s/%s/%s\n' "$(node_reimage_image_output_root)" "$profile" "$inventory_node"
}

node_reimage_state_dir() {
  printf '%s/state\n' "$(node_reimage_node_dir "$1" "$2")"
}

node_reimage_build_state_file() {
  printf '%s/build.json\n' "$(node_reimage_state_dir "$1" "$2")"
}

node_reimage_serve_state_file() {
  printf '%s/serve.json\n' "$(node_reimage_state_dir "$1" "$2")"
}

node_reimage_apply_state_file() {
  printf '%s/apply.json\n' "$(node_reimage_state_dir "$1" "$2")"
}

node_reimage_cleanup_state_file() {
  printf '%s/cleanup.json\n' "$(node_reimage_state_dir "$1" "$2")"
}

node_reimage_resolve_existing_inventory_node() {
  local profile="$1"
  local input_node="$2"
  local inventory_node inventory_role

  IFS=$'\t' read -r inventory_node inventory_role < <(node_resolve_inventory_node "$profile" "$input_node")
  case "$inventory_role" in
    master|node)
      printf '%s\t%s\n' "$inventory_node" "$inventory_role"
      ;;
    absent)
      node_die "node is not present in ${profile} inventory: ${input_node}"
      ;;
    conflict)
      node_die "node is present in multiple ${profile} inventory groups: ${input_node}"
      ;;
    *)
      node_die "could not resolve inventory role for node: ${input_node}"
      ;;
  esac
}

node_reimage_read_state_value() {
  local file="$1"
  local query="$2"
  [[ -f "$file" ]] || node_die "missing reimage state file: ${file}"
  "$NODE_JQ_BIN" -er "$query" "$file"
}

node_reimage_sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print tolower($1)}'
  else
    node_die "required tool not found: sha256sum or shasum"
  fi
}

node_reimage_remote_dir_for() {
  local inventory_node="$1"
  printf '/tmp/home-ops-reimage/%s\n' "$inventory_node"
}

node_reimage_assert_safe_remote_dir() {
  local inventory_node="$1"
  local remote_dir="$2"
  local expected_remote_dir

  expected_remote_dir="$(node_reimage_remote_dir_for "$inventory_node")"
  [[ "$remote_dir" == "$expected_remote_dir" ]] ||
    node_die "unsafe reimage remote dir in state: expected ${expected_remote_dir}, got ${remote_dir}"
}

node_reimage_default_rpi_image_gen_dir() {
  printf '%s/../rpi-image-gen\n' "$REPO_ROOT"
}

node_reimage_builder_effective_mode() {
  local mode="$1"
  case "$mode" in
    auto)
      case "$(uname -s)" in
        Darwin)
          printf 'lima\n'
          ;;
        Linux)
          printf 'local\n'
          ;;
        *)
          node_die "unsupported host OS for node-reimage-build: $(uname -s)"
          ;;
      esac
      ;;
    lima|local)
      printf '%s\n' "$mode"
      ;;
    *)
      node_die "unknown reimage builder mode: ${mode}"
      ;;
  esac
}

node_reimage_lima_instance_exists() {
  limactl list --format='{{.Name}}' 2>/dev/null | grep -Fxq "$1"
}

node_reimage_lima_instance_running() {
  local instance="$1"
  limactl list --format='{{.Name}} {{.Status}}' 2>/dev/null |
    awk -v instance="$instance" '$1 == instance && $2 == "Running" {found = 1} END {exit found ? 0 : 1}'
}

node_reimage_ensure_lima_builder() {
  local builder_name="$1"
  local rpi_image_gen_dir="$2"
  local source_root="$3"

  node_require_tool limactl
  if ! node_reimage_lima_instance_exists "$builder_name"; then
    node_log "creating Lima image builder ${builder_name}"
    limactl start --tty=false \
      --name="$builder_name" \
      --cpus="$NODE_REIMAGE_BUILDER_CPUS" \
      --memory="$NODE_REIMAGE_BUILDER_MEMORY_GIB" \
      --disk="$NODE_REIMAGE_BUILDER_DISK_GIB" \
      --mount-writable \
      "$NODE_REIMAGE_BUILDER_TEMPLATE"
  elif ! node_reimage_lima_instance_running "$builder_name"; then
    node_log "starting Lima image builder ${builder_name}"
    limactl start --tty=false "$builder_name"
  fi

  node_log "validating Lima image builder mounts"
  # shellcheck disable=SC2016
  limactl shell --tty=false "$builder_name" -- env \
    RPI_IMAGE_GEN_DIR="$rpi_image_gen_dir" \
    SOURCE_ROOT="$source_root" \
    sh -lc '
      set -eu
      test -x "${RPI_IMAGE_GEN_DIR}/rpi-image-gen"
      test -d "${SOURCE_ROOT}"
    '

  node_log "ensuring rpi-image-gen builder dependencies"
  # shellcheck disable=SC2016
  limactl shell --tty=false "$builder_name" -- env RPI_IMAGE_GEN_DIR="$rpi_image_gen_dir" bash -lc '
    set -euo pipefail
    cd "$RPI_IMAGE_GEN_DIR"
    sudo ./install_deps.sh
  '
}

node_reimage_run_image_build() {
  local builder_mode="$1"
  local builder_name="$2"
  local rpi_image_gen_dir="$3"
  local source_dir="$4"
  local build_dir="$5"
  local image_name="$6"

  case "$builder_mode" in
    local)
      [[ -x "${rpi_image_gen_dir}/rpi-image-gen" ]] ||
        node_die "missing rpi-image-gen executable: ${rpi_image_gen_dir}/rpi-image-gen"
      (
        cd "$rpi_image_gen_dir" || exit
        ./rpi-image-gen build -S "$source_dir" -B "$build_dir" -c home-ops-node.yaml
      )
      ;;
    lima)
      node_reimage_ensure_lima_builder "$builder_name" "$rpi_image_gen_dir" "$source_dir"
      local remote_build_dir
      local remote_artifact
      remote_build_dir="/var/tmp/home-ops-reimage-build/$(basename "$(dirname "$build_dir")")"
      # shellcheck disable=SC2016
      limactl shell --tty=false "$builder_name" -- env \
        RPI_IMAGE_GEN_DIR="$rpi_image_gen_dir" \
        SOURCE_DIR="$source_dir" \
        BUILD_DIR="$remote_build_dir" \
        bash -lc '
          set -euo pipefail
          sudo rm -rf "$BUILD_DIR"
          mkdir -p "$BUILD_DIR"
          cd "$RPI_IMAGE_GEN_DIR"
          ./rpi-image-gen build -S "$SOURCE_DIR" -B "$BUILD_DIR" -c home-ops-node.yaml
        '
      # shellcheck disable=SC2016
      remote_artifact="$(
        limactl shell --tty=false "$builder_name" -- env \
          BUILD_DIR="$remote_build_dir" \
          IMAGE_NAME="$image_name" \
          bash -lc '
            set -u
            for suffix in img.zst img.xz img.gz img; do
              mapfile -t artifacts < <(find "$BUILD_DIR" -maxdepth 2 -type f -name "${IMAGE_NAME}.${suffix}" | sort)
              case "${#artifacts[@]}" in
                0)
                  ;;
                1)
                  printf "%s\n" "${artifacts[0]}"
                  exit 0
                  ;;
                *)
                  printf "multiple image artifacts found for %s.%s:\n" "$IMAGE_NAME" "$suffix" >&2
                  printf "  %s\n" "${artifacts[@]}" >&2
                  exit 3
                  ;;
              esac
            done
            exit 2
          '
      )" || node_die "rpi-image-gen build did not produce a copyable image artifact for ${image_name}"
      limactl copy --tty=false "${builder_name}:${remote_artifact}" "$build_dir/"
      # shellcheck disable=SC2016
      limactl shell --tty=false "$builder_name" -- env \
        BUILD_DIR="$remote_build_dir" \
        sh -lc 'sudo rm -rf "$BUILD_DIR"'
      ;;
    *)
      node_die "unknown builder mode: ${builder_mode}"
      ;;
  esac
}

node_reimage_find_build_artifact() {
  local build_dir="$1"
  local image_name="$2"
  local -a artifacts

  mapfile -t artifacts < <(
    find "$build_dir" -type f \( \
      -name "${image_name}.img" -o \
      -name "${image_name}.img.gz" -o \
      -name "${image_name}.img.xz" -o \
      -name "${image_name}.img.zst" \
    \) | sort
  )

  case "${#artifacts[@]}" in
    0)
      node_die "rpi-image-gen build did not produce an image artifact for ${image_name} under ${build_dir}"
      ;;
    1)
      printf '%s\n' "${artifacts[0]}"
      ;;
    *)
      printf 'multiple image artifacts found for %s:\n' "$image_name" >&2
      printf '  %s\n' "${artifacts[@]}" >&2
      node_die "refusing to choose an image artifact"
      ;;
  esac
}

node_reimage_write_build_state() {
  local profile="$1"
  local inventory_node="$2"
  local image_name="$3"
  local builder_mode="$4"
  local builder_name="$5"
  local rpi_image_gen_dir="$6"
  local source_dir="$7"
  local build_dir="$8"
  local artifact_path="$9"
  local sha256="${10}"
  local state_file

  state_file="$(node_reimage_build_state_file "$profile" "$inventory_node")"
  mkdir -p "$(dirname "$state_file")"
  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -n \
    --arg schema "$NODE_REIMAGE_BUILD_SCHEMA" \
    --arg builtAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg profile "$profile" \
    --arg node "$inventory_node" \
    --arg imageName "$image_name" \
    --arg builderMode "$builder_mode" \
    --arg builderName "$builder_name" \
    --arg rpiImageGenDir "$rpi_image_gen_dir" \
    --arg sourceDir "$source_dir" \
    --arg buildDir "$build_dir" \
    --arg artifactPath "$artifact_path" \
    --arg sha256 "$sha256" \
    '{
      schemaVersion: $schema,
      builtAt: $builtAt,
      profile: $profile,
      node: $node,
      imageName: $imageName,
      builderMode: $builderMode,
      builderName: $builderName,
      rpiImageGenDir: $rpiImageGenDir,
      sourceDir: $sourceDir,
      buildDir: $buildDir,
      artifactPath: $artifactPath,
      sha256: $sha256
    }' > "$state_file"
  printf '%s\n' "$state_file"
}

node_reimage_write_serve_state() {
  local profile="$1"
  local inventory_node="$2"
  local host_node="$3"
  local host_address="$4"
  local port="$5"
  local remote_dir="$6"
  local image_url="$7"
  local artifact_path="$8"
  local metadata_path="$9"
  local sha256="${10}"
  local state_file

  state_file="$(node_reimage_serve_state_file "$profile" "$inventory_node")"
  mkdir -p "$(dirname "$state_file")"
  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -n \
    --arg schema "$NODE_REIMAGE_SERVE_SCHEMA" \
    --arg servedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg profile "$profile" \
    --arg node "$inventory_node" \
    --arg hostNode "$host_node" \
    --arg hostAddress "$host_address" \
    --argjson port "$port" \
    --arg remoteDir "$remote_dir" \
    --arg remotePidFile "${remote_dir}/http.pid" \
    --arg remoteLogFile "${remote_dir}/http.log" \
    --arg imageUrl "$image_url" \
    --arg artifactPath "$artifact_path" \
    --arg metadataPath "$metadata_path" \
    --arg sha256 "$sha256" \
    '{
      schemaVersion: $schema,
      servedAt: $servedAt,
      profile: $profile,
      node: $node,
      hostNode: $hostNode,
      hostAddress: $hostAddress,
      port: $port,
      remoteDir: $remoteDir,
      remotePidFile: $remotePidFile,
      remoteLogFile: $remoteLogFile,
      imageUrl: $imageUrl,
      artifactPath: $artifactPath,
      metadataPath: $metadataPath,
      sha256: $sha256
    }' > "$state_file"
  printf '%s\n' "$state_file"
}

node_reimage_write_apply_state() {
  local profile="$1"
  local inventory_node="$2"
  local image_url="$3"
  local sha256="$4"
  local state_file

  state_file="$(node_reimage_apply_state_file "$profile" "$inventory_node")"
  mkdir -p "$(dirname "$state_file")"
  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -n \
    --arg schema "$NODE_REIMAGE_APPLY_SCHEMA" \
    --arg appliedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg profile "$profile" \
    --arg node "$inventory_node" \
    --arg imageUrl "$image_url" \
    --arg sha256 "$sha256" \
    '{
      schemaVersion: $schema,
      appliedAt: $appliedAt,
      profile: $profile,
      node: $node,
      imageUrl: $imageUrl,
      sha256: $sha256
    }' > "$state_file"
  printf '%s\n' "$state_file"
}

node_reimage_write_cleanup_state() {
  local profile="$1"
  local inventory_node="$2"
  local host_node="$3"
  local remote_dir="$4"
  local state_file

  state_file="$(node_reimage_cleanup_state_file "$profile" "$inventory_node")"
  mkdir -p "$(dirname "$state_file")"
  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -n \
    --arg schema "$NODE_REIMAGE_CLEANUP_SCHEMA" \
    --arg cleanedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg profile "$profile" \
    --arg node "$inventory_node" \
    --arg hostNode "$host_node" \
    --arg remoteDir "$remote_dir" \
    '{
      schemaVersion: $schema,
      cleanedAt: $cleanedAt,
      profile: $profile,
      node: $node,
      hostNode: $hostNode,
      remoteDir: $remoteDir
    }' > "$state_file"
  printf '%s\n' "$state_file"
}

node_reimage_ansible_copy() {
  local profile="$1"
  local inventory_node="$2"
  local src="$3"
  local dest="$4"
  local mode="$5"

  ANSIBLE_HOST_KEY_CHECKING=False ansible \
    -i "$(node_ansible_inventory_file "$profile")" \
    "$inventory_node" \
    --become \
    -m ansible.builtin.copy \
    -a "src=${src} dest=${dest} owner=root group=root mode=${mode}" >/dev/null
}

node_reimage_target_address() {
  local profile="$1"
  local inventory_node="$2"
  local target
  target="$(node_inventory_value "$profile" "$inventory_node" ansible_host 2>/dev/null || true)"
  if [[ -z "$target" || "$target" == "null" ]]; then
    target="$inventory_node"
  fi
  printf '%s\n' "$target"
}

node_reimage_ssh_target() {
  local profile="$1"
  local inventory_node="$2"
  local target user

  target="$(node_reimage_target_address "$profile" "$inventory_node")"
  user="$(node_effective_ansible_user "$profile" "$inventory_node")"
  [[ -n "$user" && "$user" != "null" ]] ||
    node_die "could not resolve ansible_user for ${inventory_node}"
  printf '%s@%s\n' "$user" "$target"
}

node_reimage_ssh_args() {
  local profile="$1"
  local inventory_node="$2"
  local ssh_key

  printf '%s\n' -o BatchMode=yes
  printf '%s\n' -o ConnectTimeout=5
  printf '%s\n' -o StrictHostKeyChecking=accept-new
  ssh_key="$(node_effective_ssh_key "$profile" "$inventory_node")"
  if [[ -n "$ssh_key" ]]; then
    printf '%s\n' -i
    printf '%s\n' "$ssh_key"
  fi
}

node_reimage_ssh_ok() {
  local profile="$1"
  local inventory_node="$2"
  local -a ssh_args
  mapfile -t ssh_args < <(node_reimage_ssh_args "$profile" "$inventory_node")
  ssh "${ssh_args[@]}" "$(node_reimage_ssh_target "$profile" "$inventory_node")" true >/dev/null 2>&1
}

node_reimage_wait_port_down() {
  local host="$1"
  local port="$2"
  local timeout="$3"
  local deadline

  deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    if ! nc -z -w 5 "$host" "$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  node_die "timed out waiting for ${host}:${port} to go down"
}

node_reimage_wait_port_up() {
  local host="$1"
  local port="$2"
  local timeout="$3"
  local deadline

  deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    if nc -z -w 5 "$host" "$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  node_die "timed out waiting for ${host}:${port} to come up"
}

node_reimage_wait_ssh_auth() {
  local profile="$1"
  local inventory_node="$2"
  local timeout="$3"
  local deadline

  deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    if node_reimage_ssh_ok "$profile" "$inventory_node"; then
      return 0
    fi
    sleep 10
  done
  node_die "timed out waiting for SSH authentication on ${inventory_node}"
}
