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
