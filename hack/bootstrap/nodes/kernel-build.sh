#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/kernel-build.sh [options]

Rebuild the Raspberry Pi OS kernel source package pinned in
hack/bootstrap/nodes/kernel/source.yaml with kernel/config.2712.delta, and
record the packages under .out/kernel/<build-id>/ for node-reimage-build.

Options:
  --builder-mode MODE  auto, lima, or local. Defaults to auto (lima on macOS).
  --builder-name NAME  Lima builder name. Defaults to home-ops-rpi-image-builder.
  --jobs N             Parallel build jobs. Defaults to the builder CPU count.
  --force              Rebuild even when a verified build for the committed
                       inputs already exists.
  -h, --help           Show help.

A build that matches the committed source lock and config delta, with package
hashes intact, is reused without starting the builder.
EOF
}

builder_mode="$NODE_REIMAGE_BUILDER_MODE"
builder_name="$NODE_REIMAGE_BUILDER_NAME"
jobs=""
force=false
jobs_re='^[1-9][0-9]*$'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --builder-mode)
      builder_mode="${2:?missing value for --builder-mode}"
      shift 2
      ;;
    --builder-name)
      builder_name="${2:?missing value for --builder-name}"
      shift 2
      ;;
    --jobs)
      jobs="${2:?missing value for --jobs}"
      shift 2
      ;;
    --force)
      force=true
      shift
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

[[ -z "$jobs" || "$jobs" =~ $jobs_re ]] || node_die "--jobs must be a positive integer: ${jobs}"
node_require_tool "$NODE_YQ_BIN"
node_require_tool "$NODE_JQ_BIN"
builder_mode="$(node_reimage_builder_effective_mode "$builder_mode")"
node_kernel_require_inputs

build_id="$(node_kernel_current_build_id)"
build_dir="$(node_kernel_build_dir "$build_id")"
state_file="${build_dir}/state/kernel-build.json"
node_kernel_guard_build_reuse "$state_file" "$build_id"
if [[ "$force" != true && -f "$state_file" ]]; then
  if existing_state="$(node_kernel_require_current_build)"; then
    node_log "kernel build ${build_id} already exists and matches the committed inputs; use --force to rebuild"
    printf 'kernel_build_id=%s\n' "$build_id"
    printf 'kernel_package_version=%s\n' "$(node_kernel_package_version)"
    printf 'kernel_build_state=%s\n' "$existing_state"
    exit 0
  fi
  node_warn "existing kernel build ${build_id} does not verify against the committed inputs; rebuilding"
fi

if [[ "$builder_mode" == lima ]]; then
  node_reimage_start_lima_builder "$builder_name"
  if [[ -z "$jobs" ]]; then
    jobs="$(limactl shell --tty=false "$builder_name" -- getconf _NPROCESSORS_ONLN)" ||
      node_die "could not read the CPU count from Lima builder ${builder_name}"
  fi
elif [[ -z "$jobs" ]]; then
  jobs="$(getconf _NPROCESSORS_ONLN)"
fi
[[ "$jobs" =~ $jobs_re ]] || node_die "could not determine builder CPU count: ${jobs}"

guest_env=(
  "KERNEL_ARCHIVE_URL=$(node_kernel_lock_field archiveUrl)"
  "KERNEL_DIRECTORY=$(node_kernel_lock_field directory)"
  "KERNEL_SOURCE_VERSION=$(node_kernel_lock_field version)"
  "KERNEL_PACKAGE_VERSION=$(node_kernel_package_version)"
  "KERNEL_RELEASE=$(node_kernel_lock_field kernelRelease)"
  "KERNEL_FLAVOUR=${NODE_KERNEL_FLAVOUR}"
  "KERNEL_FILES=$(node_kernel_lock_files)"
  "KERNEL_CONFIG_DELTA=${NODE_KERNEL_CONFIG_DELTA}"
  "KERNEL_OUT_DIR=${build_dir}/packages"
  "KERNEL_WORK_DIR=/var/tmp/home-ops-kernel-build/${build_id}"
  "KERNEL_JOBS=${jobs}"
)

rm -f "$state_file"
mkdir -p "${build_dir}/packages" "${build_dir}/state"

node_log "building kernel ${build_id} with ${builder_mode} builder (${jobs} jobs)"
if [[ "$builder_mode" == lima ]]; then
  limactl shell --tty=false "$builder_name" -- env "${guest_env[@]}" bash "$NODE_KERNEL_BUILD_GUEST_SCRIPT" ||
    node_die "kernel build failed in the lima builder"
else
  env "${guest_env[@]}" bash "$NODE_KERNEL_BUILD_GUEST_SCRIPT" ||
    node_die "kernel build failed in the local builder"
fi

state_file="$(node_kernel_write_build_state "$build_id" "$build_dir")" ||
  node_die "could not record kernel build ${build_id}"
printf 'kernel_build_id=%s\n' "$build_id"
printf 'kernel_package_version=%s\n' "$(node_kernel_package_version)"
printf 'kernel_build_state=%s\n' "$state_file"
