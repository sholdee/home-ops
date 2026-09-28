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

@test "kernel source lock requires a greater build suffix for the same source version" {
  local lock="${tmp}/source.yaml"
  write_kernel_test_lock "$lock"
  yq -i '.buildSuffix = "+btf2"' "$lock"

  run_kernel_source_lock "${BATS_FILE_TMPDIR}/archive" \
    --keyring "${BATS_FILE_TMPDIR}/archive-keyring.gpg" --output "$lock" --build-suffix +btf1
  assert_failure
  assert_output_contains "build suffix +btf1 must be greater than +btf2 for ${KERNEL_TEST_SOURCE_VERSION}"
  run yq -r '.buildSuffix' "$lock"
  assert_output_contains '+btf2'

  # A changed delta cannot reuse a lower suffix either.
  yq -i '.configDeltaSha256 = "0000000000000000000000000000000000000000000000000000000000000000"' "$lock"
  run_kernel_source_lock "${BATS_FILE_TMPDIR}/archive" \
    --keyring "${BATS_FILE_TMPDIR}/archive-keyring.gpg" --output "$lock" --build-suffix +btf1
  assert_failure
  assert_output_contains 'build suffix +btf1 must be greater than +btf2'

  write_kernel_test_lock "$lock"
  yq -i '.buildSuffix = "+btf2"' "$lock"
  run_kernel_source_lock "${BATS_FILE_TMPDIR}/archive" \
    --keyring "${BATS_FILE_TMPDIR}/archive-keyring.gpg" --output "$lock" --build-suffix +btf2
  assert_success

  # Suffixes compare numerically: +btf10 follows +btf9.
  yq -i '.buildSuffix = "+btf9"' "$lock"
  run_kernel_source_lock "${BATS_FILE_TMPDIR}/archive" \
    --keyring "${BATS_FILE_TMPDIR}/archive-keyring.gpg" --output "$lock" --build-suffix +btf10
  assert_success
  run yq -r '.buildSuffix' "$lock"
  assert_output_contains '+btf10'
}

@test "kernel source lock and inputs reject a build suffix that is not +btf<N>" {
  local lock="${tmp}/source.yaml"
  local suffix
  for suffix in +rebuild +btf0 +btf02 +btf2a btf2; do
    run_kernel_source_lock "${BATS_FILE_TMPDIR}/archive" \
      --keyring "${BATS_FILE_TMPDIR}/archive-keyring.gpg" --output "$lock" --build-suffix "$suffix"
    assert_failure
    assert_output_contains "invalid kernel build suffix: ${suffix}"
    [[ ! -f "$lock" ]]
  done

  write_kernel_test_lock "$lock"
  yq -i '.buildSuffix = "+rebuild"' "$lock"
  run_kernel_source_lock "${BATS_FILE_TMPDIR}/archive" \
    --keyring "${BATS_FILE_TMPDIR}/archive-keyring.gpg" --output "$lock" --build-suffix +btf2
  assert_failure
  assert_output_contains "invalid buildSuffix in ${lock}: +rebuild"

  run env NODE_KERNEL_SOURCE_LOCK="$lock" bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_kernel_require_inputs"
  assert_failure
  assert_output_contains 'invalid buildSuffix'
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

write_kernel_verify_fixture() {
  verify_root="${tmp}/verify"
  mkdir -p "${verify_root}/bin"
  cat >"${verify_root}/kernel-build" <<EOF
KERNEL_BUILD_ID=${KERNEL_TEST_BUILD_ID}
KERNEL_PACKAGE_VERSION=${KERNEL_TEST_PACKAGE_VERSION}
KERNEL_RELEASE=${KERNEL_TEST_RELEASE}
KERNEL_CONFIG_DELTA_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
  printf 'btf\n' >"${verify_root}/vmlinux"
  printf 'CONFIG_BPF_SYSCALL=y\nCONFIG_DEBUG_INFO_BTF=y\nCONFIG_PSI=y\n' | gzip -n -c >"${verify_root}/config.gz"
  cat >"${verify_root}/bin/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -r) printf '%s\n' "${FAKE_UNAME_R:?}" ;;
  -v) printf '%s\n' "${FAKE_UNAME_V:?}" ;;
  *) exit 2 ;;
esac
EOF
  cat >"${verify_root}/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
[[ $# == 3 && "$1" == -W && "$2" == '-f=${db:Status-Status} ${Version}' && "$3" == "${FAKE_DPKG_PACKAGE:?}" ]] || exit 2
[[ -n "${FAKE_DPKG_VERSION:-}" ]] || exit 1
printf '%s %s' "${FAKE_DPKG_STATUS:-installed}" "$FAKE_DPKG_VERSION"
EOF
  chmod +x "${verify_root}/bin/uname" "${verify_root}/bin/dpkg-query"
}

run_kernel_verify() {
  run env PATH="${verify_root}/bin:${PATH}" \
    HOME_OPS_KERNEL_BUILD_MARKER="${verify_root}/kernel-build" \
    HOME_OPS_KERNEL_BTF="${verify_root}/vmlinux" \
    HOME_OPS_KERNEL_PROC_CONFIG="${verify_root}/config.gz" \
    FAKE_DPKG_PACKAGE="linux-image-${KERNEL_TEST_RELEASE}" \
    FAKE_UNAME_V="#1 SMP PREEMPT Debian ${KERNEL_TEST_PACKAGE_VERSION} (2026-09-11)" \
    "$@" \
    "${ROOT}/hack/bootstrap/nodes/kernel/verify-kernel-build.sh"
}

@test "kernel verifier accepts the home-ops kernel build" {
  write_kernel_verify_fixture
  run_kernel_verify FAKE_UNAME_R="$KERNEL_TEST_RELEASE" FAKE_DPKG_VERSION="$KERNEL_TEST_PACKAGE_VERSION"
  assert_success
  assert_output_contains "kernel_build_id=${KERNEL_TEST_BUILD_ID}"
}

@test "kernel verifier rejects the stock kernel that shares the release string" {
  write_kernel_verify_fixture
  run_kernel_verify FAKE_UNAME_R="$KERNEL_TEST_RELEASE" FAKE_DPKG_VERSION="$KERNEL_TEST_SOURCE_VERSION"
  assert_failure
  assert_output_contains "linux-image-${KERNEL_TEST_RELEASE} is installed ${KERNEL_TEST_SOURCE_VERSION}, expected installed ${KERNEL_TEST_PACKAGE_VERSION}"
  assert_output_not_contains 'kernel_build_id='
}

@test "kernel verifier rejects a running kernel without BTF" {
  write_kernel_verify_fixture
  rm "${verify_root}/vmlinux"
  run_kernel_verify FAKE_UNAME_R="$KERNEL_TEST_RELEASE" FAKE_DPKG_VERSION="$KERNEL_TEST_PACKAGE_VERSION"
  assert_failure
  assert_output_contains 'kernel BTF is missing'

  write_kernel_verify_fixture
  printf 'CONFIG_BPF_SYSCALL=y\n# CONFIG_DEBUG_INFO_BTF is not set\n' | gzip -n -c >"${verify_root}/config.gz"
  run_kernel_verify FAKE_UNAME_R="$KERNEL_TEST_RELEASE" FAKE_DPKG_VERSION="$KERNEL_TEST_PACKAGE_VERSION"
  assert_failure
  assert_output_contains 'running kernel config lacks CONFIG_DEBUG_INFO_BTF=y'

  write_kernel_verify_fixture
  rm "${verify_root}/config.gz"
  run_kernel_verify FAKE_UNAME_R="$KERNEL_TEST_RELEASE" FAKE_DPKG_VERSION="$KERNEL_TEST_PACKAGE_VERSION"
  assert_failure
  assert_output_contains 'running kernel config is not exposed'
}

@test "kernel verifier rejects another release, an uninstalled package, and a missing marker" {
  write_kernel_verify_fixture
  run_kernel_verify FAKE_UNAME_R='6.18.39+rpt-rpi-2712' FAKE_DPKG_VERSION="$KERNEL_TEST_PACKAGE_VERSION"
  assert_failure
  assert_output_contains "running kernel 6.18.39+rpt-rpi-2712 is not the home-ops kernel ${KERNEL_TEST_RELEASE}"

  run_kernel_verify FAKE_UNAME_R="$KERNEL_TEST_RELEASE"
  assert_failure
  assert_output_contains 'is not installed'

  rm "${verify_root}/kernel-build"
  run_kernel_verify FAKE_UNAME_R="$KERNEL_TEST_RELEASE" FAKE_DPKG_VERSION="$KERNEL_TEST_PACKAGE_VERSION"
  assert_failure
  assert_output_contains 'kernel build marker is missing'

  write_kernel_verify_fixture
  sed -i.bak '/^KERNEL_BUILD_ID=/d' "${verify_root}/kernel-build"
  run_kernel_verify FAKE_UNAME_R="$KERNEL_TEST_RELEASE" FAKE_DPKG_VERSION="$KERNEL_TEST_PACKAGE_VERSION"
  assert_failure
  assert_output_contains 'kernel build marker is incomplete'
}

@test "kernel verifier rejects a removed package that dpkg still lists" {
  write_kernel_verify_fixture
  run_kernel_verify FAKE_UNAME_R="$KERNEL_TEST_RELEASE" FAKE_DPKG_VERSION="$KERNEL_TEST_PACKAGE_VERSION" FAKE_DPKG_STATUS=config-files
  assert_failure
  assert_output_contains "is config-files ${KERNEL_TEST_PACKAGE_VERSION}, expected installed ${KERNEL_TEST_PACKAGE_VERSION}"
}

@test "kernel verifier rejects a running kernel from another build of the same release" {
  write_kernel_verify_fixture
  run_kernel_verify FAKE_UNAME_R="$KERNEL_TEST_RELEASE" FAKE_DPKG_VERSION="$KERNEL_TEST_PACKAGE_VERSION" \
    FAKE_UNAME_V='#1 SMP PREEMPT Debian 1:6.18.50-1+rpt1+btf2 (2026-09-20)'
  assert_failure
  assert_output_contains "is not ${KERNEL_TEST_PACKAGE_VERSION}"

  # +btf10 starts with +btf1: the version must end at the " (" delimiter.
  run_kernel_verify FAKE_UNAME_R="$KERNEL_TEST_RELEASE" FAKE_DPKG_VERSION="$KERNEL_TEST_PACKAGE_VERSION" \
    FAKE_UNAME_V='#1 SMP PREEMPT Debian 1:6.18.50-1+rpt1+btf10 (2026-09-20)'
  assert_failure
  assert_output_contains "is not ${KERNEL_TEST_PACKAGE_VERSION}"

  run_kernel_verify FAKE_UNAME_R="$KERNEL_TEST_RELEASE" FAKE_DPKG_VERSION="$KERNEL_TEST_PACKAGE_VERSION" \
    FAKE_UNAME_V="#1 SMP PREEMPT Debian ${KERNEL_TEST_SOURCE_VERSION} (2026-09-11)"
  assert_failure
  assert_output_contains "is not ${KERNEL_TEST_PACKAGE_VERSION}"
}

# --- kernel update node tool -------------------------------------------------

# setup_kernel_node builds the default fake node and the package directory of
# the next build, and sets node, boot, fallback and pkgdir for the test body.
setup_kernel_node() {
  node="${tmp}/node"
  boot="${node}/boot/firmware"
  fallback="${boot}/home-ops-kernel-prev"
  pkgdir="${tmp}/packages"
  create_fake_kernel_node "$node" "$KERNEL_TEST_RELEASE" "$KERNEL_TEST_PACKAGE_VERSION" "$KERNEL_TEST_BUILD_ID"
  create_fake_kernel_package_dir "$pkgdir" "$KERNEL_TEST_RELEASE" \
    "$KERNEL_TEST_NEXT_PACKAGE_VERSION" "$KERNEL_TEST_NEXT_BUILD_ID"
}

@test "kernel update status reports a clean node" {
  local boot_set
  setup_kernel_node
  run_kernel_node status
  assert_success
  assert_output_contains 'state=S0'
  assert_output_contains 'running_matches=marker'
  assert_output_contains 'booted_via_fallback=no'
  assert_output_contains 'holds=4'
  assert_output_contains 'fallback_copy=no'
  assert_output_contains 'tryboot_present=no'
  assert_output_contains 'reimage_staged=no'
  assert_output_contains 'trial_pending=no'
  assert_output_contains 'config_fallback_block=no'
  assert_output_contains "running_release=${KERNEL_TEST_RELEASE}"
  assert_output_contains "marker_build_id=${KERNEL_TEST_BUILD_ID}"
  assert_output_contains "marker_version=${KERNEL_TEST_PACKAGE_VERSION}"
  assert_output_contains "installed_version=${KERNEL_TEST_PACKAGE_VERSION}"
  boot_set=$(($(kernel_test_size "${boot}/kernel_2712.img") + $(kernel_test_size "${boot}/initramfs_2712")))
  assert_output_contains "boot_set_bytes=${boot_set}"
}

@test "kernel update prepare refuses an unverified running kernel" {
  setup_kernel_node
  fake_node_set_running "$KERNEL_TEST_RELEASE" "$KERNEL_TEST_SOURCE_VERSION"
  run_kernel_node prepare
  assert_failure
  assert_output_contains 'refusing to update from an unverified state'
  [[ ! -d "$fallback" ]]
}

@test "kernel update prepare refuses a staged reimage, a foreign boot set, a full boot partition, and unheld packages" {
  setup_kernel_node

  mkdir -p "${boot}/home-ops-reimage"
  run_kernel_node prepare
  assert_failure
  assert_output_contains 'a reimage or another kernel update is staged'
  rmdir "${boot}/home-ops-reimage"

  head -c 4096 /dev/urandom >"${boot}/kernel_2712.img"
  run_kernel_node prepare
  assert_failure
  assert_output_contains 'root-level boot set is not the running kernel'
  # stage repeats the check: the host flow can reach it without prepare.
  run_kernel_node stage "$pkgdir"
  assert_failure
  assert_output_contains 'root-level boot set is not the running kernel'
  [[ ! -d "$fallback" ]]
  cp "${node}/boot/vmlinuz-${KERNEL_TEST_RELEASE}" "${boot}/kernel_2712.img"

  # need = kernel (4096) + initramfs (8192) + 4 MiB headroom.
  run_kernel_node FAKE_BOOT_FREE_BYTES=1000 prepare
  assert_failure
  assert_output_contains 'not enough space in'
  assert_output_contains 'free=1000'
  assert_output_contains "need=$((4096 + 8192 + 4 * 1024 * 1024))"

  awk '$1 == "linux-base-rpi-2712" { $3 = "install" } { print }' "${node}/dpkg.state" >"${node}/dpkg.state.new"
  mv "${node}/dpkg.state.new" "${node}/dpkg.state"
  run_kernel_node prepare
  assert_failure
  assert_output_contains "the four kernel packages for ${KERNEL_TEST_RELEASE} are not all held"
}

@test "kernel update stage appends missing cmdline args to the trial line only" {
  setup_kernel_node
  run_kernel_node prepare --cmdline-arg panic=30
  assert_failure
  assert_output_contains 'unknown prepare argument: --cmdline-arg'

  run_kernel_node prepare
  assert_success
  run_kernel_node stage "$pkgdir" --cmdline-arg panic=30 --cmdline-arg cgroup_memory=1
  assert_success
  assert_output_contains 'cmdline_added=panic=30'
  assert_output_not_contains 'cmdline_added=cgroup_memory=1'
  [[ "$(sed -n '1p' "${boot}/cmdline.txt")" == "${KERNEL_TEST_NODE_CMDLINE} panic=30" ]]
  [[ "$(wc -l <"${boot}/cmdline.txt" | tr -d ' ')" == 1 ]]
  # The fallback boots the pre-update line, so a newly requested argument must
  # only ever reach the trial.
  [[ "$(cat "${fallback}/cmdline.txt")" == "${KERNEL_TEST_NODE_CMDLINE} home_ops_kernel_fallback=1" ]]
  assert_file_not_contains "${fallback}/cmdline.txt" 'panic=30'
  cp "${fallback}/cmdline.txt" "${tmp}/fallback-cmdline"

  run_kernel_node stage "$pkgdir" --cmdline-arg panic=30
  assert_success
  assert_output_not_contains 'cmdline_added='
  [[ "$(sed -n '1p' "${boot}/cmdline.txt")" == "${KERNEL_TEST_NODE_CMDLINE} panic=30" ]]
  [[ "$(wc -l <"${boot}/cmdline.txt" | tr -d ' ')" == 1 ]]
  cmp "${tmp}/fallback-cmdline" "${fallback}/cmdline.txt"
}

@test "kernel update stage creates the fallback, installs, and updates the marker" {
  local deb_args expected_debs
  setup_kernel_node
  cp "${boot}/kernel_2712.img" "${tmp}/pre-kernel.img"
  cp "${boot}/initramfs_2712" "${tmp}/pre-initramfs"
  cp "${boot}/config.txt" "${tmp}/pre-config.txt"

  run_kernel_node prepare
  assert_success
  run_kernel_node stage "$pkgdir"
  assert_success
  assert_output_contains 'stage=ok'
  assert_output_contains "staged_build_id=${KERNEL_TEST_NEXT_BUILD_ID}"
  assert_output_contains "staged_version=${KERNEL_TEST_NEXT_PACKAGE_VERSION}"

  cmp "${tmp}/pre-kernel.img" "${fallback}/kernel_2712.img"
  cmp "${tmp}/pre-initramfs" "${fallback}/initramfs_2712"
  cmp "${tmp}/pre-config.txt" "${fallback}/config.txt.orig"
  assert_file_contains "${fallback}/META" "KERNEL_BUILD_ID=${KERNEL_TEST_BUILD_ID}"
  assert_file_contains "${fallback}/META" "KERNEL_PACKAGE_VERSION=${KERNEL_TEST_PACKAGE_VERSION}"
  assert_file_contains "${fallback}/META" "KERNEL_RELEASE=${KERNEL_TEST_RELEASE}"
  assert_file_contains "${fallback}/META" "KERNEL_SHA256=$(kernel_test_sha256 "${tmp}/pre-kernel.img")"
  assert_file_contains "${fallback}/META" "INITRAMFS_SHA256=$(kernel_test_sha256 "${tmp}/pre-initramfs")"
  assert_file_contains "${fallback}/META" "CONFIG_SHA256=$(kernel_test_sha256 "${tmp}/pre-config.txt")"
  [[ "$(cat "${fallback}/cmdline.txt")" == "${KERNEL_TEST_NODE_CMDLINE} home_ops_kernel_fallback=1" ]]
  [[ "$(cat "${fallback}/TRIAL")" == "$KERNEL_TEST_NEXT_BUILD_ID" ]]

  cat >"${tmp}/expected-block" <<'EOF'
# BEGIN home-ops kernel fallback (home-ops-kernel-update)
[all]
kernel=home-ops-kernel-prev/kernel_2712.img
initramfs home-ops-kernel-prev/initramfs_2712 followkernel
cmdline=home-ops-kernel-prev/cmdline.txt
# END home-ops kernel fallback (home-ops-kernel-update)
EOF
  diff "${tmp}/expected-block" <(tail -6 "${boot}/config.txt")
  cmp "${boot}/tryboot.txt" "${fallback}/config.txt.orig"

  [[ "$(wc -l <"${node}/apt-mark.log" | tr -d ' ')" == 2 ]]
  [[ "$(sed -n '1p' "${node}/apt-mark.log")" == "unhold linux-image-${KERNEL_TEST_RELEASE} linux-base-${KERNEL_TEST_RELEASE} linux-image-rpi-2712 linux-base-rpi-2712" ]]
  [[ "$(sed -n '2p' "${node}/apt-mark.log")" == "hold linux-image-${KERNEL_TEST_RELEASE} linux-base-${KERNEL_TEST_RELEASE} linux-image-rpi-2712 linux-base-rpi-2712" ]]
  # The order is asserted deliberately: it catches a duplicated package and a
  # dropped ./ prefix, both of which apt would otherwise resolve from the index.
  deb_args="$(grep -o -- '\./[^ ]*_arm64\.deb' "${node}/apt-get.log" | tr '\n' ' ')"
  expected_debs="./linux-image-${KERNEL_TEST_RELEASE}_${KERNEL_TEST_NEXT_DEB_VERSION}_arm64.deb "
  expected_debs+="./linux-base-${KERNEL_TEST_RELEASE}_${KERNEL_TEST_NEXT_DEB_VERSION}_arm64.deb "
  expected_debs+="./linux-image-rpi-2712_${KERNEL_TEST_NEXT_DEB_VERSION}_arm64.deb "
  expected_debs+="./linux-base-rpi-2712_${KERNEL_TEST_NEXT_DEB_VERSION}_arm64.deb "
  [[ "$deb_args" == "$expected_debs" ]]

  assert_file_contains "${node}/dpkg.state" "linux-image-${KERNEL_TEST_RELEASE} installed hold ${KERNEL_TEST_NEXT_PACKAGE_VERSION}"
  cmp "${boot}/kernel_2712.img" "${node}/boot/vmlinuz-${KERNEL_TEST_RELEASE}"
  cmp "${boot}/initramfs_2712" "${node}/boot/initrd.img-${KERNEL_TEST_RELEASE}"
  assert_file_contains "${node}/etc/home-ops/kernel-build" "KERNEL_BUILD_ID=${KERNEL_TEST_NEXT_BUILD_ID}"
  assert_file_contains "${node}/etc/home-ops/kernel-build" "KERNEL_PACKAGE_VERSION=${KERNEL_TEST_NEXT_PACKAGE_VERSION}"
  assert_file_contains "${node}/etc/home-ops/kernel-build" "KERNEL_RELEASE=${KERNEL_TEST_RELEASE}"
  assert_file_contains "${node}/etc/home-ops/kernel-build" "KERNEL_CONFIG_DELTA_SHA256=${KERNEL_TEST_DELTA_SHA256}"

  run_kernel_node status
  assert_success
  assert_output_contains 'state=S2'
  assert_output_contains 'running_matches=fallback'
  assert_output_contains 'booted_via_fallback=no'
  assert_output_contains 'trial_pending=yes'
  assert_output_contains 'fallback_copy=yes'
  assert_output_contains "fallback_build_id=${KERNEL_TEST_BUILD_ID}"

  fake_node_boot_trial "$node"
  fake_node_set_running "$KERNEL_TEST_RELEASE" "$KERNEL_TEST_NEXT_PACKAGE_VERSION"
  run_kernel_node status
  assert_success
  assert_output_contains 'state=S1'
  assert_output_contains 'running_matches=marker'
  assert_output_contains 'booted_via_fallback=no'

  fake_node_boot_fallback "$node"
  fake_node_set_running "$KERNEL_TEST_RELEASE" "$KERNEL_TEST_PACKAGE_VERSION"
  run_kernel_node status
  assert_success
  assert_output_contains 'state=S2'
  assert_output_contains 'booted_via_fallback=yes'
  assert_output_contains 'running_matches=fallback'
}

@test "kernel update stage refuses bad checksums, extra packages, and re-holds after an install failure" {
  local retry_dir decoy retry_version='1:6.18.50-1+rpt1+btf3' retry_id='6.18.50-1-rpt1-btf3'
  setup_kernel_node
  retry_dir="${tmp}/packages-retry"
  run_kernel_node prepare
  assert_success

  head -c 512 /dev/urandom >"${pkgdir}/linux-base-rpi-2712_${KERNEL_TEST_NEXT_DEB_VERSION}_arm64.deb"
  run_kernel_node stage "$pkgdir"
  assert_failure
  assert_output_contains 'package checksum mismatch'
  [[ ! -d "$fallback" ]]
  [[ ! -f "${node}/apt-get.log" ]]

  create_fake_kernel_package_dir "$pkgdir" "$KERNEL_TEST_RELEASE" \
    "$KERNEL_TEST_NEXT_PACKAGE_VERSION" "$KERNEL_TEST_NEXT_BUILD_ID"
  head -c 512 /dev/urandom >"${pkgdir}/linux-image-9.9.9+rpt-rpi-2712_9.9.9-1_arm64.deb"
  run_kernel_node stage "$pkgdir"
  assert_failure
  assert_output_contains 'must hold exactly the four'
  [[ ! -d "$fallback" ]]
  [[ ! -f "${node}/apt-get.log" ]]

  create_fake_kernel_package_dir "$pkgdir" "$KERNEL_TEST_RELEASE" \
    "$KERNEL_TEST_NEXT_PACKAGE_VERSION" "$KERNEL_TEST_NEXT_BUILD_ID"
  grep -v "linux-base-rpi-2712_${KERNEL_TEST_NEXT_DEB_VERSION}_arm64.deb\$" "${pkgdir}/SHA256SUMS" >"${pkgdir}/SHA256SUMS.new"
  mv "${pkgdir}/SHA256SUMS.new" "${pkgdir}/SHA256SUMS"
  run_kernel_node stage "$pkgdir"
  assert_failure
  assert_output_contains "SHA256SUMS does not cover linux-base-rpi-2712_${KERNEL_TEST_NEXT_DEB_VERSION}_arm64.deb"
  [[ ! -d "$fallback" ]]
  [[ ! -f "${node}/apt-get.log" ]]

  # A name that merely prefixes another listed name is not coverage.
  create_fake_kernel_package_dir "$pkgdir" "$KERNEL_TEST_RELEASE" \
    "$KERNEL_TEST_NEXT_PACKAGE_VERSION" "$KERNEL_TEST_NEXT_BUILD_ID"
  decoy="linux-base-rpi-2712_${KERNEL_TEST_NEXT_DEB_VERSION}_arm64.deb"
  printf 'signature\n' >"${pkgdir}/${decoy}.sig"
  grep -v "  ${decoy}\$" "${pkgdir}/SHA256SUMS" >"${pkgdir}/SHA256SUMS.new"
  printf '%s  %s.sig\n' "$(kernel_test_sha256 "${pkgdir}/${decoy}.sig")" "$decoy" >>"${pkgdir}/SHA256SUMS.new"
  mv "${pkgdir}/SHA256SUMS.new" "${pkgdir}/SHA256SUMS"
  run_kernel_node stage "$pkgdir"
  assert_failure
  assert_output_contains "SHA256SUMS does not cover ${decoy}"
  [[ ! -d "$fallback" ]]
  [[ ! -f "${node}/apt-get.log" ]]

  # A failed retry of an already trialled node must leave the fallback armed,
  # the packages held, the marker alone, and no TRIAL claiming a trial that
  # never happened.
  create_fake_kernel_package_dir "$pkgdir" "$KERNEL_TEST_RELEASE" \
    "$KERNEL_TEST_NEXT_PACKAGE_VERSION" "$KERNEL_TEST_NEXT_BUILD_ID"
  run_kernel_node stage "$pkgdir"
  assert_success
  [[ "$(cat "${fallback}/TRIAL")" == "$KERNEL_TEST_NEXT_BUILD_ID" ]]

  create_fake_kernel_package_dir "$retry_dir" "$KERNEL_TEST_RELEASE" "$retry_version" "$retry_id"
  run_kernel_node FAKE_APT_FAIL=1 stage "$retry_dir"
  assert_failure
  assert_output_contains 'kernel package install failed'
  [[ "$(grep -c ' hold ' "${node}/dpkg.state")" == 4 ]]
  assert_file_contains "${node}/dpkg.state" "linux-image-${KERNEL_TEST_RELEASE} installed hold ${KERNEL_TEST_NEXT_PACKAGE_VERSION}"
  assert_file_contains "${node}/etc/home-ops/kernel-build" "KERNEL_BUILD_ID=${KERNEL_TEST_NEXT_BUILD_ID}"
  assert_file_not_contains "${node}/etc/home-ops/kernel-build" "KERNEL_BUILD_ID=${retry_id}"
  [[ -d "$fallback" ]]
  [[ ! -f "${fallback}/TRIAL" ]]
  assert_file_contains "${boot}/config.txt" 'kernel=home-ops-kernel-prev/kernel_2712.img'
  cmp "${boot}/tryboot.txt" "${fallback}/config.txt.orig"
  run_kernel_node status
  assert_success
  assert_output_contains 'state=S2'
  assert_output_contains 'trial_pending=no'
}

@test "kernel update stage detects hooks that did not update the boot set" {
  setup_kernel_node
  run_kernel_node prepare
  assert_success
  run_kernel_node FAKE_APT_SKIP_HOOKS=1 stage "$pkgdir"
  assert_failure
  assert_output_contains 'kernel hooks did not update the boot set'
  assert_file_contains "${node}/etc/home-ops/kernel-build" "KERNEL_BUILD_ID=${KERNEL_TEST_BUILD_ID}"
  [[ ! -f "${fallback}/TRIAL" ]]
}

@test "kernel update stage retries from a fallen-back node, recreates a missing tryboot.txt, and refuses a pending trial" {
  local third_dir='' third_version='1:6.18.50-1+rpt1+btf3' third_id='6.18.50-1-rpt1-btf3'
  setup_kernel_node
  third_dir="${tmp}/packages-third"
  run_kernel_node prepare
  assert_success
  run_kernel_node stage "$pkgdir"
  assert_success
  cp "${fallback}/META" "${tmp}/meta-after-first-stage"
  rm "${boot}/tryboot.txt"

  create_fake_kernel_package_dir "$third_dir" "$KERNEL_TEST_RELEASE" "$third_version" "$third_id"
  run_kernel_node prepare
  assert_success
  assert_output_contains 'prepare_state=S2'
  run_kernel_node stage "$third_dir"
  assert_success
  assert_output_contains "staged_build_id=${third_id}"
  cmp "${tmp}/meta-after-first-stage" "${fallback}/META"
  [[ "$(grep -c 'BEGIN home-ops kernel fallback' "${boot}/config.txt")" == 1 ]]
  cmp "${boot}/tryboot.txt" "${fallback}/config.txt.orig"
  [[ "$(cat "${fallback}/TRIAL")" == "$third_id" ]]

  fake_node_boot_trial "$node"
  fake_node_set_running "$KERNEL_TEST_RELEASE" "$third_version"
  run_kernel_node status
  assert_success
  assert_output_contains 'state=S1'
  run_kernel_node stage "$third_dir"
  assert_failure
  assert_output_contains 'a trial is pending'
}

@test "kernel update commit strips the block, removes the fallback, and purges an old release" {
  local bump_node bump_pkgs fail_node
  local bump_release='6.18.60+rpt-rpi-2712' bump_version='1:6.18.60-1+rpt1+btf1' bump_id='6.18.60-1-rpt1-btf1'
  setup_kernel_node
  cp "${boot}/config.txt" "${tmp}/pre-config.txt"
  run_kernel_node prepare
  assert_success
  run_kernel_node stage "$pkgdir"
  assert_success
  fake_node_boot_trial "$node"
  fake_node_set_running "$KERNEL_TEST_RELEASE" "$KERNEL_TEST_NEXT_PACKAGE_VERSION"
  run_kernel_node commit
  assert_success
  assert_output_contains 'commit=ok'
  assert_output_not_contains 'config_changed_during_update'
  assert_output_not_contains 'purge_failed'
  cmp "${tmp}/pre-config.txt" "${boot}/config.txt"
  [[ ! -e "${boot}/tryboot.txt" ]]
  [[ ! -d "$fallback" ]]
  assert_file_not_contains "${node}/apt-get.log" 'purge'

  bump_node="${tmp}/node-bump"
  bump_pkgs="${tmp}/packages-bump"
  create_fake_kernel_node "$bump_node" "$KERNEL_TEST_RELEASE" "$KERNEL_TEST_PACKAGE_VERSION" "$KERNEL_TEST_BUILD_ID"
  create_fake_kernel_package_dir "$bump_pkgs" "$bump_release" "$bump_version" "$bump_id"
  run_kernel_node prepare
  assert_success
  run_kernel_node stage "$bump_pkgs"
  assert_success
  fake_node_boot_trial "$bump_node"
  fake_node_set_running "$bump_release" "$bump_version"
  # Split streams: apt's purge chatter must not reach the tool's own stdout.
  run_kernel_node_split commit
  assert_file_contains "${tmp}/stdout" 'commit=ok'
  assert_kernel_node_stdout_clean "${tmp}/stdout"
  assert_file_contains "${tmp}/stderr" 'Removing linux-image'
  assert_file_contains "${bump_node}/apt-get.log" "purge linux-image-${KERNEL_TEST_RELEASE} linux-base-${KERNEL_TEST_RELEASE}"
  # Install and purge alike must run non-interactively.
  [[ "$(grep -c '^NEEDRESTART_MODE=l DEBIAN_FRONTEND=noninteractive$' "${bump_node}/apt-get.env.log")" == 2 ]]
  assert_file_not_contains "${bump_node}/dpkg.state" "linux-image-${KERNEL_TEST_RELEASE} "
  assert_file_not_contains "${bump_node}/dpkg.state" "linux-base-${KERNEL_TEST_RELEASE} "
  assert_file_contains "${bump_node}/dpkg.state" "linux-image-${bump_release} installed hold ${bump_version}"

  fail_node="${tmp}/node-purge-fail"
  create_fake_kernel_node "$fail_node" "$KERNEL_TEST_RELEASE" "$KERNEL_TEST_PACKAGE_VERSION" "$KERNEL_TEST_BUILD_ID"
  run_kernel_node prepare
  assert_success
  run_kernel_node stage "$bump_pkgs"
  assert_success
  fake_node_boot_trial "$fail_node"
  fake_node_set_running "$bump_release" "$bump_version"
  run_kernel_node FAKE_APT_PURGE_FAIL=1 commit
  assert_success
  assert_output_contains 'commit=ok'
  assert_output_contains "purge_failed=linux-image-${KERNEL_TEST_RELEASE}"
  [[ ! -d "${fail_node}/boot/firmware/home-ops-kernel-prev" ]]
  [[ ! -e "${fail_node}/boot/firmware/tryboot.txt" ]]
  assert_file_not_contains "${fail_node}/boot/firmware/config.txt" 'BEGIN home-ops kernel fallback'
}

@test "kernel update commit refuses a node that fell back or failed verification" {
  setup_kernel_node
  run_kernel_node prepare
  assert_success
  run_kernel_node stage "$pkgdir"
  assert_success

  fake_node_boot_fallback "$node"
  run_kernel_node commit
  assert_failure
  assert_output_contains 'node is in state S2; commit needs a booted, uncommitted trial (S1)'
  assert_file_contains "${boot}/config.txt" 'BEGIN home-ops kernel fallback'
  [[ -f "${boot}/tryboot.txt" ]]

  fake_node_boot_trial "$node"
  fake_node_set_running "$KERNEL_TEST_RELEASE" "$KERNEL_TEST_NEXT_PACKAGE_VERSION"
  run_kernel_node FAKE_VERIFY_FAIL=1 commit
  assert_failure
  assert_output_contains 'kernel verification failed; do not commit'
  assert_file_contains "${boot}/config.txt" 'BEGIN home-ops kernel fallback'
  [[ -f "${boot}/tryboot.txt" ]]
  [[ -d "$fallback" ]]
}

@test "kernel update commit keeps a config.txt edited during the trial" {
  setup_kernel_node
  run_kernel_node prepare
  assert_success
  run_kernel_node stage "$pkgdir"
  assert_success
  printf 'dtparam=i2c_arm=on\n' >>"${boot}/config.txt"
  fake_node_boot_trial "$node"
  fake_node_set_running "$KERNEL_TEST_RELEASE" "$KERNEL_TEST_NEXT_PACKAGE_VERSION"
  run_kernel_node commit
  assert_success
  assert_output_contains 'config_changed_during_update=yes'
  assert_output_contains 'commit=ok'
  assert_file_contains "${boot}/config.txt" 'dtparam=i2c_arm=on'
  assert_file_contains "${boot}/config.txt" 'BEGIN ANSIBLE MANAGED BLOCK home-ops raspberry pi config'
  assert_file_not_contains "${boot}/config.txt" 'home-ops kernel fallback'
  assert_file_not_contains "${boot}/config.txt" 'home-ops-kernel-prev'
}

@test "kernel update status flags a firmware that honoured cmdline but not kernel" {
  setup_kernel_node
  run_kernel_node prepare
  assert_success
  run_kernel_node stage "$pkgdir"
  assert_success
  fake_node_boot_fallback "$node"
  fake_node_set_running "$KERNEL_TEST_RELEASE" "$KERNEL_TEST_NEXT_PACKAGE_VERSION"
  run_kernel_node status
  assert_success
  assert_output_contains 'running_matches=marker'
  assert_output_contains 'booted_via_fallback=yes'
  assert_output_contains 'state=S3'
}

@test "kernel update fallback block uses the fallback directory name" {
  local other_node other_boot
  setup_kernel_node
  run_kernel_node "HOME_OPS_KERNEL_FALLBACK_DIR=${boot}/other-prev" prepare
  assert_success
  run_kernel_node "HOME_OPS_KERNEL_FALLBACK_DIR=${boot}/other-prev" stage "$pkgdir"
  assert_success
  [[ "$(grep -c 'other-prev/' "${boot}/config.txt")" == 3 ]]
  assert_file_contains "${boot}/config.txt" 'kernel=other-prev/kernel_2712.img'
  assert_file_contains "${boot}/config.txt" 'initramfs other-prev/initramfs_2712 followkernel'
  assert_file_contains "${boot}/config.txt" 'cmdline=other-prev/cmdline.txt'
  assert_file_not_contains "${boot}/config.txt" 'home-ops-kernel-prev'

  other_node="${tmp}/node-outside"
  other_boot="${other_node}/boot/firmware"
  create_fake_kernel_node "$other_node" "$KERNEL_TEST_RELEASE" "$KERNEL_TEST_PACKAGE_VERSION" "$KERNEL_TEST_BUILD_ID"
  run_kernel_node "HOME_OPS_KERNEL_FALLBACK_DIR=${tmp}/outside-prev" stage "$pkgdir"
  assert_failure
  assert_output_contains "fallback dir must be directly under ${other_boot}"
  assert_file_not_contains "${other_boot}/config.txt" 'home-ops kernel fallback'
  [[ ! -e "${tmp}/outside-prev" ]]
}

@test "kernel update refuses missing or empty boot files before touching anything" {
  setup_kernel_node

  : >"${boot}/cmdline.txt"
  run_kernel_node prepare
  assert_failure
  assert_output_contains "missing ${boot}/cmdline.txt; is ${boot} mounted?"
  run_kernel_node stage "$pkgdir"
  assert_failure
  assert_output_contains "missing ${boot}/cmdline.txt; is ${boot} mounted?"
  [[ ! -d "$fallback" ]]
  [[ ! -e "${boot}/tryboot.txt" ]]
  [[ ! -f "${node}/apt-get.log" ]]
  [[ "$(kernel_test_size "${boot}/cmdline.txt")" == 0 ]]

  printf '%s\n' "$KERNEL_TEST_NODE_CMDLINE" >"${boot}/cmdline.txt"
  rm "${boot}/config.txt"
  run_kernel_node prepare
  assert_failure
  assert_output_contains "missing ${boot}/config.txt; is ${boot} mounted?"
  run_kernel_node stage "$pkgdir"
  assert_failure
  assert_output_contains "missing ${boot}/config.txt; is ${boot} mounted?"
  [[ ! -d "$fallback" ]]
  [[ ! -e "${boot}/tryboot.txt" ]]
  [[ ! -f "${node}/apt-get.log" ]]

  run_kernel_node status
  assert_success
  assert_output_contains 'boot_files_present=no'
}

@test "kernel update commits a rollback to the build the fallback holds" {
  local rollback
  setup_kernel_node
  rollback="${tmp}/packages-rollback"
  cp "${boot}/config.txt" "${tmp}/pre-config.txt"
  run_kernel_node prepare
  assert_success
  run_kernel_node stage "$pkgdir"
  assert_success

  fake_node_boot_fallback "$node"
  run_kernel_node status
  assert_success
  assert_output_contains 'state=S2'
  assert_output_contains 'booted_via_fallback=yes'
  assert_output_contains 'running_matches=fallback'

  create_fake_kernel_package_dir "$rollback" "$KERNEL_TEST_RELEASE" \
    "$KERNEL_TEST_PACKAGE_VERSION" "$KERNEL_TEST_BUILD_ID"
  run_kernel_node prepare
  assert_success
  assert_output_contains 'prepare_state=S2'
  run_kernel_node stage "$rollback"
  assert_success
  assert_output_contains "staged_build_id=${KERNEL_TEST_BUILD_ID}"

  fake_node_boot_trial "$node"
  run_kernel_node status
  assert_success
  assert_output_contains 'trial_pending=yes'
  assert_output_contains 'booted_via_fallback=no'
  assert_output_contains 'running_matches=marker'
  assert_output_contains 'state=S1'

  run_kernel_node commit
  assert_success
  assert_output_contains 'commit=ok'
  [[ ! -e "${boot}/tryboot.txt" ]]
  [[ ! -d "$fallback" ]]
  cmp "${tmp}/pre-config.txt" "${boot}/config.txt"
}

@test "kernel update fallback copy with a corrupted image is refused" {
  setup_kernel_node
  run_kernel_node prepare
  assert_success
  run_kernel_node stage "$pkgdir"
  assert_success

  printf 'corrupt' >>"${fallback}/kernel_2712.img"
  run_kernel_node status
  assert_success
  assert_output_contains 'fallback_copy=partial'
  assert_output_contains 'state=S3'

  run_kernel_node stage "$pkgdir"
  assert_failure
  assert_output_contains 'node is in state S3'
  run_kernel_node prepare
  assert_failure
  assert_output_contains 'node is in state S3 (tryboot_present=yes, reimage_staged=no)'
  run_kernel_node commit
  assert_failure
  assert_output_contains 'node is in state S3; commit needs a booted, uncommitted trial (S1)'
}

@test "kernel update stage refuses a tryboot.txt that is not the fallback config" {
  setup_kernel_node
  run_kernel_node prepare
  assert_success
  run_kernel_node stage "$pkgdir"
  assert_success
  cp "${boot}/config.txt" "${tmp}/config-after-stage"

  printf 'kernel=somebody-elses-image.img\n' >"${boot}/tryboot.txt"
  run_kernel_node stage "$pkgdir"
  assert_failure
  assert_output_contains 'tryboot.txt differs from the fallback copy'
  cmp "${tmp}/config-after-stage" "${boot}/config.txt"
}

@test "kernel update commit does not flag a config.txt that ends in a blank line" {
  setup_kernel_node
  printf '\n' >>"${boot}/config.txt"
  run_kernel_node prepare
  assert_success
  run_kernel_node stage "$pkgdir"
  assert_success
  cp "${fallback}/config.txt.orig" "${tmp}/orig-snapshot"

  fake_node_boot_trial "$node"
  fake_node_set_running "$KERNEL_TEST_RELEASE" "$KERNEL_TEST_NEXT_PACKAGE_VERSION"
  run_kernel_node commit
  assert_success
  assert_output_contains 'commit=ok'
  assert_output_not_contains 'config_changed_during_update'
  cmp "${tmp}/orig-snapshot" "${boot}/config.txt"
  [[ "$(tail -c 2 "${boot}/config.txt" | od -An -tx1 | tr -d ' \n')" != '0a0a' ]]
}

@test "kernel update stage keeps stdout to key=value lines" {
  setup_kernel_node
  run_kernel_node prepare
  assert_success
  run_kernel_node_split stage "$pkgdir" --cmdline-arg panic=30
  assert_file_contains "${tmp}/stdout" 'stage=ok'
  assert_file_contains "${tmp}/stdout" 'cmdline_added=panic=30'
  # apt's progress belongs on stderr, so the host side can parse stdout.
  assert_kernel_node_stdout_clean "${tmp}/stdout"
  assert_file_contains "${tmp}/stderr" 'Selecting previously unselected package'
  assert_file_contains "${tmp}/stderr" '[1,234 kB]'
}

@test "kernel update prepare refuses a pending trial" {
  setup_kernel_node
  run_kernel_node prepare
  assert_success
  run_kernel_node stage "$pkgdir"
  assert_success
  fake_node_boot_trial "$node"
  fake_node_set_running "$KERNEL_TEST_RELEASE" "$KERNEL_TEST_NEXT_PACKAGE_VERSION"
  run_kernel_node status
  assert_success
  assert_output_contains 'state=S1'

  run_kernel_node prepare
  assert_failure
  assert_output_contains 'node is in state S1; a trial is pending: run the host flow with --resume to commit it, or reboot to fall back'
}
