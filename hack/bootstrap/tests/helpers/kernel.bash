#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

KERNEL_TEST_SOURCE_VERSION='1:6.18.50-1+rpt1'
KERNEL_TEST_PACKAGE_VERSION='1:6.18.50-1+rpt1+btf1'
KERNEL_TEST_DEB_VERSION='6.18.50-1+rpt1+btf1'
KERNEL_TEST_RELEASE='6.18.50+rpt-rpi-2712'
KERNEL_TEST_BUILD_ID='6.18.50-1-rpt1-btf1'

kernel_test_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

kernel_test_size() {
  wc -c <"$1" | tr -d ' '
}

# create_kernel_test_gpg_key GNUPGHOME NAME EXPORT_FILE
create_kernel_test_gpg_key() {
  local gnupg_home="$1"
  local name="$2"
  local export_file="$3"
  GNUPGHOME="$gnupg_home" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "${name} <${name}@example.invalid>" ed25519 sign never >/dev/null
  GNUPGHOME="$gnupg_home" gpg --batch --export "${name}@example.invalid" >"$export_file"
}

# create_kernel_test_archive ARCHIVE_DIR GNUPGHOME SIGNER_NAME [SUITE_LABEL] [LINUX_STANZAS]
create_kernel_test_archive() {
  local archive="$1"
  local gnupg_home="$2"
  local signer="$3"
  local suite_label="${4:-trixie}"
  local linux_stanzas="${5:-1}"
  local pool="${archive}/pool/main/l/linux"
  local suite_dir="${archive}/dists/trixie"
  local source_dir="${suite_dir}/main/source"
  local name
  local i

  mkdir -p "$pool" "$source_dir"
  printf 'fake dsc\n' >"${pool}/linux_6.18.50-1+rpt1.dsc"
  printf 'fake orig\n' >"${pool}/linux_6.18.50.orig.tar.xz"
  printf 'fake debian\n' >"${pool}/linux_6.18.50-1+rpt1.debian.tar.xz"
  {
    printf 'Package: bpftool\nVersion: 1:7.7.0+6.18.50-1+rpt1\nDirectory: pool/main/l/linux\n\n'
    for ((i = 0; i < linux_stanzas; i++)); do
      printf 'Package: linux\nBinary: linux-image-rpi-2712\nVersion: %s\nDirectory: pool/main/l/linux\nChecksums-Sha256: \n' \
        "$KERNEL_TEST_SOURCE_VERSION"
      for name in linux_6.18.50-1+rpt1.dsc linux_6.18.50.orig.tar.xz linux_6.18.50-1+rpt1.debian.tar.xz; do
        printf ' %s %s %s\n' "$(kernel_test_sha256 "${pool}/${name}")" "$(kernel_test_size "${pool}/${name}")" "$name"
      done
      printf 'Package-List:\n linux-image-rpi-2712 deb kernel optional arch=arm64\n\n'
    done
  } >"${source_dir}/Sources"
  gzip -n -c "${source_dir}/Sources" >"${source_dir}/Sources.gz"
  {
    printf 'Origin: Raspberry Pi Foundation\nSuite: %s\nSHA256:\n' "$suite_label"
    printf ' %s %s main/source/Sources\n' "$(kernel_test_sha256 "${source_dir}/Sources")" "$(kernel_test_size "${source_dir}/Sources")"
    printf ' %s %s main/source/Sources.gz\n' "$(kernel_test_sha256 "${source_dir}/Sources.gz")" "$(kernel_test_size "${source_dir}/Sources.gz")"
  } >"${suite_dir}/Release"
  GNUPGHOME="$gnupg_home" gpg --batch --yes --pinentry-mode loopback --passphrase '' \
    --local-user "${signer}@example.invalid" --clearsign \
    -o "${suite_dir}/InRelease" "${suite_dir}/Release" >/dev/null
}

write_kernel_test_lock() {
  local lock="$1"
  mkdir -p "$(dirname "$lock")"
  cat >"$lock" <<EOF
---
package: linux
version: "${KERNEL_TEST_SOURCE_VERSION}"
buildSuffix: "+btf1"
configDeltaSha256: $(kernel_test_sha256 "${ROOT}/hack/bootstrap/nodes/kernel/config.2712.delta")
kernelRelease: ${KERNEL_TEST_RELEASE}
archiveUrl: http://archive.invalid/debian
suite: trixie
component: main
directory: pool/main/l/linux
files:
  - name: linux_6.18.50-1+rpt1.dsc
    size: 9
    sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  - name: linux_6.18.50.orig.tar.xz
    size: 10
    sha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
}

write_fake_kernel_guest() {
  fake_kernel_guest="${tmp}/fake-kernel-guest.sh"
  cat >"$fake_kernel_guest" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
env | grep '^KERNEL_' | sort >"${FAKE_KERNEL_GUEST_ENV_FILE:?}"
deb_version="${KERNEL_PACKAGE_VERSION#*:}"
mkdir -p "$KERNEL_OUT_DIR"
for pkg in "linux-image-${KERNEL_RELEASE}" "linux-base-${KERNEL_RELEASE}" "linux-image-${KERNEL_FLAVOUR}" "linux-base-${KERNEL_FLAVOUR}"; do
  if [[ "$pkg" == "${FAKE_KERNEL_GUEST_SKIP_PACKAGE:-}" ]]; then
    continue
  fi
  printf 'fake %s %s\n' "$pkg" "$KERNEL_PACKAGE_VERSION" >"${KERNEL_OUT_DIR}/${pkg}_${deb_version}_arm64.deb"
done
grep -v '^##' "$KERNEL_CONFIG_DELTA" >"${KERNEL_OUT_DIR}/config-${KERNEL_RELEASE}"
EOF
  chmod +x "$fake_kernel_guest"
}

# create_fake_kernel_build builds a kernel build state from a test lock and the
# fake guest. Sets kernel_test_lock and kernel_test_output_root.
create_fake_kernel_build() {
  kernel_test_lock="${tmp}/kernel/source.yaml"
  kernel_test_output_root="${tmp}/kernel-out"
  write_kernel_test_lock "$kernel_test_lock"
  write_fake_kernel_guest
  NODE_KERNEL_SOURCE_LOCK="$kernel_test_lock" \
    NODE_KERNEL_OUTPUT_ROOT="$kernel_test_output_root" \
    NODE_KERNEL_BUILD_GUEST_SCRIPT="$fake_kernel_guest" \
    FAKE_KERNEL_GUEST_ENV_FILE="${tmp}/kernel-guest.env" \
    "${ROOT}/hack/bootstrap/nodes/kernel-build.sh" --builder-mode local --jobs 1 >/dev/null
}

KERNEL_TEST_NEXT_PACKAGE_VERSION='1:6.18.50-1+rpt1+btf2'
KERNEL_TEST_NEXT_DEB_VERSION='6.18.50-1+rpt1+btf2'
KERNEL_TEST_NEXT_BUILD_ID='6.18.50-1-rpt1-btf2'
KERNEL_TEST_DELTA_SHA256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
KERNEL_TEST_NODE_CMDLINE='console=serial0,115200 console=tty1 root=/dev/disk/by-slot/system fsck.repair=yes rootwait cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off'

# write_fake_kernel_node_stubs BIN_DIR writes the node-side stubs the kernel
# update tool shells out to. Every stub reads FAKE_NODE_ROOT, which
# kernel_node_env passes, so they work whether they are reached through PATH or
# through an explicit HOME_OPS_KERNEL_* override.
write_fake_kernel_node_stubs() {
  local bin="$1"
  mkdir -p "$bin"

  cat >"${bin}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -r) printf '%s\n' "${FAKE_UNAME_R:?}" ;;
  -v) printf '%s\n' "${FAKE_UNAME_V:?}" ;;
  *) exit 2 ;;
esac
EOF

  # dpkg.state lines are "<name> <status> <want> <version>".
  cat >"${bin}/dpkg-query" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == -W ]] || exit 2
fmt="${2:-}"
name="${3:-}"
line="$(grep "^${name} " "${FAKE_NODE_ROOT:?}/dpkg.state" || true)"
[[ -n "$line" ]] || exit 1
read -r _ pkg_status pkg_want pkg_version <<<"$line"
case "$fmt" in
  '-f=${db:Status-Status} ${Version}') printf '%s %s' "$pkg_status" "$pkg_version" ;;
  '-f=${db:Status-Want}') printf '%s' "$pkg_want" ;;
  *) exit 2 ;;
esac
EOF

  cat >"${bin}/apt-mark" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="${FAKE_NODE_ROOT:?}"
op="${1:?apt-mark needs an operation}"
shift
printf '%s %s\n' "$op" "$*" >>"${root}/apt-mark.log"
want=install
[[ "$op" != hold ]] || want=hold
for name in "$@"; do
  awk -v name="$name" -v want="$want" '$1 == name { $3 = want } { print }' \
    "${root}/dpkg.state" >"${root}/dpkg.state.new"
  mv "${root}/dpkg.state.new" "${root}/dpkg.state"
done
EOF

  # apt-get install unpacks the root-level boot set and, standing in for the
  # raspi-firmware kernel hooks, copies it into the firmware partition.
  cat >"${bin}/apt-get" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
root="${FAKE_NODE_ROOT:?}"
printf '%s\n' "$*" >>"${root}/apt-get.log"
printf 'NEEDRESTART_MODE=%s DEBIAN_FRONTEND=%s\n' \
  "${NEEDRESTART_MODE:-}" "${DEBIAN_FRONTEND:-}" >>"${root}/apt-get.env.log"
op=""
for arg in "$@"; do
  case "$arg" in
    install | purge) op="$arg" ;;
  esac
done
if [[ "$op" == install ]]; then
  if [[ "${FAKE_APT_FAIL:-}" == 1 ]]; then
    printf 'E: simulated install failure\n' >&2
    exit 100
  fi
  printf 'Reading package lists... Done\n'
  printf 'Get:1 /var/tmp/home-ops-kernel linux-image arm64 [1,234 kB]\n'
  printf 'Selecting previously unselected package linux-image.\n'
  for arg in "$@"; do
    [[ "$arg" == ./linux-image-*_arm64.deb ]] || continue
    stem="${arg#./linux-image-}"
    stem="${stem%_arm64.deb}"
    release="${stem%%_*}"
    version="${stem#*_}"
    [[ "$release" != rpi-2712 ]] || continue
    for name in "linux-image-${release}" "linux-base-${release}" linux-image-rpi-2712 linux-base-rpi-2712; do
      grep -v "^${name} " "${root}/dpkg.state" >"${root}/dpkg.state.new" || true
      # Every home-ops kernel package carries epoch 1, like the archive ones.
      printf '%s installed install 1:%s\n' "$name" "$version" >>"${root}/dpkg.state.new"
      mv "${root}/dpkg.state.new" "${root}/dpkg.state"
    done
    head -c 4096 /dev/urandom >"${root}/boot/vmlinuz-${release}"
    head -c 8192 /dev/urandom >"${root}/boot/initrd.img-${release}"
    # dpkg unpacks the root-level boot set; the raspi-firmware kernel hooks are
    # what copy it into the firmware partition. FAKE_APT_SKIP_HOOKS=1 stops
    # after the unpack, which is what a node with broken hooks looks like.
    [[ "${FAKE_APT_SKIP_HOOKS:-}" != 1 ]] || continue
    cp "${root}/boot/vmlinuz-${release}" "${root}/boot/firmware/kernel_2712.img"
    cp "${root}/boot/initrd.img-${release}" "${root}/boot/firmware/initramfs_2712"
  done
elif [[ "$op" == purge ]]; then
  if [[ "${FAKE_APT_PURGE_FAIL:-}" == 1 ]]; then
    printf 'E: simulated purge failure\n' >&2
    exit 100
  fi
  printf 'Reading package lists... Done\n'
  printf 'Removing linux-image (1,234 kB) ...\n'
  for arg in "$@"; do
    [[ "$arg" == linux-* ]] || continue
    grep -v "^${arg} " "${root}/dpkg.state" >"${root}/dpkg.state.new" || true
    mv "${root}/dpkg.state.new" "${root}/dpkg.state"
  done
fi
EOF

  cat >"${bin}/df" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
free="${FAKE_BOOT_FREE_BYTES:-60000000}"
block=1
for arg in "$@"; do
  case "$arg" in
    -B1) block=1 ;;
    -k | -Pk | -kP) block=1024 ;;
  esac
done
printf 'Filesystem %s-blocks Used Available Capacity Mounted on\n' "$block"
printf '/dev/fake %s %s %s 41%% /boot/firmware\n' "$((110100480 / block))" "$((45000000 / block))" "$((free / block))"
EOF

  cat >"${bin}/sync" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  # Stands in for /usr/local/sbin/home-ops-verify-kernel-build: the real one
  # needs /proc/config.gz and /sys/kernel/btf, which a fake node has not got.
  cat >"${bin}/home-ops-verify-kernel-build" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
marker="${HOME_OPS_KERNEL_BUILD_MARKER:-${FAKE_NODE_ROOT:?}/etc/home-ops/kernel-build}"
fail() {
  printf 'home-ops-verify-kernel-build: %s\n' "$*" >&2
  exit 1
}
[[ "${FAKE_VERIFY_FAIL:-}" != 1 ]] || fail 'forced verification failure'
[[ -r "$marker" ]] || fail "kernel build marker is missing: ${marker}"
marker_value() { sed -n "s/^$1=//p" "$marker" | sed -n '1p'; }
build_id="$(marker_value KERNEL_BUILD_ID)"
version="$(marker_value KERNEL_PACKAGE_VERSION)"
release="$(marker_value KERNEL_RELEASE)"
[[ -n "$build_id" && -n "$version" && -n "$release" ]] || fail "kernel build marker is incomplete: ${marker}"
[[ "${FAKE_UNAME_R:?}" == "$release" ]] || fail "running kernel ${FAKE_UNAME_R} is not the home-ops kernel ${release}"
[[ "${FAKE_UNAME_V:?}" == *" ${version} ("* ]] || fail "running kernel build '${FAKE_UNAME_V}' is not ${version}"
grep -q "^linux-image-${release} installed [a-z]* ${version}\$" "${FAKE_NODE_ROOT:?}/dpkg.state" ||
  fail "linux-image-${release} is not installed at ${version}"
printf 'kernel_build_id=%s\n' "$build_id"
EOF

  chmod +x "${bin}"/*
}

# create_fake_kernel_node NODE_ROOT RELEASE VERSION BUILD_ID builds a node that
# boots the home-ops kernel: a firmware partition, the root-level boot set the
# Debian kernel hooks keep in sync with it, the build marker, /proc/cmdline, a
# dpkg state file with the four packages held, and the stubs above. Sets the
# kernel_node_env array and exports FAKE_UNAME_R and FAKE_UNAME_V.
create_fake_kernel_node() {
  local node_root="$1" release="$2" version="$3" build_id="$4"
  local name
  mkdir -p "${node_root}/boot/firmware" "${node_root}/etc/home-ops" "${node_root}/proc"
  head -c 4096 /dev/urandom >"${node_root}/boot/vmlinuz-${release}"
  head -c 8192 /dev/urandom >"${node_root}/boot/initrd.img-${release}"
  cp "${node_root}/boot/vmlinuz-${release}" "${node_root}/boot/firmware/kernel_2712.img"
  cp "${node_root}/boot/initrd.img-${release}" "${node_root}/boot/firmware/initramfs_2712"
  cat >"${node_root}/boot/firmware/config.txt" <<'EOF'
auto_initramfs=1
disable_fw_kms_setup=1

[pi5]
arm_boost=1

[all]
# BEGIN ANSIBLE MANAGED BLOCK home-ops raspberry pi config
dtparam=nvme
dtparam=pciex1_gen=3
dtoverlay=cma,cma-96
# END ANSIBLE MANAGED BLOCK home-ops raspberry pi config
EOF
  printf '%s\n' "$KERNEL_TEST_NODE_CMDLINE" >"${node_root}/boot/firmware/cmdline.txt"
  printf '%s\n' "$KERNEL_TEST_NODE_CMDLINE" >"${node_root}/proc/cmdline"
  cat >"${node_root}/etc/home-ops/kernel-build" <<EOF
KERNEL_BUILD_ID=${build_id}
KERNEL_PACKAGE_VERSION=${version}
KERNEL_RELEASE=${release}
KERNEL_CONFIG_DELTA_SHA256=${KERNEL_TEST_DELTA_SHA256}
EOF
  : >"${node_root}/dpkg.state"
  for name in "linux-image-${release}" "linux-base-${release}" linux-image-rpi-2712 linux-base-rpi-2712; do
    printf '%s installed hold %s\n' "$name" "$version" >>"${node_root}/dpkg.state"
  done
  write_fake_kernel_node_stubs "${node_root}/bin"
  fake_node_set_running "$release" "$version"
  kernel_node_env=(
    "HOME_OPS_KERNEL_BOOT_DIR=${node_root}/boot/firmware"
    "HOME_OPS_KERNEL_VMLINUZ_DIR=${node_root}/boot"
    "HOME_OPS_KERNEL_BUILD_MARKER=${node_root}/etc/home-ops/kernel-build"
    "HOME_OPS_KERNEL_VERIFY_BIN=${node_root}/bin/home-ops-verify-kernel-build"
    "HOME_OPS_KERNEL_PROC_CMDLINE=${node_root}/proc/cmdline"
    "HOME_OPS_KERNEL_APT_GET=${node_root}/bin/apt-get"
    "HOME_OPS_KERNEL_APT_MARK=${node_root}/bin/apt-mark"
    "HOME_OPS_KERNEL_SYNC=${node_root}/bin/sync"
    "FAKE_NODE_ROOT=${node_root}"
    "PATH=${node_root}/bin:${PATH}"
  )
}

# create_fake_kernel_package_dir DIR RELEASE VERSION BUILD_ID writes the four
# shipped packages, their SHA256SUMS, and the build env the tool reads.
create_fake_kernel_package_dir() {
  local dir="$1" release="$2" version="$3" build_id="$4"
  local deb_version="${version#*:}" name
  rm -rf "$dir"
  mkdir -p "$dir"
  for name in "linux-image-${release}" "linux-base-${release}" linux-image-rpi-2712 linux-base-rpi-2712; do
    head -c 512 /dev/urandom >"${dir}/${name}_${deb_version}_arm64.deb"
  done
  (
    cd "$dir" || exit 1
    for name in *.deb; do
      printf '%s  %s\n' "$(kernel_test_sha256 "$name")" "$name"
    done >SHA256SUMS
  )
  cat >"${dir}/kernel-build.env" <<EOF
KERNEL_BUILD_ID=${build_id}
KERNEL_PACKAGE_VERSION=${version}
KERNEL_RELEASE=${release}
KERNEL_CONFIG_DELTA_SHA256=${KERNEL_TEST_DELTA_SHA256}
EOF
}

# fake_node_set_running RELEASE VERSION points the uname stub at a build.
fake_node_set_running() {
  FAKE_UNAME_R="$1"
  FAKE_UNAME_V="#1 SMP PREEMPT Debian ${2} (2026-09-28)"
  export FAKE_UNAME_R FAKE_UNAME_V
}

# fake_node_boot_fallback NODE_ROOT [FALLBACK_DIR_NAME] simulates a plain
# reboot, which the firmware serves from config.txt and so from the fallback.
fake_node_boot_fallback() {
  local node_root="$1" name="${2:-home-ops-kernel-prev}"
  cp "${node_root}/boot/firmware/${name}/cmdline.txt" "${node_root}/proc/cmdline"
}

# fake_node_boot_trial NODE_ROOT simulates the one "0 tryboot" boot, which the
# firmware serves from tryboot.txt and so from the root-level cmdline.
fake_node_boot_trial() {
  local node_root="$1"
  cp "${node_root}/boot/firmware/cmdline.txt" "${node_root}/proc/cmdline"
}

# assert_kernel_node_stdout_clean FILE fails unless every line of FILE is a
# key=value line. A bare "! grep" cannot be used here: in Bats a negated
# command does not fail the test.
assert_kernel_node_stdout_clean() {
  local file="$1"
  if grep -qvE '^[a-z_]+=' "$file"; then
    printf 'expected only key=value lines on stdout, got:\n' >&2
    grep -vE '^[a-z_]+=' "$file" >&2
    return 1
  fi
}

# run_kernel_node_split ARGS... runs the tool with its streams captured
# separately, in ${tmp}/stdout and ${tmp}/stderr, so a test can assert that the
# tool's stdout carries nothing but key=value lines.
run_kernel_node_split() {
  env "${kernel_node_env[@]}" "${ROOT}/hack/bootstrap/nodes/kernel/update-node.sh" "$@" \
    >"${tmp}/stdout" 2>"${tmp}/stderr"
}

# run_kernel_node [VAR=VALUE]... ARGS... runs the node-side kernel update tool
# against the fake node, with any leading assignments added to its environment.
run_kernel_node() {
  local -a cmd=(env "${kernel_node_env[@]}")
  while (($# > 0)) && [[ "$1" == *=* ]]; do
    cmd+=("$1")
    shift
  done
  cmd+=("${ROOT}/hack/bootstrap/nodes/kernel/update-node.sh")
  run "${cmd[@]}" "$@"
}

# write_fake_kernel_status FILE writes the status block of a clean node, the
# shape the fake ansible hands back for "home-ops-kernel-update status". Tests
# rewrite the file between phases, or drop a line from it to stand in for a
# truncated read.
write_fake_kernel_status() {
  local file="$1"
  cat >"$file" <<EOF
running_release=${KERNEL_TEST_RELEASE}
running_build=#1 SMP PREEMPT Debian ${KERNEL_TEST_PACKAGE_VERSION} (2026-09-28)
booted_via_fallback=no
boot_files_present=yes
marker_present=yes
marker_build_id=${KERNEL_TEST_BUILD_ID}
marker_version=${KERNEL_TEST_PACKAGE_VERSION}
marker_release=${KERNEL_TEST_RELEASE}
installed_version=${KERNEL_TEST_PACKAGE_VERSION}
fallback_copy=no
fallback_version=
fallback_release=
fallback_build_id=
config_fallback_block=no
tryboot_present=no
reimage_staged=no
trial_pending=no
running_matches=marker
state=S0
boot_free_bytes=60000000
boot_set_bytes=12288
holds=4
EOF
}
