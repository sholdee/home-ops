# shellcheck shell=bash

node_reimage_image_output_root() {
  printf '%s\n' "${NODE_REIMAGE_OUTPUT_ROOT:-${BOOTSTRAP_DIR}/.out/reimage}"
}

node_reimage_image_inventory_or_default() {
  local profile="$1"
  local inventory_node="$2"
  local key="$3"
  local default_value="$4"
  local value

  value="$(node_inventory_value "$profile" "$inventory_node" "$key" 2>/dev/null || true)"
  if [[ -n "$value" && "$value" != "null" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default_value"
  fi
}

node_reimage_image_default_gateway() {
  local address="$1"

  [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
    node_die "cannot derive image gateway from non-IPv4 ansible_host: ${address}"
  awk -F. '{printf "%s.%s.%s.1\n", $1, $2, $3}' <<<"$address"
}

node_reimage_image_validate_ipv4() {
  local label="$1"
  local value="$2"
  local part
  local -a parts

  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
    node_die "${label} must be an IPv4 address: ${value}"
  IFS=. read -r -a parts <<<"$value"
  for part in "${parts[@]}"; do
    ((part >= 0 && part <= 255)) || node_die "${label} has an invalid octet: ${value}"
  done
}

node_reimage_image_validate_network() {
  local hostname="$1"
  local iface="$2"
  local address="$3"
  local prefix="$4"
  local gateway="$5"
  local dns="$6"

  [[ "$hostname" =~ ^[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?$ ]] ||
    node_die "image hostname is not valid: ${hostname}"
  [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] ||
    node_die "image network interface is not valid: ${iface}"
  [[ "$prefix" =~ ^[0-9]+$ && "$prefix" -ge 1 && "$prefix" -le 32 ]] ||
    node_die "image network prefix must be 1-32: ${prefix}"
  node_reimage_image_validate_ipv4 "image address" "$address"
  node_reimage_image_validate_ipv4 "image gateway" "$gateway"
  node_reimage_image_validate_ipv4 "image DNS" "$dns"
}

node_reimage_image_expand_path() {
  local path="$1"
  case "$path" in
    \~/*)
      printf '%s/%s\n' "$HOME" "${path#"~/"}"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

node_reimage_image_public_key_from_file() {
  local public_key_file="$1"

  public_key_file="$(node_reimage_image_expand_path "$public_key_file")"
  [[ -f "$public_key_file" ]] || node_die "SSH public key file does not exist: ${public_key_file}"
  sed -n '1p' "$public_key_file"
}

node_reimage_image_public_key() {
  local profile="$1"
  local inventory_node="$2"
  local explicit_path="$3"
  local inventory_path public_key ssh_key

  if [[ -n "$explicit_path" ]]; then
    node_reimage_image_public_key_from_file "$explicit_path"
    return 0
  fi

  inventory_path="$(node_inventory_value "$profile" "$inventory_node" home_ops_reimage_ssh_public_key_file 2>/dev/null || true)"
  if [[ -n "$inventory_path" && "$inventory_path" != "null" ]]; then
    node_reimage_image_public_key_from_file "$inventory_path"
    return 0
  fi

  ssh_key="$(node_effective_ssh_key "$profile" "$inventory_node")"
  if [[ -n "$ssh_key" && -f "${ssh_key}.pub" ]]; then
    node_reimage_image_public_key_from_file "${ssh_key}.pub"
    return 0
  fi

  if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
    node_require_tool "$NODE_SSH_KEYGEN_BIN"
    public_key="$("$NODE_SSH_KEYGEN_BIN" -y -f "$ssh_key" -P '' 2>/dev/null || true)"
    [[ -n "$public_key" ]] || node_die "could not derive SSH public key from ${ssh_key}"
    printf '%s\n' "$public_key"
    return 0
  fi

  if [[ -n "$ssh_key" ]]; then
    node_die "missing SSH key for image; pass --ssh-public-key, create ${ssh_key}.pub, or make ${ssh_key} readable"
  fi
  node_die "missing SSH public key for image; pass --ssh-public-key"
}

# node_reimage_image_kernel_values STATE prints the validated kernel build id,
# package version, release and config delta sha256, tab separated, or nothing
# (after node_die) when the state is unusable.
node_reimage_image_kernel_values() {
  local kernel_state="$1"
  local build_id version release delta_sha
  local name file
  local version_re='^[0-9]+:[0-9][A-Za-z0-9.+~-]*$'
  local release_re="^[0-9][A-Za-z0-9.+_-]*-${NODE_KERNEL_FLAVOUR}\$"
  local sha_re='^[0-9a-f]{64}$'

  node_kernel_verify_build_state "$kernel_state"
  build_id="$("$NODE_JQ_BIN" -r '.buildId // ""' "$kernel_state")"
  version="$("$NODE_JQ_BIN" -r '.packageVersion // ""' "$kernel_state")"
  release="$("$NODE_JQ_BIN" -r '.kernelRelease // ""' "$kernel_state")"
  delta_sha="$("$NODE_JQ_BIN" -r '.configDeltaSha256 // ""' "$kernel_state")"
  node_kernel_build_id_valid "$build_id" || node_die "invalid kernel build id in ${kernel_state}: ${build_id}"
  [[ "$version" =~ $version_re ]] || node_die "invalid kernel package version in ${kernel_state}: ${version}"
  [[ "$release" =~ $release_re ]] || node_die "invalid kernel release in ${kernel_state}: ${release}"
  [[ "$delta_sha" =~ $sha_re ]] || node_die "invalid kernel config delta sha256 in ${kernel_state}"
  [[ "$(node_kernel_build_id_for_version "$version")" == "$build_id" ]] ||
    node_die "kernel build state ${kernel_state} buildId ${build_id} does not match packageVersion ${version}"
  [[ "$(node_kernel_release_for_version "$version")" == "$release" ]] ||
    node_die "kernel build state ${kernel_state} kernelRelease ${release} does not match packageVersion ${version}"
  while IFS=$'\t' read -r name file; do
    [[ "$(basename "$file")" == "${name}_${version#*:}_arm64.deb" ]] ||
      node_die "kernel build state ${kernel_state} lists ${file} for ${name} ${version}"
  done < <("$NODE_JQ_BIN" -r '.packages[] | [.name, .file] | @tsv' "$kernel_state")
  printf '%s\t%s\t%s\t%s\n' "$build_id" "$version" "$release" "$delta_sha"
}

node_reimage_image_stage_kernel_packages() {
  local kernel_state="$1"
  local kernel_dir="$2"
  local packages file sha staged

  packages="$("$NODE_JQ_BIN" -r '.packages[] | [.file, .sha256] | @tsv' "$kernel_state")" ||
    node_die "could not read kernel packages from ${kernel_state}"
  [[ "$(grep -c . <<<"$packages")" == 4 ]] || node_die "kernel build state must list four packages: ${kernel_state}"
  mkdir -p "$kernel_dir" || node_die "could not create ${kernel_dir}"
  rm -f "${kernel_dir}"/*.deb
  while IFS=$'\t' read -r file sha; do
    staged="${kernel_dir}/$(basename "$file")"
    cp "$file" "$staged" || node_die "could not stage kernel package ${file}"
    [[ "$(node_reimage_sha256_file "$staged")" == "$sha" ]] ||
      node_die "staged kernel package does not match the kernel build state: ${staged}"
  done <<<"$packages"
}

# rpi-image-gen's rpi5 device layer requires rpi-linux-2712, which installs the
# stock archive kernel. These layers keep everything else about rpi5 and leave
# the kernel to the config packages section (the home-ops kernel build).
node_reimage_image_render_kernel_layers() {
  local output_dir="$1"

  cat >"${output_dir}/layer/home-ops-rpi5.yaml" <<'EOF' || node_die "could not write ${output_dir}/layer/home-ops-rpi5.yaml"
# METABEGIN
# X-Env-Layer-Name: home-ops-rpi5
# X-Env-Layer-Category: device
# X-Env-Layer-Desc: Raspberry Pi 5 device layer that installs the home-ops
#  kernel build instead of the stock Raspberry Pi archive kernel.
# X-Env-Layer-Version: 1.0.0
# X-Env-Layer-Requires: rpi-device-base,home-ops-linux-2712
# X-Env-Layer-Provides: rpi-device
#
# X-Env-VarPrefix: device
#
# X-Env-Var-class: pi5
# X-Env-Var-class-Desc: Device class
# X-Env-Var-class-Required: n
# X-Env-Var-class-Valid: keywords:pi5
# X-Env-Var-class-Set: y
#
# X-Env-Var-storage_type: sd
# X-Env-Var-storage_type-Desc: Storage media the image is intended for, as seen
#  by the OS.
# X-Env-Var-storage_type-Required: n
# X-Env-Var-storage_type-Valid: sd,nvme,usb
# X-Env-Var-storage_type-Set: y
#
# X-Env-Var-assetdir: ${DIRECTORY}
# X-Env-Var-assetdir-Desc: Device specific asset directory
# X-Env-Var-assetdir-Required: n
# X-Env-Var-assetdir-Valid: string
# X-Env-Var-assetdir-Set: y
# METAEND
---
EOF

  cat >"${output_dir}/layer/home-ops-linux-2712.yaml" <<'EOF' || node_die "could not write ${output_dir}/layer/home-ops-linux-2712.yaml"
# METABEGIN
# X-Env-Layer-Name: home-ops-linux-2712
# X-Env-Layer-Category: kernel
# X-Env-Layer-Desc: Raspberry Pi 2712 kernel environment for the home-ops
#  kernel build, whose packages come from the config packages section.
# X-Env-Layer-Version: 1.0.0
# X-Env-Layer-Requires: linux-base
#
# X-Env-VarPrefix: linux
#
# X-Env-Var-page_size: 16384
# X-Env-Var-page_size-Desc: 2712 uses a 16K page size kernel
# X-Env-Var-page_size-Valid: int:16384-16384
# X-Env-Var-page_size-Set: force
# METAEND
---
# rpi-image-gen only hands layers with an mmdebstrap mapping to bdebstrap, and
# the INITRD env below must reach the kernel install and initramfs hooks.
env:
  INITRD: "No"
mmdebstrap:
  architectures:
    - arm64
EOF
}

node_reimage_image_render_config() {
  local output_dir="$1"
  local base_layer="$2"
  local hostname="$3"
  local user="$4"
  local image_name="$5"
  local public_key="$6"
  local kernel_state="$7"

  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -n \
    --arg base "$base_layer" \
    --arg hostname "$hostname" \
    --arg user "$user" \
    --arg imageName "$image_name" \
    --arg publicKey "$public_key" \
    --slurpfile kernel "$kernel_state" \
    '{
      device: {
        layer: "home-ops-rpi5",
        hostname: $hostname,
        user1: $user,
        user1sudo: "nopasswd"
      },
      image: {
        layer: "image-rpios",
        boot_part_size: "200%",
        root_part_size: "300%",
        name: $imageName,
        compression: "xz"
      },
      ssh: {
        pubkey_user1: $publicKey,
        pubkey_only: "y"
      },
      layer: {
        base: $base,
        custom: "home-ops-node-bootstrap"
      },
      packages: (
        $kernel[0].packages
        | to_entries
        | map({key: "kernel_\(.key + 1)", value: ("kernel/" + (.value.file | split("/") | last))})
        | from_entries
      )
    }' |
    "$NODE_YQ_BIN" -P >"${output_dir}/config/home-ops-node.yaml" ||
    node_die "could not write ${output_dir}/config/home-ops-node.yaml"
}

# The image seeds the same Raspberry Pi boot settings that Ansible node-prep
# enforces later, read from the Ansible defaults (inventory overrides of these
# keys are not supported). Values are rendered into shell hooks: cmdline args
# must be plain tokens and firmware config lines must be key=value, which also
# keeps a line from ending the hook's EOCONFIG heredoc early.
node_reimage_image_boot_cmdline_args() {
  local defaults="$NODE_REIMAGE_ANSIBLE_DEFAULTS_FILE"
  local args arg
  local arg_re='^[A-Za-z0-9_./,:=@+-]+$'

  [[ -f "$defaults" ]] || node_die "Ansible defaults file not found: ${defaults}"
  args="$("$NODE_YQ_BIN" -r '.home_ops_raspberry_pi_cmdline_args // [] | .[]' "$defaults")" ||
    node_die "could not read home_ops_raspberry_pi_cmdline_args from ${defaults}"
  [[ -n "$args" ]] || node_die "home_ops_raspberry_pi_cmdline_args is empty in ${defaults}"
  while IFS= read -r arg; do
    [[ "$arg" =~ $arg_re ]] || node_die "unsafe Raspberry Pi cmdline arg in ${defaults}: ${arg}"
  done <<<"$args"
  printf '%s\n' "${args//$'\n'/ }"
}

node_reimage_image_boot_config_block() {
  local defaults="$NODE_REIMAGE_ANSIBLE_DEFAULTS_FILE"
  local block line
  local line_re='^[A-Za-z0-9_.-]+=[A-Za-z0-9_.,:=-]*$'

  [[ -f "$defaults" ]] || node_die "Ansible defaults file not found: ${defaults}"
  block="$("$NODE_YQ_BIN" -r '.home_ops_raspberry_pi_config_block // ""' "$defaults")" ||
    node_die "could not read home_ops_raspberry_pi_config_block from ${defaults}"
  [[ -n "$block" ]] || node_die "home_ops_raspberry_pi_config_block is empty in ${defaults}"
  while IFS= read -r line; do
    [[ "$line" =~ $line_re ]] || node_die "unsafe Raspberry Pi config line in ${defaults}: ${line:-<blank line>}"
  done <<<"$block"
  printf '%s\n' "$block"
}

node_reimage_image_render_layer() {
  local output_dir="$1"
  local hostname="$2"
  local address="$3"
  local prefix="$4"
  local gateway="$5"
  local dns="$6"
  local iface="$7"
  local timezone="$8"
  local kernel_state="$9"
  local cmdline_args config_block verify_script kernel_values
  local kernel_build_id kernel_package_version kernel_release kernel_config_delta_sha256

  cmdline_args="$(node_reimage_image_boot_cmdline_args)" ||
    node_die "could not render Raspberry Pi cmdline args"
  config_block="$(node_reimage_image_boot_config_block)" ||
    node_die "could not render Raspberry Pi firmware config"
  config_block="      ${config_block//$'\n'/$'\n'      }"
  kernel_values="$(node_reimage_image_kernel_values "$kernel_state")" ||
    node_die "could not render kernel build values from ${kernel_state}"
  IFS=$'\t' read -r kernel_build_id kernel_package_version kernel_release kernel_config_delta_sha256 <<<"$kernel_values"
  [[ -f "$NODE_KERNEL_VERIFY_SCRIPT" ]] || node_die "kernel verifier not found: ${NODE_KERNEL_VERIFY_SCRIPT}"
  verify_script="$(sed 's/^/      /' "$NODE_KERNEL_VERIFY_SCRIPT")" ||
    node_die "could not read ${NODE_KERNEL_VERIFY_SCRIPT}"

  cat >"${output_dir}/layer/home-ops-node-bootstrap.yaml" <<EOF || node_die "could not write ${output_dir}/layer/home-ops-node-bootstrap.yaml"
# METABEGIN
# X-Env-Layer-Name: home-ops-node-bootstrap
# X-Env-Layer-Desc: Minimal first-boot settings for a home-ops K3s node.
# X-Env-Layer-Version: 1.0.0
# X-Env-Layer-Requires: rpi-user-credentials,systemd-net-min,openssh-server
# METAEND
---
mmdebstrap:
  customize-hooks:
    - install -d -m 0755 \$1/etc/systemd/network
    - |
      cat > \$1/etc/systemd/network/00-home-ops-static.network <<'EONET'
      [Match]
      Name=${iface}

      [Network]
      Address=${address}/${prefix}
      Gateway=${gateway}
      DNS=${dns}
      IPv6AcceptRA=no
      LinkLocalAddressing=no
      EONET
    - |
      cmdline_file=\$1/boot/firmware/cmdline.txt
      if [ -f "\$cmdline_file" ]; then
        cmdline="\$(cat "\$cmdline_file")"
        for arg in ${cmdline_args}; do
          case " \$cmdline " in
            *" \$arg "*)
              ;;
            *)
              cmdline="\${cmdline} \${arg}"
              ;;
          esac
        done
        printf '%s\n' "\$cmdline" > "\$cmdline_file"
      fi
    - |
      config_file=\$1/boot/firmware/config.txt
      if [ -f "\$config_file" ]; then
        sed -i -E '/^[[:space:]]*(dtparam=(pciex1|nvme|pciex1_gen|audio)(=.*)?|dtoverlay=(cma(,.*)?|disable-wifi|disable-bt)|arm_boost=.*)[[:space:]]*$/d' "\$config_file"
        cat >> "\$config_file" <<'EOCONFIG'

      [all]
      # BEGIN ANSIBLE MANAGED BLOCK home-ops raspberry pi config
${config_block}
      # END ANSIBLE MANAGED BLOCK home-ops raspberry pi config
      EOCONFIG
      fi
    - install -d -m 0755 \$1/etc/systemd/system/multi-user.target.wants \$1/usr/local/sbin \$1/etc/apt/preferences.d \$1/etc/home-ops
    - |
      cat > \$1/usr/local/sbin/home-ops-verify-kernel-build <<'EOVERIFY'
${verify_script}
      EOVERIFY
      chmod 0755 \$1/usr/local/sbin/home-ops-verify-kernel-build
    - |
      cat > \$1/etc/apt/preferences.d/90-home-ops-kernel <<'EOPIN'
      Explanation: home-ops runs its own BTF-enabled rebuild of the Raspberry Pi kernel
      Explanation: (hack/bootstrap/nodes/kernel in home-ops). Never install kernel
      Explanation: packages from the Raspberry Pi archive over it; kernel updates
      Explanation: are rebuilds.
      Package: /^linux-(image|base|headers)-(.+-)?rpi-2712\$/
      Pin: origin "archive.raspberrypi.com"
      Pin-Priority: -1
      EOPIN
    - |
      cat > \$1/etc/home-ops/kernel-build <<'EOKERNEL'
      KERNEL_BUILD_ID=${kernel_build_id}
      KERNEL_PACKAGE_VERSION=${kernel_package_version}
      KERNEL_RELEASE=${kernel_release}
      KERNEL_CONFIG_DELTA_SHA256=${kernel_config_delta_sha256}
      EOKERNEL
    - |
      cat > \$1/usr/local/sbin/home-ops-firstboot <<'EOSCRIPT'
      #!/usr/bin/env bash
      set -euo pipefail

      grow_rootfs() {
        local root_source root_dev root_disk root_partnum root_disk_path
        local disk_size root_end free_after

        root_source="\$(findmnt -no SOURCE /)"
        root_dev="\$(readlink -f "\$root_source")"
        root_disk="\$(lsblk -no PKNAME "\$root_dev" | sed -n '1p')"
        root_partnum="\$(lsblk -no PARTN "\$root_dev" | sed -n '1p')"
        [[ -n "\$root_disk" && -n "\$root_partnum" ]] || return 0
        root_disk_path="/dev/\${root_disk}"
        command -v parted >/dev/null 2>&1 || return 0
        command -v resize2fs >/dev/null 2>&1 || return 0

        disk_size="\$(
          parted -m "\$root_disk_path" unit B print |
            awk -F: -v disk="\$root_disk_path" '\$1 == disk {gsub(/B$/, "", \$2); print \$2; exit}'
        )"
        root_end="\$(
          parted -m "\$root_disk_path" unit B print |
            awk -F: -v part="\$root_partnum" '\$1 == part {gsub(/B$/, "", \$3); print \$3; exit}'
        )"
        [[ -n "\$disk_size" && -n "\$root_end" ]] || return 0
        free_after=\$((disk_size - root_end))
        ((free_after > 1073741824)) || return 0

        printf 'Yes\n' | parted ---pretend-input-tty "\$root_disk_path" resizepart "\$root_partnum" 100%
        partprobe "\$root_disk_path" 2>/dev/null || true
        resize2fs "\$root_dev"
      }

      # Fail closed before touching the node: a wrong kernel leaves no
      # firstboot-complete marker, which stops node-prep and reimage-apply.
      /usr/local/sbin/home-ops-verify-kernel-build
      hostnamectl set-hostname '${hostname}'
      timedatectl set-timezone '${timezone}' || true
      systemctl disable --now dphys-swapfile 2>/dev/null || true
      grow_rootfs
      update-initramfs -u -k all
      EOSCRIPT
      chmod 0755 \$1/usr/local/sbin/home-ops-firstboot
    - |
      cat > \$1/etc/systemd/system/home-ops-firstboot.service <<'EOSERVICE'
      [Unit]
      Description=home-ops first boot node normalization
      After=network-online.target
      Wants=network-online.target
      ConditionPathExists=!/var/lib/home-ops/firstboot-complete

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/home-ops-firstboot
      ExecStartPost=/usr/bin/install -d -m 0755 /var/lib/home-ops
      ExecStartPost=/usr/bin/touch /var/lib/home-ops/firstboot-complete

      [Install]
      WantedBy=multi-user.target
      EOSERVICE
      ln -sf /etc/systemd/system/home-ops-firstboot.service \$1/etc/systemd/system/multi-user.target.wants/home-ops-firstboot.service
  cleanup-hooks:
    - chroot \$1 apt-mark hold linux-image-${kernel_release} linux-base-${kernel_release} linux-image-${NODE_KERNEL_FLAVOUR} linux-base-${NODE_KERNEL_FLAVOUR}
  packages:
    - bash
    - bpftool
    - busybox-static
    - ca-certificates
    - conntrack
    - cryptsetup
    - curl
    - dnsutils
    - dmsetup
    - e2fsprogs
    - ethtool
    - git
    - htop
    - initramfs-tools
    - iproute2
    - iptables
    - jq
    - kmod
    - lsof
    - nano
    - nfs-common
    - nvme-cli
    - open-iscsi
    - parted
    - python3
    - socat
    - smartmontools
    - strace
    - tcpdump
    - xz-utils
    - zstd
EOF
}

node_reimage_image_render_readme() {
  local output_dir="$1"
  local node="$2"
  local image_name="$3"

  cat >"${output_dir}/README.md" <<EOF
# home-ops Raspberry Pi image source: ${node}

Build from a checked-out \`rpi-image-gen\` repository:

\`\`\`bash
./rpi-image-gen build -S ${output_dir} -c home-ops-node.yaml
\`\`\`

The expected image name is \`${image_name}\`. After the build produces an
\`.img.xz\`, compute its SHA256 and feed that URL plus checksum to
\`just node-reimage-metadata\` and \`just node-reimage-stage\`.
EOF
}

node_reimage_image_render_source() {
  local profile="$1"
  local inventory_node="$2"
  local output_dir="$3"
  local public_key_file="$4"
  local base_layer="$5"
  local iface="$6"
  local prefix="$7"
  local gateway="$8"
  local dns="$9"
  local kernel_state="${10}"
  local role ansible_host user public_key image_name timezone

  [[ -f "$kernel_state" ]] || node_die "kernel build state not found: ${kernel_state}"
  node_reimage_image_kernel_values "$kernel_state" >/dev/null ||
    node_die "invalid kernel build state: ${kernel_state}"
  role="$(node_inventory_role "$profile" "$inventory_node")"
  [[ "$role" == master || "$role" == node ]] ||
    node_die "node is not present in ${profile} inventory: ${inventory_node}"

  ansible_host="$(node_inventory_value "$profile" "$inventory_node" ansible_host)"
  [[ -n "$ansible_host" && "$ansible_host" != "null" ]] ||
    node_die "inventory ansible_host is required for image rendering: ${inventory_node}"
  user="$(node_effective_ansible_user "$profile" "$inventory_node")"
  [[ -n "$user" && "$user" != "null" ]] ||
    node_die "inventory ansible_user is required for image rendering: ${inventory_node}"
  public_key="$(node_reimage_image_public_key "$profile" "$inventory_node" "$public_key_file")"
  [[ "$public_key" =~ ^ssh-[A-Za-z0-9-]+[[:space:]]+[^[:space:]]+ ]] ||
    node_die "SSH public key does not look like an OpenSSH public key"

  base_layer="$(node_reimage_image_inventory_or_default "$profile" "$inventory_node" home_ops_reimage_image_base_layer "$base_layer")"
  iface="$(node_reimage_image_inventory_or_default "$profile" "$inventory_node" home_ops_reimage_image_iface "$iface")"
  prefix="$(node_reimage_image_inventory_or_default "$profile" "$inventory_node" home_ops_reimage_image_prefix "$prefix")"
  gateway="$(node_reimage_image_inventory_or_default "$profile" "$inventory_node" home_ops_reimage_image_gateway "$gateway")"
  if [[ -z "$gateway" ]]; then
    gateway="$(node_reimage_image_default_gateway "$ansible_host")"
  fi
  dns="$(node_reimage_image_inventory_or_default "$profile" "$inventory_node" home_ops_reimage_image_dns "$dns")"
  if [[ -z "$dns" ]]; then
    dns="$gateway"
  fi
  timezone="$(node_group_var "$profile" system_timezone 2>/dev/null || true)"
  [[ -n "$timezone" && "$timezone" != "null" ]] || timezone=Etc/UTC

  [[ "$base_layer" =~ ^[A-Za-z0-9._/-]+$ ]] ||
    node_die "rpi-image-gen base layer is not valid: ${base_layer}"
  node_reimage_image_validate_network "$inventory_node" "$iface" "$ansible_host" "$prefix" "$gateway" "$dns"

  if [[ -z "$output_dir" ]]; then
    output_dir="$(node_reimage_image_output_root)/${profile}/${inventory_node}/source"
  fi
  mkdir -p "${output_dir}/config" "${output_dir}/layer" "${output_dir}/kernel"
  node_reimage_image_stage_kernel_packages "$kernel_state" "${output_dir}/kernel"

  image_name="home-ops-${inventory_node}"
  node_reimage_image_render_config "$output_dir" "$base_layer" "$inventory_node" "$user" "$image_name" "$public_key" "$kernel_state"
  node_reimage_image_render_kernel_layers "$output_dir"
  node_reimage_image_render_layer "$output_dir" "$inventory_node" "$ansible_host" "$prefix" "$gateway" "$dns" "$iface" "$timezone" "$kernel_state"
  node_reimage_image_render_readme "$output_dir" "$inventory_node" "$image_name"

  printf 'source_dir=%s\n' "$output_dir"
  printf 'config=%s\n' "${output_dir}/config/home-ops-node.yaml"
  printf 'layer=%s\n' "${output_dir}/layer/home-ops-node-bootstrap.yaml"
  printf 'image_name=%s\n' "$image_name"
  printf 'base_layer=%s\n' "$base_layer"
  printf 'hostname=%s\n' "$inventory_node"
  printf 'ansible_host=%s\n' "$ansible_host"
  printf 'network_interface=%s\n' "$iface"
  printf 'network_cidr=%s/%s\n' "$ansible_host" "$prefix"
  printf 'network_gateway=%s\n' "$gateway"
  printf 'kernel_build_id=%s\n' "$("$NODE_JQ_BIN" -r '.buildId' "$kernel_state")"
  printf 'kernel_package_version=%s\n' "$("$NODE_JQ_BIN" -r '.packageVersion' "$kernel_state")"
  printf 'kernel_build_state=%s\n' "$kernel_state"
}
