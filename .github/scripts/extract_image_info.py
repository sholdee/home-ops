import os
import re
import requests
import sys
import json

def extract_images_from_pr_diff():
    """Extracts image updates from PR files (Docker PR updates) with logging."""
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

            if re.search(r'^apps/.*/unifi-db.yml$', filename):
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
                        image = image_tag.split('@')[0].split(':')[0].strip()
                        tag = image_tag.split(':')[1].split('@')[0].strip() if ':' in image_tag else ""
                        digest = image_tag.split('@')[1].strip() if '@' in image_tag else ""

                        print(f"   ✅ Found Image: {image}, Tag: {tag}, Digest: {digest}")
                        images.append((image, tag, digest))
                        break  # Stop after first match

    print(f"📊 Extracted {len(images)} images from PR diff.")
    return images

def extract_images_from_helm_diff():
    """Extracts unique image updates from Helm diff.txt with logging."""
    unique_images = set()  # Using a set to deduplicate images

    diff_txt_path = os.getenv("DIFF_TXT_PATH", "diff.txt")

    print(f"✅ Reading {diff_txt_path}...")
    with open(diff_txt_path, "r") as f:
        diff_lines = f.readlines()

    print(f"📂 Loaded {len(diff_lines)} lines.")

    for i, line in enumerate(diff_lines):
        print(f"🔎 [{i+1}/{len(diff_lines)}] Processing: {repr(line.strip())}")

        match = re.match(r'^\+\s*(?:image):\s*"?([^\s"]+)"?$', line, re.IGNORECASE)
        if match:
            image_tag = match.group(1).strip()
            image = image_tag.split('@')[0].split(':')[0].strip()
            tag = image_tag.split(':')[1].split('@')[0].strip() if ':' in image_tag else ""
            digest = image_tag.split('@')[1].strip() if '@' in image_tag else ""

            image_entry = (image, tag, digest)
            if image_entry not in unique_images:
                print(f"✅ Found New Image: {image}, Tag: {tag}, Digest: {digest}")
                unique_images.add(image_entry)
            else:
                print(f"ℹ️ Duplicate Image Found: {image}, Tag: {tag}, Digest: {digest} (Skipping)")

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
