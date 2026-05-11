#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${BOOTSTRAP_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${BOOTSTRAP_DIR}/lib/k8s.sh"
# shellcheck disable=SC1091
source "${BOOTSTRAP_DIR}/lib/render.sh"
# shellcheck disable=SC1091
source "${BOOTSTRAP_DIR}/lib/reports.sh"

PHASES=(
  preflight
  seed-secret
  bootstrap-crds
  cert-manager
  external-secrets
  dragonfly-operator
  argocd-dependencies
  argocd
  wait-argocd
  takeover-cleanup
  audit
)

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/bootstrap.sh [options]

Options:
  --repo PATH              Local home-ops checkout. Defaults to repo root.
  --repo-url URL           Clone/fetch home-ops from URL into a temp dir.
  --ref REF                Git ref for --repo-url mode. Defaults to master.
  --kubeconfig PATH        Kubeconfig path.
  --kube-context NAME      Kube context to use.
  --op-vault NAME          1Password vault. Defaults to Kubernetes.
  --op-item NAME           1Password item. Defaults to op-credentials.
  --op-field NAME          1Password field. Defaults to op-credentials.yaml.
  --op-account NAME        Optional 1Password account shorthand.
  --seed-secret-stdin      Read the 1Password seed Secret manifest from stdin.
  --field-manager NAME     Server-side apply field manager. Defaults to argocd-controller.
  --profile NAME           Bootstrap profile: full or foundation. Defaults to full.
  --dry-run                Use server-side dry-run where possible.
  --yes                    Do not prompt for confirmation.
  --audit-only             Run only the audit phase.
  --from-phase NAME        Start at phase NAME.
  --only-phase NAME        Run only phase NAME.
  -h, --help               Show help.
EOF
}

parse_args() {
  REPO_PATH=""
  REPO_URL=""
  REPO_REF="master"
  KUBECONFIG_PATH="${KUBECONFIG:-}"
  KUBE_CONTEXT=""
  OP_VAULT="Kubernetes"
  OP_ITEM="op-credentials"
  OP_FIELD="op-credentials.yaml"
  BOOTSTRAP_OP_ACCOUNT="${BOOTSTRAP_OP_ACCOUNT:-}"
  SEED_SECRET_STDIN=false
  FIELD_MANAGER="argocd-controller"
  BOOTSTRAP_PROFILE="full"
  DRY_RUN=false
  YES=false
  AUDIT_ONLY=false
  FROM_PHASE=""
  ONLY_PHASE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        REPO_PATH="$2"
        shift 2
        ;;
      --repo-url)
        REPO_URL="$2"
        shift 2
        ;;
      --ref)
        REPO_REF="$2"
        shift 2
        ;;
      --kubeconfig)
        KUBECONFIG_PATH="$2"
        shift 2
        ;;
      --kube-context)
        KUBE_CONTEXT="$2"
        shift 2
        ;;
      --op-vault)
        OP_VAULT="$2"
        shift 2
        ;;
      --op-item)
        OP_ITEM="$2"
        shift 2
        ;;
      --op-field)
        OP_FIELD="$2"
        shift 2
        ;;
      --op-account)
        BOOTSTRAP_OP_ACCOUNT="$2"
        shift 2
        ;;
      --seed-secret-stdin)
        SEED_SECRET_STDIN=true
        shift
        ;;
      --field-manager)
        FIELD_MANAGER="$2"
        shift 2
        ;;
      --profile)
        BOOTSTRAP_PROFILE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --yes)
        YES=true
        shift
        ;;
      --audit-only)
        AUDIT_ONLY=true
        shift
        ;;
      --from-phase)
        FROM_PHASE="$2"
        shift 2
        ;;
      --only-phase)
        ONLY_PHASE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

resolve_repo_root() {
  if [[ -n "$REPO_URL" ]]; then
    REPO_WORK_DIR="${TMP_DIR}/repo"
    log "cloning ${REPO_URL} at ${REPO_REF}"
    git clone --quiet "$REPO_URL" "$REPO_WORK_DIR"
    git -C "$REPO_WORK_DIR" fetch --quiet origin "$REPO_REF"
    git -C "$REPO_WORK_DIR" checkout --quiet FETCH_HEAD
    REPO_ROOT="$REPO_WORK_DIR"
    return
  fi

  if [[ -n "$REPO_PATH" ]]; then
    REPO_ROOT="$(cd "$REPO_PATH" && pwd)"
    return
  fi

  REPO_ROOT="$(cd "${BOOTSTRAP_DIR}/../.." && pwd)"
}

phase_selected() {
  local phase="$1"
  if [[ "$AUDIT_ONLY" == true ]]; then
    [[ "$phase" == "audit" ]]
    return
  fi
  if [[ -n "$ONLY_PHASE" ]]; then
    [[ "$phase" == "$ONLY_PHASE" ]]
    return
  fi
  if [[ -z "$FROM_PHASE" ]]; then
    return 0
  fi

  local seen=false candidate
  for candidate in "${PHASES[@]}"; do
    if [[ "$candidate" == "$FROM_PHASE" ]]; then
      seen=true
    fi
    if [[ "$candidate" == "$phase" ]]; then
      [[ "$seen" == true ]]
      return
    fi
  done
  return 1
}

validate_phase_names() {
  local candidate found phase
  for candidate in "$FROM_PHASE" "$ONLY_PHASE"; do
    [[ -z "$candidate" ]] && continue
    found=false
    for phase in "${PHASES[@]}"; do
      if [[ "$phase" == "$candidate" ]]; then
        found=true
      fi
    done
    [[ "$found" == true ]] || die "unknown phase: ${candidate}"
  done

  case "$BOOTSTRAP_PROFILE" in
    full|foundation) ;;
    *) die "unknown bootstrap profile: ${BOOTSTRAP_PROFILE}" ;;
  esac
}

run_phase() {
  local phase="$1"
  phase_selected "$phase" || return 0
  log_phase "$phase"
  # shellcheck source=/dev/null
  source "${BOOTSTRAP_DIR}/phases/${phase}.sh"
}

main() {
  parse_args "$@"
  validate_phase_names

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR}"' EXIT

  resolve_repo_root
  setup_report_dir
  exec > >(tee -a "${REPORT_DIR}/bootstrap.log") 2>&1

  export BOOTSTRAP_DIR REPO_ROOT TMP_DIR REPORT_DIR
  export KUBECONFIG_PATH KUBE_CONTEXT OP_VAULT OP_ITEM OP_FIELD BOOTSTRAP_OP_ACCOUNT SEED_SECRET_STDIN FIELD_MANAGER
  export BOOTSTRAP_PROFILE
  export DRY_RUN YES AUDIT_ONLY

  for phase in "${PHASES[@]}"; do
    run_phase "$phase"
  done
}

main "$@"
