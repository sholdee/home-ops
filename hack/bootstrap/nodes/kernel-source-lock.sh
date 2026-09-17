#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/kernel-source-lock.sh [options]

Verify the Raspberry Pi archive InRelease signature, follow its SHA256 index to
the source Sources.gz, and pin the current linux source package (version and
file hashes) for just node-kernel-build.

Options:
  --keyring FILE         Keyring that signs the archive. Defaults to
                         ../rpi-image-gen/keydir/raspberrypi-archive-keyring.gpg.
  --build-suffix SUFFIX  Package version suffix +btfN for the rebuild, such as
                         +btf2. For an unchanged source version, N must be
                         greater than the current lock's suffix. Defaults to
                         the current lock's suffix when the source version is
                         unchanged, otherwise +btf1.
  --output FILE          Lock file. Defaults to hack/bootstrap/nodes/kernel/source.yaml.
  -h, --help             Show help.
EOF
}

keyring="$(node_reimage_default_rpi_image_gen_dir)/keydir/raspberrypi-archive-keyring.gpg"
build_suffix=""
output="$NODE_KERNEL_SOURCE_LOCK"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keyring)
      keyring="${2:?missing value for --keyring}"
      shift 2
      ;;
    --build-suffix)
      build_suffix="${2:?missing value for --build-suffix}"
      shift 2
      ;;
    --output)
      output="${2:?missing value for --output}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      node_die "unknown argument: $1"
      ;;
  esac
done

node_require_tool "$NODE_CURL_BIN"
node_require_tool "$NODE_GPGV_BIN"
node_require_tool "$NODE_JQ_BIN"
node_require_tool "$NODE_YQ_BIN"
node_require_tool gzip
[[ -f "$keyring" ]] || node_die "archive keyring not found: ${keyring}"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

node_kernel_lock_source "$keyring" "$work_dir" "$output" "$build_suffix"
