#!/usr/bin/env bash

set -euo pipefail

DIFF_TXT_PATH="${DIFF_TXT_PATH:-diff.txt}" # Use diff.txt as default if not set

echo "🔍 Checking for diff.txt at: $DIFF_TXT_PATH"

if [[ ! -f "$DIFF_TXT_PATH" ]]; then
    echo "❌ diff.txt NOT FOUND! Exiting script early."
    exit 0
fi

echo "✅ diff.txt found! Reading contents..."
IMAGE_COUNT=0

while IFS= read -r line; do
    # Debug output
    echo "🔎 Processing line: $line"

    # Match lines with + image: or similar
    if [[ "$line" =~ ^\+\s*(image|[a-z_]+image|imageName):\s*\"?([^"\s]+)\"? ]]; then
        IMAGE_TAG="${BASH_REMATCH[2]}"
        echo "✅ Matched image line: $line"
        echo "  - Extracted Image Tag: $IMAGE_TAG"

        # Extract image, tag, and digest
        IMAGE=$(echo "$IMAGE_TAG" | cut -d':' -f1 | cut -d'@' -f1)
        TAG=$(echo "$IMAGE_TAG" | grep -oP '(?<=:)[^:@]+' || echo "")
        DIGEST=$(echo "$IMAGE_TAG" | grep -oP '(?<=@).*' || echo "")

        echo "  - Image: $IMAGE"
        echo "  - Tag: $TAG"
        echo "  - Digest: $DIGEST"

        # Export to GitHub Actions environment
        echo "IMAGE_$IMAGE_COUNT=$IMAGE" >> "$GITHUB_ENV"
        echo "TAG_$IMAGE_COUNT=$TAG" >> "$GITHUB_ENV"
        echo "DIGEST_$IMAGE_COUNT=$DIGEST" >> "$GITHUB_ENV"
        ((IMAGE_COUNT++))
    fi
done < "$DIFF_TXT_PATH"

echo "IMAGE_COUNT=$IMAGE_COUNT" >> "$GITHUB_ENV"
echo "📊 Extracted $IMAGE_COUNT images."
