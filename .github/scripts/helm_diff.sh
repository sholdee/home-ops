#!/usr/bin/env bash
set -euo pipefail

###############################
## Check required input vars ##
###############################
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${BASE_REF:?BASE_REF is required}"

#######################
## Setup script vars ##
#######################
KUBE_VERSION_DEFAULT="1.33.0"
PLAN_FILE="apps/system-upgrade/manifests/plan.yaml"
BASE_WORKTREE_DIR="../base-worktree"
ARGO_APPLICATION_KIND="Application"
ARGO_APPLICATION_API_VERSIONS=("argoproj.io/v1alpha1")

EXCLUDE_FIELDS='.metadata.labels."helm.sh/chart"'
EXCLUDE_FIELDS+=',.metadata.labels.chart'
EXCLUDE_FIELDS+=',.metadata.labels."app.kubernetes.io/version"'
EXCLUDE_FIELDS+=',.spec.template.metadata.labels."helm.sh/chart"'
EXCLUDE_FIELDS+=',.spec.template.metadata.labels.chart'
EXCLUDE_FIELDS+=',.spec.template.metadata.labels."app.kubernetes.io/version"'
EXCLUDE_FIELDS+=',.spec.template.metadata.annotations."checksum/*"'

#####################
## Setup functions ##
#####################
#######################################
# Description: Build a yq expression that matches any provided apiVersion.
# Arguments:
#   $@ - One or more apiVersion strings
# Outputs:
#   Prints a yq expression like: (.apiVersion == "v1" or .apiVersion == "v2")
#######################################
build_yq_apiversion_expr() {
    local expr=""
    local version

    for version in "$@"; do
        [[ -z "$version" ]] && continue
        if [[ -n "$expr" ]]; then
            expr+=" or "
        fi
        expr+=".apiVersion == \"${version}\""
    done

    # If no versions provided, default to an always-false match.
    if [[ -z "$expr" ]]; then
        printf '%s' '(.apiVersion == "")'
        return
    fi

    printf '(%s)' "$expr"
}

# Precomputed Argo Application selectors for yq.
ARGO_APP_API_VERSION_MATCH="$(build_yq_apiversion_expr "${ARGO_APPLICATION_API_VERSIONS[@]}")"
ARGO_APP_BASE_SELECTOR="select(${ARGO_APP_API_VERSION_MATCH} and .kind == \"${ARGO_APPLICATION_KIND}\")"

#######################################
# Description: Determine Kubernetes version for Helm templating
# Globals:
#   KUBE_VERSION_DEFAULT - Default fallback version
#   PLAN_FILE - Path to system-upgrade plan file
#   KUBE_VERSION - Set by this function
# Arguments:
#   $1 - Optional kubeVersion override from Argo spec
# Outputs:
#   Version string message to stdout
# Returns:
#   0 if successful
#######################################
get_kube_version() {
    # Optional override (e.g. from spec.source.helm.kubeVersion)
    local override="${1:-}"

    if [[ -n "$override" && "$override" != "null" ]]; then
        # Argo expects semver without leading "v", but be lenient
        local stripped="${override#v}"
        KUBE_VERSION="$stripped"
        echo "📌 Using override kubeVersion=${KUBE_VERSION} for Helm templating"
        return
    fi

    KUBE_VERSION="$KUBE_VERSION_DEFAULT"
    if [ -f "$PLAN_FILE" ]; then
        RAW_K3S_VERSION=$(
            yq e '. |
              select(.kind == "Plan"
                     and .metadata.name == "k3s-server") |
              .spec.version' "$PLAN_FILE" 2>/dev/null || echo ""
        )
        if [ -n "$RAW_K3S_VERSION" ] && [ "$RAW_K3S_VERSION" != "null" ]; then
            # Strip leading "v" and any "+k3s1" style suffix
            STRIPPED="${RAW_K3S_VERSION#v}"
            STRIPPED="${STRIPPED%%+*}"

            # Only accept full semver-like x.y.z
            if [[ "$STRIPPED" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                KUBE_VERSION="$STRIPPED"
            else
                echo "⚠️ Parsed kube version '$STRIPPED' did not match x.y.z, using fallback ${KUBE_VERSION_DEFAULT}"
            fi
        fi
    else
        echo "⚠️ Plan file '$PLAN_FILE' not found, using fallback kube version ${KUBE_VERSION_DEFAULT}"
    fi

    echo "📌 Using kubeVersion=${KUBE_VERSION} for Helm templating"
}

#######################################
# Description: Process and diff two manifest files
# Globals:
#   EXCLUDE_FIELDS - Fields to exclude from diff
# Arguments:
#   $1 - Path to old manifest file
#   $2 - Path to new manifest file
# Outputs:
#   Appends diff to diff.txt
# Returns:
#   0 if successful
#######################################
process_and_diff() {
    local old_file="$1"
    local new_file="$2"

    local tmpdir
    tmpdir="$(mktemp -d helm_diff_tmp_XXXX)"
    local old_processed="${tmpdir}/old.yaml"
    local new_processed="${tmpdir}/new.yaml"

    echo "🛠️ Processing manifests for diff..."
    yq eval "del(${EXCLUDE_FIELDS}) | select(.kind != \"Secret\")" "$old_file" > "$old_processed"
    yq eval "del(${EXCLUDE_FIELDS}) | select(.kind != \"Secret\")" "$new_file" > "$new_processed"

    echo "🔍 Generating diff"
    git diff --no-index --text "$old_processed" "$new_processed" >> diff.txt || true
    rm -rf "$tmpdir"
}

#######################################
# Description: Render Helm templates for old and new versions and diff them
# Globals:
#   HELM_ARGS_OLD - Helm arguments array for old version (caller-provided)
#   HELM_ARGS_NEW - Helm arguments array for new version (caller-provided)
# Arguments:
#   $1  - Application name
#   $2  - Repository URL (OCI or HTTP)
#   $3  - Chart name
#   $4  - Old chart version
#   $5  - New chart version
#   $6  - Old namespace
#   $7  - New namespace
#   $8  - Old release name
#   $9  - New release name
#   $10 - Old kubeVersion override (optional)
#   $11 - New kubeVersion override (optional)
# Outputs:
#   Status messages and diff via process_and_diff
# Returns:
#   0 if successful, 1 on error
#######################################
helm_template_and_diff() {
    APP_NAME="$1"
    REPO_URL="$2"
    CHART_NAME="$3"
    OLD_VERSION="$4"
    NEW_VERSION="$5"
    OLD_NAMESPACE="$6"
    NEW_NAMESPACE="$7"
    OLD_RELEASE_NAME="$8"
    NEW_RELEASE_NAME="$9"
    OLD_KUBE_VERSION_OVERRIDE="${10:-}"
    NEW_KUBE_VERSION_OVERRIDE="${11:-}"

    # HELM_ARGS_OLD / HELM_ARGS_NEW are populated by the caller

    # Track whether we actually have versions
    local HAS_OLD_VERSION=1
    local HAS_NEW_VERSION=1

    if [[ -z "$OLD_VERSION" || "$OLD_VERSION" == "null" ]]; then
        HAS_OLD_VERSION=0
    fi
    if [[ -z "$NEW_VERSION" || "$NEW_VERSION" == "null" ]]; then
        HAS_NEW_VERSION=0
    fi

    # If neither side has a version, nothing to render
    if (( HAS_OLD_VERSION == 0 && HAS_NEW_VERSION == 0 )); then
        echo "ℹ️ No targetRevision found for $APP_NAME/$CHART_NAME; skipping templating."
        return 0
    fi

    # We must have a new version to render anything useful
    if (( HAS_NEW_VERSION == 0 )); then
        echo "⚠️ New targetRevision missing for $APP_NAME/$CHART_NAME; skipping templating."
        return 1
    fi

    # Default release names if not set
    if [[ -z "$OLD_RELEASE_NAME" || "$OLD_RELEASE_NAME" == "null" ]]; then
        OLD_RELEASE_NAME="$APP_NAME"
    fi
    if [[ -z "$NEW_RELEASE_NAME" || "$NEW_RELEASE_NAME" == "null" ]]; then
        NEW_RELEASE_NAME="$APP_NAME"
    fi

    # Default namespaces if somehow empty
    if [[ -z "$OLD_NAMESPACE" || "$OLD_NAMESPACE" == "null" ]]; then
        OLD_NAMESPACE="default"
    fi
    if [[ -z "$NEW_NAMESPACE" || "$NEW_NAMESPACE" == "null" ]]; then
        NEW_NAMESPACE="default"
    fi

    #######################
    ## Resolve chart ref ##
    #######################
    if [[ "$REPO_URL" == oci://* || ( "$REPO_URL" != http://* && "$REPO_URL" != https://* && "$REPO_URL" != file://* ) ]]; then
        ########################
        # ===== OCI REPO ===== #
        ########################
        CHART_REF="$REPO_URL"
        if [[ "$CHART_REF" != oci://* ]]; then
            CHART_REF="oci://$CHART_REF"
        fi

        # Append chart name if repoURL doesn't already include it
        if [[ "$CHART_REF" != */"$CHART_NAME" ]]; then
            CHART_REF="${CHART_REF%/}/$CHART_NAME"
        fi

        echo "📦 OCI chart detected: $CHART_REF"
        echo "📡 Validating versions in OCI registry..."

        if (( HAS_OLD_VERSION == 1 )); then
            if ! helm show chart "$CHART_REF" --version "$OLD_VERSION" >/dev/null 2>&1; then
                echo "⚠️ Chart $CHART_REF version $OLD_VERSION not found in OCI registry. Skipping old side..."
                HAS_OLD_VERSION=0
            fi
        fi

        if ! helm show chart "$CHART_REF" --version "$NEW_VERSION" >/dev/null 2>&1; then
            echo "⚠️ Chart $CHART_REF version $NEW_VERSION not found in OCI registry. Skipping..."
            return 1
        fi
    else
        #########################
        # ===== HTTP REPO ===== #
        #########################
        REPO_NAME=$(echo "$REPO_URL" | sed 's|/$||' | awk -F/ '{print $NF}')
        CHART_REF="${REPO_NAME}/${CHART_NAME}"

        echo "📦 HTTP chart repo detected: $REPO_URL (name: $REPO_NAME)"
        echo "📡 Checking available versions for $CHART_NAME in $REPO_NAME..."

        helm repo add "$REPO_NAME" "$REPO_URL"
        helm repo update "$REPO_NAME"

        if (( HAS_OLD_VERSION == 1 )); then
            if ! helm search repo "$CHART_REF" --versions | grep -q "$OLD_VERSION"; then
                echo "⚠️ Chart $CHART_REF version $OLD_VERSION not found in repo $REPO_NAME. Skipping old side..."
                HAS_OLD_VERSION=0
            fi
        fi

        if ! helm search repo "$CHART_REF" --versions | grep -q "$NEW_VERSION"; then
            echo "⚠️ Chart $CHART_REF version $NEW_VERSION not found in repo $REPO_NAME. Skipping..."
            return 1
        fi
    fi

    #############################
    # ===== RENDER CHARTS ===== #
    #############################
    local workdir
    workdir="$(mktemp -d "helm_diff_${APP_NAME}_XXXX")"

    # OLD side
    if (( HAS_OLD_VERSION == 1 )); then
        echo "🎭 Rendering old Helm template: $APP_NAME $CHART_REF --version $OLD_VERSION ..."
        get_kube_version "$OLD_KUBE_VERSION_OVERRIDE"
        if ! helm template "$OLD_RELEASE_NAME" "$CHART_REF" \
            --version "$OLD_VERSION" \
            --namespace "$OLD_NAMESPACE" \
            --kube-version "$KUBE_VERSION" \
            "${HELM_ARGS_OLD[@]}" > "${workdir}/old.yaml"; then
            echo "❌ Helm template failed for old version"
            rm -rf "$workdir"
            return 1
        fi
    else
        echo "🆕 No old version for $APP_NAME/$CHART_NAME; treating old manifests as empty."
        echo "" > "${workdir}/old.yaml"
    fi

    # NEW side (must exist)
    echo "🎭 Rendering new Helm template: $APP_NAME $CHART_REF --version $NEW_VERSION ..."
    get_kube_version "$NEW_KUBE_VERSION_OVERRIDE"
    if ! helm template "$NEW_RELEASE_NAME" "$CHART_REF" \
        --version "$NEW_VERSION" \
        --namespace "$NEW_NAMESPACE" \
        --kube-version "$KUBE_VERSION" \
        "${HELM_ARGS_NEW[@]}" > "${workdir}/new.yaml"; then
        echo "❌ Helm template failed for new version"
        rm -rf "$workdir"
        return 1
    fi

    process_and_diff "${workdir}/old.yaml" "${workdir}/new.yaml"
    rm -rf "$workdir"
}

#######################################
# Description: Process a single Argo CD Application source for Helm changes.
#
# Notes:
# - Compares the PR working tree to a checked-out base worktree (`$BASE_WORKTREE_DIR`).
# - If the base branch does not contain the Application manifest file (e.g., app added in PR),
#   old-side Helm inputs are treated as empty/defaults so the diff shows a net-new install.
# Globals:
#   BASE_REF - Base branch reference
#   BASE_WORKTREE_DIR - Base worktree checkout root
#   HELM_ARGS_OLD - Set by this function for old revision
#   HELM_ARGS_NEW - Set by this function for new revision
# Arguments:
#   $1 - File path to Argo Application manifest
#   $2 - Application name
#   $3 - Application namespace
#   $4 - Source expression (e.g., .spec.source or .spec.sources[0])
#   $5 - Source label for logging (e.g., "source" or "sources[0]")
# Outputs:
#   Status messages; may call helm_template_and_diff
# Returns:
#   0 if successful or no changes detected (or not a Helm source)
#######################################
process_argo_source() {
    local FILE="$1"
    local APP_NAME="$2"
    local NAMESPACE="$3"
    local SRC_EXPR="$4"   # e.g. .spec.source or .spec.sources[0]
    local SRC_LABEL="$5"  # for logging, e.g. "source" or "sources[0]"

    local APP_SELECTOR
    APP_SELECTOR="select(${ARGO_APP_API_VERSION_MATCH} and .kind == \"${ARGO_APPLICATION_KIND}\" and .metadata.name == \"${APP_NAME}\" and (.metadata.namespace == \"${NAMESPACE}\" or .metadata.namespace == null))"

    local BASE_FILE="${BASE_WORKTREE_DIR}/${FILE}"
    local HAS_BASE_FILE=0
    if [[ -f "$BASE_FILE" ]]; then
        HAS_BASE_FILE=1
    else
        echo "🆕 No base counterpart for $FILE on origin/${BASE_REF}; treating old side as empty for $APP_NAME ${SRC_LABEL}."
    fi

    # OLD (base) fields
    local OLD_VERSION OLD_VALUES_OBJECT OLD_VALUES_STRING OLD_PARAMETERS
    local OLD_FILE_PARAMETERS OLD_RELEASE_NAME OLD_HELM_NAMESPACE
    local OLD_HELM_KUBEVERSION OLD_DEST_NAMESPACE

    if (( HAS_BASE_FILE == 1 )); then
        OLD_VERSION=$(yq e \
            "${APP_SELECTOR} | ${SRC_EXPR}.targetRevision" "$BASE_FILE")
        OLD_VALUES_OBJECT=$(yq e \
            "${APP_SELECTOR} | ${SRC_EXPR}.helm.valuesObject" "$BASE_FILE")
        OLD_VALUES_STRING=$(yq e \
            "${APP_SELECTOR} | ${SRC_EXPR}.helm.values" "$BASE_FILE")
        OLD_PARAMETERS=$(yq e -o=json -r \
            "${APP_SELECTOR} | ${SRC_EXPR}.helm.parameters | select(.) | select(length > 0) | tojson" "$BASE_FILE" 2>/dev/null || echo "")
        OLD_FILE_PARAMETERS=$(yq e -o=json -r \
            "${APP_SELECTOR} | ${SRC_EXPR}.helm.fileParameters | select(.) | tojson" "$BASE_FILE" 2>/dev/null || echo "")
        OLD_RELEASE_NAME=$(yq e \
            "${APP_SELECTOR} | ${SRC_EXPR}.helm.releaseName" "$BASE_FILE")
        OLD_HELM_NAMESPACE=$(yq e \
            "${APP_SELECTOR} | ${SRC_EXPR}.helm.namespace" "$BASE_FILE")
        OLD_HELM_KUBEVERSION=$(yq e \
            "${APP_SELECTOR} | ${SRC_EXPR}.helm.kubeVersion" "$BASE_FILE")
        OLD_DEST_NAMESPACE=$(yq e \
            "${APP_SELECTOR} | .spec.destination.namespace" "$BASE_FILE" 2>/dev/null || echo "default")
    else
        OLD_VERSION=""
        OLD_VALUES_OBJECT=""
        OLD_VALUES_STRING=""
        OLD_PARAMETERS=""
        OLD_FILE_PARAMETERS=""
        OLD_RELEASE_NAME=""
        OLD_HELM_NAMESPACE=""
        OLD_HELM_KUBEVERSION=""
        OLD_DEST_NAMESPACE="default"
    fi

    # NEW (PR) fields
    local NEW_VERSION NEW_VALUES_OBJECT NEW_VALUES_STRING NEW_PARAMETERS
    local NEW_FILE_PARAMETERS NEW_RELEASE_NAME NEW_HELM_NAMESPACE
    local NEW_HELM_KUBEVERSION NEW_DEST_NAMESPACE

    NEW_VERSION=$(yq e \
        "${APP_SELECTOR} | ${SRC_EXPR}.targetRevision" "$FILE")
    NEW_VALUES_OBJECT=$(yq e \
        "${APP_SELECTOR} | ${SRC_EXPR}.helm.valuesObject" "$FILE")
    NEW_VALUES_STRING=$(yq e \
        "${APP_SELECTOR} | ${SRC_EXPR}.helm.values" "$FILE")
    NEW_PARAMETERS=$(yq e -o=json -r \
        "${APP_SELECTOR} | ${SRC_EXPR}.helm.parameters | select(.) | select(length > 0) | tojson" "$FILE" 2>/dev/null || echo "")
    NEW_FILE_PARAMETERS=$(yq e -o=json -r \
        "${APP_SELECTOR} | ${SRC_EXPR}.helm.fileParameters | select(.) | tojson" "$FILE" 2>/dev/null || echo "")
    NEW_RELEASE_NAME=$(yq e \
        "${APP_SELECTOR} | ${SRC_EXPR}.helm.releaseName" "$FILE")
    NEW_HELM_NAMESPACE=$(yq e \
        "${APP_SELECTOR} | ${SRC_EXPR}.helm.namespace" "$FILE")
    NEW_HELM_KUBEVERSION=$(yq e \
        "${APP_SELECTOR} | ${SRC_EXPR}.helm.kubeVersion" "$FILE")
    NEW_DEST_NAMESPACE=$(yq e \
        "${APP_SELECTOR} | .spec.destination.namespace" "$FILE" 2>/dev/null || echo "default")

    # Chart/repoURL (from PR – needed for fallback mapping)
    local CHART_NAME REPO_URL
    CHART_NAME=$(yq e \
        "${APP_SELECTOR} | ${SRC_EXPR}.chart" "$FILE")
    REPO_URL=$(yq e \
        "${APP_SELECTOR} | ${SRC_EXPR}.repoURL" "$FILE")

    # If this is a .spec.sources[i] entry with no old config, try to
    # map it back to the old .spec.source in the base ref if it has
    # the same chart + repoURL. This handles the "source → sources[0]"
    # migration without showing a net-add diff.
    if [[ "$SRC_EXPR" == .spec.sources* ]] && [[ -z "$OLD_VERSION" || "$OLD_VERSION" == "null" ]]; then
        local F_OLD_CHART F_OLD_REPO
        if (( HAS_BASE_FILE == 1 )); then
            F_OLD_CHART=$(yq e \
                "${APP_SELECTOR} | .spec.source.chart" "$BASE_FILE")
            F_OLD_REPO=$(yq e \
                "${APP_SELECTOR} | .spec.source.repoURL" "$BASE_FILE")
        else
            F_OLD_CHART=""
            F_OLD_REPO=""
        fi

        if [[ -n "$F_OLD_CHART" && "$F_OLD_CHART" != "null" && -n "$F_OLD_REPO" && "$F_OLD_REPO" != "null" ]]; then
            if [[ "$F_OLD_CHART" == "$CHART_NAME" && "$F_OLD_REPO" == "$REPO_URL" ]]; then
                # Rehydrate OLD_* from .spec.source in base
                OLD_VERSION=$(yq e \
                    "${APP_SELECTOR} | .spec.source.targetRevision" "$BASE_FILE")
                OLD_VALUES_OBJECT=$(yq e \
                    "${APP_SELECTOR} | .spec.source.helm.valuesObject" "$BASE_FILE")
                OLD_VALUES_STRING=$(yq e \
                    "${APP_SELECTOR} | .spec.source.helm.values" "$BASE_FILE")
                OLD_PARAMETERS=$(yq e -o=json -r \
                    "${APP_SELECTOR} | .spec.source.helm.parameters | select(.) | select(length > 0) | tojson" "$BASE_FILE" 2>/dev/null || echo "")
                OLD_FILE_PARAMETERS=$(yq e -o=json -r \
                    "${APP_SELECTOR} | .spec.source.helm.fileParameters | select(.) | tojson" "$BASE_FILE" 2>/dev/null || echo "")
                OLD_RELEASE_NAME=$(yq e \
                    "${APP_SELECTOR} | .spec.source.helm.releaseName" "$BASE_FILE")
                OLD_HELM_NAMESPACE=$(yq e \
                    "${APP_SELECTOR} | .spec.source.helm.namespace" "$BASE_FILE")
                OLD_HELM_KUBEVERSION=$(yq e \
                    "${APP_SELECTOR} | .spec.source.helm.kubeVersion" "$BASE_FILE")
            fi
        fi
    fi

    # If no version in either old or new, this "source" probably isn't a Helm chart
    if [[ -z "$OLD_VERSION" && -z "$NEW_VERSION" ]]; then
        return 0
    fi

    # Not a Helm-from-repo source? bail out
    if [[ -z "$CHART_NAME" || "$CHART_NAME" == "null" || -z "$REPO_URL" || "$REPO_URL" == "null" ]]; then
        return 0
    fi

    # Fingerprint all helm inputs we care about
    local OLD_FP NEW_FP
    OLD_FP="${OLD_VERSION}|${OLD_VALUES_STRING}|${OLD_VALUES_OBJECT}|${OLD_PARAMETERS}|${OLD_FILE_PARAMETERS}|${OLD_RELEASE_NAME}|${OLD_HELM_NAMESPACE}|${OLD_HELM_KUBEVERSION}"
    NEW_FP="${NEW_VERSION}|${NEW_VALUES_STRING}|${NEW_VALUES_OBJECT}|${NEW_PARAMETERS}|${NEW_FILE_PARAMETERS}|${NEW_RELEASE_NAME}|${NEW_HELM_NAMESPACE}|${NEW_HELM_KUBEVERSION}"

    if [[ "$OLD_FP" == "$NEW_FP" ]]; then
        echo "ℹ️ No relevant Helm changes detected for Application ${APP_NAME} ${SRC_LABEL} in $FILE. Skipping."
        return 0
    fi

    # Effective namespaces: helm.namespace overrides destination.namespace
    local EFFECTIVE_OLD_NAMESPACE EFFECTIVE_NEW_NAMESPACE
    if [[ -n "$OLD_HELM_NAMESPACE" && "$OLD_HELM_NAMESPACE" != "null" ]]; then
        EFFECTIVE_OLD_NAMESPACE="$OLD_HELM_NAMESPACE"
    else
        EFFECTIVE_OLD_NAMESPACE="${OLD_DEST_NAMESPACE:-default}"
    fi
    if [[ -n "$NEW_HELM_NAMESPACE" && "$NEW_HELM_NAMESPACE" != "null" ]]; then
        EFFECTIVE_NEW_NAMESPACE="$NEW_HELM_NAMESPACE"
    else
        EFFECTIVE_NEW_NAMESPACE="${NEW_DEST_NAMESPACE:-default}"
    fi

    echo "🔄 Processing $APP_NAME ${SRC_LABEL} (Dest(old): $EFFECTIVE_OLD_NAMESPACE, Dest(new): $EFFECTIVE_NEW_NAMESPACE): ${OLD_VERSION:-<none>} → ${NEW_VERSION:-<none>}"

    local HELM_ARGS_OLD=()
    local HELM_ARGS_NEW=()

    ############################
    # Prepare args for OLD rev #
    ############################

    # 1. values
    if [[ -n "$OLD_VALUES_STRING" && "$OLD_VALUES_STRING" != "null" ]]; then
        echo "$OLD_VALUES_STRING" > old-values.yaml
        HELM_ARGS_OLD+=("-f" "old-values.yaml")
    fi

    # 2. valuesObject (overrides values)
    if [[ -n "$OLD_VALUES_OBJECT" && "$OLD_VALUES_OBJECT" != "null" ]]; then
        echo "$OLD_VALUES_OBJECT" > old-values-object.yaml
        HELM_ARGS_OLD+=("-f" "old-values-object.yaml")
    fi

    # 3. fileParameters (--set-file)
    if [[ -n "$OLD_FILE_PARAMETERS" && "$OLD_FILE_PARAMETERS" != "null" ]]; then
        while IFS= read -r fp; do
            local NAME PATH_VAL
            NAME=$(echo "$fp" | jq -r '.name')
            PATH_VAL=$(echo "$fp" | jq -r '.path')
            [[ -z "$NAME" || -z "$PATH_VAL" ]] && continue
            HELM_ARGS_OLD+=("--set-file" "${NAME}=${PATH_VAL}")
        done < <(echo "$OLD_FILE_PARAMETERS" | jq -c '.[]')
    fi

    # 4. parameters (--set, highest precedence)
    if [[ -n "$OLD_PARAMETERS" && "$OLD_PARAMETERS" != "null" ]]; then
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            HELM_ARGS_OLD+=("--set" "$p")
        done < <(echo "$OLD_PARAMETERS" | jq -r '.[] | "\(.name)=\(.value)" ')
    fi

    ############################
    # Prepare args for NEW rev #
    ############################

    # 1. values
    if [[ -n "$NEW_VALUES_STRING" && "$NEW_VALUES_STRING" != "null" ]]; then
        echo "$NEW_VALUES_STRING" > new-values.yaml
        HELM_ARGS_NEW+=("-f" "new-values.yaml")
    fi

    # 2. valuesObject (overrides values)
    if [[ -n "$NEW_VALUES_OBJECT" && "$NEW_VALUES_OBJECT" != "null" ]]; then
        echo "$NEW_VALUES_OBJECT" > new-values-object.yaml
        HELM_ARGS_NEW+=("-f" "new-values-object.yaml")
    fi

    # 3. fileParameters (--set-file)
    if [[ -n "$NEW_FILE_PARAMETERS" && "$NEW_FILE_PARAMETERS" != "null" ]]; then
        while IFS= read -r fp; do
            local NAME PATH_VAL
            NAME=$(echo "$fp" | jq -r '.name')
            PATH_VAL=$(echo "$fp" | jq -r '.path')
            [[ -z "$NAME" || -z "$PATH_VAL" ]] && continue
            HELM_ARGS_NEW+=("--set-file" "${NAME}=${PATH_VAL}")
        done < <(echo "$NEW_FILE_PARAMETERS" | jq -c '.[]')
    fi

    # 4. parameters (--set, highest precedence)
    if [[ -n "$NEW_PARAMETERS" && "$NEW_PARAMETERS" != "null" ]]; then
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            HELM_ARGS_NEW+=("--set" "$p")
        done < <(echo "$NEW_PARAMETERS" | jq -r '.[] | "\(.name)=\(.value)" ')
    fi

    ############################################
    # Call templating with per-rev settings   #
    ############################################
    helm_template_and_diff \
        "$APP_NAME" \
        "$REPO_URL" \
        "$CHART_NAME" \
        "$OLD_VERSION" \
        "$NEW_VERSION" \
        "$EFFECTIVE_OLD_NAMESPACE" \
        "$EFFECTIVE_NEW_NAMESPACE" \
        "$OLD_RELEASE_NAME" \
        "$NEW_RELEASE_NAME" \
        "$OLD_HELM_KUBEVERSION" \
        "$NEW_HELM_KUBEVERSION"
}

#######################################
# Description: Process a kustomization file with Helm charts.
#
# Notes:
# - Compares the PR working tree to a checked-out base worktree (`$BASE_WORKTREE_DIR`).
# - If the base branch does not contain the kustomization file/directory (e.g., app added in PR),
#   old manifests are treated as empty so the diff shows net-new resources.
# Globals:
#   BASE_REF - Base branch reference for comparison
#   BASE_WORKTREE_DIR - Directory of base worktree
#   RESPONSE - GitHub API response with changed files
# Arguments:
#   $1 - Path to kustomization.yaml file
# Outputs:
#   Diff output via process_and_diff
# Returns:
#   0 if successful (or skipped)
#######################################
process_kustomization() {
    local kustomization_file="$1"
    
    echo "📄 Processing kustomization file: $kustomization_file"

    # Check if this is a Helm kustomization (has helmCharts section)
    if yq e '.helmCharts' "$kustomization_file" | grep -q "null"; then
        echo "ℹ️ No Helm charts found in kustomization"
        return 0
    fi
    
    echo "🔍 Found Helm charts in kustomization"

    local HELMCHART_NAMES_QUERY
    HELMCHART_NAMES_QUERY='.helmCharts[]?.name'

    # Get directory containing the kustomization file
    local kustomize_dir
    kustomize_dir=$(dirname "$kustomization_file")

    local CHANGED=0

    local base_kustomization_file="${BASE_WORKTREE_DIR}/${kustomization_file}"
    local HAS_BASE_KUSTOMIZATION=0
    if [[ -f "$base_kustomization_file" ]]; then
        HAS_BASE_KUSTOMIZATION=1
    else
        echo "🆕 No base counterpart for $kustomization_file on origin/${BASE_REF}; treating old manifests as empty."
        CHANGED=1
    fi

    ##########################################
    # 1) Detect changes to helmCharts entries
    ##########################################

    # Compare set of chart names first (added/removed charts)
    local OLD_NAMES NEW_NAMES
    if (( HAS_BASE_KUSTOMIZATION == 1 )); then
        OLD_NAMES=$(
            yq e "$HELMCHART_NAMES_QUERY" -r "$base_kustomization_file" 2>/dev/null \
            | sort | tr '\n' ','
        )
    else
        OLD_NAMES=""
    fi
    NEW_NAMES=$(
        yq e "$HELMCHART_NAMES_QUERY" -r "$kustomization_file" 2>/dev/null \
        | sort | tr '\n' ','
    )

    if [[ "$OLD_NAMES" != "$NEW_NAMES" ]]; then
        echo "⬆️ helmCharts set changed (added/removed charts or renamed) in $kustomization_file"
        CHANGED=1
    fi

    # If names are the same, compare full chart entries per name
    if [[ "$CHANGED" -eq 0 ]]; then
        while read -r CHART_NAME; do
            [[ -z "$CHART_NAME" ]] && continue

            local OLD_ENTRY NEW_ENTRY
            if (( HAS_BASE_KUSTOMIZATION == 1 )); then
                OLD_ENTRY=$(
                    yq e -o=json ".helmCharts[] | select(.name == \"$CHART_NAME\")" "$base_kustomization_file" 2>/dev/null || echo ""
                )
            else
                OLD_ENTRY=""
            fi
            NEW_ENTRY=$(
                yq e -o=json ".helmCharts[] | select(.name == \"$CHART_NAME\")" "$kustomization_file" 2>/dev/null || echo ""
            )

            if [[ -z "$OLD_ENTRY" ]]; then
                echo "🆕 Chart $CHART_NAME appears new (no old entry found)."
                CHANGED=1
                break
            fi

            if [[ "$OLD_ENTRY" != "$NEW_ENTRY" ]]; then
                echo "⬆️ helmCharts entry for $CHART_NAME changed."
                CHANGED=1
                break
            fi
        done < <(yq e "$HELMCHART_NAMES_QUERY" -r "$kustomization_file")
    fi

    #########################################################
    # 2) Detect changes to underlying valuesFile(s) on disk #
    #########################################################
    # valuesFile is relative to the kustomization directory.
    # If any such file is in the PR's changed files, we should
    # run the kustomize diff even if helmCharts YAML is identical.
    if [[ "$CHANGED" -eq 0 ]]; then
        while read -r VFILE; do
            [[ -z "$VFILE" || "$VFILE" == "null" ]] && continue
            # Resolve to the path as it appears in the PR file list
            local local_path="${kustomize_dir%/}/$VFILE"

            if echo "$RESPONSE" | jq -e --arg f "$local_path" '.[] | select(.filename == $f)' >/dev/null 2>&1; then
                echo "📝 values file $local_path changed; forcing kustomize Helm diff."
                CHANGED=1
                break
            fi
        done < <(yq e '.helmCharts[]? | .valuesFile // ""' -r "$kustomization_file")
    fi

    if [[ "$CHANGED" -eq 0 ]]; then
        echo "ℹ️ No helmCharts or valuesFile changes detected in $kustomization_file. Skipping kustomize diff."
        return 0
    fi

    local tmpdir
    tmpdir="$(mktemp -d "kustomize_${kustomize_dir##*/}_XXXX")"

    echo "🎭 Rendering Helm kustomizations"
    (cd "$kustomize_dir" && kustomize build . --enable-helm) > "${tmpdir}/new.yaml"

    if (( HAS_BASE_KUSTOMIZATION == 1 )) && [[ -d "$BASE_WORKTREE_DIR/$kustomize_dir" ]]; then
        (cd "$BASE_WORKTREE_DIR/$kustomize_dir" && kustomize build . --enable-helm) > "${tmpdir}/old.yaml"
    else
        echo "" > "${tmpdir}/old.yaml"
    fi

    process_and_diff "${tmpdir}/old.yaml" "${tmpdir}/new.yaml"
    rm -rf "$tmpdir"
}

#######################################
# Description: Find kustomization.yaml that references a values file
# Globals:
#   None
# Arguments:
#   $1 - Path to values file
# Outputs:
#   Path to kustomization.yaml if found, empty otherwise
# Returns:
#   0 if found, 1 otherwise
#######################################
find_kustomization_for_values() {
    local values_file="$1"
    local current_dir
    current_dir=$(dirname "$values_file")
    
    # Walk up directory tree looking for kustomization.yaml
    while [[ "$current_dir" != "." && "$current_dir" != "/" ]]; do
        local kustomization_path="$current_dir/kustomization.yaml"
        
        if [[ -f "$kustomization_path" ]]; then
            # Check if this kustomization references our values file
            local relative_path
            relative_path=$(realpath --relative-to="$current_dir" "$values_file" 2>/dev/null || \
                           python3 -c "import os.path; print(os.path.relpath('$values_file', '$current_dir'))" 2>/dev/null)
            
            if [[ -z "$relative_path" ]]; then
                # Fallback: manual relative path calculation
                relative_path="${values_file#"$current_dir"/}"
            fi
            
            # Check if any helmChart entry references this values file
            if yq e ".helmCharts[]? | select(.valuesFile == \"$relative_path\")" \
                "$kustomization_path" 2>/dev/null | grep -q .; then
                echo "$kustomization_path"
                return 0
            fi
        fi
        
        # Move up one directory
        current_dir=$(dirname "$current_dir")
    done
    
    return 1
}

##########################
## Create base worktree ##
##########################
if [ ! -d "$BASE_WORKTREE_DIR" ]; then
    echo "📂 Creating base worktree at $BASE_WORKTREE_DIR from origin/${BASE_REF}..."
    git worktree add "$BASE_WORKTREE_DIR" "origin/${BASE_REF}"
fi

###################################
## Fetch PR diff from GitHub API ##
###################################
DIFF_URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/files"
RESPONSE=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "$DIFF_URL")

#################################
## Process ArgoCD Applications ##
#################################
echo "$RESPONSE" | jq -c '.[] | select(.patch) | {file: .filename}' | while read -r json; do
    FILE=$(echo "$json" | jq -r '.file')

    # All Application objects in this file (namespace may be empty in raw YAML)
    APP_ENTRIES=$(yq e ". | ${ARGO_APP_BASE_SELECTOR} | .metadata.name + \"|\" + (.metadata.namespace // \"\")" "$FILE" -r)

    if [[ -z "$APP_ENTRIES" ]]; then
        continue
    fi

    echo "📄 Processing ArgoCD Application file: $FILE"

    echo "$APP_ENTRIES" | while IFS="|" read -r APP_NAME NAMESPACE; do
        if [[ -z "$APP_NAME" ]]; then
            continue
        fi

        # 1) Single-source .spec.source
        process_argo_source "$FILE" "$APP_NAME" "$NAMESPACE" ".spec.source" "source"

        # 2) Multi-source .spec.sources[]
        APP_INSTANCE_SELECTOR="select(${ARGO_APP_API_VERSION_MATCH} and .kind == \"${ARGO_APPLICATION_KIND}\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null))"

        SRC_INDEXES=$(
            yq e "${APP_INSTANCE_SELECTOR} | (.spec.sources // []) | to_entries | .[].key" \
                "$FILE" -r 2>/dev/null || true
        )

        if [[ -n "$SRC_INDEXES" ]]; then
            while read -r IDX; do
                [[ -z "$IDX" ]] && continue
                process_argo_source "$FILE" "$APP_NAME" "$NAMESPACE" ".spec.sources[${IDX}]" "sources[${IDX}]"
            done <<< "$SRC_INDEXES"
        fi
    done
done

###################################
## Process Kustomize Helm Charts ##
###################################

# Track processed kustomization files to avoid duplicates
declare -A PROCESSED_KUSTOMIZATIONS

# Process kustomization.yaml files directly changed in PR
while read -r kustomization_file; do
    kustomization_file=$(echo "$kustomization_file" | tr -d '"')
    PROCESSED_KUSTOMIZATIONS["$kustomization_file"]=1
    process_kustomization "$kustomization_file"
done < <(echo "$RESPONSE" | jq -c '.[] | select(.filename | endswith("kustomization.yaml")) | .filename')

# Process standalone values*.yaml files by finding their kustomization
while read -r values_file; do
    values_file=$(echo "$values_file" | tr -d '"')
    
    echo "🔍 Checking if values file $values_file is referenced by a kustomization..."
    
    # Find the kustomization that references this values file
    kustomization_path=$(find_kustomization_for_values "$values_file")
    
    if [[ -n "$kustomization_path" ]]; then
        # Check if we've already processed this kustomization
        if [[ -n "${PROCESSED_KUSTOMIZATIONS[$kustomization_path]:-}" ]]; then
            echo "ℹ️ Kustomization $kustomization_path already processed (referenced by $values_file)"
            continue
        fi
        
        echo "📝 Found kustomization at $kustomization_path referencing $values_file"
        PROCESSED_KUSTOMIZATIONS["$kustomization_path"]=1
        process_kustomization "$kustomization_path"
    else
        echo "ℹ️ No kustomization found referencing $values_file"
    fi
done < <(echo "$RESPONSE" | jq -c '.[] | select(.filename | test("values.*\\.yaml$")) | .filename')
