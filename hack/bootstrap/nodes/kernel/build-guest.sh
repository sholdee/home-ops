#!/usr/bin/env bash
# Builds the home-ops BTF kernel packages on an arm64 Debian trixie builder: the
# Lima image builder VM, or an arm64 trixie host in local builder mode. The
# kernel tree stays under KERNEL_WORK_DIR on the builder's own disk because the
# macOS home mount is case-insensitive and corrupts a kernel tree. Packages and
# the packaged kernel config are copied to KERNEL_OUT_DIR.
set -euo pipefail

kernel_guest_die() {
  printf 'kernel-build: %s\n' "$*" >&2
  exit 1
}

kernel_guest_log() {
  printf 'kernel-build: %s\n' "$*" >&2
}

kernel_guest_require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || kernel_guest_die "missing required environment variable: ${name}"
  done
}

# kernel_guest_set_changelog_version rewrites the version of the top changelog
# entry in place. debian/bin/gencontrol.py derives the kernel ABI name from the
# changelog: a new entry (dch -v or dch --local) renames every package and the
# running uname, while an in-place edit keeps the stock ABI name.
kernel_guest_set_changelog_version() {
  local changelog="$1"
  local old_version="$2"
  local new_version="$3"

  awk -v old="(${old_version})" -v new="(${new_version})" '
    NR == 1 {
      idx = index($0, old)
      if (idx == 0) {
        exit 2
      }
      $0 = substr($0, 1, idx - 1) new substr($0, idx + length(old))
    }
    {print}
  ' "$changelog" >"${changelog}.new" || {
    rm -f "${changelog}.new"
    kernel_guest_die "top changelog entry is not ${old_version}"
  }
  mv "${changelog}.new" "$changelog"
}

# kernel_guest_require_config_lines fails unless every non-## line of the delta
# appears verbatim in the kernel config. Kconfig oldconfig silently drops options
# whose dependencies are unmet and the Debian packaging does not check, so this
# is the only guard that the delta survived.
kernel_guest_require_config_lines() {
  local delta="$1"
  local config="$2"
  local line
  local missing=()

  while IFS= read -r line; do
    if [[ -z "$line" || "$line" == '##'* ]]; then
      continue
    fi
    if ! grep -Fxq -- "$line" "$config"; then
      missing+=("$line")
    fi
  done <"$delta"

  if ((${#missing[@]} > 0)); then
    printf 'kernel-build: %s is missing config delta lines:\n' "$config" >&2
    printf '  %s\n' "${missing[@]}" >&2
    return 1
  fi
}

kernel_guest_require_rules_gen() {
  local rules_gen="$1"
  local abiname="$2"
  local version="$3"
  local abinames

  grep -Fq "ABINAME='${abiname}'" "$rules_gen" ||
    kernel_guest_die "debian/rules.gen does not use ABINAME='${abiname}'"
  # Collect first: grep -q reading a pipe can SIGPIPE the producer, and under
  # pipefail that turns a detected mismatch into a false condition.
  abinames="$(grep -oE "ABINAME='[^']*'" "$rules_gen" | sort -u)"
  [[ "$abinames" == "ABINAME='${abiname}'" ]] ||
    kernel_guest_die "debian/rules.gen uses ABI names other than ABINAME='${abiname}': ${abinames//$'\n'/ }"
  grep -Fq "SOURCEVERSION='${version}'" "$rules_gen" ||
    kernel_guest_die "debian/rules.gen does not use SOURCEVERSION='${version}'"
}

# kernel_guest_deb_ships DEB PATH succeeds when the package contains PATH. The
# listing goes through a file: grep -q on a pipe would SIGPIPE dpkg-deb and
# fail the pipeline under pipefail even when the path is present.
kernel_guest_deb_ships() {
  local deb="$1"
  local path="$2"
  local listing="${KERNEL_WORK_DIR}/listing.txt"

  dpkg-deb -c "$deb" | awk '{print $NF}' >"$listing"
  grep -Fxq -- "$path" "$listing"
}

kernel_guest_main() {
  local arch codename free_gib entry name sha256 dsc="" src_dir abiname deb_version pkg deb config_deb=""
  local min_free_gib="${KERNEL_MIN_FREE_GIB:-40}"
  local work_dir_re='^/var/tmp/home-ops-kernel-build/[A-Za-z0-9][A-Za-z0-9._-]*$'
  local entries=()

  kernel_guest_require_env KERNEL_ARCHIVE_URL KERNEL_DIRECTORY KERNEL_SOURCE_VERSION KERNEL_PACKAGE_VERSION \
    KERNEL_RELEASE KERNEL_FLAVOUR KERNEL_FILES KERNEL_CONFIG_DELTA KERNEL_OUT_DIR KERNEL_WORK_DIR KERNEL_JOBS

  arch="$(dpkg --print-architecture)"
  [[ "$arch" == arm64 ]] || kernel_guest_die "builder architecture is ${arch}, expected arm64"
  # shellcheck source=/dev/null
  codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
  [[ "$codename" == trixie ]] || kernel_guest_die "builder is ${codename:-unknown}, expected Debian trixie"
  [[ "$KERNEL_FLAVOUR" == rpi-2712 ]] || kernel_guest_die "unsupported kernel flavour: ${KERNEL_FLAVOUR}"
  [[ -f "$KERNEL_CONFIG_DELTA" ]] || kernel_guest_die "config delta not found: ${KERNEL_CONFIG_DELTA}"
  mkdir -p "$KERNEL_OUT_DIR" && [[ -w "$KERNEL_OUT_DIR" ]] ||
    kernel_guest_die "KERNEL_OUT_DIR is not writable: ${KERNEL_OUT_DIR}"

  [[ "$KERNEL_WORK_DIR" =~ $work_dir_re && "$KERNEL_WORK_DIR" != *..* ]] ||
    kernel_guest_die "KERNEL_WORK_DIR must be a build directory under /var/tmp/home-ops-kernel-build/: ${KERNEL_WORK_DIR}"
  sudo rm -rf /var/tmp/home-ops-kernel-build
  sudo install -d -o "$(id -u)" -g "$(id -g)" "$KERNEL_WORK_DIR"
  free_gib="$(df -Pk "$KERNEL_WORK_DIR" | awk 'NR == 2 {print int($4 / 1048576)}')"
  ((free_gib >= min_free_gib)) ||
    kernel_guest_die "only ${free_gib} GiB free under ${KERNEL_WORK_DIR}; need ${min_free_gib} GiB"

  kernel_guest_log "installing base build tools"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl dpkg-dev fakeroot

  cd "$KERNEL_WORK_DIR"
  IFS=';' read -r -a entries <<<"$KERNEL_FILES"
  for entry in "${entries[@]}"; do
    name="${entry%%:*}"
    sha256="${entry#*:}"
    [[ -n "$name" && -n "$sha256" && "$name" != "$entry" && "$name" != */* && "$name" != .* ]] || kernel_guest_die "invalid KERNEL_FILES entry: ${entry}"
    kernel_guest_log "downloading ${name}"
    curl -fsSL --retry 3 --connect-timeout 30 -o "$name" "${KERNEL_ARCHIVE_URL%/}/${KERNEL_DIRECTORY}/${name}"
    printf '%s  %s\n' "$sha256" "$name" | sha256sum -c --strict --quiet - ||
      kernel_guest_die "sha256 mismatch for ${name}"
    if [[ "$name" == *.dsc ]]; then
      dsc="$name"
    fi
  done
  [[ -n "$dsc" ]] || kernel_guest_die "KERNEL_FILES has no .dsc"

  src_dir="${KERNEL_WORK_DIR}/src"
  dpkg-source -x "$dsc" "$src_dir"
  cd "$src_dir"

  kernel_guest_set_changelog_version debian/changelog "$KERNEL_SOURCE_VERSION" "$KERNEL_PACKAGE_VERSION"
  [[ "$(dpkg-parsechangelog -S Version)" == "$KERNEL_PACKAGE_VERSION" ]] ||
    kernel_guest_die "changelog version is $(dpkg-parsechangelog -S Version), expected ${KERNEL_PACKAGE_VERSION}"
  grep -v '^##' "$KERNEL_CONFIG_DELTA" >>debian/config/arm64/rpi/config.2712

  kernel_guest_log "installing kernel build dependencies"
  sudo DEBIAN_FRONTEND=noninteractive apt-get build-dep -y -P pkg.linux.nokerneldbg,nodoc ./

  debian/rules debian/control-real
  abiname="${KERNEL_RELEASE%-"${KERNEL_FLAVOUR}"}"
  kernel_guest_require_rules_gen debian/rules.gen "$abiname" "$KERNEL_PACKAGE_VERSION"

  # pkg.linux.nokerneldbg drops only the -dbg packages. rules.real forces
  # DEBUG_INFO_NONE=y for pkg.linux.nokerneldbginfo and pkg.linux.quick after
  # every config file, which would silently cancel BTF.
  export DEB_BUILD_PROFILES='pkg.linux.nokerneldbg nodoc'
  export DEB_BUILD_OPTIONS="parallel=${KERNEL_JOBS} terse"
  export DEB_RULES_REQUIRES_ROOT=no

  debian/rules source
  # debian/rules turns parallel=N into -jN (debian/rules:12-17); rules.gen and
  # rules.real do not (rules.real uses it only for xz threads), so a direct
  # rules.gen call would compile serially. rules.gen is .NOTPARALLEL, like
  # debian/rules, so only the kernel make fans out.
  export MAKEFLAGS="-j${KERNEL_JOBS}"
  make -f debian/rules.gen setup_arm64_rpi_2712
  kernel_guest_require_config_lines "$KERNEL_CONFIG_DELTA" debian/build/build_arm64_rpi_2712/.config ||
    kernel_guest_die "kernel config dropped config delta lines before compiling"

  kernel_guest_log "building ${KERNEL_RELEASE} packages ${KERNEL_PACKAGE_VERSION} with ${KERNEL_JOBS} jobs"
  make -f debian/rules.gen binary-arch_arm64_rpi_2712

  deb_version="${KERNEL_PACKAGE_VERSION#*:}"
  mkdir -p "$KERNEL_OUT_DIR"
  rm -f "${KERNEL_OUT_DIR}"/*.deb "${KERNEL_OUT_DIR}/config-${KERNEL_RELEASE}"
  for pkg in "linux-image-${KERNEL_RELEASE}" "linux-base-${KERNEL_RELEASE}" "linux-image-${KERNEL_FLAVOUR}" "linux-base-${KERNEL_FLAVOUR}"; do
    deb="${KERNEL_WORK_DIR}/${pkg}_${deb_version}_arm64.deb"
    [[ -f "$deb" ]] || kernel_guest_die "expected package was not built: $(basename "$deb")"
    [[ "$(dpkg-deb -f "$deb" Version)" == "$KERNEL_PACKAGE_VERSION" ]] ||
      kernel_guest_die "$(basename "$deb") has version $(dpkg-deb -f "$deb" Version)"
    if [[ "$pkg" == "linux-image-${KERNEL_RELEASE}" || "$pkg" == "linux-base-${KERNEL_RELEASE}" ]] &&
      kernel_guest_deb_ships "$deb" "./boot/config-${KERNEL_RELEASE}"; then
      config_deb="$deb"
    fi
  done

  kernel_guest_deb_ships "${KERNEL_WORK_DIR}/linux-image-${KERNEL_RELEASE}_${deb_version}_arm64.deb" "./boot/vmlinuz-${KERNEL_RELEASE}" ||
    kernel_guest_die "linux-image-${KERNEL_RELEASE} does not ship /boot/vmlinuz-${KERNEL_RELEASE}"
  [[ -n "$config_deb" ]] || kernel_guest_die "no built package ships /boot/config-${KERNEL_RELEASE}"
  dpkg-deb --fsys-tarfile "$config_deb" | tar -xOf - "./boot/config-${KERNEL_RELEASE}" >"${KERNEL_WORK_DIR}/config-${KERNEL_RELEASE}"
  kernel_guest_require_config_lines "$KERNEL_CONFIG_DELTA" "${KERNEL_WORK_DIR}/config-${KERNEL_RELEASE}" ||
    kernel_guest_die "packaged kernel config is missing config delta lines"

  for pkg in "linux-image-${KERNEL_RELEASE}" "linux-base-${KERNEL_RELEASE}" "linux-image-${KERNEL_FLAVOUR}" "linux-base-${KERNEL_FLAVOUR}"; do
    cp "${KERNEL_WORK_DIR}/${pkg}_${deb_version}_arm64.deb" "$KERNEL_OUT_DIR/"
  done
  cp "${KERNEL_WORK_DIR}/config-${KERNEL_RELEASE}" "$KERNEL_OUT_DIR/"
  kernel_guest_log "kernel packages written to ${KERNEL_OUT_DIR}"
  cd /
  sudo rm -rf "$KERNEL_WORK_DIR"
}

if [[ "${KERNEL_GUEST_SOURCE_ONLY:-false}" != true ]]; then
  kernel_guest_main "$@"
fi
