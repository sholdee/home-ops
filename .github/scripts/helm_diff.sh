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
    NAMESPACE="$6"

    get_kube_version

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
    if ! helm template "$APP_NAME" "$CHART_REF" \
        --version "$OLD_VERSION" \
        --namespace "$NAMESPACE" \
        --kube-version "$KUBE_VERSION" \
        "${HELM_ARGS_OLD[@]}" > "${workdir}/old.yaml"; then
        echo "❌ Helm template failed for old version"
        rm -rf "$workdir"
        return 1
    fi

    echo "🎭 Rendering new Helm template: $APP_NAME $CHART_REF --version $NEW_VERSION ..."
    if ! helm template "$APP_NAME" "$CHART_REF" \
        --version "$NEW_VERSION" \
        --namespace "$NAMESPACE" \
        --kube-version "$KUBE_VERSION" \
        "${HELM_ARGS_NEW[@]}" > "${workdir}/new.yaml"; then
        echo "❌ Helm template failed for new version"
        rm -rf "$workdir"
        return 1
    fi

    process_and_diff "${workdir}/old.yaml" "${workdir}/new.yaml"
    rm -rf "$workdir"
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
echo "$RESPONSE" | jq -c '.[] | select(.patch) | 
     .filename as $file | 
     .patch |
     capture("\\+\\s+targetRevision:\\s+(?<ver>.+)") | 
     {file: $file, version: .ver}' | 
     while read -r json; do

    FILE=$(echo "$json" | jq -r '.file')
    REV=$(echo "$json" | jq -r '.version')

    echo "📄 Processing ArgoCD Application file: $FILE with targetRevision $REV"

    # Extract app names and namespaces properly
    APP_ENTRIES=$(yq e ". | select(.kind == \"Application\" and .spec.source.targetRevision == \"$REV\") | .metadata.name + \"|\" + (.metadata.namespace // \"\")" "$FILE" -r)

    if [[ -z "$APP_ENTRIES" ]]; then
        echo "⚠️ No matching applications found for targetRevision: $REV"
        continue
    fi

    # Loop through each app entry
    echo "$APP_ENTRIES" | while IFS="|" read -r APP_NAME NAMESPACE; do
        if [[ -z "$APP_NAME" ]]; then
            continue
        fi

        OLD_VERSION=$(git show origin/"${BASE_REF}":"$FILE" | yq e "select(.metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | .spec.source.targetRevision" -)
        NEW_VERSION=$(yq e "select(.metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | .spec.source.targetRevision" "$FILE")

        # Skip apps where targetRevision didn't actually change
        if [[ "$OLD_VERSION" == "$NEW_VERSION" || -z "$NEW_VERSION" ]]; then
            continue
        fi

        CHART_NAME=$(yq e "select(.metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | .spec.source.chart" "$FILE")
        REPO_URL=$(yq e "select(.metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | .spec.source.repoURL" "$FILE")
        DEST_NAMESPACE=$(yq e "select(.metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | .spec.destination.namespace" "$FILE" || echo "default")

        echo "🔄 Processing $APP_NAME (Namespace: ${NAMESPACE:-unset}, Dest: $DEST_NAMESPACE): $OLD_VERSION → $NEW_VERSION"

        OLD_VALUES_OBJECT=$(git show origin/"${BASE_REF}":"$FILE" | yq e "select(.metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | .spec.source.helm.valuesObject" -)
        NEW_VALUES_OBJECT=$(yq e "select(.metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | .spec.source.helm.valuesObject" "$FILE")

        OLD_VALUES_STRING=$(git show origin/"${BASE_REF}":"$FILE" | yq e "select(.metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | .spec.source.helm.values" -)
        NEW_VALUES_STRING=$(yq e "select(.metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | .spec.source.helm.values" "$FILE")

        OLD_PARAMETERS=$(git show origin/"${BASE_REF}":"$FILE" | yq e -o=json -r "select(.metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | .spec.source.helm.parameters | select(.) | select(length > 0) | tojson" -)
        NEW_PARAMETERS=$(yq e -o=json -r "select(.metadata.name == \"$APP_NAME\" and (.metadata.namespace == \"$NAMESPACE\" or .metadata.namespace == null)) | .spec.source.helm.parameters | select(.) | select(length > 0) | tojson" "$FILE")

        HELM_ARGS_OLD=()
        HELM_ARGS_NEW=()

        # Prepare args for OLD version
        if [[ -n "$OLD_VALUES_STRING" && "$OLD_VALUES_STRING" != "null" ]]; then
            echo "$OLD_VALUES_STRING" > old-values.yaml
            HELM_ARGS_OLD+=("-f" "old-values.yaml")
        fi

        if [[ -n "$OLD_VALUES_OBJECT" && "$OLD_VALUES_OBJECT" != "null" ]]; then
            echo "$OLD_VALUES_OBJECT" > old-values-object.yaml
            HELM_ARGS_OLD+=("-f" "old-values-object.yaml")
        fi

        while IFS= read -r p; do
            HELM_ARGS_OLD+=("--set" "$p")
        done < <(echo "$OLD_PARAMETERS" | jq -r '.[] | "\(.name)=\(.value)" ')

        # Prepare args for NEW version
        if [[ -n "$NEW_VALUES_STRING" && "$NEW_VALUES_STRING" != "null" ]]; then
            echo "$NEW_VALUES_STRING" > new-values.yaml
            HELM_ARGS_NEW+=("-f" "new-values.yaml")
        fi

        if [[ -n "$NEW_VALUES_OBJECT" && "$NEW_VALUES_OBJECT" != "null" ]]; then
            echo "$NEW_VALUES_OBJECT" > new-values-object.yaml
            HELM_ARGS_NEW+=("-f" "new-values-object.yaml")
        fi

        while IFS= read -r p; do
            HELM_ARGS_NEW+=("--set" "$p")
        done < <(echo "$NEW_PARAMETERS" | jq -r '.[] | "\(.name)=\(.value)" ')

        helm_template_and_diff "$APP_NAME" "$REPO_URL" "$CHART_NAME" "$OLD_VERSION" "$NEW_VERSION" "$DEST_NAMESPACE"
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
