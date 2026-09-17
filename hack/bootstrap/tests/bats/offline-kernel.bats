#!/usr/bin/env bats
# shellcheck disable=SC2154

load '../helpers/common.bash'
load '../helpers/kernel.bash'

setup_file() {
  require_tools yq jq gpg gpgv gzip curl
  # Short path: gpg-agent socket paths under macOS BATS_FILE_TMPDIR are too long.
  KERNEL_TEST_GNUPGHOME="$(mktemp -d /tmp/home-ops-gpg.XXXXXX)"
  chmod 700 "$KERNEL_TEST_GNUPGHOME"
  export KERNEL_TEST_GNUPGHOME
  create_kernel_test_gpg_key "$KERNEL_TEST_GNUPGHOME" archive "${BATS_FILE_TMPDIR}/archive-keyring.gpg"
  create_kernel_test_gpg_key "$KERNEL_TEST_GNUPGHOME" intruder "${BATS_FILE_TMPDIR}/intruder-keyring.gpg"
  create_kernel_test_archive "${BATS_FILE_TMPDIR}/archive" "$KERNEL_TEST_GNUPGHOME" archive
  create_kernel_test_archive "${BATS_FILE_TMPDIR}/archive-bookworm" "$KERNEL_TEST_GNUPGHOME" archive bookworm
  create_kernel_test_archive "${BATS_FILE_TMPDIR}/archive-duplicate" "$KERNEL_TEST_GNUPGHOME" archive trixie 2
  GNUPGHOME="$KERNEL_TEST_GNUPGHOME" gpgconf --kill gpg-agent >/dev/null 2>&1 || true
}

teardown_file() {
  if [[ -n "${KERNEL_TEST_GNUPGHOME:-}" ]]; then
    GNUPGHOME="$KERNEL_TEST_GNUPGHOME" gpgconf --kill gpg-agent >/dev/null 2>&1 || true
    rm -rf "$KERNEL_TEST_GNUPGHOME"
  fi
}

setup() {
  tmp="$BATS_TEST_TMPDIR"
}

run_kernel_source_lock() {
  local archive="$1"
  shift
  run env NODE_KERNEL_ARCHIVE_URL="file://${archive}" \
    "${ROOT}/hack/bootstrap/nodes/kernel-source-lock.sh" "$@"
}

@test "kernel source lock pins the signed archive linux source package" {
  local lock="${tmp}/source.yaml"
  run_kernel_source_lock "${BATS_FILE_TMPDIR}/archive" \
    --keyring "${BATS_FILE_TMPDIR}/archive-keyring.gpg" --output "$lock"
  assert_success
  assert_output_contains "kernel_release=${KERNEL_TEST_RELEASE}"

  run yq -r '[.package, .version, .buildSuffix, .kernelRelease, .directory, (.files | length | tostring)] | join("|")' "$lock"
  assert_success
  assert_output_contains "linux|${KERNEL_TEST_SOURCE_VERSION}|+btf1|${KERNEL_TEST_RELEASE}|pool/main/l/linux|3"

  run yq -r '.files[] | select(.name == "linux_6.18.50.orig.tar.xz") | .sha256' "$lock"
  assert_success
  assert_output_contains "$(kernel_test_sha256 "${BATS_FILE_TMPDIR}/archive/pool/main/l/linux/linux_6.18.50.orig.tar.xz")"
}

@test "kernel source lock rejects an InRelease signed by an untrusted key" {
  run_kernel_source_lock "${BATS_FILE_TMPDIR}/archive" \
    --keyring "${BATS_FILE_TMPDIR}/intruder-keyring.gpg" --output "${tmp}/source.yaml"
  assert_failure
  assert_output_contains 'InRelease signature verification failed'
  [[ ! -f "${tmp}/source.yaml" ]]
}

@test "kernel source lock rejects a Sources index that does not match the signed InRelease" {
  cp -R "${BATS_FILE_TMPDIR}/archive" "${tmp}/archive"
  printf 'tampered\n' | gzip -n -c >>"${tmp}/archive/dists/trixie/main/source/Sources.gz"

  run_kernel_source_lock "${tmp}/archive" \
    --keyring "${BATS_FILE_TMPDIR}/archive-keyring.gpg" --output "${tmp}/source.yaml"
  assert_failure
  assert_output_contains 'main/source/Sources.gz does not match the signed InRelease'
  [[ ! -f "${tmp}/source.yaml" ]]
}

@test "kernel source lock rejects a signed InRelease for another suite" {
  run_kernel_source_lock "${BATS_FILE_TMPDIR}/archive-bookworm" \
    --keyring "${BATS_FILE_TMPDIR}/archive-keyring.gpg" --output "${tmp}/source.yaml"
  assert_failure
  assert_output_contains 'signed InRelease is not for suite trixie'
  [[ ! -f "${tmp}/source.yaml" ]]
}

@test "kernel source lock rejects more than one linux source package" {
  run_kernel_source_lock "${BATS_FILE_TMPDIR}/archive-duplicate" \
    --keyring "${BATS_FILE_TMPDIR}/archive-keyring.gpg" --output "${tmp}/source.yaml"
  assert_failure
  assert_output_contains 'expected exactly one linux source package in main/source/Sources.gz, found 2'
  [[ ! -f "${tmp}/source.yaml" ]]
}

@test "kernel source lock keeps the build suffix for an unchanged source version" {
  local lock="${tmp}/source.yaml"
  write_kernel_test_lock "$lock"
  yq -i '.buildSuffix = "+btf2"' "$lock"

  run_kernel_source_lock "${BATS_FILE_TMPDIR}/archive" \
    --keyring "${BATS_FILE_TMPDIR}/archive-keyring.gpg" --output "$lock"
  assert_success
  run yq -r '.buildSuffix' "$lock"
  assert_output_contains '+btf2'

  yq -i '.version = "1:6.18.39-1+rpt1" | .buildSuffix = "+btf3"' "$lock"
  run_kernel_source_lock "${BATS_FILE_TMPDIR}/archive" \
    --keyring "${BATS_FILE_TMPDIR}/archive-keyring.gpg" --output "$lock"
  assert_success
  run yq -r '.buildSuffix' "$lock"
  assert_output_contains '+btf1'

  run_kernel_source_lock "${BATS_FILE_TMPDIR}/archive" \
    --keyring "${BATS_FILE_TMPDIR}/archive-keyring.gpg" --output "$lock" --build-suffix +btf4
  assert_success
  run yq -r '.buildSuffix' "$lock"
  assert_output_contains '+btf4'
}

@test "kernel source lock refuses a changed config delta under the same version and suffix" {
  local lock="${tmp}/source.yaml"
  write_kernel_test_lock "$lock"
  yq -i '.configDeltaSha256 = "0000000000000000000000000000000000000000000000000000000000000000"' "$lock"

  run_kernel_source_lock "${BATS_FILE_TMPDIR}/archive" \
    --keyring "${BATS_FILE_TMPDIR}/archive-keyring.gpg" --output "$lock"
  assert_failure
  assert_output_contains 'config.2712.delta changed since'
}

run_fake_kernel_build() {
  run env NODE_KERNEL_SOURCE_LOCK="${tmp}/kernel/source.yaml" \
    NODE_KERNEL_OUTPUT_ROOT="${tmp}/kernel-out" \
    NODE_KERNEL_BUILD_GUEST_SCRIPT="$fake_kernel_guest" \
    FAKE_KERNEL_GUEST_ENV_FILE="${tmp}/guest.env" \
    "$@" \
    "${ROOT}/hack/bootstrap/nodes/kernel-build.sh" --builder-mode local --jobs 3
}

@test "kernel build records the rebuilt packages and inputs" {
  local state packages
  write_kernel_test_lock "${tmp}/kernel/source.yaml"
  write_fake_kernel_guest
  run_fake_kernel_build
  assert_success
  assert_output_contains "kernel_build_id=${KERNEL_TEST_BUILD_ID}"
  assert_output_contains "kernel_package_version=${KERNEL_TEST_PACKAGE_VERSION}"

  state="${tmp}/kernel-out/${KERNEL_TEST_BUILD_ID}/state/kernel-build.json"
  packages="${tmp}/kernel-out/${KERNEL_TEST_BUILD_ID}/packages"
  [[ -f "$state" ]]
  run jq -r '[.schemaVersion, .buildId, .sourceVersion, .packageVersion, .kernelRelease, (.packages | map(.name) | join(","))] | join("|")' "$state"
  assert_success
  assert_output_contains "home-ops.node-kernel-build/v1|${KERNEL_TEST_BUILD_ID}|${KERNEL_TEST_SOURCE_VERSION}|${KERNEL_TEST_PACKAGE_VERSION}|${KERNEL_TEST_RELEASE}|linux-image-6.18.50+rpt-rpi-2712,linux-base-6.18.50+rpt-rpi-2712,linux-image-rpi-2712,linux-base-rpi-2712"

  run jq -r '.packages[0].sha256, .lockSha256, .configDeltaSha256, .kernelConfig' "$state"
  assert_success
  assert_output_contains "$(kernel_test_sha256 "${packages}/linux-image-${KERNEL_TEST_RELEASE}_${KERNEL_TEST_DEB_VERSION}_arm64.deb")"
  assert_output_contains "$(kernel_test_sha256 "${tmp}/kernel/source.yaml")"
  assert_output_contains "$(kernel_test_sha256 "${ROOT}/hack/bootstrap/nodes/kernel/config.2712.delta")"
  assert_output_contains "${packages}/config-${KERNEL_TEST_RELEASE}"

  assert_file_contains "${tmp}/guest.env" "KERNEL_PACKAGE_VERSION=${KERNEL_TEST_PACKAGE_VERSION}"
  assert_file_contains "${tmp}/guest.env" "KERNEL_SOURCE_VERSION=${KERNEL_TEST_SOURCE_VERSION}"
  assert_file_contains "${tmp}/guest.env" "KERNEL_WORK_DIR=/var/tmp/home-ops-kernel-build/${KERNEL_TEST_BUILD_ID}"
  assert_file_contains "${tmp}/guest.env" 'KERNEL_JOBS=3'
  assert_file_contains "${tmp}/guest.env" 'KERNEL_ARCHIVE_URL=http://archive.invalid/debian'
  assert_file_contains "${tmp}/guest.env" 'KERNEL_DIRECTORY=pool/main/l/linux'
  assert_file_contains "${tmp}/guest.env" 'KERNEL_FILES=linux_6.18.50-1+rpt1.dsc:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;linux_6.18.50.orig.tar.xz:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
}

@test "kernel build fails when the builder does not produce every package" {
  write_kernel_test_lock "${tmp}/kernel/source.yaml"
  write_fake_kernel_guest
  run_fake_kernel_build FAKE_KERNEL_GUEST_SKIP_PACKAGE=linux-base-rpi-2712
  assert_failure
  assert_output_contains 'kernel build did not produce'
  [[ ! -f "${tmp}/kernel-out/${KERNEL_TEST_BUILD_ID}/state/kernel-build.json" ]]
}

@test "kernel build refuses to reuse a build id after the config delta changes" {
  write_kernel_test_lock "${tmp}/kernel/source.yaml"
  write_fake_kernel_guest
  cp "${ROOT}/hack/bootstrap/nodes/kernel/config.2712.delta" "${tmp}/delta"
  run_fake_kernel_build NODE_KERNEL_CONFIG_DELTA="${tmp}/delta"
  assert_success

  printf 'CONFIG_HOME_OPS_TEST=y\n' >>"${tmp}/delta"
  run_fake_kernel_build NODE_KERNEL_CONFIG_DELTA="${tmp}/delta"
  assert_failure
  assert_output_contains 'does not match configDeltaSha256'

  yq -i ".configDeltaSha256 = \"$(kernel_test_sha256 "${tmp}/delta")\"" "${tmp}/kernel/source.yaml"
  run_fake_kernel_build NODE_KERNEL_CONFIG_DELTA="${tmp}/delta"
  assert_failure
  assert_output_contains 'bump buildSuffix'
  [[ -f "${tmp}/kernel-out/${KERNEL_TEST_BUILD_ID}/state/kernel-build.json" ]]
}

@test "current kernel build lookup rejects stale inputs and modified packages" {
  local deb
  write_kernel_test_lock "${tmp}/kernel/source.yaml"
  write_fake_kernel_guest
  cp "${ROOT}/hack/bootstrap/nodes/kernel/config.2712.delta" "${tmp}/delta"
  run_fake_kernel_build NODE_KERNEL_CONFIG_DELTA="${tmp}/delta"
  assert_success

  run env NODE_KERNEL_SOURCE_LOCK="${tmp}/kernel/source.yaml" NODE_KERNEL_OUTPUT_ROOT="${tmp}/kernel-out" \
    NODE_KERNEL_CONFIG_DELTA="${tmp}/delta" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_kernel_require_current_build"
  assert_success
  assert_output_contains "${KERNEL_TEST_BUILD_ID}/state/kernel-build.json"

  run env NODE_KERNEL_SOURCE_LOCK="${tmp}/kernel/source.yaml" NODE_KERNEL_OUTPUT_ROOT="${tmp}/kernel-out" \
    NODE_KERNEL_CONFIG_DELTA="${tmp}/missing-delta" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_kernel_require_current_build"
  assert_failure
  assert_output_contains 'kernel config delta not found'

  printf 'CONFIG_HOME_OPS_TEST=y\n' >"${tmp}/other-delta"
  run env NODE_KERNEL_SOURCE_LOCK="${tmp}/kernel/source.yaml" NODE_KERNEL_OUTPUT_ROOT="${tmp}/kernel-out" \
    NODE_KERNEL_CONFIG_DELTA="${tmp}/other-delta" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_kernel_require_current_build"
  assert_failure
  assert_output_contains 'does not match configDeltaSha256'

  run env NODE_KERNEL_SOURCE_LOCK="${tmp}/kernel/source.yaml" NODE_KERNEL_OUTPUT_ROOT="${tmp}/kernel-out" \
    NODE_KERNEL_CONFIG_DELTA="${tmp}/delta" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_kernel_require_current_build"
  assert_success
  deb="${tmp}/kernel-out/${KERNEL_TEST_BUILD_ID}/packages/linux-image-${KERNEL_TEST_RELEASE}_${KERNEL_TEST_DEB_VERSION}_arm64.deb"
  printf 'tampered\n' >>"$deb"
  run env NODE_KERNEL_SOURCE_LOCK="${tmp}/kernel/source.yaml" NODE_KERNEL_OUTPUT_ROOT="${tmp}/kernel-out" \
    NODE_KERNEL_CONFIG_DELTA="${tmp}/delta" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_kernel_require_current_build"
  assert_failure
  assert_output_contains 'kernel package changed since build'

  yq -i '.buildSuffix = "+btf2"' "${tmp}/kernel/source.yaml"
  run env NODE_KERNEL_SOURCE_LOCK="${tmp}/kernel/source.yaml" NODE_KERNEL_OUTPUT_ROOT="${tmp}/kernel-out" \
    NODE_KERNEL_CONFIG_DELTA="${tmp}/delta" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_kernel_require_current_build"
  assert_failure
  assert_output_contains 'no kernel build for 6.18.50-1-rpt1-btf2; run: just node-kernel-build'
}

@test "kernel build reuses a verified build and rebuilds with --force or after tampering" {
  local deb
  write_kernel_test_lock "${tmp}/kernel/source.yaml"
  write_fake_kernel_guest
  run_fake_kernel_build
  assert_success
  rm "${tmp}/guest.env"

  run_fake_kernel_build
  assert_success
  assert_output_contains "kernel build ${KERNEL_TEST_BUILD_ID} already exists and matches the committed inputs"
  assert_output_contains "kernel_build_state=${tmp}/kernel-out/${KERNEL_TEST_BUILD_ID}/state/kernel-build.json"
  [[ ! -f "${tmp}/guest.env" ]]

  run env NODE_KERNEL_SOURCE_LOCK="${tmp}/kernel/source.yaml" \
    NODE_KERNEL_OUTPUT_ROOT="${tmp}/kernel-out" \
    NODE_KERNEL_BUILD_GUEST_SCRIPT="$fake_kernel_guest" \
    FAKE_KERNEL_GUEST_ENV_FILE="${tmp}/guest.env" \
    "${ROOT}/hack/bootstrap/nodes/kernel-build.sh" --builder-mode local --jobs 3 --force
  assert_success
  assert_output_not_contains 'already exists and matches'
  [[ -f "${tmp}/guest.env" ]]

  rm "${tmp}/guest.env"
  deb="${tmp}/kernel-out/${KERNEL_TEST_BUILD_ID}/packages/linux-image-${KERNEL_TEST_RELEASE}_${KERNEL_TEST_DEB_VERSION}_arm64.deb"
  printf 'tampered\n' >>"$deb"
  run_fake_kernel_build
  assert_success
  assert_output_contains 'does not verify against the committed inputs; rebuilding'
  [[ -f "${tmp}/guest.env" ]]
  run jq -r '.packages[0].sha256' "${tmp}/kernel-out/${KERNEL_TEST_BUILD_ID}/state/kernel-build.json"
  assert_output_contains "$(kernel_test_sha256 "$deb")"
}

@test "kernel guest edits only the top changelog entry version" {
  local changelog="${tmp}/changelog"
  cat >"$changelog" <<'EOF'
linux (1:6.18.50-1+rpt1) trixie; urgency=medium

  * Mentions (1:6.18.50-1+rpt1) in the body.

 -- Raspberry Pi <kernel@example.invalid>  Mon, 14 Sep 2026 10:00:00 +0100

linux (1:6.18.39-1+rpt1) trixie; urgency=medium
EOF
  run env KERNEL_GUEST_SOURCE_ONLY=true bash -c \
    "source '${ROOT}/hack/bootstrap/nodes/kernel/build-guest.sh'; kernel_guest_set_changelog_version '${changelog}' '1:6.18.50-1+rpt1' '1:6.18.50-1+rpt1+btf1'"
  assert_success
  run sed -n '1p;3p;7p' "$changelog"
  assert_output_contains 'linux (1:6.18.50-1+rpt1+btf1) trixie; urgency=medium'
  assert_output_contains '  * Mentions (1:6.18.50-1+rpt1) in the body.'
  assert_output_contains 'linux (1:6.18.39-1+rpt1) trixie; urgency=medium'

  run env KERNEL_GUEST_SOURCE_ONLY=true bash -c \
    "source '${ROOT}/hack/bootstrap/nodes/kernel/build-guest.sh'; kernel_guest_set_changelog_version '${changelog}' '1:6.18.51-1+rpt1' '1:6.18.51-1+rpt1+btf1'"
  assert_failure
  assert_output_contains 'top changelog entry is not 1:6.18.51-1+rpt1'
}

@test "kernel guest requires every config delta line in the kernel config" {
  printf '## comment\n# CONFIG_DEBUG_INFO_NONE is not set\nCONFIG_DEBUG_INFO_BTF=y\nCONFIG_FPROBE=y\n' >"${tmp}/delta"
  printf 'CONFIG_BPF_SYSCALL=y\n# CONFIG_DEBUG_INFO_NONE is not set\nCONFIG_DEBUG_INFO_BTF=y\nCONFIG_FPROBE=y\n' >"${tmp}/config"
  run env KERNEL_GUEST_SOURCE_ONLY=true bash -c \
    "source '${ROOT}/hack/bootstrap/nodes/kernel/build-guest.sh'; kernel_guest_require_config_lines '${tmp}/delta' '${tmp}/config'"
  assert_success

  printf 'CONFIG_BPF_SYSCALL=y\nCONFIG_DEBUG_INFO_NONE=y\n# CONFIG_FPROBE is not set\n' >"${tmp}/config"
  run env KERNEL_GUEST_SOURCE_ONLY=true bash -c \
    "source '${ROOT}/hack/bootstrap/nodes/kernel/build-guest.sh'; kernel_guest_require_config_lines '${tmp}/delta' '${tmp}/config'"
  assert_failure
  assert_output_contains '# CONFIG_DEBUG_INFO_NONE is not set'
  assert_output_contains 'CONFIG_DEBUG_INFO_BTF=y'
  assert_output_contains 'CONFIG_FPROBE=y'
  assert_output_not_contains '## comment'
}

@test "kernel guest requires the unchanged ABI name and rebuilt version in rules.gen" {
  printf "\t\$(MAKE) -f debian/rules.real build ABINAME='6.18.50+rpt' SOURCEVERSION='1:6.18.50-1+rpt1+btf1'\n" >"${tmp}/rules.gen"
  run env KERNEL_GUEST_SOURCE_ONLY=true bash -c \
    "source '${ROOT}/hack/bootstrap/nodes/kernel/build-guest.sh'; kernel_guest_require_rules_gen '${tmp}/rules.gen' '6.18.50+rpt' '1:6.18.50-1+rpt1+btf1'"
  assert_success

  printf "\t\$(MAKE) -f debian/rules.real build ABINAME='6.18.50+rpt+1' SOURCEVERSION='1:6.18.50-1+rpt1+btf1'\n" >"${tmp}/rules.gen"
  run env KERNEL_GUEST_SOURCE_ONLY=true bash -c \
    "source '${ROOT}/hack/bootstrap/nodes/kernel/build-guest.sh'; kernel_guest_require_rules_gen '${tmp}/rules.gen' '6.18.50+rpt' '1:6.18.50-1+rpt1+btf1'"
  assert_failure
  assert_output_contains "ABINAME='6.18.50+rpt'"

  printf "\t\$(MAKE) -f debian/rules.real a ABINAME='6.18.50+rpt' SOURCEVERSION='1:6.18.50-1+rpt1+btf1'\n\t\$(MAKE) -f debian/rules.real b ABINAME='6.18.50+rpt+1' SOURCEVERSION='1:6.18.50-1+rpt1+btf1'\n" >"${tmp}/rules.gen"
  run env KERNEL_GUEST_SOURCE_ONLY=true bash -c \
    "source '${ROOT}/hack/bootstrap/nodes/kernel/build-guest.sh'; kernel_guest_require_rules_gen '${tmp}/rules.gen' '6.18.50+rpt' '1:6.18.50-1+rpt1+btf1'"
  assert_failure
  assert_output_contains 'uses ABI names other than'

  printf "\t\$(MAKE) -f debian/rules.real build ABINAME='6.18.50+rpt' SOURCEVERSION='1:6.18.50-1+rpt1'\n" >"${tmp}/rules.gen"
  run env KERNEL_GUEST_SOURCE_ONLY=true bash -c \
    "source '${ROOT}/hack/bootstrap/nodes/kernel/build-guest.sh'; kernel_guest_require_rules_gen '${tmp}/rules.gen' '6.18.50+rpt' '1:6.18.50-1+rpt1+btf1'"
  assert_failure
  assert_output_contains "does not use SOURCEVERSION='1:6.18.50-1+rpt1+btf1'"
}

@test "kernel guest keeps kernel debug info and never renames the kernel ABI" {
  local guest="${ROOT}/hack/bootstrap/nodes/kernel/build-guest.sh"
  assert_file_contains "$guest" "export DEB_BUILD_PROFILES='pkg.linux.nokerneldbg nodoc'"
  assert_file_contains "$guest" "export MAKEFLAGS=\"-j\${KERNEL_JOBS}\""
  run grep -nE '^[^#]*(nokerneldbginfo|pkg\.linux\.quick)' "$guest"
  assert_failure
  run grep -nE '^[[:space:]]*dch([[:space:]]|$)' "$guest"
  assert_failure
  run grep -nE '^[^#]*make[[:space:]].*[[:space:]]-j' "$guest"
  assert_failure
}

@test "kernel build fails without state when the state cannot be written, and a rerun builds" {
  local state
  write_kernel_test_lock "${tmp}/kernel/source.yaml"
  write_fake_kernel_guest
  state="${tmp}/kernel-out/${KERNEL_TEST_BUILD_ID}/state/kernel-build.json"
  mkdir -p "${tmp}/bin"
  cat >"${tmp}/bin/jq" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -n ]]; then
  exit 3
fi
exec "${REAL_JQ:?}" "$@"
EOF
  chmod +x "${tmp}/bin/jq"

  run_fake_kernel_build NODE_JQ_BIN="${tmp}/bin/jq" REAL_JQ="$(command -v jq)"
  assert_failure
  assert_output_contains 'could not write kernel build state'
  [[ ! -e "$state" && ! -e "${state}.tmp" ]]

  run_fake_kernel_build
  assert_success
  [[ -s "$state" ]]
}

@test "kernel build fails and records no state when the builder fails" {
  write_kernel_test_lock "${tmp}/kernel/source.yaml"
  printf '#!/usr/bin/env bash\nexit 7\n' >"${tmp}/failing-guest.sh"
  chmod +x "${tmp}/failing-guest.sh"

  run env NODE_KERNEL_SOURCE_LOCK="${tmp}/kernel/source.yaml" NODE_KERNEL_OUTPUT_ROOT="${tmp}/kernel-out" \
    NODE_KERNEL_BUILD_GUEST_SCRIPT="${tmp}/failing-guest.sh" \
    "${ROOT}/hack/bootstrap/nodes/kernel-build.sh" --builder-mode local --jobs 1
  assert_failure
  assert_output_contains 'kernel build failed in the local builder'
  [[ ! -e "${tmp}/kernel-out/${KERNEL_TEST_BUILD_ID}/state/kernel-build.json" ]]
}

@test "kernel build keeps an existing build when a forced run fails before building" {
  write_kernel_test_lock "${tmp}/kernel/source.yaml"
  write_fake_kernel_guest
  run_fake_kernel_build
  assert_success

  run env NODE_KERNEL_SOURCE_LOCK="${tmp}/kernel/source.yaml" NODE_KERNEL_OUTPUT_ROOT="${tmp}/kernel-out" \
    NODE_KERNEL_BUILD_GUEST_SCRIPT="$fake_kernel_guest" FAKE_KERNEL_GUEST_ENV_FILE="${tmp}/guest.env" \
    "${ROOT}/hack/bootstrap/nodes/kernel-build.sh" --builder-mode lcoal --jobs 1 --force
  assert_failure
  assert_output_contains 'unknown reimage builder mode: lcoal'
  [[ -f "${tmp}/kernel-out/${KERNEL_TEST_BUILD_ID}/state/kernel-build.json" ]]
}

@test "kernel inputs reject unsafe source lock fields" {
  local lock="${tmp}/kernel/source.yaml"
  write_kernel_test_lock "$lock"
  yq -i '.files[0].name = "../escape.dsc"' "$lock"
  run env NODE_KERNEL_SOURCE_LOCK="$lock" bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_kernel_require_inputs"
  assert_failure
  assert_output_contains 'invalid source file name'

  write_kernel_test_lock "$lock"
  yq -i '.archiveUrl = "http://archive.invalid/debian;touch /tmp/x"' "$lock"
  run env NODE_KERNEL_SOURCE_LOCK="$lock" bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_kernel_require_inputs"
  assert_failure
  assert_output_contains 'invalid archiveUrl'

  write_kernel_test_lock "$lock"
  yq -i '.directory = "pool/../../etc"' "$lock"
  run env NODE_KERNEL_SOURCE_LOCK="$lock" bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_kernel_require_inputs"
  assert_failure
  assert_output_contains 'invalid directory'
}

@test "committed kernel source lock matches the committed kernel config delta" {
  run bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_kernel_require_inputs"
  assert_success
}
