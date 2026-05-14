# shellcheck shell=bash

NODE_REIMAGE_METADATA_SCHEMA="home-ops.node-image/v1"
NODE_REIMAGE_STAGE_SCHEMA="home-ops.node-reimage-stage/v1"
NODE_REIMAGE_DEFAULT_DISK="/dev/nvme0n1"
NODE_REIMAGE_DEFAULT_STAGE_DIR="/boot/firmware/home-ops-reimage"
NODE_REIMAGE_BOOT_CONFIG="/boot/firmware/tryboot.txt"

node_reimage_inventory_disk_path() {
  local profile="$1"
  local inventory_node="$2"
  local value

  value="$(node_inventory_value "$profile" "$inventory_node" home_ops_reimage_disk_path 2>/dev/null || true)"
  if [[ -z "$value" || "$value" == "null" ]]; then
    value="$NODE_REIMAGE_DEFAULT_DISK"
  fi
  printf '%s\n' "$value"
}

node_reimage_inventory_stage_dir() {
  local profile="$1"
  local inventory_node="$2"
  local value

  value="$(node_inventory_value "$profile" "$inventory_node" home_ops_reimage_stage_dir 2>/dev/null || true)"
  if [[ -z "$value" || "$value" == "null" ]]; then
    value="$NODE_REIMAGE_DEFAULT_STAGE_DIR"
  fi
  printf '%s\n' "$value"
}

node_reimage_required_inventory_value() {
  local profile="$1"
  local inventory_node="$2"
  local key="$3"
  local value

  value="$(node_inventory_value "$profile" "$inventory_node" "$key" 2>/dev/null || true)"
  [[ -n "$value" && "$value" != "null" ]] ||
    node_die "missing inventory value ${key} for ${inventory_node}; run just node-reimage-plan ${inventory_node} to discover it"
  printf '%s\n' "$value"
}

node_reimage_probe_remote_script() {
  local disk_path="$1"
  local disk_path_q
  printf -v disk_path_q '%q' "$disk_path"

  cat <<EOF
set -eu
disk_path=${disk_path_q}

printf 'hostname=%s\n' "\$(hostname)"

pi_model=''
if [ -r /proc/device-tree/model ]; then
  pi_model="\$(tr -d '\\000' < /proc/device-tree/model 2>/dev/null || true)"
fi
printf 'pi_model=%s\n' "\$pi_model"

raspberry_pi=false
if printf '%s' "\$pi_model" | grep -qi 'Raspberry Pi'; then
  raspberry_pi=true
elif [ -r /proc/cpuinfo ] && grep -Eqi 'Raspberry Pi|BCM2708|BCM2709|BCM2835|BCM2836' /proc/cpuinfo; then
  raspberry_pi=true
fi
printf 'raspberry_pi=%s\n' "\$raspberry_pi"

pi_serial=''
if [ -r /proc/cpuinfo ]; then
  pi_serial="\$(awk -F: '/^Serial/ {gsub(/^[ \t]+/, "", \$2); print \$2; exit}' /proc/cpuinfo 2>/dev/null || true)"
fi
printf 'pi_serial=%s\n' "\$pi_serial"

mac_addresses="\$(for interface_path in /sys/class/net/*; do
  [ -e "\$interface_path/address" ] || continue
  [ -e "\$interface_path/device" ] || continue
  interface_name="\${interface_path##*/}"
  [ "\$interface_name" = lo ] && continue
  address="\$(cat "\$interface_path/address")"
  [ "\$address" != "00:00:00:00:00:00" ] || continue
  printf '%s\n' "\$address"
done | sort | paste -sd, -)"
printf 'mac_addresses=%s\n' "\$mac_addresses"

if [ -b "\$disk_path" ]; then
  disk_name="\$(basename "\$disk_path")"
  sys_block="/sys/class/block/\$disk_name"
  disk_model=''
  disk_serial=''
  disk_size_bytes=''
  if [ -r "\$sys_block/device/model" ]; then
    disk_model="\$(tr -d '\\000' < "\$sys_block/device/model" | sed 's/^[[:space:]]\+//; s/[[:space:]]\+\$//' || true)"
  fi
  if [ -r "\$sys_block/device/serial" ]; then
    disk_serial="\$(tr -d '\\000' < "\$sys_block/device/serial" | sed 's/^[[:space:]]\+//; s/[[:space:]]\+\$//' || true)"
  fi
  disk_size_bytes="\$(blockdev --getsize64 "\$disk_path" 2>/dev/null || true)"
  printf 'disk_present=true\n'
  printf 'disk_path=%s\n' "\$disk_path"
  printf 'disk_model=%s\n' "\$disk_model"
  printf 'disk_serial=%s\n' "\$disk_serial"
  printf 'disk_size_bytes=%s\n' "\$disk_size_bytes"
else
  printf 'disk_present=false\n'
  printf 'disk_path=%s\n' "\$disk_path"
  printf 'disk_model=\n'
  printf 'disk_serial=\n'
  printf 'disk_size_bytes=\n'
fi

if findmnt -rn /boot/firmware >/dev/null 2>&1; then
  printf 'boot_firmware_mounted=true\n'
else
  printf 'boot_firmware_mounted=false\n'
fi
EOF
}

node_reimage_probe_host() {
  local profile="$1"
  local inventory_node="$2"
  local disk_path="$3"
  local inventory_file remote_script

  inventory_file="$(node_ansible_inventory_file "$profile")"
  remote_script="$(node_reimage_probe_remote_script "$disk_path")"
  node_run_remote_shell "$inventory_file" "$inventory_node" "$remote_script"
}

node_reimage_probe_value() {
  local probe="$1"
  local key="$2"
  awk -F= -v key="$key" '
    $1 == key {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' <<<"$probe"
}

node_reimage_validate_probe() {
  local profile="$1"
  local inventory_node="$2"
  local probe="$3"
  local expected_pi_serial expected_disk_serial expected_disk_path
  local actual_pi actual_pi_serial actual_disk_present actual_disk_serial actual_disk_path boot_mounted

  expected_pi_serial="$(node_reimage_required_inventory_value "$profile" "$inventory_node" home_ops_reimage_pi_serial)"
  expected_disk_serial="$(node_reimage_required_inventory_value "$profile" "$inventory_node" home_ops_reimage_disk_serial)"
  expected_disk_path="$(node_reimage_inventory_disk_path "$profile" "$inventory_node")"

  actual_pi="$(node_reimage_probe_value "$probe" raspberry_pi)"
  actual_pi_serial="$(node_reimage_probe_value "$probe" pi_serial)"
  actual_disk_present="$(node_reimage_probe_value "$probe" disk_present)"
  actual_disk_serial="$(node_reimage_probe_value "$probe" disk_serial)"
  actual_disk_path="$(node_reimage_probe_value "$probe" disk_path)"
  boot_mounted="$(node_reimage_probe_value "$probe" boot_firmware_mounted)"

  [[ "$actual_pi" == true ]] ||
    node_die "remote host did not identify as a Raspberry Pi: ${inventory_node}"
  [[ -n "$actual_pi_serial" && "$actual_pi_serial" == "$expected_pi_serial" ]] ||
    node_die "Raspberry Pi serial mismatch for ${inventory_node}: expected ${expected_pi_serial}, got ${actual_pi_serial:-missing}"
  [[ "$actual_disk_present" == true ]] ||
    node_die "target disk is not present on ${inventory_node}: ${expected_disk_path}"
  [[ "$actual_disk_path" == "$expected_disk_path" ]] ||
    node_die "target disk path mismatch for ${inventory_node}: expected ${expected_disk_path}, got ${actual_disk_path:-missing}"
  [[ -n "$actual_disk_serial" && "$actual_disk_serial" == "$expected_disk_serial" ]] ||
    node_die "target disk serial mismatch for ${inventory_node}: expected ${expected_disk_serial}, got ${actual_disk_serial:-missing}"
  [[ "$boot_mounted" == true ]] ||
    node_die "/boot/firmware is not mounted on ${inventory_node}; cannot stage tryboot files"
}

node_reimage_normalize_sha256() {
  local sha256="$1"
  [[ "$sha256" =~ ^[0-9A-Fa-f]{64}$ ]] ||
    node_die "image SHA256 must be 64 hexadecimal characters"
  printf '%s\n' "${sha256,,}"
}

node_reimage_read_metadata() {
  local metadata_source="$1"

  if [[ -f "$metadata_source" ]]; then
    cat "$metadata_source"
    return 0
  fi

  node_require_tool curl
  curl -fsSL "$metadata_source"
}

node_reimage_validate_metadata() {
  local profile="$1"
  local inventory_node="$2"
  local image_url="$3"
  local expected_sha256="$4"
  local metadata="$5"
  local ansible_host schema node hostname metadata_image_url metadata_sha256 arch metadata_ansible_host

  if ! "$NODE_JQ_BIN" -e . >/dev/null 2>&1 <<<"$metadata"; then
    node_die "image metadata is not valid JSON"
  fi

  schema="$("$NODE_JQ_BIN" -r '.schemaVersion // ""' <<<"$metadata")"
  node="$("$NODE_JQ_BIN" -r '.node // ""' <<<"$metadata")"
  hostname="$("$NODE_JQ_BIN" -r '.hostname // ""' <<<"$metadata")"
  metadata_image_url="$("$NODE_JQ_BIN" -r '.imageUrl // ""' <<<"$metadata")"
  metadata_sha256="$("$NODE_JQ_BIN" -r '.sha256 // ""' <<<"$metadata")"
  arch="$("$NODE_JQ_BIN" -r '.arch // ""' <<<"$metadata")"
  metadata_ansible_host="$("$NODE_JQ_BIN" -r '.ansibleHost // ""' <<<"$metadata")"
  ansible_host="$(node_inventory_value "$profile" "$inventory_node" ansible_host 2>/dev/null || true)"

  [[ "$schema" == "$NODE_REIMAGE_METADATA_SCHEMA" ]] ||
    node_die "image metadata schema must be ${NODE_REIMAGE_METADATA_SCHEMA}"
  [[ "$node" == "$inventory_node" ]] ||
    node_die "image metadata node mismatch: expected ${inventory_node}, got ${node:-missing}"
  [[ "$hostname" == "$inventory_node" ]] ||
    node_die "image metadata hostname mismatch: expected ${inventory_node}, got ${hostname:-missing}"
  [[ "$metadata_image_url" == "$image_url" ]] ||
    node_die "image metadata imageUrl mismatch: expected ${image_url}, got ${metadata_image_url:-missing}"
  [[ "${metadata_sha256,,}" == "$expected_sha256" ]] ||
    node_die "image metadata SHA256 mismatch for ${inventory_node}"
  case "$arch" in
    arm64|aarch64)
      ;;
    *)
      node_die "image metadata arch must be arm64 or aarch64, got ${arch:-missing}"
      ;;
  esac
  [[ -n "$ansible_host" && "$ansible_host" != "null" ]] ||
    node_die "inventory ansible_host is required for image metadata validation: ${inventory_node}"
  [[ "$metadata_ansible_host" == "$ansible_host" ]] ||
    node_die "image metadata ansibleHost mismatch: expected ${ansible_host}, got ${metadata_ansible_host:-missing}"

  "$NODE_JQ_BIN" -c . <<<"$metadata"
}

node_reimage_build_manifest() {
  local profile="$1"
  local inventory_node="$2"
  local kubernetes_node="$3"
  local image_url="$4"
  local image_sha256="$5"
  local metadata_source="$6"
  local metadata="$7"
  local disk_path disk_serial pi_serial stage_dir staged_at

  disk_path="$(node_reimage_inventory_disk_path "$profile" "$inventory_node")"
  disk_serial="$(node_reimage_required_inventory_value "$profile" "$inventory_node" home_ops_reimage_disk_serial)"
  pi_serial="$(node_reimage_required_inventory_value "$profile" "$inventory_node" home_ops_reimage_pi_serial)"
  stage_dir="$(node_reimage_inventory_stage_dir "$profile" "$inventory_node")"
  staged_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -n \
    --arg schema "$NODE_REIMAGE_STAGE_SCHEMA" \
    --arg stagedAt "$staged_at" \
    --arg profile "$profile" \
    --arg inventoryNode "$inventory_node" \
    --arg kubernetesNode "$kubernetes_node" \
    --arg imageUrl "$image_url" \
    --arg imageSha256 "$image_sha256" \
    --arg metadataSource "$metadata_source" \
    --arg targetDisk "$disk_path" \
    --arg targetDiskSerial "$disk_serial" \
    --arg raspberryPiSerial "$pi_serial" \
    --arg stageDir "$stage_dir" \
    --argjson imageMetadata "$metadata" \
    '{
      schemaVersion: $schema,
      stagedAt: $stagedAt,
      profile: $profile,
      inventoryNode: $inventoryNode,
      kubernetesNode: $kubernetesNode,
      imageUrl: $imageUrl,
      imageSha256: $imageSha256,
      metadataSource: $metadataSource,
      targetDisk: $targetDisk,
      targetDiskSerial: $targetDiskSerial,
      raspberryPiSerial: $raspberryPiSerial,
      stageDir: $stageDir,
      imageMetadata: $imageMetadata
    }'
}

node_reimage_tryboot_config() {
  local stage_dir="$1"
  local stage_relative

  stage_relative="${stage_dir#/boot/firmware/}"
  [[ "$stage_relative" != "$stage_dir" && -n "$stage_relative" ]] ||
    node_die "reimage stage dir must be under /boot/firmware: ${stage_dir}"

  cat <<EOF
# Managed by home-ops node-reimage-stage. Loaded only by reboot '0 tryboot'.
[all]
include config.txt
[all]
initramfs ${stage_relative}/initramfs.img followkernel
cmdline=${stage_relative}/cmdline.txt
EOF
}

node_reimage_payload_file() {
  local payload_dir="$1"
  local file_name="$2"
  local file_path="${payload_dir}/${file_name}"
  [[ -f "$file_path" ]] ||
    node_die "missing reimage payload file: ${file_path}"
  printf '%s\n' "$file_path"
}

node_reimage_write_remote_text_file() {
  local profile="$1"
  local inventory_node="$2"
  local path="$3"
  local mode="$4"
  local content="$5"
  local dir path_q dir_q content_b64 remote_script

  dir="$(dirname "$path")"
  printf -v dir_q '%q' "$dir"
  printf -v path_q '%q' "$path"
  content_b64="$(printf '%s' "$content" | base64 | tr -d '\n')"

  read -r -d '' remote_script <<EOF || true
set -eu
mkdir -p ${dir_q}
printf '%s' '${content_b64}' | base64 -d > ${path_q}
chmod ${mode} ${path_q}
sync ${path_q}
EOF

  node_run_remote_shell "$(node_ansible_inventory_file "$profile")" "$inventory_node" "$remote_script" >/dev/null
}

node_reimage_ensure_stage_dir() {
  local profile="$1"
  local inventory_node="$2"
  local stage_dir stage_dir_q remote_script

  stage_dir="$(node_reimage_inventory_stage_dir "$profile" "$inventory_node")"
  printf -v stage_dir_q '%q' "$stage_dir"
  read -r -d '' remote_script <<EOF || true
set -eu
install -d -m 0700 ${stage_dir_q}
sync ${stage_dir_q}
EOF

  node_run_remote_shell "$(node_ansible_inventory_file "$profile")" "$inventory_node" "$remote_script" >/dev/null
}

node_reimage_copy_payload_file() {
  local profile="$1"
  local inventory_node="$2"
  local src="$3"
  local dest="$4"
  local mode="$5"
  local inventory_file

  inventory_file="$(node_ansible_inventory_file "$profile")"
  ANSIBLE_HOST_KEY_CHECKING=False ansible \
    -i "$inventory_file" \
    "$inventory_node" \
    --become \
    -m ansible.builtin.copy \
    -a "src=${src} dest=${dest} mode=${mode}" >/dev/null
}

node_reimage_stage_files() {
  local profile="$1"
  local inventory_node="$2"
  local manifest="$3"
  local payload_dir="$4"
  local stage_dir initramfs_src cmdline_src tryboot_config

  stage_dir="$(node_reimage_inventory_stage_dir "$profile" "$inventory_node")"
  initramfs_src="$(node_reimage_payload_file "$payload_dir" initramfs.img)"
  cmdline_src="$(node_reimage_payload_file "$payload_dir" cmdline.txt)"
  tryboot_config="$(node_reimage_tryboot_config "$stage_dir")"

  node_log "staging reimage manifest and tryboot payload on ${inventory_node}"
  node_reimage_ensure_stage_dir "$profile" "$inventory_node"
  node_reimage_write_remote_text_file "$profile" "$inventory_node" "${stage_dir}/manifest.json" 0600 "$manifest"
  node_reimage_copy_payload_file "$profile" "$inventory_node" "$initramfs_src" "${stage_dir}/initramfs.img" 0600
  node_reimage_copy_payload_file "$profile" "$inventory_node" "$cmdline_src" "${stage_dir}/cmdline.txt" 0600
  node_reimage_write_remote_text_file "$profile" "$inventory_node" "$NODE_REIMAGE_BOOT_CONFIG" 0644 "$tryboot_config"
}

node_reimage_validate_staged_manifest() {
  local profile="$1"
  local inventory_node="$2"
  local kubernetes_node="$3"
  local manifest="$4"
  local schema manifest_inventory_node manifest_kubernetes_node manifest_target_disk
  local manifest_target_disk_serial manifest_pi_serial manifest_stage_dir
  local expected_target_disk expected_target_disk_serial expected_pi_serial expected_stage_dir

  if ! "$NODE_JQ_BIN" -e . >/dev/null 2>&1 <<<"$manifest"; then
    node_die "staged reimage manifest is not valid JSON"
  fi

  schema="$("$NODE_JQ_BIN" -r '.schemaVersion // ""' <<<"$manifest")"
  manifest_inventory_node="$("$NODE_JQ_BIN" -r '.inventoryNode // ""' <<<"$manifest")"
  manifest_kubernetes_node="$("$NODE_JQ_BIN" -r '.kubernetesNode // ""' <<<"$manifest")"
  manifest_target_disk="$("$NODE_JQ_BIN" -r '.targetDisk // ""' <<<"$manifest")"
  manifest_target_disk_serial="$("$NODE_JQ_BIN" -r '.targetDiskSerial // ""' <<<"$manifest")"
  manifest_pi_serial="$("$NODE_JQ_BIN" -r '.raspberryPiSerial // ""' <<<"$manifest")"
  manifest_stage_dir="$("$NODE_JQ_BIN" -r '.stageDir // ""' <<<"$manifest")"

  expected_target_disk="$(node_reimage_inventory_disk_path "$profile" "$inventory_node")"
  expected_target_disk_serial="$(node_reimage_required_inventory_value "$profile" "$inventory_node" home_ops_reimage_disk_serial)"
  expected_pi_serial="$(node_reimage_required_inventory_value "$profile" "$inventory_node" home_ops_reimage_pi_serial)"
  expected_stage_dir="$(node_reimage_inventory_stage_dir "$profile" "$inventory_node")"

  [[ "$schema" == "$NODE_REIMAGE_STAGE_SCHEMA" ]] ||
    node_die "staged reimage manifest schema mismatch: expected ${NODE_REIMAGE_STAGE_SCHEMA}, got ${schema:-missing}"
  [[ "$manifest_inventory_node" == "$inventory_node" ]] ||
    node_die "staged reimage manifest inventoryNode mismatch: expected ${inventory_node}, got ${manifest_inventory_node:-missing}"
  [[ "$manifest_kubernetes_node" == "$kubernetes_node" ]] ||
    node_die "staged reimage manifest kubernetesNode mismatch: expected ${kubernetes_node}, got ${manifest_kubernetes_node:-missing}"
  [[ "$manifest_target_disk" == "$expected_target_disk" ]] ||
    node_die "staged reimage manifest targetDisk mismatch: expected ${expected_target_disk}, got ${manifest_target_disk:-missing}"
  [[ "$manifest_target_disk_serial" == "$expected_target_disk_serial" ]] ||
    node_die "staged reimage manifest targetDiskSerial mismatch for ${inventory_node}"
  [[ "$manifest_pi_serial" == "$expected_pi_serial" ]] ||
    node_die "staged reimage manifest raspberryPiSerial mismatch for ${inventory_node}"
  [[ "$manifest_stage_dir" == "$expected_stage_dir" ]] ||
    node_die "staged reimage manifest stageDir mismatch: expected ${expected_stage_dir}, got ${manifest_stage_dir:-missing}"
}

node_reimage_assert_staged() {
  local profile="$1"
  local inventory_node="$2"
  local kubernetes_node="$3"
  local stage_dir manifest_path initramfs_path cmdline_path remote_script
  local manifest_path_q initramfs_path_q cmdline_path_q boot_config_q
  local output manifest

  stage_dir="$(node_reimage_inventory_stage_dir "$profile" "$inventory_node")"
  manifest_path="${stage_dir}/manifest.json"
  initramfs_path="${stage_dir}/initramfs.img"
  cmdline_path="${stage_dir}/cmdline.txt"
  printf -v manifest_path_q '%q' "$manifest_path"
  printf -v initramfs_path_q '%q' "$initramfs_path"
  printf -v cmdline_path_q '%q' "$cmdline_path"
  printf -v boot_config_q '%q' "$NODE_REIMAGE_BOOT_CONFIG"

  read -r -d '' remote_script <<EOF || true
set -eu
for path in ${manifest_path_q} ${initramfs_path_q} ${cmdline_path_q} ${boot_config_q}; do
  [ -s "\$path" ] || {
    printf 'missing_or_empty=%s\n' "\$path"
    exit 2
  }
done
printf 'manifest_begin\n'
cat ${manifest_path_q}
printf '\nmanifest_end\n'
printf 'reimage_stage=present\n'
EOF

  output="$(node_run_remote_shell "$(node_ansible_inventory_file "$profile")" "$inventory_node" "$remote_script")" ||
    node_die "reimage stage is incomplete on ${inventory_node}; run node-reimage-stage again"
  manifest="$(node_extract_block manifest_begin manifest_end <<<"$output")"
  node_reimage_validate_staged_manifest "$profile" "$inventory_node" "$kubernetes_node" "$manifest"
}
