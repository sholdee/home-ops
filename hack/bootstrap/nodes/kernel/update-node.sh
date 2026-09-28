#!/usr/bin/env bash
# Installed on nodes as /usr/local/sbin/home-ops-kernel-update by
# hack/bootstrap/nodes/kernel-update.sh, which copies it on every run.
#
# In-place home-ops kernel update with a firmware-level fallback. "stage"
# copies the running boot set to a fallback directory, points config.txt at
# that copy with explicit kernel=, initramfs, and cmdline= lines, writes
# tryboot.txt as the pre-update config.txt, installs the new packages (the
# raspi-firmware hooks rewrite the root-level boot set), and updates the
# marker. The host then reboots with "0 tryboot": that one boot uses the new
# kernel; every other boot uses config.txt and the previous kernel until
# "commit". The fallback cmdline carries home_ops_kernel_fallback=1, so
# /proc/cmdline tells a fallback boot from a trial boot.
set -euo pipefail

boot="${HOME_OPS_KERNEL_BOOT_DIR:-/boot/firmware}"
vmlinuz_dir="${HOME_OPS_KERNEL_VMLINUZ_DIR:-/boot}"
fallback="${HOME_OPS_KERNEL_FALLBACK_DIR:-${boot}/home-ops-kernel-prev}"
marker="${HOME_OPS_KERNEL_BUILD_MARKER:-/etc/home-ops/kernel-build}"
verify_bin="${HOME_OPS_KERNEL_VERIFY_BIN:-/usr/local/sbin/home-ops-verify-kernel-build}"
reimage_stage="${HOME_OPS_KERNEL_REIMAGE_STAGE_DIR:-${boot}/home-ops-reimage}"
proc_cmdline="${HOME_OPS_KERNEL_PROC_CMDLINE:-/proc/cmdline}"
apt_get="${HOME_OPS_KERNEL_APT_GET:-apt-get}"
apt_mark="${HOME_OPS_KERNEL_APT_MARK:-apt-mark}"
sync_bin="${HOME_OPS_KERNEL_SYNC:-sync}"
flavour="rpi-2712"
fallback_arg="home_ops_kernel_fallback=1"
rehold_release=""
kernel_img="${boot}/kernel_2712.img"
initramfs_img="${boot}/initramfs_2712"
config="${boot}/config.txt"
tryboot="${boot}/tryboot.txt"
cmdline="${boot}/cmdline.txt"
begin_mark='# BEGIN home-ops kernel fallback (home-ops-kernel-update)'
end_mark='# END home-ops kernel fallback (home-ops-kernel-update)'

die() {
  printf 'home-ops-kernel-update: %s\n' "$*" >&2
  exit 1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

check_sums() {
  # Portable "sha256sum -c --strict" for the SHA256SUMS in the current dir.
  local line sum file
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    sum="${line%% *}"
    file="${line##* }"
    [[ "$sum" =~ ^[0-9a-f]{64}$ && -f "$file" ]] || die "bad SHA256SUMS entry: ${line}"
    [[ "$(sha256_of "$file")" == "$sum" ]] || die "package checksum mismatch: ${file}"
  done <SHA256SUMS
}

kv() {
  # kv FILE KEY prints the first KEY= value from FILE, or nothing.
  [[ -r "$1" ]] || return 0
  sed -n "s/^$2=//p" "$1" | sed -n '1p'
}

package_names() {
  printf '%s\n' "linux-image-$1" "linux-base-$1" "linux-image-${flavour}" "linux-base-${flavour}"
}

write_atomic() {
  # write_atomic PATH MODE < content. The content must already be complete:
  # this helper cannot tell a finished producer from one that died mid-pipe,
  # so callers materialise the content first and only pipe a checked string.
  local path="$1" mode="$2" tmp
  tmp="$(mktemp "${path}.XXXXXX")" || die "cannot create a temp file next to ${path}"
  cat >"$tmp"
  [[ -s "$tmp" ]] || {
    rm -f "$tmp"
    die "refusing to write an empty ${path}"
  }
  chmod "$mode" "$tmp"
  mv "$tmp" "$path"
  "$sync_bin"
}

fallback_dir_name() {
  [[ "$(dirname "$fallback")" == "$boot" ]] || die "fallback dir must be directly under ${boot}: ${fallback}"
  basename "$fallback"
}

fallback_block() {
  local name
  name="$(fallback_dir_name)" || exit 1
  printf '%s\n[all]\nkernel=%s/kernel_2712.img\ninitramfs %s/initramfs_2712 followkernel\ncmdline=%s/cmdline.txt\n%s\n' \
    "$begin_mark" "$name" "$name" "$name" "$end_mark"
}

config_has_block() {
  local b e
  b="$(grep -nxF -- "$begin_mark" "$config" 2>/dev/null | head -1 | cut -d: -f1)"
  e="$(grep -nxF -- "$end_mark" "$config" 2>/dev/null | head -1 | cut -d: -f1)"
  [[ -n "$b" && -n "$e" && "$b" -lt "$e" ]]
}

strip_block() {
  awk -v b="$begin_mark" -v e="$end_mark" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$config"
}

running_matches_version() {
  # running_matches_version RELEASE VERSION
  [[ "$(uname -r)" == "$1" && "$(uname -v)" == *" $2 ("* ]]
}

booted_via_fallback() {
  local line
  line="$(sed -n '1p' "$proc_cmdline" 2>/dev/null || true)"
  [[ " ${line} " == *" ${fallback_arg} "* ]]
}

fallback_state() {
  local f
  [[ -d "$fallback" ]] || {
    printf 'no\n'
    return
  }
  for f in kernel_2712.img initramfs_2712 cmdline.txt config.txt.orig META; do
    [[ -f "${fallback}/${f}" ]] || {
      printf 'partial\n'
      return
    }
  done
  if [[ "$(sha256_of "${fallback}/kernel_2712.img")" == "$(kv "${fallback}/META" KERNEL_SHA256)" &&
    "$(sha256_of "${fallback}/initramfs_2712")" == "$(kv "${fallback}/META" INITRAMFS_SHA256)" ]]; then
    printf 'yes\n'
  else
    printf 'partial\n'
  fi
}

installed_version() {
  local out
  # shellcheck disable=SC2016
  out="$(dpkg-query -W -f='${db:Status-Status} ${Version}' "linux-image-$1" 2>/dev/null || true)"
  if [[ "$out" == installed\ * ]]; then
    printf '%s\n' "${out#installed }"
  else
    printf 'none\n'
  fi
}

held_count() {
  local n=0 name status
  while IFS= read -r name; do
    # shellcheck disable=SC2016
    status="$(dpkg-query -W -f='${db:Status-Want}' "$name" 2>/dev/null || true)"
    if [[ "$status" == hold ]]; then
      n=$((n + 1))
    fi
  done < <(package_names "$1")
  printf '%s\n' "$n"
}

boot_free_bytes() {
  if df -P -B1 "$boot" >/dev/null 2>&1; then
    df -P -B1 "$boot" | awk 'NR == 2 { print $4 }'
  else
    df -Pk "$boot" | awk 'NR == 2 { print $4 * 1024 }'
  fi
}

file_size() {
  stat -c %s "$1" 2>/dev/null || stat -f %z "$1"
}

classify() {
  # classify BLOCK FALLBACK TRYBOOT MATCH VIA
  if [[ "$1" == no && "$2" == no && "$3" == no ]]; then
    printf 'S0\n'
  elif [[ "$1" == yes && "$2" == yes && "$4" == marker && "$5" == no ]]; then
    printf 'S1\n'
  elif [[ "$1" == yes && "$2" == yes && "$4" == fallback ]]; then
    printf 'S2\n'
  else
    printf 'S3\n'
  fi
}

status_fields() {
  local m_present=no m_id="" m_ver="" m_rel="" block=no fb tb=no rs=no match=none via=no trial=no
  local f_ver="" f_rel="" f_id="" size_k=0 size_i=0 installed=none holds=0
  uname -r >/dev/null || die "cannot read the running kernel release"
  if [[ -r "$marker" ]]; then
    m_present=yes
    m_id="$(kv "$marker" KERNEL_BUILD_ID)"
    m_ver="$(kv "$marker" KERNEL_PACKAGE_VERSION)"
    m_rel="$(kv "$marker" KERNEL_RELEASE)"
  fi
  if config_has_block; then block=yes; fi
  fb="$(fallback_state)"
  if [[ "$fb" != no && -f "${fallback}/META" ]]; then
    f_ver="$(kv "${fallback}/META" KERNEL_PACKAGE_VERSION)"
    f_rel="$(kv "${fallback}/META" KERNEL_RELEASE)"
    f_id="$(kv "${fallback}/META" KERNEL_BUILD_ID)"
  fi
  if [[ -f "$tryboot" ]]; then tb=yes; fi
  if [[ -d "$reimage_stage" ]]; then rs=yes; fi
  if booted_via_fallback; then via=yes; fi
  if [[ -f "${fallback}/TRIAL" ]]; then trial=yes; fi
  # Which copy is running? booted_via_fallback is authoritative: the fallback
  # cmdline booted. Otherwise trial_pending decides, because the marker and
  # META describe the same build in two different situations -- a stage that
  # died before the marker write (never trialled) and a rollback to the build
  # the fallback holds (trialled). TRIAL is written only by a completed stage.
  if [[ "$via" == yes ]]; then
    if [[ -n "$f_rel" && -n "$f_ver" ]] && running_matches_version "$f_rel" "$f_ver"; then
      match=fallback
    elif [[ -n "$m_rel" && -n "$m_ver" ]] && running_matches_version "$m_rel" "$m_ver"; then
      match=marker
    fi
  elif [[ "$trial" == yes && -n "$m_rel" && -n "$m_ver" ]] && running_matches_version "$m_rel" "$m_ver"; then
    match=marker
  elif [[ -n "$f_rel" && -n "$f_ver" ]] && running_matches_version "$f_rel" "$f_ver"; then
    match=fallback
  elif [[ -n "$m_rel" && -n "$m_ver" ]] && running_matches_version "$m_rel" "$m_ver"; then
    match=marker
  fi
  if [[ -f "$kernel_img" ]]; then size_k="$(file_size "$kernel_img")"; fi
  if [[ -f "$initramfs_img" ]]; then size_i="$(file_size "$initramfs_img")"; fi
  if [[ -n "$m_rel" ]]; then
    installed="$(installed_version "$m_rel")"
    holds="$(held_count "$m_rel")"
  fi
  printf 'running_release=%s\n' "$(uname -r)"
  printf 'running_build=%s\n' "$(uname -v)"
  printf 'booted_via_fallback=%s\n' "$via"
  printf 'marker_present=%s\nmarker_build_id=%s\nmarker_version=%s\nmarker_release=%s\n' "$m_present" "$m_id" "$m_ver" "$m_rel"
  printf 'installed_version=%s\n' "$installed"
  printf 'fallback_present=%s\nfallback_version=%s\nfallback_release=%s\nfallback_build_id=%s\n' "$fb" "$f_ver" "$f_rel" "$f_id"
  printf 'config_fallback_block=%s\ntryboot_present=%s\nreimage_staged=%s\ntrial_pending=%s\nrunning_matches=%s\n' "$block" "$tb" "$rs" "$trial" "$match"
  printf 'state=%s\n' "$(classify "$block" "$fb" "$tb" "$match" "$via")"
  printf 'boot_free_bytes=%s\nboot_set_bytes=%s\n' "$(boot_free_bytes)" "$((size_k + size_i))"
  printf 'holds=%s\n' "$holds"
}

state_of() {
  status_fields | sed -n 's/^state=//p'
}

ensure_cmdline_args() {
  # ensure_cmdline_args ARG... appends missing whole tokens to cmdline.txt.
  local present added="" arg
  present="$(sed -n '1p' "$cmdline")" || die "cannot read ${cmdline}"
  [[ -n "$present" ]] || die "cmdline.txt is empty: ${cmdline}"
  for arg in "$@"; do
    case " ${present} " in
      *" ${arg} "*) ;;
      *)
        present="${present} ${arg}"
        added="${added} ${arg}"
        printf 'cmdline_added=%s\n' "$arg"
        ;;
    esac
  done
  if [[ -n "$added" ]]; then
    printf '%s\n' "$present" | write_atomic "$cmdline" 0644
  fi
}

cmd_status() {
  status_fields
}

cmd_prepare() {
  local state free need
  local -a args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cmdline-arg)
        args+=("${2:?missing value for --cmdline-arg}")
        shift 2
        ;;
      *) die "unknown prepare argument: $1" ;;
    esac
  done
  state="$(state_of)"
  case "$state" in
    S0)
      "$verify_bin" >/dev/null ||
        die "running kernel does not match the installed home-ops kernel; refusing to update from an unverified state"
      [[ ! -e "$tryboot" && ! -d "$reimage_stage" ]] || die "a reimage or another kernel update is staged"
      if ! { cmp -s "$kernel_img" "${vmlinuz_dir}/vmlinuz-$(uname -r)" &&
        cmp -s "$initramfs_img" "${vmlinuz_dir}/initrd.img-$(uname -r)"; }; then
        die "root-level boot set is not the running kernel"
      fi
      free="$(boot_free_bytes)"
      need=$(($(file_size "$kernel_img") + $(file_size "$initramfs_img") + 4 * 1024 * 1024))
      ((free >= need)) || die "not enough space in ${boot} for the fallback copy: free=${free} need=${need}"
      [[ "$(held_count "$(uname -r)")" == 4 ]] || die "the four kernel packages for $(uname -r) are not all held"
      ;;
    S2) ;;
    S1) die "node is in state S1; a trial is pending: run the host flow with --resume to commit it, or reboot to fall back" ;;
    *) die "node is in state ${state}; clean up ${boot} by hand before retrying" ;;
  esac
  if ((${#args[@]} > 0)); then
    ensure_cmdline_args "${args[@]}"
  fi
  printf 'prepare_state=%s\nprepare=ok\n' "$state"
}

create_fallback() {
  local id ver rel meta_content config_content tryboot_content cmdline_content
  id="$(kv "$marker" KERNEL_BUILD_ID)"
  ver="$(kv "$marker" KERNEL_PACKAGE_VERSION)"
  rel="$(kv "$marker" KERNEL_RELEASE)"
  [[ -n "$id" && -n "$ver" && -n "$rel" ]] || die "kernel build marker is incomplete: ${marker}"
  install -d -m 0755 "$fallback"
  cp "$kernel_img" "${fallback}/kernel_2712.img"
  cp "$initramfs_img" "${fallback}/initramfs_2712"
  cp "$config" "${fallback}/config.txt.orig"
  cmdline_content="$(sed -n '1p' "$cmdline")" || die "cannot read ${cmdline}"
  [[ -n "$cmdline_content" ]] || die "cmdline.txt is empty: ${cmdline}"
  case " ${cmdline_content} " in
    *" ${fallback_arg} "*) ;;
    *) cmdline_content="${cmdline_content} ${fallback_arg}" ;;
  esac
  printf '%s\n' "$cmdline_content" | write_atomic "${fallback}/cmdline.txt" 0644
  "$sync_bin"
  meta_content="$(
    printf 'KERNEL_BUILD_ID=%s\nKERNEL_PACKAGE_VERSION=%s\nKERNEL_RELEASE=%s\n' "$id" "$ver" "$rel"
    printf 'KERNEL_SHA256=%s\n' "$(sha256_of "${fallback}/kernel_2712.img")"
    printf 'INITRAMFS_SHA256=%s\n' "$(sha256_of "${fallback}/initramfs_2712")"
    printf 'CONFIG_SHA256=%s\n' "$(sha256_of "${fallback}/config.txt.orig")"
  )" || die "could not hash the fallback boot set"
  printf '%s\n' "$meta_content" | write_atomic "${fallback}/META" 0644
  if ! { cmp -s "$kernel_img" "${fallback}/kernel_2712.img" &&
    cmp -s "$initramfs_img" "${fallback}/initramfs_2712"; }; then
    die "fallback copy does not match the running boot set"
  fi
  config_content="$(cat "$config")" || die "cannot read ${config}"
  config_content="${config_content}"$'\n'"$(fallback_block)"
  printf '%s\n' "$config_content" | write_atomic "$config" 0644
  tryboot_content="$(cat "${fallback}/config.txt.orig")" || die "cannot read ${fallback}/config.txt.orig"
  printf '%s\n' "$tryboot_content" | write_atomic "$tryboot" 0644
}

rehold_target() {
  package_names "$rehold_release" | xargs "$apt_mark" hold >/dev/null 2>&1 || true
}

cmd_stage() {
  local dir="${1:?stage needs the package directory}" state env_file id ver rel delta name
  local deb_count tryboot_content marker_content
  local -a debs=()
  [[ -d "$dir" ]] || die "package directory not found: ${dir}"
  env_file="${dir}/kernel-build.env"
  [[ -f "$env_file" && -f "${dir}/SHA256SUMS" ]] || die "package directory lacks kernel-build.env or SHA256SUMS: ${dir}"
  id="$(kv "$env_file" KERNEL_BUILD_ID)"
  ver="$(kv "$env_file" KERNEL_PACKAGE_VERSION)"
  rel="$(kv "$env_file" KERNEL_RELEASE)"
  delta="$(kv "$env_file" KERNEL_CONFIG_DELTA_SHA256)"
  [[ -n "$id" && -n "$ver" && -n "$rel" && -n "$delta" ]] || die "kernel-build.env is incomplete: ${env_file}"
  (cd "$dir" && check_sums)
  deb_count="$(find "$dir" -maxdepth 1 -type f -name '*.deb' | wc -l | tr -d ' ')"
  [[ "$deb_count" == 4 ]] ||
    die "package directory must hold exactly the four ${ver} kernel packages, found ${deb_count}: ${dir}"
  while IFS= read -r name; do
    [[ -f "${dir}/${name}_${ver#*:}_arm64.deb" ]] ||
      die "package directory lacks ${name}_${ver#*:}_arm64.deb: ${dir}"
    debs+=("./${name}_${ver#*:}_arm64.deb")
  done < <(package_names "$rel")
  for name in "${debs[@]}"; do
    grep -qF -- "  ${name#./}" "${dir}/SHA256SUMS" ||
      die "SHA256SUMS does not cover ${name#./}: ${dir}"
  done
  state="$(state_of)"
  case "$state" in
    S0)
      create_fallback
      ;;
    S2)
      if [[ -e "$tryboot" ]]; then
        cmp -s "$tryboot" "${fallback}/config.txt.orig" ||
          die "tryboot.txt differs from the fallback copy of config.txt; refusing to retry; a reimage may be staged — check ${reimage_stage}"
      else
        tryboot_content="$(cat "${fallback}/config.txt.orig")" || die "cannot read ${fallback}/config.txt.orig"
        printf '%s\n' "$tryboot_content" | write_atomic "$tryboot" 0644
      fi
      ;;
    S1) die "a trial is pending; run the host flow with --resume to commit it, or reboot to fall back" ;;
    *) die "node is in state ${state}; clean up ${boot} by hand before retrying" ;;
  esac
  rm -f "${fallback}/TRIAL"
  package_names "$rel" | xargs "$apt_mark" unhold >/dev/null 2>&1 || true
  rehold_release="$rel"
  trap rehold_target EXIT
  (
    cd "$dir" || exit 1
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
      "$apt_get" -y --allow-downgrades \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
      install "${debs[@]}"
  ) || die "kernel package install failed; the fallback kernel remains the default boot"
  package_names "$rel" | xargs "$apt_mark" hold >/dev/null
  trap - EXIT
  [[ "$(installed_version "$rel")" == "$ver" ]] || die "linux-image-${rel} is not installed at ${ver} after install"
  if ! { cmp -s "$kernel_img" "${vmlinuz_dir}/vmlinuz-${rel}" &&
    cmp -s "$initramfs_img" "${vmlinuz_dir}/initrd.img-${rel}"; }; then
    die "kernel hooks did not update the boot set"
  fi
  marker_content="$(printf 'KERNEL_BUILD_ID=%s\nKERNEL_PACKAGE_VERSION=%s\nKERNEL_RELEASE=%s\nKERNEL_CONFIG_DELTA_SHA256=%s' \
    "$id" "$ver" "$rel" "$delta")"
  printf '%s\n' "$marker_content" | write_atomic "$marker" 0644
  printf '%s\n' "$id" | write_atomic "${fallback}/TRIAL" 0644
  printf 'stage=ok\nstaged_build_id=%s\nstaged_version=%s\n' "$id" "$ver"
}

cmd_commit() {
  local state out id old_rel new_rel config_content
  state="$(state_of)"
  [[ "$state" == S1 ]] || die "node is in state ${state}; commit needs a booted, uncommitted trial (S1)"
  out="$("$verify_bin")" || die "kernel verification failed; do not commit"
  id="$(sed -n 's/^kernel_build_id=//p' <<<"$out" | sed -n '1p')"
  [[ -n "$id" && "$id" == "$(kv "$marker" KERNEL_BUILD_ID)" ]] ||
    die "verifier reported ${id:-<empty>}, marker says $(kv "$marker" KERNEL_BUILD_ID)"
  rm -f "$tryboot"
  config_content="$(strip_block)" || die "could not strip the fallback block from ${config}"
  printf '%s\n' "$config_content" | write_atomic "$config" 0644
  if ! cmp -s "$config" "${fallback}/config.txt.orig"; then
    printf 'config_changed_during_update=yes\n'
  fi
  old_rel="$(kv "${fallback}/META" KERNEL_RELEASE)"
  new_rel="$(kv "$marker" KERNEL_RELEASE)"
  rm -rf "$fallback"
  "$sync_bin"
  if [[ -n "$old_rel" && "$old_rel" != "$new_rel" ]]; then
    "$apt_mark" unhold "linux-image-${old_rel}" "linux-base-${old_rel}" >/dev/null 2>&1 || true
    if ! DEBIAN_FRONTEND=noninteractive "$apt_get" -y purge "linux-image-${old_rel}" "linux-base-${old_rel}"; then
      printf 'purge_failed=linux-image-%s\n' "$old_rel"
    fi
  fi
  printf 'commit=ok\n'
}

case "${1:-}" in
  status)
    shift
    cmd_status "$@"
    ;;
  prepare)
    shift
    cmd_prepare "$@"
    ;;
  stage)
    shift
    cmd_stage "$@"
    ;;
  commit)
    shift
    cmd_commit "$@"
    ;;
  *) die "usage: home-ops-kernel-update status|prepare [--cmdline-arg ARG]...|stage DIR|commit" ;;
esac
