#!/bin/bash

FILE="apps/argocd-conf/argocd-apps.yml"

# Extract list of modified targetRevision values
CHANGED_VERSIONS=$(git diff --unified=0 --no-color origin/${{ github.event.pull_request.base.ref }} -- "$FILE" | grep -E "^\+\s+targetRevision:" | awk '{$NF=$NF};1' | awk '{print $NF}' | tr -d '[:space:]' || true)

if [ -z "$CHANGED_VERSIONS" ]; then
      echo "No Helm chart updates detected."
      exit 0
fi

echo "Modified Versions: $CHANGED_VERSIONS"

echo "## Helm Chart Diff" > diff.txt

# Loop over changed targetRevision versions
for REV in $CHANGED_VERSIONS; do
      # Extract all app names that now have this targetRevision
      APP_NAMES=$(yq e ". | select(.kind == \"Application\" and .spec.source.targetRevision == \"$REV\") | .metadata.name" "$FILE")
      
      # Loop through each app and check if it actually changed
      for APP_NAME in $APP_NAMES; do
            OLD_VERSION=$(git show origin/${{ github.event.pull_request.base.ref }}:"$FILE" | yq e "select(.metadata.name == \"$APP_NAME\") | .spec.source.targetRevision" -)
            NEW_VERSION=$(yq e "select(.metadata.name == \"$APP_NAME\") | .spec.source.targetRevision" "$FILE")

            # Skip apps where targetRevision didn't actually change
            if [[ "$OLD_VERSION" == "$NEW_VERSION" || -z "$NEW_VERSION" ]]; then
                  continue
            fi
            
            CHART_NAME=$(yq e "select(.metadata.name == \"$APP_NAME\") | .spec.source.chart" "$FILE")
            REPO_URL=$(yq e "select(.metadata.name == \"$APP_NAME\") | .spec.source.repoURL" "$FILE")
            NAMESPACE=$(yq e "select(.metadata.name == \"$APP_NAME\") | .spec.destination.namespace" "$FILE")

            echo "Processing $APP_NAME: $OLD_VERSION → $NEW_VERSION"
            
            git show origin/${{ github.event.pull_request.base.ref }}:"$FILE" | yq e "select(.metadata.name == \"$APP_NAME\") | .spec.source.helm.valuesObject" - > old-values.yaml
            yq e "select(.metadata.name == \"$APP_NAME\") | .spec.source.helm.valuesObject" "$FILE" > new-values.yaml
            
            REPO_NAME=$(echo "$REPO_URL" | awk -F/ '{print $NF}')
            helm repo add "$REPO_NAME" "$REPO_URL"
            helm repo update
            
            echo "Checking available versions for $CHART_NAME..."
            helm search repo "$REPO_NAME/$CHART_NAME" --versions
            
            if ! helm search repo "$REPO_NAME/$CHART_NAME" --versions | grep -q "$OLD_VERSION"; then
                  echo "Error: Chart $CHART_NAME version $OLD_VERSION not found in repo $REPO_NAME. Skipping..."
                  continue
            fi
            
            if ! helm search repo "$REPO_NAME/$CHART_NAME" --versions | grep -q "$NEW_VERSION"; then
                  echo "Error: Chart $CHART_NAME version $NEW_VERSION not found in repo $REPO_NAME. Skipping..."
                  continue
            fi
            
            echo "Rendering old Helm template..."
            helm template "$APP_NAME" "$REPO_NAME/$CHART_NAME" --version "$OLD_VERSION" --namespace "$NAMESPACE" -f old-values.yaml > old.yaml || { echo "Helm template failed for old version"; continue; }
            
            echo "Rendering new Helm template..."
            helm template "$APP_NAME" "$REPO_NAME/$CHART_NAME" --version "$NEW_VERSION" --namespace "$NAMESPACE" -f new-values.yaml > new.yaml || { echo "Helm template failed for new version"; continue; }

            # Process in chunks and stream the diff using git diff
            echo "Formatting and diffing manifests..."
            yq eval old.yaml | split -l 10000 - old_chunk_
            yq eval new.yaml | split -l 10000 - new_chunk_
            
            # For first chunk, use normal git diff
            first_chunk=true
            # Loop through chunks and diff them using git diff
            for old_chunk in old_chunk_*; do
              chunk_num=${old_chunk#old_chunk_}
              new_chunk="new_chunk_$chunk_num"
              
              if [ -f "$new_chunk" ]; then
                echo "Processing chunk $chunk_num..." 
                if [ "$first_chunk" = true ]; then
                  git diff --no-index --text "$old_chunk" "$new_chunk" >> diff.txt || true
                  first_chunk=false
                else
                  # For subsequent chunks, use --no-prefix to avoid headers
                  git diff --no-index --text --no-prefix "$old_chunk" "$new_chunk" >> diff.txt || true
                fi
              fi
            done
      done
done
