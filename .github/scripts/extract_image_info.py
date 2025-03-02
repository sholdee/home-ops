import os
import re
import requests
import sys

def debug_log(message):
    print(f"::debug::{message}")
    sys.stderr.write(message + "\n")
    sys.stderr.flush()

def extract_images_from_pr_diff():
    """Extracts image updates from PR files (Docker PR updates)."""
    pr_number = os.environ['PR_NUMBER']
    repo = os.environ['GITHUB_REPOSITORY']
    token = os.environ['GITHUB_TOKEN']
    diff_url = f'https://api.github.com/repos/{repo}/pulls/{pr_number}/files'

    debug_log(f"🔍 Fetching PR diff from {diff_url}")

    headers = {
        'Authorization': f'token {token}',
        'Accept': 'application/vnd.github.v3+json'
    }

    response = requests.get(diff_url, headers=headers)
    files = response.json()

    images = []

    debug_log(f"📂 Retrieved {len(files)} files from PR.")

    for file in files:
        if file['filename'].endswith('.yaml') or file['filename'].endswith('.yml'):
            patch = file.get('patch', '')  # Ensure we have a patch
            lines = patch.split('\n')

            debug_log(f"📜 Processing file: {file['filename']} with {len(lines)} changed lines.")

            for line in lines:
                debug_log(f"🔎 Checking line: {repr(line.strip())}")

                match = re.match(r'^\+\s*(?:image|[a-z_]+image|imageName):\s*"?([^\s"]+)"?', line, re.IGNORECASE)
                if match:
                    image_tag = match.group(1).strip()
                    debug_log(f"✅ Matched Image Line: {repr(line.strip())}")
                    debug_log(f"  - Extracted Image Tag: {image_tag}")

                    image = image_tag.split('@')[0].split(':')[0].strip()
                    tag = image_tag.split(':')[1].split('@')[0].strip() if ':' in image_tag else ""
                    digest = image_tag.split('@')[1].strip() if '@' in image_tag else ""

                    debug_log(f"  - Image: {image}")
                    debug_log(f"  - Tag: {tag}")
                    debug_log(f"  - Digest: {digest}")

                    images.append((image, tag, digest))

    debug_log(f"📊 Extracted {len(images)} images from PR diff.")
    return images

def extract_images_from_helm_diff():
    """Extracts image updates from Helm diff.txt if it exists."""
    images = []
    diff_txt_path = os.getenv("DIFF_TXT_PATH", "diff.txt")

    debug_log(f"🔍 Checking for diff.txt at: {diff_txt_path}")

    if not os.path.exists(diff_txt_path):
        debug_log("❌ diff.txt NOT FOUND! Exiting script early.")
        return images

    debug_log("✅ diff.txt found! Reading contents...")

    with open(diff_txt_path, "r") as f:
        diff_lines = f.readlines()

    debug_log(f"📂 Loaded {len(diff_lines)} lines from diff.txt")

    if not diff_lines:
        debug_log("❌ diff.txt is empty! Exiting.")
        return images

    for i, line in enumerate(diff_lines):
        debug_log(f"🔎 [{i+1}/{len(diff_lines)}] Processing line: {repr(line.strip())}")

        match = re.match(r'^\+\s*(?:image|[a-z_]+image|imageName):\s*"?([^\s"]+)"?', line, re.IGNORECASE)
        if match:
            image_tag = match.group(1).strip()
            debug_log(f"✅ Matched Image Line: {repr(line.strip())}")
            debug_log(f"  - Extracted Image Tag: {image_tag}")

            image = image_tag.split('@')[0].split(':')[0].strip()
            tag = image_tag.split(':')[1].split('@')[0].strip() if ':' in image_tag else ""
            digest = image_tag.split('@')[1].strip() if '@' in image_tag else ""

            debug_log(f"  - Image: {image}")
            debug_log(f"  - Tag: {tag}")
            debug_log(f"  - Digest: {digest}")

            images.append((image, tag, digest))

    debug_log(f"📊 Extracted {len(images)} images from Helm diff.")
    return images

def main():
    """Main function to extract image updates, preferring Helm diff if present."""
    debug_log("🚀 extract_image_info.py script started!")

    helm_diff = os.path.exists(os.getenv("DIFF_TXT_PATH", "diff.txt"))
    
    if helm_diff:
        debug_log("🔍 Helm diff detected, extracting updated images.")
        images = extract_images_from_helm_diff()
    else:
        debug_log("🔍 No Helm diff found, extracting updated image from PR.")
        images = extract_images_from_pr_diff()

    debug_log(f"✅ Images Extracted: {len(images)}")

    if not images:
        debug_log("❌ No image updates detected. Exiting.")
        sys.exit(1)  # 🔥 Force failure to confirm script execution

    debug_log(f"✅ Writing {len(images)} extracted images to GitHub Environment Variables.")
    
    with open(os.environ['GITHUB_ENV'], 'a') as f:
        if helm_diff:
            for index, (image, tag, digest) in enumerate(images):
                f.write(f"IMAGE_{index}={image}\n")
                f.write(f"TAG_{index}={tag}\n")
                f.write(f"DIGEST_{index}={digest}\n")
            f.write(f"IMAGE_COUNT={len(images)}\n")
        else:
            image, tag, digest = images[0]  # Default for non-Helm PRs
            f.write(f"IMAGE={image}\n")
            f.write(f"TAG={tag}\n")
            f.write(f"DIGEST={digest}\n")

if __name__ == "__main__":
    main()
