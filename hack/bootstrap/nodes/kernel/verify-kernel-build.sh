#!/usr/bin/env bash
# Installed on reimaged nodes as /usr/local/sbin/home-ops-verify-kernel-build.
# Fails unless the running kernel is the home-ops kernel build recorded in the
# marker. The stock Raspberry Pi kernel shares the release string, so the
# running kernel's build version, the installed package state and version, and
# the BTF checks are what tell them apart. Prints kernel_build_id=<id> on success.
set -euo pipefail

marker="${HOME_OPS_KERNEL_BUILD_MARKER:-/etc/home-ops/kernel-build}"
btf="${HOME_OPS_KERNEL_BTF:-/sys/kernel/btf/vmlinux}"
proc_config="${HOME_OPS_KERNEL_PROC_CONFIG:-/proc/config.gz}"

fail() {
  printf 'home-ops-verify-kernel-build: %s\n' "$*" >&2
  exit 1
}

marker_value() {
  sed -n "s/^$1=//p" "$marker" | sed -n '1p'
}

[[ -r "$marker" ]] || fail "kernel build marker is missing: ${marker}"
build_id="$(marker_value KERNEL_BUILD_ID)"
expected_version="$(marker_value KERNEL_PACKAGE_VERSION)"
expected_release="$(marker_value KERNEL_RELEASE)"
[[ -n "$build_id" && -n "$expected_version" && -n "$expected_release" ]] ||
  fail "kernel build marker is incomplete: ${marker}"

running_release="$(uname -r)"
[[ "$running_release" == "$expected_release" ]] ||
  fail "running kernel ${running_release} is not the home-ops kernel ${expected_release}"

# The Debian kernel build stamps the package version into uname -v
# ("#1 SMP PREEMPT Debian <version> (<date>)"), which tells two rebuilds of the
# same release apart even when both carry BTF.
running_build="$(uname -v)"
[[ "$running_build" == *" ${expected_version} ("* ]] ||
  fail "running kernel build '${running_build}' is not ${expected_version}"

# A removed but not purged package keeps its version, so check the state too.
# shellcheck disable=SC2016
installed="$(dpkg-query -W -f='${db:Status-Status} ${Version}' "linux-image-${expected_release}" || true)"
[[ "$installed" == "installed ${expected_version}" ]] ||
  fail "linux-image-${expected_release} is ${installed:-not installed}, expected installed ${expected_version}"

[[ -e "$btf" ]] || fail "kernel BTF is missing: ${btf}"

[[ -r "$proc_config" ]] || fail "running kernel config is not exposed: ${proc_config}"
# grep without -q reads all input, so gzip never sees SIGPIPE under pipefail.
gzip -dc "$proc_config" | grep -x 'CONFIG_DEBUG_INFO_BTF=y' >/dev/null ||
  fail "running kernel config lacks CONFIG_DEBUG_INFO_BTF=y"

printf 'kernel_build_id=%s\n' "$build_id"
