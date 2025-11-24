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

        if ! helm show chart "$CHART_REF" --version "$OLD_VERSION" >/dev/null 2>&1; then
            echo "⚠️ Chart $CHART_REF version $OLD_VERSION not found in OCI registry. Skipping..."
            return 1
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

        if ! helm search repo "$CHART_REF" --versions | grep -q "$OLD_VERSION"; then
            echo "⚠️ Chart $CHART_REF version $OLD_VERSION not found in repo $REPO_NAME. Skipping..."
            return 1
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

process_argo_source() {
    local FILE="$1"
    local APP_NAME="$2"
    local NAMESPACE="$3"
    local SRC_EXPR="$4"   # e.g. .spec.source or .spec.sources[0]
    local SRC_LABEL="$5"  # for logging, e.g. "source" or "sources[0]"

    # OLD (base) fields
    local OLD_VERSION OLD_VALUES_OBJECT OLD_VALUES_STRING OLD_PARAMETERS
    local OLD_FILE_PARAMETERS OLD_RELEASE_NAME OLD_HELM_NAMESPACE
    local OLD_HELM_KUBEVERSION OLD_DEST_NAMESPACE

    OLD_VERSION=$(git show origin/"${BASE_REF}":"$FILE" | yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.targetRevision" -)
    OLD_VALUES_OBJECT=$(git show origin/"${BASE_REF}":"$FILE" | yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.helm.valuesObject" -)
    OLD_VALUES_STRING=$(git show origin/"${BASE_REF}":"$FILE" | yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.helm.values" -)
    OLD_PARAMETERS=$(git show origin/"${BASE_REF}":"$FILE" | yq e -o=json -r "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.helm.parameters | select(.) | select(length > 0) | tojson" - 2>/dev/null || echo "")
    OLD_FILE_PARAMETERS=$(git show origin/"${BASE_REF}":"$FILE" | yq e -o=json -r "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.helm.fileParameters | select(.) | tojson" - 2>/dev/null || echo "")
    OLD_RELEASE_NAME=$(git show origin/"${BASE_REF}":"$FILE" | yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.helm.releaseName" -)
    OLD_HELM_NAMESPACE=$(git show origin/"${BASE_REF}":"$FILE" | yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.helm.namespace" -)
    OLD_HELM_KUBEVERSION=$(git show origin/"${BASE_REF}":"$FILE" | yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.helm.kubeVersion" -)
    OLD_DEST_NAMESPACE=$(git show origin/"${BASE_REF}":"$FILE" | yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | .spec.destination.namespace" - 2>/dev/null || echo "default")

    # NEW (PR) fields
    local NEW_VERSION NEW_VALUES_OBJECT NEW_VALUES_STRING NEW_PARAMETERS
    local NEW_FILE_PARAMETERS NEW_RELEASE_NAME NEW_HELM_NAMESPACE
    local NEW_HELM_KUBEVERSION NEW_DEST_NAMESPACE

    NEW_VERSION=$(yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.targetRevision" "$FILE")
    NEW_VALUES_OBJECT=$(yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.helm.valuesObject" "$FILE")
    NEW_VALUES_STRING=$(yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.helm.values" "$FILE")
    NEW_PARAMETERS=$(yq e -o=json -r "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.helm.parameters | select(.) | select(length > 0) | tojson" "$FILE" 2>/dev/null || echo "")
    NEW_FILE_PARAMETERS=$(yq e -o=json -r "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.helm.fileParameters | select(.) | tojson" "$FILE" 2>/dev/null || echo "")
    NEW_RELEASE_NAME=$(yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.helm.releaseName" "$FILE")
    NEW_HELM_NAMESPACE=$(yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.helm.namespace" "$FILE")
    NEW_HELM_KUBEVERSION=$(yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.helm.kubeVersion" "$FILE")
    NEW_DEST_NAMESPACE=$(yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | .spec.destination.namespace" "$FILE" 2>/dev/null || echo "default")

    # If no version in either old or new, this "source" probably isn't a Helm chart
    if [[ -z "$OLD_VERSION" && -z "$NEW_VERSION" ]]; then
        return 0
    fi

    # Chart/repoURL (required)
    local CHART_NAME REPO_URL
    CHART_NAME=$(yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.chart" "$FILE")
    REPO_URL=$(yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | ${SRC_EXPR}.repoURL" "$FILE")

    if [[ -z "$CHART_NAME" || "$CHART_NAME" == "null" || -z "$REPO_URL" || "$REPO_URL" == "null" ]]; then
        # Not a Helm-from-repo source, skip
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

    echo "📄 Processing ArgoCD Application file: $FILE"

    # All Application objects in this file (namespace may be empty in raw YAML)
    APP_ENTRIES=$(yq e '. | select(.kind == "Application") | .metadata.name + "|" + (.metadata.namespace // "")' "$FILE" -r)

    if [[ -z "$APP_ENTRIES" ]]; then
        echo "⚠️ No ArgoCD Applications found in: $FILE"
        continue
    fi

    echo "$APP_ENTRIES" | while IFS="|" read -r APP_NAME NAMESPACE; do
        if [[ -z "$APP_NAME" ]]; then
            continue
        fi

        # 1) Single-source .spec.source
        process_argo_source "$FILE" "$APP_NAME" "$NAMESPACE" ".spec.source" "source"

        # 2) Multi-source .spec.sources[]
        SRC_INDEXES=$(yq e "select(.kind == \"Application\" and .metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | (.spec.sources // []) | to_entries | .[].key" "$FILE" -r 2>/dev/null || true)

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
echo "$RESPONSE" | jq -c '.[] | select(.filename | endswith("kustomization.yaml")) | .filename' | while read -r kustomization_file; do
    kustomization_file=$(echo "$kustomization_file" | tr -d '"')
    echo "📄 Processing kustomization file: $kustomization_file"

    # Check if this is a Helm kustomization (has helmCharts section)
    if ! yq e '.helmCharts' "$kustomization_file" | grep -q "null"; then
        echo "🔍 Found Helm charts in kustomization"

        # Get directory containing the kustomization file
        kustomize_dir=$(dirname "$kustomization_file")

        # Use yq to detect version changes per chart
        CHANGED=0

        while IFS="|" read -r CHART_NAME NEW_VERSION; do
            OLD_VERSION=$(
                git show origin/"${BASE_REF}":"$kustomization_file" \
                | yq e ".helmCharts[] | select(.name == \"$CHART_NAME\") | .version" - 2>/dev/null || echo ""
            )

            if [[ -z "$OLD_VERSION" ]]; then
                echo "🆕 Chart $CHART_NAME appears new (no old version found)."
                CHANGED=1
                break
            fi

            if [[ "$OLD_VERSION" != "$NEW_VERSION" ]]; then
                echo "⬆️ Chart $CHART_NAME version changed: $OLD_VERSION → $NEW_VERSION"
                CHANGED=1
                break
            fi
        done < <(yq e '.helmCharts[] | .name + "|" + .version' -r "$kustomization_file")

        if [[ "$CHANGED" -eq 0 ]]; then
            echo "ℹ️ No helmCharts version changes detected in $kustomization_file. Skipping kustomize diff."
            continue
        fi

        tmpdir="$(mktemp -d "kustomize_${kustomize_dir##*/}_XXXX")"

        echo "🎭 Rendering Helm kustomizations"
        (cd "$kustomize_dir" && kustomize build . --enable-helm) > "${tmpdir}/new.yaml"
        (cd "$BASE_WORKTREE_DIR/$kustomize_dir" && kustomize build . --enable-helm) > "${tmpdir}/old.yaml"

        process_and_diff "${tmpdir}/old.yaml" "${tmpdir}/new.yaml"
        rm -rf "$tmpdir"
    else
        echo "ℹ️ No Helm charts found in kustomization"
    fi
done
