#!/bin/bash

IMAGE=$1
TAG=$2
DIGEST=$3

echo "IMAGE: $IMAGE"
echo "TAG: $TAG"
echo "DIGEST: $DIGEST"

# Function to get token and set the correct image name for Docker Hub
get_dockerhub_token() {
  local image=$1
  local IMAGE_NAME

  # Determine if the image is an official library image
  if [[ $image =~ ^docker\.io/.* ]]; then
      # Remove the docker.io/ prefix
      IMAGE_NAME=${image#docker.io/}
  else
      IMAGE_NAME=$image
  fi

  # If there's no organization prefix, it's an official library image
  if ! [[ $IMAGE_NAME =~ ^.*/.* ]]; then
      IMAGE_NAME="library/$IMAGE_NAME"
  fi

  AUTH_SERVICE='registry.docker.io'
  AUTH_SCOPE="repository:${IMAGE_NAME}:pull"
  TOKEN=$(curl -s "https://auth.docker.io/token?service=$AUTH_SERVICE&scope=$AUTH_SCOPE" | jq -r .token)

  # Return the TOKEN and IMAGE_NAME
  echo "$TOKEN $IMAGE_NAME"
}

# Function to get token for GitHub Container Registry (ghcr.io)
get_ghcr_token() {
  local image=$1
  local USER_IMAGE=${image#ghcr.io/}
  TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:${USER_IMAGE}:pull" | jq -r .token)
  echo "$TOKEN $USER_IMAGE"
}

# Function to get token for Quay.io
get_quay_token() {
  local image=$1
  local USER_IMAGE=${image#quay.io/}
  TOKEN=$(curl -s "https://quay.io/v2/auth?service=quay.io&scope=repository:${USER_IMAGE}:pull" | jq -r .token)
  echo "$TOKEN $USER_IMAGE"
}

# Determine the registry and get the appropriate token
if [[ $IMAGE =~ ^ghcr\.io ]]; then
  GHCR_RESPONSE=$(get_ghcr_token "$IMAGE")
  GHCR_TOKEN=$(echo $GHCR_RESPONSE | awk '{print $1}')
  IMAGE_NAME=$(echo $GHCR_RESPONSE | awk '{print $2}')
  AUTH_HEADER="Authorization: Bearer $GHCR_TOKEN"
elif [[ $IMAGE =~ ^quay\.io ]]; then
  QUAY_RESPONSE=$(get_quay_token "$IMAGE")
  QUAY_TOKEN=$(echo $QUAY_RESPONSE | awk '{print $1}')
  IMAGE_NAME=$(echo $QUAY_RESPONSE | awk '{print $2}')
  AUTH_HEADER="Authorization: Bearer $QUAY_TOKEN"
else
  DOCKERHUB_RESPONSE=$(get_dockerhub_token "$IMAGE")
  DOCKERHUB_TOKEN=$(echo $DOCKERHUB_RESPONSE | awk '{print $1}')
  IMAGE_NAME=$(echo $DOCKERHUB_RESPONSE | awk '{print $2}')
  AUTH_HEADER="Authorization: Bearer $DOCKERHUB_TOKEN"
fi

echo "AUTH_HEADER: $AUTH_HEADER"

# Construct the manifest URL
if [ -n "$DIGEST" ]; then
  MANIFEST_URL="https://registry-1.docker.io/v2/${IMAGE_NAME}/manifests/${DIGEST}"
else
  MANIFEST_URL="https://registry-1.docker.io/v2/${IMAGE_NAME}/manifests/${TAG}"
fi

if [[ $IMAGE =~ ^ghcr\.io ]]; then
  if [ -n "$DIGEST" ]; then
    MANIFEST_URL="https://ghcr.io/v2/${IMAGE_NAME}/manifests/${DIGEST}"
  else
    MANIFEST_URL="https://ghcr.io/v2/${IMAGE_NAME}/manifests/${TAG}"
  fi
elif [[ $IMAGE =~ ^quay\.io ]]; then
  if [ -n "$DIGEST" ]; then
    MANIFEST_URL="https://quay.io/v2/${IMAGE_NAME}/manifests/${DIGEST}"
  else
    MANIFEST_URL="https://quay.io/v2/${IMAGE_NAME}/manifests/${TAG}"
  fi
fi

echo "MANIFEST_URL: $MANIFEST_URL"

# Set Accept header for ghcr.io to include OCI indexes
if [[ $IMAGE =~ ^ghcr\.io ]]; then
  ACCEPT_HEADER="Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"
else
  ACCEPT_HEADER="Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"
fi

# Fetch the manifest list with authentication
HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" "$MANIFEST_URL")
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)

echo "HTTP_BODY: $HTTP_BODY"
echo "HTTP_STATUS: $HTTP_STATUS"

if [ "$HTTP_STATUS" -ne 200 ]; then
  echo "Error fetching manifest: $HTTP_BODY"
  exit 1
fi

echo "Response: $HTTP_BODY"

# Check if 'arm64' architecture is listed in the manifest
ARM64_EXIST=$(echo "$HTTP_BODY" | jq -r '.manifests[] | select(.platform.architecture == "arm64")')

if [ -n "$ARM64_EXIST" ]; then
  echo "ARM64 image is available for ${IMAGE_NAME}:${TAG}${DIGEST:+@$DIGEST}"
  exit 0
else
  echo "ARM64 image is not available for ${IMAGE_NAME}:${TAG}${DIGEST:+@$DIGEST}"
  exit 1
fi
