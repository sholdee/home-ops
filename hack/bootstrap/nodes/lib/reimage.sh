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
  printf '%s\n' "$sha256" | tr '[:upper:]' '[:lower:]'
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
  metadata_sha256="$(printf '%s\n' "$metadata_sha256" | tr '[:upper:]' '[:lower:]')"
  [[ "$metadata_sha256" == "$expected_sha256" ]] ||
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

node_reimage_b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
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
  content_b64="$(node_reimage_b64 "$content")"

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

node_reimage_runtime_script() {
  cat <<'EOF'
#!/bin/sh
set -eu

PREREQ=""
prereqs() {
  echo "$PREREQ"
}

case "${1:-}" in
  prereqs)
    prereqs
    exit 0
    ;;
esac

if ! grep -qw 'home_ops_reimage=1' /proc/cmdline; then
  exit 0
fi

. /home-ops-reimage/reimage.env

b64_decode() {
  printf '%s' "$1" | base64 -d
}

KERNEL_VERSION="$(b64_decode "$KERNEL_VERSION_B64")"
IMAGE_URL="$(b64_decode "$IMAGE_URL_B64")"
IMAGE_SHA256="$(b64_decode "$IMAGE_SHA256_B64")"
TARGET_DISK="$(b64_decode "$TARGET_DISK_B64")"
TARGET_DISK_SERIAL="$(b64_decode "$TARGET_DISK_SERIAL_B64")"
RASPBERRY_PI_SERIAL="$(b64_decode "$RASPBERRY_PI_SERIAL_B64")"
NET_IFACE="$(b64_decode "$NET_IFACE_B64")"
NET_CIDR="$(b64_decode "$NET_CIDR_B64")"
NET_GATEWAY="$(b64_decode "$NET_GATEWAY_B64")"
NET_DNS="$(b64_decode "$NET_DNS_B64")"
NET_PARENT_IFACE="$(b64_decode "$NET_PARENT_IFACE_B64")"
NET_VLAN_ID="$(b64_decode "$NET_VLAN_ID_B64")"

die() {
  echo "home-ops reimage ERROR: $*" >&2
  sleep 3600
  exit 1
}

trim_file() {
  tr -d '\000' < "$1" | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//'
}

wait_until() {
  description="$1"
  timeout="$2"
  shift 2
  elapsed=0
  while ! "$@"; do
    [ "$elapsed" -lt "$timeout" ] || die "timed out waiting for $description"
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

path_exists() {
  [ -e "$1" ]
}

block_exists() {
  [ -b "$1" ]
}

actual_pi_serial=""
if [ -r /proc/cpuinfo ]; then
  actual_pi_serial="$(awk -F: '/^Serial/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo)"
fi
[ "$actual_pi_serial" = "$RASPBERRY_PI_SERIAL" ] ||
  die "Raspberry Pi serial mismatch"

target_name="$(basename "$TARGET_DISK")"
target_sys="/sys/class/block/$target_name"
udevadm settle --timeout=30 >/dev/null 2>&1 || true
wait_until "$TARGET_DISK" 60 block_exists "$TARGET_DISK"
wait_until "$target_sys/device/serial" 60 path_exists "$target_sys/device/serial"
actual_disk_serial="$(trim_file "$target_sys/device/serial")"
[ "$actual_disk_serial" = "$TARGET_DISK_SERIAL" ] ||
  die "target disk serial mismatch"

if [ -n "$NET_VLAN_ID" ]; then
  wait_until "network interface $NET_PARENT_IFACE" 60 path_exists "/sys/class/net/$NET_PARENT_IFACE"
  if [ -f "/usr/lib/modules/$KERNEL_VERSION/kernel/net/8021q/8021q.ko" ]; then
    insmod "/usr/lib/modules/$KERNEL_VERSION/kernel/net/8021q/8021q.ko" 2>/dev/null || true
  fi
  ip link set "$NET_PARENT_IFACE" up
  ip link add link "$NET_PARENT_IFACE" name "$NET_IFACE" type vlan id "$NET_VLAN_ID" 2>/dev/null || true
fi

wait_until "network interface $NET_IFACE" 60 path_exists "/sys/class/net/$NET_IFACE"
ip link set "$NET_IFACE" up
ip addr flush dev "$NET_IFACE" || true
ip addr add "$NET_CIDR" dev "$NET_IFACE"
ip route replace default via "$NET_GATEWAY" dev "$NET_IFACE"
if [ -n "$NET_DNS" ]; then
  printf 'nameserver %s\n' "$NET_DNS" > /etc/resolv.conf
fi

download_path=/tmp/home-ops-reimage.img
rm -f "$download_path"
wget -O "$download_path" "$IMAGE_URL" || die "image download failed"
actual_sha="$(busybox sha256sum "$download_path" | awk '{print tolower($1)}')"
[ "$actual_sha" = "$IMAGE_SHA256" ] || die "image SHA256 mismatch"

case "$IMAGE_URL" in
  *.xz)
    xzcat "$download_path" > "$TARGET_DISK" || die "image write failed"
    ;;
  *.gz)
    gunzip -c "$download_path" > "$TARGET_DISK" || die "image write failed"
    ;;
  *)
    cat "$download_path" > "$TARGET_DISK" || die "image write failed"
    ;;
esac

sync
reboot -f
sleep 60
echo b > /proc/sysrq-trigger
EOF
}

node_reimage_build_remote_payload_script() {
  local stage_dir="$1"
  local manifest="$2"
  local runtime_script="$3"
  local stage_dir_q manifest_b64 runtime_b64
  local target_disk target_disk_serial raspberry_pi_serial image_url image_sha256
  local target_disk_b64 target_disk_serial_b64 raspberry_pi_serial_b64 image_url_b64 image_sha256_b64

  printf -v stage_dir_q '%q' "$stage_dir"
  manifest_b64="$(node_reimage_b64 "$manifest")"
  runtime_b64="$(node_reimage_b64 "$runtime_script")"
  target_disk="$("$NODE_JQ_BIN" -r '.targetDisk // ""' <<<"$manifest")"
  target_disk_serial="$("$NODE_JQ_BIN" -r '.targetDiskSerial // ""' <<<"$manifest")"
  raspberry_pi_serial="$("$NODE_JQ_BIN" -r '.raspberryPiSerial // ""' <<<"$manifest")"
  image_url="$("$NODE_JQ_BIN" -r '.imageUrl // ""' <<<"$manifest")"
  image_sha256="$("$NODE_JQ_BIN" -r '.imageSha256 // ""' <<<"$manifest")"
  [[ -n "$target_disk" && -n "$target_disk_serial" && -n "$raspberry_pi_serial" &&
    -n "$image_url" && -n "$image_sha256" ]] ||
    node_die "invalid reimage manifest for target-built payload"
  target_disk_b64="$(node_reimage_b64 "$target_disk")"
  target_disk_serial_b64="$(node_reimage_b64 "$target_disk_serial")"
  raspberry_pi_serial_b64="$(node_reimage_b64 "$raspberry_pi_serial")"
  image_url_b64="$(node_reimage_b64 "$image_url")"
  image_sha256_b64="$(node_reimage_b64 "$image_sha256")"

  cat <<EOF
set -eu
stage_dir=${stage_dir_q}
manifest_b64='${manifest_b64}'
runtime_b64='${runtime_b64}'
target_disk_b64='${target_disk_b64}'
target_disk_serial_b64='${target_disk_serial_b64}'
raspberry_pi_serial_b64='${raspberry_pi_serial_b64}'
image_url_b64='${image_url_b64}'
image_sha256_b64='${image_sha256_b64}'

b64_value() {
  printf '%s' "\$1" | base64 | tr -d '\n'
}

require_tool() {
  command -v "\$1" >/dev/null 2>&1 || {
    printf 'missing_tool=%s\n' "\$1"
    exit 2
  }
}

require_tool awk
require_tool base64
require_tool cpio
require_tool sed
require_tool xzcat
require_tool zstd
require_tool zstdcat

kernel_version="\$(uname -r)"
source_initramfs=''
for candidate in /boot/firmware/initramfs_2712 /boot/firmware/initramfs8 /boot/firmware/initramfs; do
  if [ -s "\$candidate" ]; then
    source_initramfs="\$candidate"
    break
  fi
done
[ -n "\$source_initramfs" ] || {
  printf 'missing_source_initramfs=true\n'
  exit 2
}

target_disk="\$(printf '%s' "\$target_disk_b64" | base64 -d)"
target_disk_serial="\$(printf '%s' "\$target_disk_serial_b64" | base64 -d)"
raspberry_pi_serial="\$(printf '%s' "\$raspberry_pi_serial_b64" | base64 -d)"
image_url="\$(printf '%s' "\$image_url_b64" | base64 -d)"
image_sha256="\$(printf '%s' "\$image_sha256_b64" | base64 -d)"
[ -n "\$target_disk" ] && [ -n "\$target_disk_serial" ] && [ -n "\$raspberry_pi_serial" ] &&
  [ -n "\$image_url" ] && [ -n "\$image_sha256" ] || {
    printf 'invalid_manifest_for_payload=true\n'
    exit 2
  }

net_iface="\$(ip -o -4 route show default | awk '{print \$5; exit}')"
net_gateway="\$(ip -o -4 route show default | awk '{print \$3; exit}')"
net_cidr="\$(ip -o -4 addr show dev "\$net_iface" scope global | awk '{print \$4; exit}')"
net_dns="\$(nmcli -g IP4.DNS dev show "\$net_iface" 2>/dev/null | sed -n '1p' || true)"
[ -n "\$net_dns" ] || net_dns="\$net_gateway"
[ -n "\$net_iface" ] && [ -n "\$net_gateway" ] && [ -n "\$net_cidr" ] || {
  printf 'missing_network_identity=true\n'
  exit 2
}

net_parent_iface=''
net_vlan_id=''
case "\$net_iface" in
  *.*)
    net_parent_iface="\${net_iface%%.*}"
    net_vlan_id="\${net_iface##*.}"
    ;;
esac

install -d -m 0700 "\$stage_dir"
printf '%s' "\$manifest_b64" | base64 -d > "\$stage_dir/manifest.json"
cat > "\$stage_dir/reimage.env" <<ENV
KERNEL_VERSION_B64=\$(b64_value "\$kernel_version")
IMAGE_URL_B64=\$(b64_value "\$image_url")
IMAGE_SHA256_B64=\$(b64_value "\$image_sha256")
TARGET_DISK_B64=\$(b64_value "\$target_disk")
TARGET_DISK_SERIAL_B64=\$(b64_value "\$target_disk_serial")
RASPBERRY_PI_SERIAL_B64=\$(b64_value "\$raspberry_pi_serial")
NET_IFACE_B64=\$(b64_value "\$net_iface")
NET_CIDR_B64=\$(b64_value "\$net_cidr")
NET_GATEWAY_B64=\$(b64_value "\$net_gateway")
NET_DNS_B64=\$(b64_value "\$net_dns")
NET_PARENT_IFACE_B64=\$(b64_value "\$net_parent_iface")
NET_VLAN_ID_B64=\$(b64_value "\$net_vlan_id")
ENV

tmp_dir="\$(mktemp -d)"
cleanup() {
  rm -rf "\$tmp_dir"
}
trap cleanup EXIT

(
  cd "\$tmp_dir"
  zstdcat "\$source_initramfs" | cpio -id --quiet

  initramfs_has_command() {
    command_name="\$1"
    for command_path in \
      "bin/\$command_name" \
      "sbin/\$command_name" \
      "usr/bin/\$command_name" \
      "usr/sbin/\$command_name"; do
      [ -e "\$command_path" ] && return 0
    done
    for busybox_path in bin/busybox usr/bin/busybox; do
      if [ -x "\$busybox_path" ] && "\$busybox_path" --list 2>/dev/null | grep -Fxq "\$command_name"; then
        return 0
      fi
    done
    return 1
  }

  require_initramfs_command() {
    initramfs_has_command "\$1" || {
      printf 'missing_initramfs_command=%s\n' "\$1"
      exit 2
    }
  }

  install_8021q_module() {
    module_dest="usr/lib/modules/\$kernel_version/kernel/net/8021q/8021q.ko"
    module_src=''
    module_src="\$(find usr lib -path '*/8021q.ko' -o -path '*/8021q.ko.xz' -o -path '*/8021q.ko.zst' 2>/dev/null | sed -n '1p' || true)"
    if [ -z "\$module_src" ]; then
      module_src="\$(find "/lib/modules/\$kernel_version" -path '*/8021q.ko' -o -path '*/8021q.ko.xz' -o -path '*/8021q.ko.zst' 2>/dev/null | sed -n '1p' || true)"
    fi
    [ -n "\$module_src" ] || return 1
    [ "\$module_src" = "\$module_dest" ] && return 0
    install -d -m 0755 "\$(dirname "\$module_dest")"
    case "\$module_src" in
      *.ko)
        cp "\$module_src" "\$module_dest"
        ;;
      *.ko.xz)
        xzcat "\$module_src" > "\$module_dest"
        ;;
      *.ko.zst)
        zstdcat "\$module_src" > "\$module_dest"
        ;;
      *)
        return 1
        ;;
    esac
  }

  for command_name in awk base64 basename busybox cat grep gunzip ip reboot rm sed sh sha256sum sleep sync tr udevadm wget xzcat; do
    require_initramfs_command "\$command_name"
  done
  if [ -n "\$net_vlan_id" ]; then
    require_initramfs_command insmod
    install_8021q_module || {
      printf 'missing_initramfs_module=8021q\n'
      exit 2
    }
  else
    install_8021q_module || true
  fi

  install -d -m 0755 scripts/local-top home-ops-reimage
  printf '%s' "\$manifest_b64" | base64 -d > home-ops-reimage/manifest.json
  cp "\$stage_dir/reimage.env" home-ops-reimage/reimage.env
  printf '%s' "\$runtime_b64" | base64 -d > scripts/local-top/home-ops-reimage
  chmod 0755 scripts/local-top/home-ops-reimage
  if [ -f scripts/local-top/ORDER ] && ! grep -Fxq home-ops-reimage scripts/local-top/ORDER; then
    printf '%s\n' home-ops-reimage >> scripts/local-top/ORDER
  fi
  if [ -f /etc/ssl/certs/ca-certificates.crt ]; then
    install -d -m 0755 etc/ssl/certs
    cp /etc/ssl/certs/ca-certificates.crt etc/ssl/certs/ca-certificates.crt
  fi
  find . | cpio -o -H newc --quiet | zstd -19 -T0 > "\$stage_dir/initramfs.img"
)

cmdline="\$(sed 's/[[:space:]]*home_ops_reimage=1//g; s/[[:space:]]*\$//' /boot/firmware/cmdline.txt)"
printf '%s home_ops_reimage=1\n' "\$cmdline" > "\$stage_dir/cmdline.txt"
chmod 0600 "\$stage_dir/manifest.json" "\$stage_dir/reimage.env" "\$stage_dir/initramfs.img" "\$stage_dir/cmdline.txt"
sync "\$stage_dir"
printf 'remote_payload=built\n'
printf 'source_initramfs=%s\n' "\$source_initramfs"
printf 'net_iface=%s\n' "\$net_iface"
printf 'net_cidr=%s\n' "\$net_cidr"
printf 'net_gateway=%s\n' "\$net_gateway"
EOF
}

node_reimage_build_remote_payload() {
  local profile="$1"
  local inventory_node="$2"
  local manifest="$3"
  local stage_dir runtime_script remote_script remote_script_b64

  stage_dir="$(node_reimage_inventory_stage_dir "$profile" "$inventory_node")"
  runtime_script="$(node_reimage_runtime_script)"
  remote_script="$(node_reimage_build_remote_payload_script "$stage_dir" "$manifest" "$runtime_script")"
  remote_script_b64="$(node_reimage_b64 "$remote_script")"

  node_log "building reimage initramfs payload on ${inventory_node}"
  node_run_remote_shell "$(node_ansible_inventory_file "$profile")" "$inventory_node" \
    "printf '%s' '${remote_script_b64}' | base64 -d | /bin/sh" |
    node_indent_block
}

node_reimage_stage_files() {
  local profile="$1"
  local inventory_node="$2"
  local manifest="$3"
  local payload_dir="$4"
  local stage_dir initramfs_src cmdline_src tryboot_config

  stage_dir="$(node_reimage_inventory_stage_dir "$profile" "$inventory_node")"
  tryboot_config="$(node_reimage_tryboot_config "$stage_dir")"

  node_log "staging reimage manifest and tryboot payload on ${inventory_node}"
  node_reimage_ensure_stage_dir "$profile" "$inventory_node"
  if [[ -n "$payload_dir" ]]; then
    initramfs_src="$(node_reimage_payload_file "$payload_dir" initramfs.img)"
    cmdline_src="$(node_reimage_payload_file "$payload_dir" cmdline.txt)"
    node_reimage_write_remote_text_file "$profile" "$inventory_node" "${stage_dir}/manifest.json" 0600 "$manifest"
    node_reimage_copy_payload_file "$profile" "$inventory_node" "$initramfs_src" "${stage_dir}/initramfs.img" 0600
    node_reimage_copy_payload_file "$profile" "$inventory_node" "$cmdline_src" "${stage_dir}/cmdline.txt" 0600
  else
    node_reimage_build_remote_payload "$profile" "$inventory_node" "$manifest"
  fi
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
