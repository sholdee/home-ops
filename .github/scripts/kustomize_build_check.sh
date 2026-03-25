#!/usr/bin/env bash
set -euo pipefail

# Find kustomization directories affected by changed files and run kustomize build.
# Pre-commit passes changed file paths as arguments.

declare -A KUSTOMIZE_DIRS

for file in "$@"; do
  # Only process files under apps/
  [[ "$file" != apps/* ]] && continue

  # Walk up from the file's directory to find nearest kustomization.yaml
  dir=$(dirname "$file")
  while [[ "$dir" != "." && "$dir" != "/" ]]; do
    if [[ -f "$dir/kustomization.yaml" ]]; then
      KUSTOMIZE_DIRS["$dir"]=1
      break
    fi
    dir=$(dirname "$dir")
  done
done

if [[ ${#KUSTOMIZE_DIRS[@]} -eq 0 ]]; then
  exit 0
fi

FAILED=0
for dir in "${!KUSTOMIZE_DIRS[@]}"; do
  # Clean up any leftover Helm charts before building
  if [[ -d "$dir/charts" ]]; then
    rm -rf "$dir/charts"
  fi

  echo "Building $dir ..."
  output=$(kustomize build --enable-helm "$dir" 2>&1 > /dev/null) || {
    echo "FAIL: kustomize build --enable-helm $dir"
    echo "$output"
    FAILED=1
  }

  # Clean up Helm chart directories created by --enable-helm
  if [[ -d "$dir/charts" ]]; then
    rm -rf "$dir/charts"
  fi
done

if [[ "$FAILED" -ne 0 ]]; then
  exit 1
fi
