#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/kernel-update.sh [options] NODE

Update the home-ops kernel on a live node in place, trial-booting it once
through the Raspberry Pi tryboot flag with the current kernel as the fallback.

Options:
  --profile NAME     Node lifecycle profile: live or lima. Defaults to live.
  --context NAME     Kubernetes context. Defaults to the profile context.
  --build-id ID      Kernel build to install. Defaults to the build for the
                     committed kernel source lock. Any recorded build works,
                     which is how a rollback is done.
  --resume           Verify and commit a trial that already booted (state S1).
  --drill-fallback   After staging, reboot normally once and require the node
                     to come back on the previous kernel, then run the trial.
  --skip-smoke       Skip the CNI smoke pod after the trial boot.
  --yes              Skip confirmation prompt.
  -h, --help         Show help.
EOF
}

profile=live
context=""
build_id=""
resume=false
drill_fallback=false
skip_smoke=false
yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="$2"
      shift 2
      ;;
    --context)
      context="$2"
      shift 2
      ;;
    --build-id)
      build_id="$2"
      shift 2
      ;;
    --resume)
      resume=true
      shift
      ;;
    --drill-fallback)
      drill_fallback=true
      shift
      ;;
    --skip-smoke)
      skip_smoke=true
      shift
      ;;
    --yes)
      yes=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      node_die "unknown argument: $1"
      ;;
    *)
      if [[ -n "${node_name:-}" ]]; then
        node_die "only one node may be provided"
      fi
      node_name="$1"
      shift
      ;;
  esac
done

[[ -n "${node_name:-}" ]] || node_die "NODE is required"
node_validate_profile "$profile"
context="${context:-$(node_context_for_profile "$profile")}"

node_require_tool "$NODE_KUBECTL_BIN"
node_require_tool "$NODE_YQ_BIN"
node_require_tool "$NODE_JQ_BIN"
node_require_tool ansible

IFS=$'\t' read -r inventory_node inventory_role < <(
  node_reimage_resolve_existing_inventory_node "$profile" "$node_name"
)
kubernetes_node="$(node_expected_kubernetes_node_name "$profile" "$inventory_node" "$node_name")"

last_status=""
from_id=""
to_id=""
# staged is true once the node holds a staged, uncommitted kernel -- after this
# run stages one, or when a --resume run finds one already booted.
staged=false

# previous_kernel_version prints what config.txt boots while a trial is
# uncommitted: the fallback copy once "stage" has made one, and the running
# marker before that, which is the build the fallback will hold.
previous_kernel_version() {
  local version
  version="$(node_kernel_update_status_value "$last_status" fallback_version)"
  [[ -n "$version" ]] || version="$(node_kernel_update_status_value "$last_status" marker_version)"
  printf '%s\n' "${version:-unknown}"
}

# print_status_block prints the last status read, for the states no flow step
# knows how to continue from.
print_status_block() {
  {
    printf 'kernel_update_status:\n'
    node_indent_block <<<"$last_status"
  } >&2
}

# A run that dies after staging leaves the node in one of two shapes, and the
# operator must never have to guess which: either the fallback is armed and any
# boot but the trial returns the previous kernel, or the trial is booted and
# uncommitted. Say which one the last status read saw, and what to do about it.
on_exit() {
  local status=$?
  if ((status == 0)) || [[ "$staged" != true ]]; then
    return 0
  fi
  {
    printf 'kernel update did not finish; last known state of %s:\n' "$kubernetes_node"
    printf '  state=%s\n' "$(node_kernel_update_status_value "$last_status" state)"
    printf '  running_matches=%s\n' "$(node_kernel_update_status_value "$last_status" running_matches)"
    printf '  booted_via_fallback=%s\n' "$(node_kernel_update_status_value "$last_status" booted_via_fallback)"
    printf 'Only the "0 tryboot" boot uses %s; config.txt boots the previous kernel (%s), so power-cycling the node returns it.\n' \
      "$to_id" "$(previous_kernel_version)"
    printf 'Then rerun to retry the trial, or rerun with --build-id %s to roll back. Leave the node cordoned until it is committed.\n' \
      "$from_id"
  } >&2
  return 0
}
trap on_exit EXIT

node_log "phase: preflight"
kernel_state="$(node_kernel_update_target_build "$build_id")" || exit 1
kernel_values="$(node_reimage_image_kernel_values "$kernel_state")" || exit 1
IFS=$'\t' read -r to_id to_version to_release _ <<<"$kernel_values"
node_log "target kernel build ${to_id} (${to_version}, ${to_release})"

if [[ "$inventory_role" == master ]]; then
  node_handoff_control_plane_api_if_needed "$profile" "$context" "$inventory_node" "$kubernetes_node"
fi
node_assert_api_reachable "$context"
node_json="$(node_node_json_if_present "$context" "$kubernetes_node")"
[[ -n "$node_json" ]] || node_die "Kubernetes node is absent: ${kubernetes_node}"
case "$inventory_role" in
  master)
    node_assert_kubernetes_control_plane "$node_json" "$kubernetes_node"
    ;;
  *)
    node_assert_inventory_worker "$inventory_node" "$inventory_role"
    node_assert_kubernetes_worker "$node_json" "$kubernetes_node"
    ;;
esac
node_assert_ready "$node_json" "$kubernetes_node"

# Installing the tool is the only node mutation before the confirmation prompt:
# the node's own status is the input every rule below reads, and only the tool
# can report it. Log it so an aborted run still shows what was touched.
[[ -f "$NODE_KERNEL_UPDATE_SCRIPT" ]] ||
  node_die "kernel update tool not found: ${NODE_KERNEL_UPDATE_SCRIPT}"
node_reimage_ansible_copy "$profile" "$inventory_node" \
  "$NODE_KERNEL_UPDATE_SCRIPT" "$NODE_KERNEL_UPDATE_BIN" 0755 ||
  node_die "could not install ${NODE_KERNEL_UPDATE_BIN} on ${inventory_node}"
node_log "installed ${NODE_KERNEL_UPDATE_BIN} on ${inventory_node}"

last_status="$(node_kernel_update_remote_status "$profile" "$inventory_node")" || exit 1
from_id="$(node_kernel_update_status_value "$last_status" marker_build_id)"
node_state="$(node_kernel_update_status_value "$last_status" state)"
resume_verify=false

case "$node_state" in
  S0)
    if [[ -n "$from_id" && "$from_id" == "$to_id" ]]; then
      node_log "already running kernel build ${to_id}; nothing to do"
      exit 0
    fi
    ;;
  S1)
    [[ "$resume" == true ]] ||
      node_die "a trial of ${from_id} is booted but not committed; rerun with --resume, or reboot the node to fall back"
    node_assert_cordoned "$node_json" "$kubernetes_node"
    resume_verify=true
    # A resumed trial is already staged and uncommitted, so a failure from here
    # leaves the node in exactly the shape the exit trap explains.
    staged=true
    ;;
  S2)
    node_warn "the last trial of ${from_id} fell back to $(node_kernel_update_status_value "$last_status" fallback_build_id); this run re-stages ${to_id}"
    ;;
  *)
    print_status_block
    node_die "node is in state ${node_state} (booted_via_fallback=$(node_kernel_update_status_value "$last_status" booted_via_fallback)); clean up by hand before retrying: ${kubernetes_node}"
    ;;
esac

# A resumed trial is already drained and booted: refusing to commit it here
# would strand the node on an uncommitted kernel, which is worse than a primary
# on a node nobody is about to reboot.
if [[ "$resume_verify" == false ]]; then
  node_assert_no_cnpg_primary "$context" "$kubernetes_node"
fi

cat <<EOF

node-kernel-update summary:
  context: ${context}
  target: ${inventory_node}
  role: ${inventory_role}
  from_build: ${from_id}
  to_build: ${to_id}
  node_state: ${node_state}
  fallback_drill: ${drill_fallback}
  final_uncordon: operator-run
EOF

if [[ "$resume_verify" == false ]]; then
  node_confirm "$yes" "update kernel on ${kubernetes_node} to ${to_id} in ${context}"

  node_log "phase: drain"
  # A node cordoned with nothing but DaemonSets left on it is already drained;
  # rerunning the drain script would only wait on Longhorn again.
  if [[ "$(node_schedulable_from_node_json <<<"$node_json")" == cordoned ]] &&
    (node_assert_no_ordinary_pods "$context" "$kubernetes_node") >/dev/null 2>&1; then
    node_log "node already drained: ${kubernetes_node}"
  else
    "$NODE_DRAIN_BIN" --profile "$profile" --context "$context" --yes "$inventory_node"
  fi

  node_log "phase: stage"
  package_dir="$(node_kernel_update_package_dir "$kernel_state")" || exit 1
  staged=true
  remote_dir="$(node_kernel_update_ship "$profile" "$inventory_node" "$package_dir")" || exit 1

  prepare_output="$(node_kernel_update_remote "$profile" "$inventory_node" prepare)" ||
    node_die "kernel update prepare failed on ${inventory_node}"
  [[ -z "$prepare_output" ]] || printf '%s\n' "$prepare_output"
  [[ "$prepare_output" == *prepare=ok* ]] ||
    node_die "kernel update prepare did not report prepare=ok on ${inventory_node}"

  cmdline="$(node_kernel_update_cmdline_args)" || exit 1
  mapfile -t cmdline_args <<<"$cmdline"
  ((${#cmdline_args[@]} > 0)) || node_die "no Raspberry Pi cmdline args to stage"

  stage_output="$(node_kernel_update_remote "$profile" "$inventory_node" \
    stage "$remote_dir" "${cmdline_args[@]}")" ||
    node_die "kernel update stage failed on ${inventory_node}"
  [[ -z "$stage_output" ]] || printf '%s\n' "$stage_output"
  [[ "$stage_output" == *stage=ok* ]] ||
    node_die "kernel update stage did not report stage=ok on ${inventory_node}"
  [[ "$stage_output" == *"staged_build_id=${to_id}"* ]] ||
    node_die "kernel update staged a different build than ${to_id} on ${inventory_node}"

  if [[ "$drill_fallback" == true ]]; then
    node_log "phase: fallback-drill"
    drill_boot_id="$(node_boot_id_from_node_json <<<"$node_json")"
    [[ -n "$drill_boot_id" ]] ||
      node_die "node bootID is missing; cannot verify reboot completion: ${kubernetes_node}"
    node_log "scheduling a plain reboot on ${inventory_node} to prove the fallback boots"
    node_run_remote_shell "$(node_ansible_inventory_file "$profile")" "$inventory_node" \
      "nohup sh -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 &"
    node_log "waiting for ${kubernetes_node} to report a new boot ID"
    node_kernel_update_wait_after_reboot "$context" "$kubernetes_node" \
      "$drill_boot_id" "$NODE_KERNEL_UPDATE_REBOOT_TIMEOUT"

    last_status="$(node_kernel_update_remote_status "$profile" "$inventory_node")" || exit 1
    drill_state="$(node_kernel_update_status_value "$last_status" state)"
    drill_matches="$(node_kernel_update_status_value "$last_status" running_matches)"
    drill_via="$(node_kernel_update_status_value "$last_status" booted_via_fallback)"
    if [[ "$drill_state" == S2 && "$drill_matches" == fallback && "$drill_via" == yes ]]; then
      node_log "fallback drill ok: node booted $(previous_kernel_version) from the fallback copy"
    elif [[ "$drill_via" == yes && "$drill_matches" == marker ]]; then
      print_status_block
      node_die "fallback drill failed: the firmware honoured cmdline= but not kernel=home-ops-kernel-prev/kernel_2712.img — the node came back on ${to_id} (state=${drill_state}). The fallback is NOT armed on this hardware; do not proceed to the fleet. The node is running the new kernel: verify it by hand and commit, or reimage."
    elif [[ "$drill_via" == no ]]; then
      print_status_block
      node_die "fallback drill failed: the firmware ignored the fallback block (state=${drill_state}, running $(node_kernel_update_status_value "$last_status" running_build)). Do not proceed to the fleet; inspect /boot/firmware/config.txt on the node."
    else
      print_status_block
      node_die "fallback drill failed: the node came back in state ${drill_state} (running_matches=${drill_matches}, booted_via_fallback=${drill_via}); do not proceed to the fleet."
    fi
  fi

  node_log "phase: tryboot"
  node_json="$(node_node_json_if_present "$context" "$kubernetes_node")"
  [[ -n "$node_json" ]] ||
    node_die "Kubernetes node disappeared before the trial boot: ${kubernetes_node}"
  previous_boot_id="$(node_boot_id_from_node_json <<<"$node_json")"
  [[ -n "$previous_boot_id" ]] ||
    node_die "node bootID is missing; cannot verify reboot completion: ${kubernetes_node}"
  node_log "trial-booting ${inventory_node} into kernel build ${to_id}"
  node_reimage_tryboot_reboot "$profile" "$inventory_node" \
    /var/log/home-ops-kernel-update.log home-ops-kernel-tryboot
  node_log "waiting for ${kubernetes_node} to report a new boot ID"
  # The wait dies on its own timeout, so it runs in a subshell: the operator
  # needs the power-cycle guidance, not just "timed out".
  (node_kernel_update_wait_after_reboot "$context" "$kubernetes_node" \
    "$previous_boot_id" "$NODE_KERNEL_UPDATE_REBOOT_TIMEOUT") ||
    node_die "the trial boot of ${to_id} did not report Ready within ${NODE_KERNEL_UPDATE_REBOOT_TIMEOUT}s; power-cycle ${kubernetes_node}: config.txt boots the previous kernel ($(previous_kernel_version)). Then rerun to retry, or rerun with --build-id ${from_id} to roll back"
fi

node_log "phase: verify"
last_status="$(node_kernel_update_remote_status "$profile" "$inventory_node")" || exit 1
node_state="$(node_kernel_update_status_value "$last_status" state)"
case "$node_state" in
  S1)
    ;;
  S2)
    # A rollback trial that fell back has nothing older to offer: the build the
    # fallback holds is the one this run was already installing.
    if [[ "$to_id" == "$(node_kernel_update_status_value "$last_status" fallback_build_id)" ]]; then
      node_die "trial boot of ${to_id} fell back to $(previous_kernel_version); the node is on the previous kernel. Inspect it, then rerun to retry the trial"
    fi
    node_die "trial boot of ${to_id} fell back to $(previous_kernel_version); the node is on the previous kernel. Inspect it, then rerun to retry or rerun with --build-id ${from_id} to roll back"
    ;;
  *)
    print_status_block
    node_die "node is in state ${node_state} after the trial boot (booted_via_fallback=$(node_kernel_update_status_value "$last_status" booted_via_fallback)); clean up by hand before retrying: ${kubernetes_node}"
    ;;
esac

if [[ "$skip_smoke" == true ]]; then
  node_warn "skipping the CNI smoke pod on ${kubernetes_node} (--skip-smoke)"
else
  node_kernel_update_cni_smoke "$context" "$kubernetes_node" "$NODE_KERNEL_UPDATE_SMOKE_TIMEOUT"
fi

node_log "phase: commit"
commit_output="$(node_kernel_update_remote "$profile" "$inventory_node" commit)" ||
  node_die "kernel update commit failed on ${inventory_node}"
[[ -z "$commit_output" ]] || printf '%s\n' "$commit_output"
[[ "$commit_output" == *commit=ok* ]] ||
  node_die "kernel update commit did not report commit=ok on ${inventory_node}"
while IFS= read -r line; do
  case "$line" in
    *purge_failed=*)
      node_warn "the superseded kernel packages were not purged on ${inventory_node}: ${line##*purge_failed=}; remove them by hand"
      ;;
    *config_changed_during_update=*)
      node_warn "config.txt on ${inventory_node} changed during the update; review it before the next reboot"
      ;;
  esac
done <<<"$commit_output"

node_log "phase: kernel-build-label"
node_reimage_label_kernel_build "$profile" "$context" "$inventory_node" "$kubernetes_node" "$to_id"

update_state="$(node_kernel_update_write_state \
  "$profile" \
  "$inventory_node" \
  "$context" \
  "$inventory_role" \
  "$from_id" \
  "$to_id" \
  complete \
  "$drill_fallback")" || exit 1

printf 'update_state=%s\n' "$update_state"
printf 'next=%s\n' "just node-status ${inventory_node} && just node-uncordon ${inventory_node}"
