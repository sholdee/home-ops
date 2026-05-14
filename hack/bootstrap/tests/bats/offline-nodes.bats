#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2154

load '../helpers/common.bash'
load '../helpers/nodes.bash'

setup_file() {
  require_tools yq jq
}

setup() {
  tmp="$BATS_TEST_TMPDIR"
  export BOOTSTRAP_ANSIBLE_OUT_DIR="${tmp}/ansible-out"
  create_node_inventory
}

@test "node inventory helpers resolve roles, values, contexts, and quorum size" {
  run env NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_inventory_role live k3s-master-0"
  assert_success
  [[ "$output" == "master" ]]

  run env NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_inventory_role live k3s-worker-0"
  assert_success
  [[ "$output" == "node" ]]

  run env NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_inventory_role live k3s-worker-9"
  assert_success
  [[ "$output" == "absent" ]]

  run env NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_inventory_value live k3s-worker-0 ansible_host"
  assert_success
  [[ "$output" == "192.168.99.20" ]]

  run env HOME=/tmp/home NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_effective_ssh_key live k3s-worker-0"
  assert_success
  [[ "$output" == "/tmp/home/ansiblekey" ]]

  run env NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_resolve_inventory_node live k3s-worker-0"
  assert_success
  [[ "$output" == "$(printf 'k3s-worker-0\tnode')" ]]

  run env NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_inventory_group_count live master"
  assert_success
  [[ "$output" == "3" ]]

  run bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_etcd_quorum_size 3"
  assert_success
  [[ "$output" == "2" ]]

  run bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_expected_kubernetes_node_name lima home-ops-k3s-test-agent-1 home-ops-k3s-test-agent-1"
  assert_success
  [[ "$output" == "lima-home-ops-k3s-test-agent-1" ]]

  run bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_context_for_profile live"
  assert_success
  [[ "$output" == "default" ]]

  run env LIMA_CLUSTER_NAME=test-cluster \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_context_for_profile lima"
  assert_success
  [[ "$output" == "lima-test-cluster" ]]
}

@test "joining taint parser distinguishes present and invalid taints" {
  run bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_joining_taint_from_node_json" <<'JSON'
{"spec":{"taints":[{"key":"node.home-ops.sh/joining","value":"true","effect":"NoSchedule"}]}}
JSON
  assert_success
  [[ "$output" == "present" ]]

  run bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_joining_taint_from_node_json" <<'JSON'
{"spec":{"taints":[{"key":"node.home-ops.sh/joining","value":"true","effect":"PreferNoSchedule"}]}}
JSON
  assert_success
  [[ "$output" == "invalid" ]]
}

@test "node cmd helper resolves live inventory SSH command" {
  local fake_ssh capture
  fake_ssh="${tmp}/ssh"
  capture="${tmp}/ssh-args"
  cat > "$fake_ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SSH_CAPTURE"
EOF
  chmod +x "$fake_ssh"

  run env PATH="${tmp}:${PATH}" HOME=/tmp/home SSH_CAPTURE="$capture" \
    NODE_LIVE_INVENTORY_DIR="$inventory" \
    "${ROOT}/hack/bootstrap/nodes/cmd.sh" \
      --profile live k3s-worker-0 -- systemctl status isp-rpi-reporter.service
  assert_success
  assert_file_contains "$capture" '-o'
  assert_file_contains "$capture" 'BatchMode=yes'
  assert_file_contains "$capture" 'StrictHostKeyChecking=accept-new'
  assert_file_contains "$capture" '-i'
  assert_file_contains "$capture" '/tmp/home/ansiblekey'
  assert_file_contains "$capture" 'ethan@192.168.99.20'
  assert_file_contains "$capture" 'systemctl'
  assert_file_contains "$capture" 'isp-rpi-reporter.service'
}

@test "node cmd just recipes quote shell metacharacters for the remote command" {
  run just --dry-run node-cmd k3s-worker-0 'set -e; cd /tmp; pwd'
  assert_success
  assert_output_contains "./hack/bootstrap/nodes/cmd.sh --profile live 'k3s-worker-0' -- 'set -e; cd /tmp; pwd'"

  run just --dry-run node-lima-cmd home-ops-k3s-test-agent-1 'set -e; cd /tmp; pwd'
  assert_success
  assert_output_contains "./hack/bootstrap/nodes/cmd.sh --profile lima 'home-ops-k3s-test-agent-1' -- 'set -e; cd /tmp; pwd'"
}

@test "node reimage just recipes expose build, serve, apply, and primitive commands" {
  local sha
  sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  run just --dry-run node-reimage-plan k3s-worker-0
  assert_success
  assert_output_contains "./hack/bootstrap/nodes/reimage-plan.sh --profile live --context default 'k3s-worker-0'"

  run just --dry-run node-reimage-metadata k3s-worker-0 https://images.example/k3s-worker-0.img.xz "$sha"
  assert_success
  assert_output_contains "./hack/bootstrap/nodes/reimage-metadata.sh --profile live 'k3s-worker-0' 'https://images.example/k3s-worker-0.img.xz' '${sha}'"

  run just --dry-run node-reimage-image-source k3s-worker-0 --ssh-public-key /tmp/ansiblekey.pub
  assert_success
  assert_output_contains "./hack/bootstrap/nodes/reimage-image-source.sh --profile live 'k3s-worker-0' --ssh-public-key /tmp/ansiblekey.pub"

  run just --dry-run node-reimage-build k3s-worker-0 --ssh-public-key /tmp/ansiblekey.pub
  assert_success
  assert_output_contains "./hack/bootstrap/nodes/reimage-build.sh --profile live 'k3s-worker-0' --ssh-public-key /tmp/ansiblekey.pub"

  run just --dry-run node-reimage-stage k3s-worker-0 https://images.example/k3s-worker-0.img.xz "$sha" --force
  assert_success
  assert_output_contains "./hack/bootstrap/nodes/reimage-stage.sh --profile live --context default 'k3s-worker-0' 'https://images.example/k3s-worker-0.img.xz' '${sha}' --force"

  run just --dry-run node-reimage-reboot k3s-worker-0 --force
  assert_success
  assert_output_contains "./hack/bootstrap/nodes/reimage-reboot.sh --profile live --context default 'k3s-worker-0' --force"

  run just --dry-run node-reimage-serve k3s-worker-0 k3s-master-0 --port 18081
  assert_success
  assert_output_contains "./hack/bootstrap/nodes/reimage-serve.sh --profile live 'k3s-worker-0' 'k3s-master-0' --port 18081"

  run just --dry-run node-reimage-apply k3s-worker-0 --force
  assert_success
  assert_output_contains "./hack/bootstrap/nodes/reimage-apply.sh --profile live --context default 'k3s-worker-0' --force"

  run just --dry-run node-reimage-cleanup k3s-worker-0 --yes
  assert_success
  assert_output_contains "./hack/bootstrap/nodes/reimage-cleanup.sh --profile live 'k3s-worker-0' --yes"
}

@test "node cmd helper tolerates an accidental extra separator before the remote command" {
  local fake_ssh capture
  fake_ssh="${tmp}/ssh"
  capture="${tmp}/ssh-args"
  cat > "$fake_ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SSH_CAPTURE"
EOF
  chmod +x "$fake_ssh"

  run env PATH="${tmp}:${PATH}" HOME=/tmp/home SSH_CAPTURE="$capture" \
    NODE_LIVE_INVENTORY_DIR="$inventory" \
    "${ROOT}/hack/bootstrap/nodes/cmd.sh" \
      --profile live k3s-worker-0 -- -- 'set -e; cd /tmp; pwd'
  assert_success
  assert_file_contains "$capture" 'ethan@192.168.99.20'
  assert_file_contains "$capture" 'set -e; cd /tmp; pwd'
  run grep -Fx -- '--' "$capture"
  assert_failure

  run env PATH="${tmp}:${PATH}" HOME=/tmp/home SSH_CAPTURE="$capture" \
    NODE_LIVE_INVENTORY_DIR="$inventory" \
    "${ROOT}/hack/bootstrap/nodes/cmd.sh" \
      --profile live k3s-worker-0 -- '-- set -e; cd /tmp; pwd'
  assert_success
  assert_file_contains "$capture" 'set -e; cd /tmp; pwd'
  assert_file_not_contains "$capture" '-- set -e'
}

@test "node cmd helper fails closed for absent inventory node" {
  run env NODE_LIVE_INVENTORY_DIR="$inventory" \
    "${ROOT}/hack/bootstrap/nodes/cmd.sh" \
      --profile live k3s-worker-9 -- true
  assert_failure
  assert_output_contains 'node is not present in live inventory'
}

@test "node reimage plan discovers Pi and disk identity without mutating state" {
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" \
    "${ROOT}/hack/bootstrap/nodes/reimage-plan.sh" --profile live --context test k3s-worker-0
  assert_success
  assert_output_contains 'inventory_node: k3s-worker-0'
  assert_output_contains 'kubernetes_node_state: unknown'
  assert_output_contains 'home_ops_reimage_pi_serial: missing'
  assert_output_contains 'raspberry_pi=true'
  assert_output_contains 'disk_serial=nvme-deadbeef'
  assert_output_contains 'next_inventory_values:'
  assert_output_contains 'home_ops_reimage_pi_serial: 10000000deadbeef'
  assert_output_contains 'home_ops_reimage_disk_serial: nvme-deadbeef'
}

@test "node reimage metadata renders stage-compatible image metadata" {
  local sha
  sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  run env NODE_LIVE_INVENTORY_DIR="$inventory" \
    "${ROOT}/hack/bootstrap/nodes/reimage-metadata.sh" \
      --profile live k3s-worker-0 https://images.example/k3s-worker-0.img.xz "$sha"
  assert_success
  printf '%s\n' "$output" >"${tmp}/metadata.json"

  run jq -r '.schemaVersion' "${tmp}/metadata.json"
  assert_success
  [[ "$output" == "home-ops.node-image/v1" ]]

  run jq -r '.node, .hostname, .ansibleHost, .imageUrl, .sha256, .arch' "${tmp}/metadata.json"
  assert_success
  assert_output_contains 'k3s-worker-0'
  assert_output_contains '192.168.99.20'
  assert_output_contains 'https://images.example/k3s-worker-0.img.xz'
  assert_output_contains "$sha"
  assert_output_contains 'arm64'
}

@test "node reimage image source renders rpi-image-gen config and first-boot layer" {
  local output_dir public_key
  output_dir="${tmp}/image-source"
  public_key="${tmp}/ansiblekey.pub"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeHomeOpsKey home-ops-test\n' >"$public_key"

  run env NODE_LIVE_INVENTORY_DIR="$inventory" \
    "${ROOT}/hack/bootstrap/nodes/reimage-image-source.sh" \
      --profile live \
      --output-dir "$output_dir" \
      --ssh-public-key "$public_key" \
      k3s-worker-0
  assert_success
  assert_output_contains "source_dir=${output_dir}"
  assert_output_contains 'base_layer=trixie-minbase'
  assert_output_contains 'network_interface=eth0'
  assert_output_contains 'network_gateway=192.168.99.1'
  assert_file_contains "${output_dir}/config/home-ops-node.yaml" 'layer: rpi5'
  assert_file_contains "${output_dir}/config/home-ops-node.yaml" 'base: trixie-minbase'
  assert_file_contains "${output_dir}/config/home-ops-node.yaml" 'custom: home-ops-node-bootstrap'
  assert_file_contains "${output_dir}/config/home-ops-node.yaml" 'hostname: k3s-worker-0'
  assert_file_contains "${output_dir}/config/home-ops-node.yaml" 'user1: ethan'
  assert_file_contains "${output_dir}/config/home-ops-node.yaml" 'user1sudo: nopasswd'
  assert_file_contains "${output_dir}/config/home-ops-node.yaml" 'pubkey_user1: ssh-ed25519'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'rpi-user-credentials,systemd-net-min,openssh-server'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'Name=eth0'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'Address=192.168.99.20/24'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'Gateway=192.168.99.1'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'DNS=192.168.99.1'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'cgroup_enable=cpuset'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'nvme_core.default_ps_max_latency_us=0'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'pcie_aspm=off'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'dtparam=pciex1'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'dtoverlay=disable-wifi'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'ANSIBLE MANAGED BLOCK home-ops raspberry pi config'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'grow_rootfs'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'parted ---pretend-input-tty'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'resize2fs'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'update-initramfs -u -k all'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'firstboot-complete'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'busybox-static'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'e2fsprogs'
  assert_file_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'initramfs-tools'
  assert_file_not_contains "${output_dir}/layer/home-ops-node-bootstrap.yaml" 'NetworkManager'
  assert_file_contains "${output_dir}/README.md" 'rpi-image-gen'
}

@test "node reimage image source derives public key from inventory private key" {
  local fake_ssh_keygen output_dir test_home
  output_dir="${tmp}/image-source-derived"
  test_home="${tmp}/home"
  fake_ssh_keygen="${tmp}/ssh-keygen"
  mkdir -p "$test_home"
  touch "${test_home}/ansiblekey"
cat >"$fake_ssh_keygen" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-y" && "$2" == "-f" && "$3" == */ansiblekey && "$4" == "-P" && "$5" == "" ]] || exit 2
printf '%s\n' 'ssh-rsa AAAAFakeDerivedHomeOpsKey ethan@ansible'
EOF
  chmod +x "$fake_ssh_keygen"

  run env HOME="$test_home" PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" \
    "${ROOT}/hack/bootstrap/nodes/reimage-image-source.sh" \
      --profile live \
      --output-dir "$output_dir" \
      k3s-worker-0
  assert_success
  assert_file_contains "${output_dir}/config/home-ops-node.yaml" 'pubkey_user1: ssh-rsa AAAAFakeDerivedHomeOpsKey ethan@ansible'
}

@test "node reimage build records artifact state from a local builder" {
  local fake_rpi public_key state artifact
  fake_rpi="${tmp}/rpi-image-gen"
  public_key="${tmp}/ansiblekey.pub"
  mkdir -p "$fake_rpi"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeHomeOpsKey home-ops-test\n' >"$public_key"
  cat > "${fake_rpi}/rpi-image-gen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source_dir=''
build_dir=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -S)
      source_dir="$2"
      shift 2
      ;;
    -B)
      build_dir="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
test -f "${source_dir}/config/home-ops-node.yaml"
mkdir -p "${build_dir}/image-home-ops-k3s-worker-0"
printf 'fake image\n' > "${build_dir}/image-home-ops-k3s-worker-0/home-ops-k3s-worker-0.img.xz"
EOF
  chmod +x "${fake_rpi}/rpi-image-gen"

  run env NODE_LIVE_INVENTORY_DIR="$inventory" NODE_REIMAGE_OUTPUT_ROOT="${tmp}/reimage-out" NODE_REIMAGE_BUILDER_MODE=local \
    "${ROOT}/hack/bootstrap/nodes/reimage-build.sh" \
      --profile live \
      --rpi-image-gen-dir "$fake_rpi" \
      --ssh-public-key "$public_key" \
      k3s-worker-0
  assert_success
  assert_output_contains 'artifact='
  assert_output_contains 'sha256='
  assert_output_contains 'build_state='

  state="${tmp}/reimage-out/live/k3s-worker-0/state/build.json"
  artifact="${tmp}/reimage-out/live/k3s-worker-0/home-ops-k3s-worker-0.img.xz"
  [[ -f "$state" ]]
  [[ -f "$artifact" ]]
  run jq -r '.schemaVersion, .builderMode, .imageName, .artifactPath' "$state"
  assert_success
  assert_output_contains 'home-ops.node-reimage-build/v1'
  assert_output_contains 'local'
  assert_output_contains 'home-ops-k3s-worker-0'
  assert_output_contains "$artifact"
}

@test "node reimage lima builder writes to guest-local workroot and copies artifacts back" {
  assert_file_contains "${ROOT}/hack/bootstrap/nodes/lib/reimage-orchestrate.sh" '/var/tmp/home-ops-reimage-build/'
  assert_file_contains "${ROOT}/hack/bootstrap/nodes/lib/reimage-orchestrate.sh" 'for suffix in img.zst img.xz img.gz img'
  assert_file_contains "${ROOT}/hack/bootstrap/nodes/lib/reimage-orchestrate.sh" 'limactl copy --tty=false'
}

@test "node reimage serve records URL and metadata for a built artifact" {
  local node_dir state artifact sha
  write_fake_ansible
  node_dir="${tmp}/reimage-out/live/k3s-worker-0"
  mkdir -p "${node_dir}/state"
  artifact="${node_dir}/home-ops-k3s-worker-0.img.xz"
  printf 'fake image\n' > "$artifact"
  sha="$(shasum -a 256 "$artifact" | awk '{print $1}')"
  jq -n \
    --arg artifact "$artifact" \
    --arg sha "$sha" \
    '{schemaVersion:"home-ops.node-reimage-build/v1", artifactPath:$artifact, sha256:$sha}' \
    > "${node_dir}/state/build.json"

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_REIMAGE_OUTPUT_ROOT="${tmp}/reimage-out" \
    "${ROOT}/hack/bootstrap/nodes/reimage-serve.sh" \
      --profile live \
      --port 18081 \
      --yes \
      k3s-worker-0 \
      k3s-master-0
  assert_success
  assert_output_contains 'image_url=http://192.168.99.10:18081/home-ops-k3s-worker-0.img.xz'
  assert_output_contains "sha256=${sha}"
  assert_output_contains 'serve_state='

  state="${node_dir}/state/serve.json"
  [[ -f "$state" ]]
  [[ -f "${artifact}.metadata.json" ]]
  run jq -r '.schemaVersion, .hostNode, .imageUrl, .metadataPath' "$state"
  assert_success
  assert_output_contains 'home-ops.node-reimage-serve/v1'
  assert_output_contains 'k3s-master-0'
  assert_output_contains 'http://192.168.99.10:18081/home-ops-k3s-worker-0.img.xz'
  assert_output_contains "${artifact}.metadata.json"
}

@test "node reimage serve refuses a stale artifact hash" {
  local node_dir artifact
  write_fake_ansible
  node_dir="${tmp}/reimage-out/live/k3s-worker-0"
  mkdir -p "${node_dir}/state"
  artifact="${node_dir}/home-ops-k3s-worker-0.img.xz"
  printf 'changed image\n' > "$artifact"
  jq -n \
    --arg artifact "$artifact" \
    '{schemaVersion:"home-ops.node-reimage-build/v1", artifactPath:$artifact, sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
    > "${node_dir}/state/build.json"

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_REIMAGE_OUTPUT_ROOT="${tmp}/reimage-out" \
    "${ROOT}/hack/bootstrap/nodes/reimage-serve.sh" \
      --profile live \
      --port 18081 \
      --yes \
      k3s-worker-0 \
      k3s-master-0
  assert_failure
  assert_output_contains 'recorded image SHA does not match artifact'
}

@test "node reimage serve stops an old HTTP server before resetting remote files" {
  run awk '
    /if \[ -f \$\{remote_dir_q\}\/http.pid \]/ {pid_check = NR}
    /rm -rf \$\{remote_dir_q\}/ {reset_dir = NR}
    END {exit !(pid_check > 0 && reset_dir > 0 && pid_check < reset_dir)}
  ' "${ROOT}/hack/bootstrap/nodes/reimage-serve.sh"
  assert_success
}

@test "node reimage stage refuses to run before the Kubernetes node is deleted" {
  local sha payload metadata
  sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  payload="${tmp}/payload"
  metadata="${tmp}/metadata.json"
  mkdir -p "$payload"
  printf 'initramfs\n' >"${payload}/initramfs.img"
  printf 'cmdline\n' >"${payload}/cmdline.txt"
  cat > "$metadata" <<EOF
{
  "schemaVersion": "home-ops.node-image/v1",
  "node": "k3s-worker-0",
  "hostname": "k3s-worker-0",
  "ansibleHost": "192.168.99.20",
  "imageUrl": "https://images.example/k3s-worker-0.img.xz",
  "sha256": "${sha}",
  "arch": "arm64"
}
EOF
  add_reimage_identity k3s-worker-0 10000000deadbeef nvme-deadbeef
  write_reimage_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_reimage_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/reimage-stage.sh" \
      --profile live --context test --metadata-file "$metadata" --payload-dir "$payload" --yes \
      k3s-worker-0 https://images.example/k3s-worker-0.img.xz "$sha"
  assert_failure
  assert_output_contains 'Kubernetes node still exists'
}

@test "node reimage stage validates identity metadata and stages tryboot payload" {
  local sha payload metadata
  sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  payload="${tmp}/payload"
  metadata="${tmp}/metadata.json"
  mkdir -p "$payload"
  printf 'initramfs\n' >"${payload}/initramfs.img"
  printf 'cmdline\n' >"${payload}/cmdline.txt"
  cat > "$metadata" <<EOF
{
  "schemaVersion": "home-ops.node-image/v1",
  "node": "k3s-worker-0",
  "hostname": "k3s-worker-0",
  "ansibleHost": "192.168.99.20",
  "imageUrl": "https://images.example/k3s-worker-0.img.xz",
  "sha256": "${sha}",
  "arch": "arm64"
}
EOF
  add_reimage_identity k3s-worker-0 10000000deadbeef nvme-deadbeef
  write_reimage_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_reimage_kubectl" FAKE_REIMAGE_NODE_ABSENT=true \
    "${ROOT}/hack/bootstrap/nodes/reimage-stage.sh" \
      --profile live --context test --metadata-file "$metadata" --payload-dir "$payload" --yes \
      k3s-worker-0 https://images.example/k3s-worker-0.img.xz "$sha"
  assert_success
  assert_output_contains 'probing k3s-worker-0 identity and target disk'
  assert_output_contains 'validating image metadata'
  assert_output_contains 'staging reimage manifest and tryboot payload on k3s-worker-0'
  assert_output_contains 'reimage staged for k3s-worker-0'
}

@test "node reimage tryboot config uses the known-good include shape" {
  run bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_reimage_tryboot_config /boot/firmware/home-ops-reimage"

  assert_success
  assert_output_contains 'include config.txt'
  assert_output_contains 'initramfs home-ops-reimage/initramfs.img followkernel'
  assert_output_contains 'cmdline=home-ops-reimage/cmdline.txt'
}

@test "node reimage stage defaults to building payload from target initramfs" {
  local sha metadata
  sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  metadata="${tmp}/metadata.json"
  cat > "$metadata" <<EOF
{
  "schemaVersion": "home-ops.node-image/v1",
  "node": "k3s-worker-0",
  "hostname": "k3s-worker-0",
  "ansibleHost": "192.168.99.20",
  "imageUrl": "https://images.example/k3s-worker-0.img.xz",
  "sha256": "${sha}",
  "arch": "arm64"
}
EOF
  add_reimage_identity k3s-worker-0 10000000deadbeef nvme-deadbeef
  write_reimage_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_REIMAGE_PAYLOAD_DIR="" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_reimage_kubectl" FAKE_REIMAGE_NODE_ABSENT=true FAKE_REIMAGE_REMOTE_PAYLOAD=true \
    "${ROOT}/hack/bootstrap/nodes/reimage-stage.sh" \
      --profile live --context test --metadata-file "$metadata" --yes \
      k3s-worker-0 https://images.example/k3s-worker-0.img.xz "$sha"
  assert_success
  assert_output_contains 'building reimage initramfs payload on k3s-worker-0'
  assert_output_contains 'remote_payload=built'
  assert_output_contains 'net_iface=eth0.99'
  assert_output_contains 'reimage staged for k3s-worker-0'
}

@test "node reimage target-built payload script does not require jq on target" {
  local manifest
  manifest="${tmp}/manifest.json"
  cat > "$manifest" <<'EOF'
{
  "schemaVersion": "home-ops.node-reimage-stage/v1",
  "imageUrl": "https://images.example/k3s-worker-0.img.xz",
  "imageSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "targetDisk": "/dev/nvme0n1",
  "targetDiskSerial": "nvme-deadbeef",
  "raspberryPiSerial": "10000000deadbeef"
}
EOF

  run bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; manifest=\$(cat '${manifest}'); node_reimage_build_remote_payload_script /boot/firmware/home-ops-reimage \"\${manifest}\" '#!/bin/sh
true'"
  assert_success
  assert_output_contains "target_disk_b64="
  assert_output_contains "missing_initramfs_command="
  assert_output_contains "require_tool find"
  assert_output_contains "require_tool unmkinitramfs"
  assert_output_contains "unmkinitramfs \"\$source_initramfs\" \"\$tmp_dir\""
  assert_output_contains "initramfs_root=\"\$tmp_dir/main\""
  assert_output_contains "unsupported_initramfs_extra_content="
  assert_output_contains "cd \"\$initramfs_root\""
  assert_output_contains "KERNEL_VERSION_B64=\$(b64_value"
  assert_output_contains "missing_initramfs_module=8021q"
  assert_output_contains "llc.ko"
  assert_output_contains "stp.ko"
  assert_output_contains "garp.ko"
  assert_output_contains "kernel/net/8021q/8021q.ko"
  assert_output_contains "runtime_commands=\"\$runtime_commands insmod\""
  assert_output_contains "runtime_commands=\"\$runtime_commands zstdcat\""
  assert_output_contains '/scripts/local-top/home-ops-reimage "$@"'
  assert_output_contains "for command_name in \$runtime_commands"
  assert_output_not_contains "install_busybox_commands"
  assert_output_not_contains "missing_busybox_applet="
  assert_output_not_contains "vconfig"
  assert_output_not_contains "beacon "
  assert_output_not_contains "require_tool jq"
  assert_output_not_contains "| jq "
}

@test "node reimage target-built payload script supports main-root initramfs extraction" {
  local manifest script stage source_initramfs source_cmdline
  manifest="${tmp}/manifest.json"
  script="${tmp}/payload.sh"
  stage="${tmp}/stage"
  source_initramfs="${tmp}/source-initramfs"
  printf 'fake initramfs\n' > "$source_initramfs"
  source_cmdline="${tmp}/cmdline.txt"
  printf 'root=/dev/nvme0n1p2 rw home_ops_reimage=1\n' > "$source_cmdline"
  cat > "$manifest" <<'EOF'
{
  "schemaVersion": "home-ops.node-reimage-stage/v1",
  "imageUrl": "https://images.example/k3s-worker-0.img.xz",
  "imageSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "targetDisk": "/dev/nvme0n1",
  "targetDiskSerial": "nvme-deadbeef",
  "raspberryPiSerial": "10000000deadbeef"
}
EOF

  cat > "${tmp}/unmkinitramfs" <<'EOF'
#!/usr/bin/env bash
dest="$2"
mkdir -p "${dest}/main/bin" "${dest}/main/scripts/local-top" "${dest}/early"
for cmd in awk base64 basename busybox cat grep gunzip ip reboot rm sed sh sleep sync tr udevadm wget xzcat; do
  printf '#!/bin/sh\nexit 0\n' > "${dest}/main/bin/${cmd}"
  chmod +x "${dest}/main/bin/${cmd}"
done
if [[ "${FAKE_UNMKINITRAMFS_EXTRA:-}" == true ]]; then
  printf 'early data\n' > "${dest}/early/boot-critical"
fi
EOF
  cat > "${tmp}/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-o -4 route show default")
    printf 'default via 192.0.2.1 dev eth0\n'
    ;;
  "-o -4 addr show dev eth0 scope global")
    printf '2: eth0 inet 192.0.2.20/24 brd 192.0.2.255 scope global eth0\n'
    ;;
esac
EOF
  cat > "${tmp}/nmcli" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "${tmp}/cpio" <<'EOF'
#!/usr/bin/env bash
cat
EOF
  cat > "${tmp}/zstd" <<'EOF'
#!/usr/bin/env bash
cat
EOF
  cat > "${tmp}/uname" <<'EOF'
#!/usr/bin/env bash
printf '6.18.0-test\n'
EOF
  cat > "${tmp}/xzcat" <<'EOF'
#!/usr/bin/env bash
cat
EOF
  cat > "${tmp}/zstdcat" <<'EOF'
#!/usr/bin/env bash
cat
EOF
  cat > "${tmp}/sync" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${tmp}/unmkinitramfs" "${tmp}/ip" "${tmp}/nmcli" "${tmp}/cpio" "${tmp}/zstd" "${tmp}/uname" "${tmp}/xzcat" "${tmp}/zstdcat" "${tmp}/sync"

  bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; manifest=\$(cat '${manifest}'); node_reimage_build_remote_payload_script '${stage}' \"\${manifest}\" '#!/bin/sh
true'" > "$script"

  run env PATH="${tmp}:${PATH}" HOME_OPS_REIMAGE_SOURCE_INITRAMFS="$source_initramfs" HOME_OPS_REIMAGE_SOURCE_CMDLINE="$source_cmdline" sh "$script"
  assert_success
  assert_output_contains "remote_payload=built"
  assert_output_contains "source_initramfs=${source_initramfs}"
  [[ -f "${stage}/initramfs.img" ]]
  run cat "${stage}/cmdline.txt"
  assert_success
  [[ "$output" == "root=/dev/nvme0n1p2 rw home_ops_reimage=1" ]]

  rm -rf "$stage"
  run env PATH="${tmp}:${PATH}" HOME_OPS_REIMAGE_SOURCE_INITRAMFS="$source_initramfs" HOME_OPS_REIMAGE_SOURCE_CMDLINE="$source_cmdline" FAKE_UNMKINITRAMFS_EXTRA=true sh "$script"
  assert_failure
  assert_output_contains "unsupported_initramfs_extra_content=early"
}

@test "node reimage runtime script loads VLAN kernel module dependencies" {
  run bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_reimage_runtime_script"
  assert_success
  assert_output_contains 'kernel/net/llc/llc.ko'
  assert_output_contains 'kernel/net/802/stp.ko'
  assert_output_contains 'kernel/net/802/garp.ko'
  assert_output_contains 'kernel/net/8021q/8021q.ko'
  assert_output_contains "busybox sha256sum"
  assert_output_not_contains ". /scripts/functions"
  assert_output_contains "zstdcat \"\$download_path\""
  assert_output_not_contains "vconfig add"
  assert_output_not_contains 'beacon '
}

@test "node reimage reboot requires deleted node unless forced and schedules tryboot" {
  write_reimage_kubectl
  write_fake_ansible
  add_reimage_identity k3s-worker-0 10000000deadbeef nvme-deadbeef
  assert_file_contains "${ROOT}/hack/bootstrap/nodes/reimage-reboot.sh" '--reboot-argument="0 tryboot"'

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_reimage_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/reimage-reboot.sh" --profile live --context test --yes k3s-worker-0
  assert_failure
  assert_output_contains 'Kubernetes node still exists'

  mkdir -p "${tmp}/reimage-reboot-state"
  run env PATH="${tmp}:${PATH}" FAKE_REBOOT_STATE_DIR="${tmp}/reimage-reboot-state" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_reimage_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/reimage-reboot.sh" --profile live --context test --force --yes k3s-worker-0
  assert_success
  assert_output_contains 'force enabled; skipping Kubernetes node-absent check'
  assert_output_contains 'tryboot reboot scheduled: k3s-worker-0'
  [[ -f "${tmp}/reimage-reboot-state/tryboot-rebooted-k3s-worker-0" ]]
}

@test "node reimage reboot rejects stale staged manifest identity" {
  write_reimage_kubectl
  write_fake_ansible
  add_reimage_identity k3s-worker-0 10000000deadbeef nvme-deadbeef

  run env PATH="${tmp}:${PATH}" FAKE_REIMAGE_STAGED_DISK_SERIAL=stale-disk NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_reimage_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/reimage-reboot.sh" --profile live --context test --force --yes k3s-worker-0
  assert_failure
  assert_output_contains 'staged reimage manifest targetDiskSerial mismatch'
}

@test "node reimage apply uses recorded serve state and refreshes host key" {
  local node_dir artifact metadata sha calls fake_stage fake_reboot fake_refresh fake_nc fake_ssh
  write_fake_ansible
  node_dir="${tmp}/reimage-out/live/k3s-worker-0"
  mkdir -p "${node_dir}/state"
  artifact="${node_dir}/home-ops-k3s-worker-0.img.xz"
  metadata="${artifact}.metadata.json"
  sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  printf 'fake image\n' > "$artifact"
  cat > "$metadata" <<EOF
{
  "schemaVersion": "home-ops.node-image/v1",
  "node": "k3s-worker-0",
  "hostname": "k3s-worker-0",
  "ansibleHost": "192.168.99.20",
  "imageUrl": "http://192.168.99.10:18080/home-ops-k3s-worker-0.img.xz",
  "sha256": "${sha}",
  "arch": "arm64"
}
EOF
  jq -n \
    --arg imageUrl "http://192.168.99.10:18080/home-ops-k3s-worker-0.img.xz" \
    --arg metadata "$metadata" \
    --arg sha "$sha" \
    '{schemaVersion:"home-ops.node-reimage-serve/v1", imageUrl:$imageUrl, metadataPath:$metadata, sha256:$sha}' \
    > "${node_dir}/state/serve.json"
  calls="${tmp}/apply-calls"
  fake_stage="${tmp}/stage"
  fake_reboot="${tmp}/reboot"
  fake_refresh="${tmp}/refresh"
  fake_nc="${tmp}/nc"
  fake_ssh="${tmp}/ssh"
  cat > "$fake_stage" <<'EOF'
#!/usr/bin/env bash
printf 'stage %s\n' "$*" >>"${CALLS_FILE:?}"
EOF
  cat > "$fake_reboot" <<'EOF'
#!/usr/bin/env bash
printf 'reboot %s\n' "$*" >>"${CALLS_FILE:?}"
EOF
  cat > "$fake_refresh" <<'EOF'
#!/usr/bin/env bash
printf 'refresh %s\n' "$*" >>"${CALLS_FILE:?}"
EOF
  cat > "$fake_nc" <<'EOF'
#!/usr/bin/env bash
count_file="${NC_COUNT_FILE:?}"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if ((count == 1)); then
  exit 1
fi
exit 0
EOF
  cat > "$fake_ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >>"${CALLS_FILE:?}"
EOF
  chmod +x "$fake_stage" "$fake_reboot" "$fake_refresh" "$fake_nc" "$fake_ssh"

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_REIMAGE_OUTPUT_ROOT="${tmp}/reimage-out" \
    NODE_REIMAGE_STAGE_BIN="$fake_stage" NODE_REIMAGE_REBOOT_BIN="$fake_reboot" NODE_REFRESH_SSH_HOST_KEY_BIN="$fake_refresh" \
    NODE_REIMAGE_SSH_DOWN_TIMEOUT_SECONDS=5 NODE_REIMAGE_SSH_UP_TIMEOUT_SECONDS=5 CALLS_FILE="$calls" NC_COUNT_FILE="${tmp}/nc-count" \
    "${ROOT}/hack/bootstrap/nodes/reimage-apply.sh" --profile live --context test --force --yes k3s-worker-0
  assert_success
  assert_output_contains 'apply_state='
  assert_output_contains 'verifying generated image boot marker'
  assert_output_contains 'next=just node-join k3s-worker-0 && just node-uncordon k3s-worker-0'
  assert_file_contains "$calls" 'stage --profile live --context test --metadata-file'
  assert_file_contains "$calls" 'reboot --profile live --context test --yes --force k3s-worker-0'
  assert_file_contains "$calls" 'refresh --profile live --yes k3s-worker-0'
  assert_file_contains "$calls" 'ssh -o BatchMode=yes'
  [[ -f "${node_dir}/state/apply.json" ]]
}

@test "node reimage generated-image verification waits for firstboot marker" {
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" \
    FAKE_REIMAGE_FIRSTBOOT_COMPLETE=false NODE_REIMAGE_FIRSTBOOT_TIMEOUT_SECONDS=0 \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_reimage_verify_generated_image_booted live k3s-worker-0"
  assert_failure
  assert_output_contains 'timed out waiting for generated image firstboot marker'
  assert_output_contains 'missing_firstboot_marker=/var/lib/home-ops/firstboot-complete'

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_reimage_verify_generated_image_booted live k3s-worker-0"
  assert_success
}

@test "node reimage cleanup removes recorded serve state" {
  local node_dir
  write_fake_ansible
  node_dir="${tmp}/reimage-out/live/k3s-worker-0"
  mkdir -p "${node_dir}/state"
  jq -n \
    '{schemaVersion:"home-ops.node-reimage-serve/v1", hostNode:"k3s-master-0", remoteDir:"/tmp/home-ops-reimage/k3s-worker-0"}' \
    > "${node_dir}/state/serve.json"

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_REIMAGE_OUTPUT_ROOT="${tmp}/reimage-out" \
    "${ROOT}/hack/bootstrap/nodes/reimage-cleanup.sh" --profile live --yes k3s-worker-0
  assert_success
  assert_output_contains 'cleanup_state='
  [[ -f "${node_dir}/state/cleanup.json" ]]
  [[ -f "${node_dir}/state/serve.cleaned.json" ]]
  [[ ! -f "${node_dir}/state/serve.json" ]]
}

@test "node reimage cleanup refuses unsafe state remote dir" {
  local node_dir
  write_fake_ansible
  node_dir="${tmp}/reimage-out/live/k3s-worker-0"
  mkdir -p "${node_dir}/state"
  jq -n \
    '{schemaVersion:"home-ops.node-reimage-serve/v1", hostNode:"k3s-master-0", remoteDir:"/tmp/home-ops-reimage/k3s-master-0"}' \
    > "${node_dir}/state/serve.json"

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_REIMAGE_OUTPUT_ROOT="${tmp}/reimage-out" \
    "${ROOT}/hack/bootstrap/nodes/reimage-cleanup.sh" --profile live --yes k3s-worker-0
  assert_failure
  assert_output_contains 'unsafe reimage remote dir in state'
}

@test "worker status command reports inventory, Kubernetes, Cilium, and Longhorn absence" {
  write_worker_status_kubectl

  run env NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/status.sh" --profile live --context test k3s-worker-0
  assert_success
  assert_output_contains 'inventory_role: node'
  assert_output_contains 'kubernetes_role: node'
  assert_output_contains 'ready: Ready'
  assert_output_contains 'schedulable: cordoned'
  assert_output_contains 'joining_taint: present'
  assert_output_contains 'default/workload phase=Running owner=ReplicaSet'
  assert_output_contains 'cilium-one phase=Running ready=1/1'
  assert_output_contains 'installed: false'
}

@test "control-plane status, preflight, and alternate join IP use healthy peer state" {
  write_control_plane_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/control-plane-status.sh" --profile live --context test k3s-master-0
  assert_success
  assert_output_contains 'inventory_control_planes: k3s-master-0,k3s-master-1,k3s-master-2'
  assert_output_contains 'inventory_control_plane_count: 3'
  assert_output_contains 'ready_control_plane_count: 3'
  assert_output_contains 'etcd_quorum_size_from_inventory: 2'
  assert_output_contains 'embedded_etcd_data=present'

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/control-plane-delete-preflight.sh" --profile live --context test k3s-master-0
  assert_success
  assert_output_contains 'probe_inventory_node: k3s-master-1'
  assert_output_contains 'etcd_member_count: 3'
  assert_output_contains 'post_remove_member_count: 2'
  assert_output_contains 'preflight_result: pass'
  assert_output_contains '  id: c9e409fd1205cc0a'
  assert_output_contains 'member remove c9e409fd1205cc0a'

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/control-plane-delete-preflight.sh" --profile live --context test --output json k3s-master-0
  assert_success
  printf '%s\n' "$output" > "${tmp}/control-plane-delete-preflight.json"

  run jq -r '.probe_inventory_node' "${tmp}/control-plane-delete-preflight.json"
  assert_success
  [[ "$output" == "k3s-master-1" ]]

  run jq -r '.target_etcd_member.id' "${tmp}/control-plane-delete-preflight.json"
  assert_success
  [[ "$output" == "c9e409fd1205cc0a" ]]

  run jq -r '.remaining_ready_control_planes_after_target_stop' "${tmp}/control-plane-delete-preflight.json"
  assert_success
  [[ "$output" == "2" ]]

  run jq -r '.planned_member_remove.command' "${tmp}/control-plane-delete-preflight.json"
  assert_success
  assert_output_contains 'member remove c9e409fd1205cc0a'

  run jq -r '.human_output' "${tmp}/control-plane-delete-preflight.json"
  assert_success
  assert_output_contains 'probe_inventory_node: k3s-master-1'
  assert_output_contains 'member remove c9e409fd1205cc0a'

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_alternate_ready_control_plane_internal_ip live test k3s-master-0"
  assert_success
  [[ "$output" == "192.168.99.11" ]]
}

@test "control-plane Ansible wrapper passes temporary join IP only for join action" {
  local fake_bootstrap
  fake_bootstrap="${tmp}/fake-bootstrap"
  mkdir -p "${fake_bootstrap}/ansible"
  cat > "${fake_bootstrap}/ansible/node-control-plane.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${FAKE_NODE_CONTROL_PLANE_ARGS:?}"
test "${NODE_CONTROL_PLANE_ANSIBLE_INTERNAL:-}" = true
EOF
  chmod +x "${fake_bootstrap}/ansible/node-control-plane.sh"

  run env FAKE_NODE_CONTROL_PLANE_ARGS="${tmp}/node-control-plane.args" NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; BOOTSTRAP_DIR='${fake_bootstrap}'; node_run_control_plane_ansible_action live k3s-master-0 join 192.168.99.11"
  assert_success
  assert_file_contains "${tmp}/node-control-plane.args" '--join-ip 192.168.99.11'

  run env FAKE_NODE_CONTROL_PLANE_ARGS="${tmp}/node-control-plane-finalize.args" NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; BOOTSTRAP_DIR='${fake_bootstrap}'; node_run_control_plane_ansible_action live k3s-master-0 finalize"
  assert_success
  assert_file_not_contains "${tmp}/node-control-plane-finalize.args" '--join-ip'
}

@test "Lima control-plane API handoff retargets away from any target control-plane" {
  local calls_file
  calls_file="${tmp}/handoff.calls"

  run env CALLS_FILE="$calls_file" bash -c "
    source '${ROOT}/hack/bootstrap/nodes/lib.sh'
    node_alternate_ready_control_plane_inventory_node() { printf '%s\n' k3s-master-0; }
    node_start_lima_api_tunnel_to_inventory_node() { printf 'tunnel=%s context=%s\n' \"\$1\" \"\$2\" >>\"\${CALLS_FILE}\"; }
    node_assert_api_reachable() { :; }
    node_node_json_if_present() { printf '{\"metadata\":{\"name\":\"%s\",\"labels\":{\"node-role.kubernetes.io/control-plane\":\"true\"}},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}' \"\$2\"; }
    node_assert_kubernetes_control_plane() { :; }
    node_assert_ready() { :; }
    node_handoff_control_plane_api_if_needed lima test k3s-master-1 lima-k3s-master-1
  "
  assert_success
  assert_output_contains 'retargeting Lima API tunnel away from k3s-master-1 to k3s-master-0'
  assert_file_contains "$calls_file" 'tunnel=k3s-master-0 context=test'
}

@test "Lima API tunnels disable SSH multiplexing" {
  assert_file_contains "$ROOT/hack/bootstrap/lima/lib.sh" '-S none'
  assert_file_contains "$ROOT/hack/bootstrap/lima/lib.sh" '-fN'
  assert_file_contains "$ROOT/hack/bootstrap/lima/lib.sh" '-o ControlMaster=no'
  assert_file_contains "$ROOT/hack/bootstrap/lima/lib.sh" '-o ExitOnForwardFailure=yes'
  assert_file_contains "$ROOT/hack/bootstrap/nodes/lib/lima.sh" '-S none'
  assert_file_contains "$ROOT/hack/bootstrap/nodes/lib/lima.sh" '-fN'
  assert_file_contains "$ROOT/hack/bootstrap/nodes/lib/lima.sh" '-o ControlMaster=no'
  assert_file_contains "$ROOT/hack/bootstrap/nodes/lib/lima.sh" '-o ExitOnForwardFailure=yes'
}

@test "Lima API tunnel pidfile must match listener PID" {
  run env LIMA_OUT_DIR="${tmp}/lima-out" LIMA_KUBECONFIG_PORT=16443 bash -c "
    source '${ROOT}/hack/bootstrap/lima/lib.sh'
    mkdir -p \"\${LIMA_OUT_DIR}\"
    printf '%s\n' \"\$\$\" >\"\$(lima_tunnel_pid_file)\"
    lima_tunnel_listener_pid() { printf '%s\n' \"\$\$\"; }
    lima_tunnel_pid_matches_listener
  "
  assert_success

  run env LIMA_OUT_DIR="${tmp}/lima-out" LIMA_KUBECONFIG_PORT=16443 bash -c "
    source '${ROOT}/hack/bootstrap/lima/lib.sh'
    mkdir -p \"\${LIMA_OUT_DIR}\"
    printf '%s\n' \"\$\$\" >\"\$(lima_tunnel_pid_file)\"
    lima_tunnel_listener_pid() { printf '%s\n' 999999; }
    lima_tunnel_pid_matches_listener
  "
  assert_failure
}

@test "verified existing Lima API tunnel refreshes stale pidfile" {
  run env LIMA_OUT_DIR="${tmp}/lima-out" LIMA_KUBECONFIG_PORT=16443 bash -c "
    source '${ROOT}/hack/bootstrap/lima/lib.sh'
    mkdir -p \"\${LIMA_OUT_DIR}\"
    printf '%s\n' 111 >\"\$(lima_tunnel_pid_file)\"
    lima_require_tool() { :; }
    lima_tunnel_pid_matches_listener() { return 1; }
    lima_tunnel_port_open() { return 0; }
    lima_existing_apiserver_tunnel_valid() { return 0; }
    lima_tunnel_listener_pid() { printf '%s\n' 4242; }
    lima_start_apiserver_tunnel
    printf 'pidfile=%s\n' \"\$(cat \"\$(lima_tunnel_pid_file)\")\"
  "
  assert_success
  assert_output_contains 'using verified existing API tunnel on 127.0.0.1:16443'
  assert_output_contains '4242'
  assert_output_contains 'pidfile=4242'
}

@test "control-plane join validates kube-proxy disable drop-in when replacement is enabled" {
  local rendered_out rendered_inventory
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" BOOTSTRAP_ANSIBLE_OUT_DIR="${tmp}/no-render" NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_kube_proxy_disable_dropin live k3s-master-0"
  assert_success
  assert_output_contains 'validating K3s kube-proxy disable drop-in on k3s-master-0'

  rendered_out="${tmp}/rendered"
  rendered_inventory="${rendered_out}/inventory/live"
  mkdir -p "${rendered_inventory}/group_vars"
  cp "${inventory}/hosts.yml" "${rendered_inventory}/hosts.yml"
  yq -i 'del(.kube_proxy_replacement)' "${inventory}/group_vars/all.yml"
  cat > "${rendered_inventory}/group_vars/all.yml" <<'EOF'
---
ansible_user: ethan
ansible_ssh_private_key_file: ~/ansiblekey
kube_proxy_replacement: true
EOF
  run env PATH="${tmp}:${PATH}" BOOTSTRAP_ANSIBLE_OUT_DIR="$rendered_out" NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_kube_proxy_disable_dropin live k3s-master-0"
  assert_success
  assert_output_contains 'validating K3s kube-proxy disable drop-in on k3s-master-0'

  yq -i '.kube_proxy_replacement = true' "${inventory}/group_vars/all.yml"
  run env PATH="${tmp}:${PATH}" BOOTSTRAP_ANSIBLE_OUT_DIR="${tmp}/no-render" FAKE_KUBE_PROXY_DROPIN=missing NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_kube_proxy_disable_dropin live k3s-master-0"
  assert_failure
  assert_output_contains 'K3s kube-proxy disable drop-in is missing or invalid on k3s-master-0'

  yq -i '.kube_proxy_replacement = false' "${inventory}/group_vars/all.yml"
  run env PATH="${tmp}:${PATH}" BOOTSTRAP_ANSIBLE_OUT_DIR="${tmp}/no-render" NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_kube_proxy_disable_dropin live k3s-master-0"
  assert_success
  assert_output_contains 'kube_proxy_replacement is false; skipping K3s kube-proxy disable drop-in check'

  yq -i 'del(.kube_proxy_replacement)' "${inventory}/group_vars/all.yml"
  run env PATH="${tmp}:${PATH}" BOOTSTRAP_ANSIBLE_OUT_DIR="${tmp}/no-render" NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_kube_proxy_disable_dropin live k3s-master-0"
  assert_failure
  assert_output_contains 'kube_proxy_replacement is missing'
}

@test "control-plane drain and delete enforce stable API and cleanup semantics" {
  write_control_plane_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/drain.sh" --profile live --context test --yes k3s-master-0
  assert_success
  assert_output_contains 'preflight_result: pass'
  assert_output_contains 'drain complete: k3s-master-0'

  run env PATH="${tmp}:${PATH}" FAKE_CLUSTER_SERVER=https://192.168.99.10:6443 NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/delete.sh" --profile live --context test --yes k3s-master-0
  assert_failure
  assert_output_contains 'live first-master lifecycle requires a stable API endpoint'

  mkdir -p "${tmp}/first-control-plane-state"
  run env PATH="${tmp}:${PATH}" FAKE_KUBECTL_STATE_DIR="${tmp}/first-control-plane-state" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/delete.sh" --profile live --context test --yes k3s-master-0
  assert_success
  assert_output_contains 'first inventory master selected; live context must remain reachable through the stable API endpoint'
  assert_output_contains 'snapshot_name=pre-remove-k3s-master-0-'
  assert_output_contains 'Member c9e409fd1205cc0a removed from cluster'
  assert_output_contains 'node "k3s-master-0" deleted'
  assert_output_contains 'control-plane delete complete: k3s-master-0'

  mkdir -p "${tmp}/control-plane-state"
  run env PATH="${tmp}:${PATH}" FAKE_KUBECTL_STATE_DIR="${tmp}/control-plane-state" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/delete.sh" --profile live --context test --yes k3s-master-1
  assert_success
  assert_output_contains 'snapshot_name=pre-remove-k3s-master-1-'
  assert_output_contains 'Member 70594c7c481c118 removed from cluster'
  assert_output_contains 'node "k3s-master-1" deleted'
  assert_output_contains 'control-plane delete complete: k3s-master-1'

  run env PATH="${tmp}:${PATH}" FAKE_KUBECTL_STATE_DIR="${tmp}/control-plane-state" FAKE_ETCD_ABSENT_MEMBER_ID=70594c7c481c118 NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/delete.sh" --profile live --context test --yes k3s-master-1
  assert_success
  assert_output_contains 'stopping k3s server on k3s-master-1 before deleted-node cleanup'
  assert_output_contains 'verifying k3s-master-1 is absent from etcd membership using k3s-master-0'
  assert_output_contains 'control-plane delete cleanup complete: k3s-master-1'

  mkdir -p "${tmp}/blocked-control-plane-cleanup-state"
  touch "${tmp}/blocked-control-plane-cleanup-state/deleted-k3s-master-1"
  run env PATH="${tmp}:${PATH}" FAKE_KUBECTL_STATE_DIR="${tmp}/blocked-control-plane-cleanup-state" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/delete.sh" --profile live --context test --yes k3s-master-1
  assert_failure
  assert_output_contains 'refusing deleted-node cleanup because etcd still has 1 member(s) for k3s-master-1'
}

@test "control-plane join/uncordon and etcd membership checks fail closed" {
  write_control_plane_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/control-plane-join.sh" --profile live --context test --yes k3s-master-0
  assert_failure
  assert_output_contains 'Kubernetes node already exists'

  mkdir -p "${tmp}/first-control-plane-state"
  touch "${tmp}/first-control-plane-state/deleted-k3s-master-0"
  run env PATH="${tmp}:${PATH}" FAKE_KUBECTL_STATE_DIR="${tmp}/first-control-plane-state" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/control-plane-uncordon.sh" --profile live --context test --yes k3s-master-0
  assert_failure
  assert_output_contains 'Kubernetes node is absent'

  run env PATH="${tmp}:${PATH}" FAKE_ETCD_ABSENT_MEMBER_ID=70594c7c481c118 NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_control_plane_etcd_member_absent live test k3s-master-1 k3s-master-1"
  assert_success
  assert_output_contains 'verifying k3s-master-1 is absent from etcd membership using k3s-master-0'

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_control_plane_etcd_member_absent live test k3s-master-1 k3s-master-1"
  assert_failure
  assert_output_contains 'etcd still has 1 member(s) for k3s-master-1'
}

@test "worker reboot requires drained state and waits for a new boot ID" {
  write_reboot_kubectl
  write_fake_ansible

  mkdir -p "${tmp}/reboot-state"
  run env PATH="${tmp}:${PATH}" FAKE_REBOOT_STATE_DIR="${tmp}/reboot-state" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_reboot_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/reboot.sh" --profile live --context test --yes k3s-worker-0
  assert_success
  assert_output_contains 'scheduling reboot on k3s-worker-0'
  assert_output_contains 'waiting for k3s-worker-0 to report a new boot ID'
  assert_output_contains 'reboot complete: k3s-worker-0; node remains cordoned'
  [[ -f "${tmp}/reboot-state/rebooted-k3s-worker-0" ]]
}

@test "node converge plans no-op inventory and emits JSON shape" {
  local nodes_json
  nodes_json="${tmp}/nodes.json"
  write_default_converge_nodes_json "$nodes_json"
  write_converge_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_converge_kubectl" FAKE_CONVERGE_NODES_JSON="$nodes_json" \
    "${ROOT}/hack/bootstrap/nodes/converge.sh" --profile live --context test --plan --output json
  assert_success
  printf '%s\n' "$output" > "${tmp}/converge-plan.json"

  run jq -r '.profile' "${tmp}/converge-plan.json"
  assert_success
  [[ "$output" == "live" ]]

  run jq -r '.join_order | length' "${tmp}/converge-plan.json"
  assert_success
  [[ "$output" == "0" ]]

  run jq -r '.blockers | length' "${tmp}/converge-plan.json"
  assert_success
  [[ "$output" == "0" ]]
}

@test "node converge joins missing workers sequentially through existing join script" {
  local nodes_json calls_file
  nodes_json="${tmp}/nodes.json"
  calls_file="${tmp}/join.calls"
  add_inventory_worker k3s-worker-1 192.168.99.21
  add_inventory_worker k3s-worker-2 192.168.99.22
  write_default_converge_nodes_json "$nodes_json"
  write_converge_kubectl
  write_fake_ansible
  write_fake_join_script

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_converge_kubectl" NODE_JOIN_SCRIPT="$fake_join_script" FAKE_CONVERGE_NODES_JSON="$nodes_json" FAKE_JOIN_CALLS="$calls_file" \
    "${ROOT}/hack/bootstrap/nodes/converge.sh" --profile live --context test --yes
  assert_success
  assert_output_contains 'join_order:'
  assert_output_contains 'k3s-worker-1'
  assert_output_contains 'k3s-worker-2'
  assert_output_contains 'just node-uncordon k3s-worker-1'
  assert_file_contains "$calls_file" '--profile live --context test --yes k3s-worker-1'
  assert_file_contains "$calls_file" '--profile live --context test --yes k3s-worker-2'
}

@test "node converge plans one control-plane repair from even to odd count" {
  local nodes_json
  nodes_json="${tmp}/nodes.json"
  add_inventory_master k3s-master-3 192.168.99.13
  add_inventory_master k3s-master-4 192.168.99.14
  write_converge_nodes_json "$nodes_json" \
    "k3s-master-0:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-1:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-2:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-3:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-worker-0:node:True:schedulable:absent:v1.35.4+k3s1"
  write_converge_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_converge_kubectl" FAKE_CONVERGE_NODES_JSON="$nodes_json" \
    "${ROOT}/hack/bootstrap/nodes/converge.sh" --profile live --context test --plan --output json
  assert_success
  printf '%s\n' "$output" > "${tmp}/converge-cp-plan.json"

  run jq -r '.join_order | join(",")' "${tmp}/converge-cp-plan.json"
  assert_success
  [[ "$output" == "k3s-master-4" ]]
}

@test "node converge refuses unsafe control-plane additions" {
  local nodes_json
  nodes_json="${tmp}/nodes.json"
  add_inventory_master k3s-master-3 192.168.99.13
  add_inventory_master k3s-master-4 192.168.99.14
  write_default_converge_nodes_json "$nodes_json"
  write_converge_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_converge_kubectl" FAKE_CONVERGE_NODES_JSON="$nodes_json" \
    "${ROOT}/hack/bootstrap/nodes/converge.sh" --profile live --context test --plan
  assert_failure
  assert_output_contains 'control-plane converge supports exactly one missing control-plane'

  create_node_inventory
  add_inventory_master k3s-master-3 192.168.99.13
  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_converge_kubectl" FAKE_CONVERGE_NODES_JSON="$nodes_json" \
    "${ROOT}/hack/bootstrap/nodes/converge.sh" --profile live --context test --plan
  assert_failure
  assert_output_contains 'desired control-plane count must be odd'
}

@test "node converge refuses unsafe control-plane counts even for worker-only plans" {
  local nodes_json
  nodes_json="${tmp}/nodes.json"
  add_inventory_worker k3s-worker-1 192.168.99.21
  write_converge_nodes_json "$nodes_json" \
    "k3s-master-0:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-1:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-worker-0:node:True:schedulable:absent:v1.35.4+k3s1"
  write_converge_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_converge_kubectl" FAKE_CONVERGE_NODES_JSON="$nodes_json" \
    "${ROOT}/hack/bootstrap/nodes/converge.sh" --profile live --context test --plan
  assert_failure
  assert_output_contains 'current Kubernetes control-plane count must be odd; current=2'

  add_inventory_master k3s-master-3 192.168.99.13
  write_default_converge_nodes_json "$nodes_json"
  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_converge_kubectl" FAKE_CONVERGE_NODES_JSON="$nodes_json" \
    "${ROOT}/hack/bootstrap/nodes/converge.sh" --profile live --context test --plan
  assert_failure
  assert_output_contains 'desired control-plane count must be odd; desired=4'
}

@test "node converge refuses duplicate inventory roles" {
  local nodes_json
  nodes_json="${tmp}/nodes.json"
  add_inventory_worker k3s-master-1 192.168.99.11
  write_default_converge_nodes_json "$nodes_json"
  write_converge_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_converge_kubectl" FAKE_CONVERGE_NODES_JSON="$nodes_json" \
    "${ROOT}/hack/bootstrap/nodes/converge.sh" --profile live --context test --plan
  assert_failure
  assert_output_contains 'node appears in both master and node inventory groups: k3s-master-1'
  assert_output_contains 'duplicate expected Kubernetes node name in inventory: k3s-master-1'
}

@test "node converge strict preflight blocks drift and pending finalization" {
  local nodes_json
  nodes_json="${tmp}/nodes.json"
  write_converge_kubectl
  write_fake_ansible

  write_converge_nodes_json "$nodes_json" \
    "k3s-master-0:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-1:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-2:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-worker-0:master:True:schedulable:absent:v1.35.4+k3s1"
  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_converge_kubectl" FAKE_CONVERGE_NODES_JSON="$nodes_json" \
    "${ROOT}/hack/bootstrap/nodes/converge.sh" --profile live --context test --plan
  assert_failure
  assert_output_contains 'role drift for k3s-worker-0'

  write_converge_nodes_json "$nodes_json" \
    "k3s-master-0:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-1:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-2:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-worker-0:node:False:schedulable:absent:v1.35.4+k3s1"
  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_converge_kubectl" FAKE_CONVERGE_NODES_JSON="$nodes_json" \
    "${ROOT}/hack/bootstrap/nodes/converge.sh" --profile live --context test --plan
  assert_failure
  assert_output_contains 'Kubernetes node is not Ready: k3s-worker-0'

  write_converge_nodes_json "$nodes_json" \
    "k3s-master-0:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-1:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-2:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-worker-0:node:True:cordoned:present:v1.35.4+k3s1"
  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_converge_kubectl" FAKE_CONVERGE_NODES_JSON="$nodes_json" \
    "${ROOT}/hack/bootstrap/nodes/converge.sh" --profile live --context test --plan
  assert_failure
  assert_output_contains 'Kubernetes node is cordoned or pending finalization: k3s-worker-0'
  assert_output_contains 'Kubernetes node still has temporary joining taint: k3s-worker-0'

  write_converge_nodes_json "$nodes_json" \
    "k3s-master-0:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-1:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-2:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-worker-0:node:True:schedulable:absent:v1.35.3+k3s1"
  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_converge_kubectl" FAKE_CONVERGE_NODES_JSON="$nodes_json" \
    "${ROOT}/hack/bootstrap/nodes/converge.sh" --profile live --context test --plan
  assert_failure
  assert_output_contains 'K3s version drift for k3s-worker-0'

  write_default_converge_nodes_json "$nodes_json"
  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_converge_kubectl" FAKE_CONVERGE_NODES_JSON="$nodes_json" FAKE_LONGHORN_INSTALLED=true FAKE_LONGHORN_DISABLED_NODE=k3s-worker-0 \
    "${ROOT}/hack/bootstrap/nodes/converge.sh" --profile live --context test --plan
  assert_failure
  assert_output_contains 'Longhorn scheduling is disabled for existing node: k3s-worker-0'
}

@test "node converge blocks unknown Kubernetes nodes and active context mismatch" {
  local nodes_json
  nodes_json="${tmp}/nodes.json"
  write_converge_nodes_json "$nodes_json" \
    "k3s-master-0:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-1:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-2:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-worker-0:node:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-stray-0:node:True:schedulable:absent:v1.35.4+k3s1"
  write_converge_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_converge_kubectl" FAKE_CONVERGE_NODES_JSON="$nodes_json" \
    "${ROOT}/hack/bootstrap/nodes/converge.sh" --profile live --context test --plan
  assert_failure
  assert_output_contains 'Kubernetes node is not present in inventory: k3s-stray-0'

  write_default_converge_nodes_json "$nodes_json"
  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_converge_kubectl" FAKE_CONVERGE_NODES_JSON="$nodes_json" FAKE_CURRENT_CONTEXT=other \
    "${ROOT}/hack/bootstrap/nodes/converge.sh" --profile live --context test --yes
  assert_failure
  assert_output_contains 'active kube context must be test'
}

@test "Longhorn deleted-node cleanup deletes only safe stale state and reports blockers" {
  write_deleted_node_longhorn_kubectl
  mkdir -p "${tmp}/longhorn-state"

  run env FAKE_KUBECTL_STATE_DIR="${tmp}/longhorn-state" NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_longhorn_replica_delete_blockers test deleted-node"
  assert_success
  [[ -z "$output" ]]

  run env FAKE_KUBECTL_STATE_DIR="${tmp}/longhorn-state" NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_longhorn_safe_stale_replicas_for_deleted_node test deleted-node"
  assert_success
  [[ "$output" == "stale-replica" ]]

  run env FAKE_KUBECTL_STATE_DIR="${tmp}/longhorn-state" NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_cleanup_longhorn_deleted_node test deleted-node 1"
  assert_success
  assert_output_contains 'deleting safe stale Longhorn replica stale-replica'
  assert_output_contains 'replica.longhorn.io "stale-replica" deleted'
  assert_output_contains 'node.longhorn.io "deleted-node" deleted'

  run env FAKE_KUBECTL_STATE_DIR="${tmp}/longhorn-state" FAKE_LONGHORN_MODE=blockers NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_longhorn_empty_for_delete test deleted-node"
  assert_failure
  assert_output_contains 'reason=volume-still-targets-node'
  assert_output_contains 'reason=engine-still-targets-node'
  assert_output_matches 'volume-b-e-0.*owner=deleted-node.*reason=engine-still-targets-node'

  run env FAKE_KUBECTL_STATE_DIR="${tmp}/longhorn-state" NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_longhorn_scheduling_problem test missing-node"
  assert_success
  [[ -z "$output" ]]

  run env FAKE_KUBECTL_STATE_DIR="${tmp}/longhorn-state" NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_longhorn_empty_for_delete test missing-node"
  assert_success
}

@test "Longhorn eviction helper fails clearly when Longhorn is absent" {
  write_control_plane_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/longhorn-evict.sh" --profile live --context test --yes k3s-master-0
  assert_failure
  assert_output_contains 'Longhorn is not installed in test'

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/longhorn-evict.sh" --profile live --context test --yes k3s-master-2
  assert_failure
  assert_output_contains 'Longhorn is not installed in test'
}

@test "Longhorn eviction and delete readiness checks enforce replica safety" {
  write_eviction_longhorn_kubectl

  run env NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_longhorn_eviction_feasible test k3s-worker-0"
  assert_failure
  assert_output_contains 'max volume replicas=3, eligible storage nodes after removing target=2'

  run env NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_longhorn_node_report test k3s-worker-0"
  assert_success
  assert_output_contains 'allowScheduling=false evictionRequested=true'

  run env NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_longhorn_scheduling_problem test k3s-worker-0"
  assert_success
  [[ -z "$output" ]]

  run env NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_longhorn_replica_delete_blockers test k3s-worker-0"
  assert_success
  [[ -z "$output" ]]

  run env NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_longhorn_empty_for_delete test k3s-worker-0"
  assert_success

  run env LONGHORN_REPLICA_CASE=insufficient NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_longhorn_empty_for_delete test k3s-worker-0"
  assert_failure
  assert_output_contains 'reason=insufficient-healthy-replicas-elsewhere'

  run env LONGHORN_REPLICA_CASE=insufficient NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_longhorn_safe_stale_replicas_for_deleted_node test k3s-worker-0"
  assert_success
  [[ -z "$output" ]]

  run env NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_restore_longhorn_scheduling test k3s-worker-0"
  assert_success
  assert_output_contains 'node.longhorn.io/k3s-worker-0 patched'

  run env NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_request_longhorn_eviction test missing-node"
  assert_success
  assert_output_contains 'Longhorn node resource is absent for missing-node; no eviction request needed'
}

@test "stale pods bound to deleted nodes are force deleted" {
  write_stale_pods_kubectl

  run env STALE_PODS_STATE="$stale_pods_state" NODE_KUBECTL_BIN="$fake_stale_pods_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_cleanup_pods_for_deleted_node test k3s-worker-0"
  assert_success
  [[ ! -e "$stale_pods_state" ]]
}

@test "node lifecycle command help paths remain available" {
  local script
  for script in \
    hack/bootstrap/nodes/drain.sh \
    hack/bootstrap/nodes/control-plane-status.sh \
    hack/bootstrap/nodes/control-plane-delete-preflight.sh \
    hack/bootstrap/nodes/control-plane-delete.sh \
    hack/bootstrap/nodes/control-plane-join.sh \
    hack/bootstrap/nodes/control-plane-uncordon.sh \
    hack/bootstrap/nodes/delete.sh \
    hack/bootstrap/nodes/reboot.sh \
    hack/bootstrap/nodes/longhorn-evict.sh \
    hack/bootstrap/nodes/join.sh \
    hack/bootstrap/nodes/uncordon.sh \
    hack/bootstrap/nodes/converge.sh \
    hack/bootstrap/nodes/reimage-metadata.sh \
    hack/bootstrap/nodes/reimage-image-source.sh \
    hack/bootstrap/nodes/reimage-plan.sh \
    hack/bootstrap/nodes/reimage-stage.sh \
    hack/bootstrap/nodes/reimage-reboot.sh \
    hack/bootstrap/nodes/refresh-ssh-host-key.sh \
    hack/bootstrap/ansible/node-control-plane.sh; do
    run "${ROOT}/${script}" --help
    assert_success
  done

  assert_file_contains "$ROOT/hack/bootstrap/nodes/drain.sh" 'node_handoff_control_plane_api_if_needed'
  assert_file_contains "$ROOT/justfile" "[group('node-mutate')]"
  assert_file_contains "$ROOT/justfile" "node-converge:"
  assert_file_not_contains "$ROOT/justfile" "node-converge-yes:"
  assert_file_contains "$ROOT/justfile" "node-lima-converge-yes:"
}
