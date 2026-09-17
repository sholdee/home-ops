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
