# shellcheck shell=bash

# Host-side helpers for the in-place kernel update. The node-side tool is
# nodes/kernel/update-node.sh, installed as NODE_KERNEL_UPDATE_BIN on every
# run; these helpers pick the build, stage its packages, ship both, read the
# node's status back, and drive the Kubernetes side of the trial reboot.

# Every key nodes/kernel/update-node.sh status_fields prints. A status block
# missing one of them is a truncated read -- a half-written line or a filtered
# transport -- and not a node in a strange state, so the flow must stop rather
# than treat an absent key as an empty value.
NODE_KERNEL_UPDATE_STATUS_KEYS=(
  running_release
  running_build
  booted_via_fallback
  boot_files_present
  marker_present
  marker_build_id
  marker_version
  marker_release
  installed_version
  fallback_copy
  fallback_version
  fallback_release
  fallback_build_id
  config_fallback_block
  tryboot_present
  reimage_staged
  trial_pending
  running_matches
  state
  boot_free_bytes
  boot_set_bytes
  holds
)

# node_kernel_update_state_file prints the update state file of one node.
node_kernel_update_state_file() {
  local profile="$1"
  local inventory_node="$2"

  printf '%s/%s/%s/state/update.json\n' "${NODE_KERNEL_UPDATE_OUTPUT_ROOT%/}" "$profile" "$inventory_node"
}

# node_kernel_update_target_build [ID] prints the kernel build state file to
# update to: a named build, or the build the committed lock pins.
node_kernel_update_target_build() {
  local build_id="${1:-}"

  if [[ -n "$build_id" ]]; then
    node_kernel_require_build "$build_id"
  else
    node_kernel_require_current_build
  fi
}

# node_kernel_update_package_dir stages one build's four packages, their
# SHA256SUMS and kernel-build.env into a per-build directory and prints it.
node_kernel_update_package_dir() {
  local kernel_state="$1"
  local kernel_values build_id version release delta_sha package_dir file sha

  kernel_values="$(node_reimage_image_kernel_values "$kernel_state")" ||
    node_die "could not read kernel build values from ${kernel_state}"
  IFS=$'\t' read -r build_id version release delta_sha <<<"$kernel_values"

  # Emptied, not merged: a deb left by an interrupted run of another build
  # would be shipped alongside this one and fail the node-side package count.
  package_dir="${NODE_KERNEL_UPDATE_OUTPUT_ROOT%/}/packages/${build_id}"
  rm -rf "$package_dir"
  mkdir -p "$package_dir" || node_die "could not create ${package_dir}"
  node_reimage_image_stage_kernel_packages "$kernel_state" "$package_dir"

  {
    while IFS=$'\t' read -r file sha; do
      printf '%s  %s\n' "$sha" "$(basename "$file")"
    done < <("$NODE_JQ_BIN" -r '.packages[] | [.file, .sha256] | @tsv' "$kernel_state")
  } >"${package_dir}/SHA256SUMS" || node_die "could not write ${package_dir}/SHA256SUMS"
  [[ -s "${package_dir}/SHA256SUMS" ]] || node_die "could not write ${package_dir}/SHA256SUMS"

  printf 'KERNEL_BUILD_ID=%s\nKERNEL_PACKAGE_VERSION=%s\nKERNEL_RELEASE=%s\nKERNEL_CONFIG_DELTA_SHA256=%s\n' \
    "$build_id" "$version" "$release" "$delta_sha" >"${package_dir}/kernel-build.env" ||
    node_die "could not write ${package_dir}/kernel-build.env"

  printf '%s\n' "$package_dir"
}

# node_kernel_update_ship installs the node-side tool and one package
# directory on a node, and prints the remote package directory.
node_kernel_update_ship() {
  local profile="$1"
  local inventory_node="$2"
  local package_dir="$3"
  local build_id remote_dir remote_dir_q remote_script file

  [[ -d "$package_dir" ]] || node_die "kernel package directory not found: ${package_dir}"
  [[ -f "$NODE_KERNEL_UPDATE_SCRIPT" ]] || node_die "kernel update tool not found: ${NODE_KERNEL_UPDATE_SCRIPT}"
  build_id="$(basename "$package_dir")"
  node_kernel_build_id_valid "$build_id" || node_die "invalid kernel build id in ${package_dir}"
  remote_dir="${NODE_KERNEL_UPDATE_REMOTE_DIR%/}/${build_id}"
  printf -v remote_dir_q '%q' "$remote_dir"

  # Recreated rather than reused: a deb from an aborted ship would still match
  # SHA256SUMS on the node and be installed as if this run had sent it.
  read -r -d '' remote_script <<EOF || true
set -eu
rm -rf ${remote_dir_q}
install -d -m 0755 ${remote_dir_q}
EOF
  node_run_remote_shell "$(node_ansible_inventory_file "$profile")" "$inventory_node" "$remote_script" >/dev/null ||
    node_die "could not prepare ${remote_dir} on ${inventory_node}"

  # Progress goes to stderr: this function's stdout is the remote directory.
  node_log "shipping kernel build ${build_id} to ${inventory_node}" >&2
  node_reimage_ansible_copy "$profile" "$inventory_node" \
    "$NODE_KERNEL_UPDATE_SCRIPT" "$NODE_KERNEL_UPDATE_BIN" 0755 ||
    node_die "could not install ${NODE_KERNEL_UPDATE_BIN} on ${inventory_node}"
  for file in "${package_dir}"/*; do
    [[ -f "$file" ]] || continue
    node_reimage_ansible_copy "$profile" "$inventory_node" \
      "$file" "${remote_dir}/$(basename "$file")" 0644 ||
      node_die "could not ship $(basename "$file") to ${inventory_node}:${remote_dir} (check free space on /var/tmp)"
  done

  printf '%s\n' "$remote_dir"
}

# node_kernel_update_remote_status prints a node's whole status block.
node_kernel_update_remote_status() {
  local profile="$1"
  local inventory_node="$2"
  local output key

  output="$(node_run_remote_shell "$(node_ansible_inventory_file "$profile")" "$inventory_node" \
    "${NODE_KERNEL_UPDATE_BIN} status")" ||
    node_die "could not read the kernel update status of ${inventory_node}"
  for key in "${NODE_KERNEL_UPDATE_STATUS_KEYS[@]}"; do
    grep -q "^${key}=" <<<"$output" ||
      node_die "truncated kernel update status from ${inventory_node}: missing ${key}"
  done
  printf '%s\n' "$output"
}

# node_kernel_update_status_value BLOCK KEY prints one status value.
node_kernel_update_status_value() {
  local block="$1"
  local key="$2"

  awk -v key="$key" '
    index($0, key "=") == 1 {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' <<<"$block"
}

# node_kernel_update_remote runs the node-side tool and prints its output
# indented, returning what the node returned.
node_kernel_update_remote() {
  local profile="$1"
  local inventory_node="$2"
  shift 2
  local remote_script="$NODE_KERNEL_UPDATE_BIN"
  local arg arg_q output status=0

  for arg in "$@"; do
    printf -v arg_q '%q' "$arg"
    remote_script+=" ${arg_q}"
  done
  output="$(node_run_remote_shell "$(node_ansible_inventory_file "$profile")" "$inventory_node" "$remote_script")" ||
    status=$?
  [[ -z "$output" ]] || node_indent_block <<<"$output"
  return "$status"
}

# node_kernel_update_cmdline_args prints the repo's Raspberry Pi cmdline args
# as "--cmdline-arg X" pairs, one token per line. They go to stage, which adds
# them to the trial line only, and never to prepare. Read it through a plain
# command substitution, never process substitution, which would swallow the
# node_die and stage a node with no cmdline args at all:
#   cmdline="$(node_kernel_update_cmdline_args)" || exit 1
#   mapfile -t cmdline_args <<<"$cmdline"
#   ((${#cmdline_args[@]} > 0)) || node_die "no Raspberry Pi cmdline args to stage"
node_kernel_update_cmdline_args() {
  local args arg
  local -a tokens=()

  args="$(node_reimage_image_boot_cmdline_args)" ||
    node_die "could not read the Raspberry Pi cmdline args"
  read -r -a tokens <<<"$args"
  for arg in "${tokens[@]}"; do
    printf '%s\n%s\n' --cmdline-arg "$arg"
  done
}

# node_kernel_update_wait_after_reboot waits for a node to come back on a new
# boot with its CNI and storage ready, exactly as nodes/reboot.sh does.
node_kernel_update_wait_after_reboot() {
  local context="$1"
  local node="$2"
  local previous_boot_id="$3"
  local timeout="${4:-$NODE_KERNEL_UPDATE_REBOOT_TIMEOUT}"

  node_wait_for_boot_id_change "$context" "$node" "$previous_boot_id" "$timeout"
  node_wait_for_cilium_ready "$context" "$node" 600
  node_wait_for_longhorn_ready_for_kubernetes_uncordon "$context" "$node" 600
}

# node_kernel_update_smoke_pod_manifest prints the CNI smoke pod for a node.
node_kernel_update_smoke_pod_manifest() {
  local node="$1"
  local pod="$2"

  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
spec:
  nodeName: ${node}
  restartPolicy: Never
  activeDeadlineSeconds: 120
  tolerations:
    - operator: Exists
  containers:
    - name: smoke
      image: ${NODE_KERNEL_UPDATE_SMOKE_IMAGE}
      imagePullPolicy: IfNotPresent
      command:
        - sh
        - -c
        - nslookup kubernetes.default.svc.cluster.local >/dev/null && echo cni-smoke-ok
EOF
}

# node_kernel_update_wait_for_pod_absent waits until a pod object is gone.
node_kernel_update_wait_for_pod_absent() {
  local context="$1"
  local namespace="$2"
  local pod="$3"
  local timeout="$4"
  local deadline=$((SECONDS + timeout))

  while node_has_resource "$context" -n "$namespace" "pod/${pod}"; do
    ((SECONDS < deadline)) ||
      node_die "timed out waiting for the CNI smoke pod to be deleted: ${namespace}/${pod}"
    sleep 1
  done
}

# node_kernel_update_smoke_log prints the smoke pod's last log line. A pod that
# never ran has no logs, so a failed read is an empty line and not a fatal
# error: the caller decides what a missing cni-smoke-ok means.
node_kernel_update_smoke_log() {
  local context="$1"
  local namespace="$2"
  local pod="$3"
  local logs

  logs="$(node_kubectl "$context" -n "$namespace" logs "pod/${pod}" --tail=1 2>/dev/null | sed -n '$p')" ||
    logs=""
  printf '%s\n' "${logs:-<no output>}"
}

# node_kernel_update_smoke_detail prints why the smoke pod is not running --
# the container's waiting reason, the pod-level failure reason, or the first
# false condition -- with its last log line. A pod stuck on an image pull has
# no logs at all, and once activeDeadlineSeconds fires the kubelet replaces
# its container state with a bare DeadlineExceeded: both are cases the log
# line alone cannot explain.
node_kernel_update_smoke_detail() {
  local context="$1"
  local namespace="$2"
  local pod="$3"
  local pod_json waiting logs

  pod_json="$(node_get_json "$context" -n "$namespace" "pod/${pod}" 2>/dev/null)" || pod_json=""
  waiting=""
  if [[ -n "$pod_json" ]]; then
    waiting="$("$NODE_JQ_BIN" -r '
      [
        (.status.containerStatuses[]? | .state.waiting | select(. != null) | "\(.reason // "Waiting"): \(.message // "")"),
        (select(.status.reason != null) | "\(.status.reason): \(.status.message // "")"),
        (.status.conditions[]? | select(.status == "False") | .message // "")
      ]
      | map(select(. != null and (. | length) > 0))
      | first // ""
    ' <<<"$pod_json" 2>/dev/null)" || waiting=""
  fi
  logs="$(node_kernel_update_smoke_log "$context" "$namespace" "$pod")"
  if [[ -n "$waiting" ]]; then
    printf '%s; last log: %s\n' "$waiting" "$logs"
  else
    printf 'last log: %s\n' "$logs"
  fi
}

# node_kernel_update_cni_smoke proves a rebooted node can still resolve
# in-cluster DNS through its CNI before the node is uncordoned. The pod is
# removed again, and waited for, so a later drained check never sees it.
node_kernel_update_cni_smoke() {
  local context="$1"
  local node="$2"
  local timeout="${3:-$NODE_KERNEL_UPDATE_SMOKE_TIMEOUT}"
  local namespace="$NODE_KERNEL_UPDATE_SMOKE_NAMESPACE"
  local pod="smoke-${node}"
  local deadline phase logs

  if ! node_has_resource "$context" "namespace/${namespace}"; then
    node_kubectl "$context" create namespace "$namespace" >/dev/null ||
      node_die "could not create the CNI smoke namespace ${namespace}"
  fi
  node_kubectl "$context" -n "$namespace" delete "pod/${pod}" --ignore-not-found --wait=false >/dev/null ||
    node_die "could not delete a leftover CNI smoke pod: ${namespace}/${pod}"
  node_kernel_update_wait_for_pod_absent "$context" "$namespace" "$pod" "$timeout"

  node_log "running the CNI smoke pod ${namespace}/${pod} on ${node}"
  node_kernel_update_smoke_pod_manifest "$node" "$pod" |
    node_kubectl "$context" -n "$namespace" apply -f - >/dev/null ||
    node_die "could not create the CNI smoke pod ${namespace}/${pod} on ${node}"

  deadline=$((SECONDS + timeout))
  while true; do
    # An unreadable pod is one more poll, not the end of the run: the API
    # server is exactly what a just-rebooted node is still reconnecting to.
    phase="$(node_get_json "$context" -n "$namespace" "pod/${pod}" 2>/dev/null |
      "$NODE_JQ_BIN" -r '.status.phase // ""' 2>/dev/null)" || phase=""
    case "$phase" in
      Succeeded) break ;;
      Failed)
        node_die "CNI smoke pod failed on ${node}: $(node_kernel_update_smoke_detail "$context" "$namespace" "$pod")"
        ;;
    esac
    ((SECONDS < deadline)) ||
      node_die "timed out waiting for the CNI smoke pod on ${node} (phase=${phase:-unknown}): $(node_kernel_update_smoke_detail "$context" "$namespace" "$pod")"
    sleep 5
  done

  # Read the log, then remove the pod, then judge: a lost log read must still
  # leave the node clean for the drained check that follows.
  logs="$(node_kernel_update_smoke_log "$context" "$namespace" "$pod")"
  node_kubectl "$context" -n "$namespace" delete "pod/${pod}" --ignore-not-found --wait=false >/dev/null ||
    node_die "could not delete the CNI smoke pod: ${namespace}/${pod}"
  node_kernel_update_wait_for_pod_absent "$context" "$namespace" "$pod" "$timeout"

  [[ "$logs" == *cni-smoke-ok* ]] ||
    node_die "CNI smoke pod on ${node} did not report cni-smoke-ok: ${logs}"
  printf 'cni_smoke=ok\n'
}

# node_kernel_update_write_state records one node's update and prints the path.
node_kernel_update_write_state() {
  local profile="$1"
  local inventory_node="$2"
  local context="$3"
  local role="$4"
  local from_build_id="$5"
  local to_build_id="$6"
  local status="$7"
  local fallback_drill="$8"
  local state_file state_dir

  [[ "$fallback_drill" == true || "$fallback_drill" == false ]] ||
    node_die "fallbackDrill must be true or false: ${fallback_drill}"
  state_file="$(node_kernel_update_state_file "$profile" "$inventory_node")"
  state_dir="$(dirname "$state_file")"
  mkdir -p "$state_dir" || node_die "could not create ${state_dir}"
  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -n \
    --arg schema "$NODE_KERNEL_UPDATE_SCHEMA" \
    --arg completedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg profile "$profile" \
    --arg context "$context" \
    --arg node "$inventory_node" \
    --arg role "$role" \
    --arg fromBuildId "$from_build_id" \
    --arg toBuildId "$to_build_id" \
    --arg status "$status" \
    --argjson fallbackDrill "$fallback_drill" \
    '{
      schemaVersion: $schema,
      completedAt: $completedAt,
      profile: $profile,
      context: $context,
      node: $node,
      role: $role,
      fromBuildId: $fromBuildId,
      toBuildId: $toBuildId,
      status: $status,
      fallbackDrill: $fallbackDrill
    }' >"${state_file}.tmp" || {
    rm -f "${state_file}.tmp"
    node_die "could not write ${state_file}"
  }
  mv "${state_file}.tmp" "$state_file" || node_die "could not write ${state_file}"
  printf '%s\n' "$state_file"
}
