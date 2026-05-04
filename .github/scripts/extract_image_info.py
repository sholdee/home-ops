import os
import re
import sys
import json

# Regex derived from output of distribution/reference Go module: fmt.Printf("%q\n", reference.ReferenceRegexp)
DOCKER_IMAGE_REGEX = re.compile(
    r"^((?:(?:(?:[a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9])(?:\.(?:[a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]))*|\[(?:[a-fA-F0-9:]+)\])(?::[0-9]+)?/)?"
    r"[a-z0-9]+(?:(?:[._]|__|[-]+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:[._]|__|[-]+)[a-z0-9]+)*)*)"
    r"(?::([\w][\w.-]{0,127}))?"
    r"(?:@([A-Za-z][A-Za-z0-9]*(?:[-_+.][A-Za-z][A-Za-z0-9]*)*:[0-9A-Fa-f]{32,}))?$"
)

# Primary regex for image: keyed Helm diff lines
IMAGE_KEY_REGEX = re.compile(r'^\+\s*image:\s*(?:(["\'])(?P<image_quoted>[^"\']+)\1|(?P<image>\S+))', re.IGNORECASE)

# Fallback regex for Helm diff lines
FALLBACK_IMAGE_REGEX = re.compile(
    r"([a-zA-Z0-9.-]+(?:\.[a-zA-Z]{2,}|\d{1,3}(?:\.\d{1,3}){3})?(?::\d+)?(?:/[a-zA-Z0-9_.-]+)+)"  # group 1: optional registry and required repo/image
    r"(?="  # positive lookahead to require at least one of:
    r"(?::[\w][\w.-]{0,127}" # :tag
    r"|@[A-Za-z][A-Za-z0-9]*(?:[-_+.][A-Za-z][A-Za-z0-9]*)*:[0-9A-Fa-f]{32,})" # @digest
    r")"
    r"(?::([\w][\w.-]{0,127}))?"  # group 2: optional :tag
    r"(?:@([A-Za-z][A-Za-z0-9]*(?:[-_+.][A-Za-z][A-Za-z0-9]*)*:[0-9A-Fa-f]{32,}))?"  # group 3: optional @digest
)

def is_valid_docker_image(image):
    """Validates whether an image reference conforms to Docker standard."""
    return bool(DOCKER_IMAGE_REGEX.fullmatch(image))

def parse_docker_image(image):
    """Returns image, tag, and digest parts for a valid Docker image reference."""
    match = DOCKER_IMAGE_REGEX.fullmatch(image)
    if not match:
        return None

    image_name, tag, digest = match.groups()
    return image_name.strip(), (tag or "").strip(), (digest or "").strip()

def extract_images_from_pr_diff():
    """Extracts container image updates from PR files with validation."""
    import requests

    pr_number = os.environ['PR_NUMBER']
    repo = os.environ['GITHUB_REPOSITORY']
    token = os.environ['GITHUB_TOKEN']
    diff_url = f'https://api.github.com/repos/{repo}/pulls/{pr_number}/files'

    headers = {
        'Authorization': f'token {token}',
        'Accept': 'application/vnd.github.v3+json'
    }

    print(f"📡 Fetching PR diff from: {diff_url}")
    response = requests.get(diff_url, headers=headers)

    if response.status_code != 200:
        print(f"❌ Failed to fetch PR diff: {response.status_code} - {response.text}")
        return []

    files = response.json()
    print(f"📂 Loaded {len(files)} files from PR.")

    images = []

    for file_idx, file in enumerate(files):
        filename = file['filename']
        print(f"🔎 [{file_idx+1}/{len(files)}] Processing file: {filename}")

        if filename.endswith('.yaml') or filename.endswith('.yml'):
            patch = file['patch']
            lines = patch.split('\n')

            if re.search(r'^apps/unifi/unifi-db/manifests/replicaset.yaml$', filename):
                for line_idx, line in enumerate(lines):
                    print(f"   🔍 Checking line {line_idx+1}: {repr(line.strip())}")
                    match = re.match(r'^\+\s*version:\s*"?([^\s"]+)"?', line, re.IGNORECASE)
                    if match:
                        version = match.group(1).strip()
                        print(f"   ✅ Found Unifi DB version update: {version}-ubi8")
                        images.append(("mongodb/mongodb-community-server", f"{version}-ubi8", ""))
                        break  # Stop after first match
            else:
                for line_idx, line in enumerate(lines):
                    print(f"   🔍 Checking line {line_idx+1}: {repr(line.strip())}")
                    match = re.match(r'^\+\s*(?:image|[a-z_]+image|imageName):\s*"?([^\s"]+)"?', line, re.IGNORECASE)
                    if match:
                        image_tag = match.group(1).strip()
                        parsed_image = parse_docker_image(image_tag)
                        if parsed_image:
                            image, tag, digest = parsed_image

                            print(f"   ✅ Found Image: {image}, Tag: {tag}, Digest: {digest}")
                            images.append((image, tag, digest))
                            break  # Stop after first match
                        else:
                            print(f"❌ Invalid Image Format: {image_tag}")

    print(f"📊 Extracted {len(images)} images from PR diff.")
    return images

def extract_images_from_helm_diff():
    """Extracts unique image updates from Helm diff.txt, prioritizing `+ image:` lines but allowing a stricter fallback match."""
    unique_images = set()  # Using a set to deduplicate images
    diff_txt_path = os.getenv("DIFF_TXT_PATH", "diff.txt")

    print(f"✅ Reading {diff_txt_path}...")
    with open(diff_txt_path, "r") as f:
        diff_lines = f.readlines()

    print(f"📂 Loaded {len(diff_lines)} lines.")

    for i, line in enumerate(diff_lines):
        line = line.strip()
        if not line.startswith("+ "):  # Only process added lines
            continue

        print(f"🔎 [{i+1}/{len(diff_lines)}] Processing: {repr(line)}")

        image_tag = None  # Initialize variable for image match

        # **Primary Match: `+ image:` lines**
        match = IMAGE_KEY_REGEX.match(line)
        if match:
            image_tag = match.group('image_quoted') or match.group('image')
        else:
            # **Fallback Match: Look for valid `repo/image` format with a tag or digest**
            match = FALLBACK_IMAGE_REGEX.search(line)
            if match:
                repo_image = match.group(1)
                tag = match.group(2) or ""
                digest = match.group(3) or ""

                if not tag and not digest:
                    print(f"⚠️ Skipping potential image reference (missing tag/digest): {repo_image}")
                    continue  # Skip matches that lack a tag/digest

                image_tag = f"{repo_image}@{digest}" if digest else f"{repo_image}:{tag}"

        if image_tag:
            # Extract components
            parsed_image = parse_docker_image(image_tag)
            if not parsed_image:
                print(f"❌ Invalid Docker Image Reference: {image_tag}")
                continue

            image, tag, digest = parsed_image

            image_entry = (image, tag, digest)
            if image_entry not in unique_images:
                print(f"✅ Found New Image: {image}, Tag: {tag}, Digest: {digest}")
                unique_images.add(image_entry)
            else:
                print(f"ℹ️ Skipped Duplicate Image: {image}, Tag: {tag}, Digest: {digest}")

    print(f"📊 Extracted {len(unique_images)} unique images.")
    return list(unique_images)  # Convert set back to list before returning

def main():
    """Main function to extract image updates, preferring Helm diff if present."""
    helm_diff = os.path.exists(os.getenv("DIFF_TXT_PATH", "diff.txt"))

    if helm_diff:
        print("Helm diff detected, extracting updated images.")
        images = extract_images_from_helm_diff()
    else:
        print("No Helm diff found, extracting updated image from PR.")
        images = extract_images_from_pr_diff()

    if not images:
        print("No image updates detected.")
        return

    with open(os.environ['GITHUB_ENV'], 'a') as f:
        if helm_diff:
            print("Using indexed variables for Helm images.")
            for index, (image, tag, digest) in enumerate(images):
                f.write(f"IMAGE_{index}={image}\n")
                f.write(f"TAG_{index}={tag}\n")
                f.write(f"DIGEST_{index}={digest}\n")
            f.write(f"IMAGE_COUNT={len(images)}\n")  # Store total count
        else:
            print("Using default single-image variables for Docker PR.")
            image, tag, digest = images[0]  # Only take the first one
            f.write(f"IMAGE={image}\n")
            f.write(f"TAG={tag}\n")
            f.write(f"DIGEST={digest}\n")

if __name__ == "__main__":
    main()
