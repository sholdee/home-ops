# shellcheck shell=bash

NODE_REIMAGE_IMAGE_DEFAULT_BASE_LAYER="${NODE_REIMAGE_IMAGE_DEFAULT_BASE_LAYER:-trixie-minbase}"
NODE_REIMAGE_IMAGE_DEFAULT_INTERFACE="${NODE_REIMAGE_IMAGE_DEFAULT_INTERFACE:-eth0}"
NODE_REIMAGE_IMAGE_DEFAULT_PREFIX="${NODE_REIMAGE_IMAGE_DEFAULT_PREFIX:-24}"

node_reimage_image_output_root() {
  printf '%s/.out/reimage\n' "$BOOTSTRAP_DIR"
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

node_reimage_image_render_config() {
  local output_dir="$1"
  local base_layer="$2"
  local hostname="$3"
  local user="$4"
  local image_name="$5"
  local public_key="$6"

  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -n \
    --arg base "$base_layer" \
    --arg hostname "$hostname" \
    --arg user "$user" \
    --arg imageName "$image_name" \
    --arg publicKey "$public_key" \
    '{
      device: {
        layer: "rpi5",
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
      }
    }' |
    "$NODE_YQ_BIN" -P >"${output_dir}/config/home-ops-node.yaml"
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

  cat >"${output_dir}/layer/home-ops-node-bootstrap.yaml" <<EOF
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
        for arg in \
          cgroup_enable=cpuset \
          cgroup_memory=1 \
          cgroup_enable=memory \
          nvme_core.default_ps_max_latency_us=0 \
          pcie_aspm=off \
          pcie_port_pm=off; do
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
      dtparam=pciex1
      dtparam=nvme
      dtparam=pciex1_gen=3
      dtoverlay=cma,cma-96
      dtparam=audio=off
      dtoverlay=disable-wifi
      dtoverlay=disable-bt
      arm_boost=1
      # END ANSIBLE MANAGED BLOCK home-ops raspberry pi config
      EOCONFIG
      fi
    - install -d -m 0755 \$1/etc/systemd/system/multi-user.target.wants \$1/usr/local/sbin
    - |
      cat > \$1/usr/local/sbin/home-ops-firstboot <<'EOSCRIPT'
      #!/usr/bin/env bash
      set -euo pipefail
      hostnamectl set-hostname '${hostname}'
      timedatectl set-timezone '${timezone}' || true
      systemctl disable --now dphys-swapfile 2>/dev/null || true
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
  packages:
    - bash
    - ca-certificates
    - curl
    - git
    - iproute2
    - iptables
    - jq
    - nfs-common
    - open-iscsi
    - python3
    - socat
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
  local role ansible_host user public_key image_name timezone

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
  mkdir -p "${output_dir}/config" "${output_dir}/layer"

  image_name="home-ops-${inventory_node}"
  node_reimage_image_render_config "$output_dir" "$base_layer" "$inventory_node" "$user" "$image_name" "$public_key"
  node_reimage_image_render_layer "$output_dir" "$inventory_node" "$ansible_host" "$prefix" "$gateway" "$dns" "$iface" "$timezone"
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
}
