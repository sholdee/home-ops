import os
import re
import requests

def extract_images_from_pr_diff():
    """Extracts image updates from PR files (Docker PR updates)."""
    pr_number = os.environ['PR_NUMBER']
    repo = os.environ['GITHUB_REPOSITORY']
    token = os.environ['GITHUB_TOKEN']
    diff_url = f'https://api.github.com/repos/{repo}/pulls/{pr_number}/files'

    headers = {
        'Authorization': f'token {token}',
        'Accept': 'application/vnd.github.v3+json'
    }

    response = requests.get(diff_url, headers=headers)
    files = response.json()

    images = []

    for file in files:
        if file['filename'].endswith('.yaml') or file['filename'].endswith('.yml'):
            patch = file['patch']
            lines = patch.split('\n')

            if re.search(r'^apps/.*/unifi-db.yml$', file['filename']):
                for line in lines:
                    match = re.match(r'^\+ *version:\s*"?([^\s"]+)"?', line, re.IGNORECASE)
                    if match:
                        version = match.group(1).strip()
                        images.append(("mongodb/mongodb-community-server", f"{version}-ubi8", ""))
                        break  # Stop after first match
            else:
                for line in lines:
                    match = re.match(r'^\+\s*(?:image|[a-z_]+image|imageName):\s*"?([^\s"]+)"?', line, re.IGNORECASE)
                    if match:
                        image_tag = match.group(1).strip()
                        
                        image = image_tag.split('@')[0].split(':')[0].strip()
                        tag = image_tag.split(':')[1].split('@')[0].strip() if ':' in image_tag else ""
                        digest = image_tag.split('@')[1].strip() if '@' in image_tag else ""

                        images.append((image, tag, digest))
                        break  # Stop after first match

    return images

def extract_images_from_helm_diff():
    """Extracts image updates from Helm diff.txt if it exists."""
    images = []
    diff_txt_path = os.getenv("DIFF_TXT_PATH", "diff.txt")

    print(f"🔍 Checking for diff.txt at: {diff_txt_path}")
    sys.stdout.flush()

    if not os.path.exists(diff_txt_path):
        print("❌ diff.txt NOT FOUND! Exiting script early.")
        return images

    print("✅ diff.txt found! Reading contents...")
    sys.stdout.flush()

    with open(diff_txt_path, "r") as f:
        diff_lines = f.readlines()

    print(f"📂 Loaded {len(diff_lines)} lines from diff.txt")
    sys.stdout.flush()

    if not diff_lines:
        print("❌ diff.txt is empty! Exiting.")
        return images

    for i, line in enumerate(diff_lines):
        print(f"🔎 [{i+1}/{len(diff_lines)}] Processing line: {repr(line.strip())}")  # Use repr() to see raw formatting
        sys.stdout.flush()

        match = re.match(r'^\+\s*(?:image|[a-z_]+image|imageName):\s*"?([^\s"]+)"?', line, re.IGNORECASE)
        if match:
            image_tag = match.group(1).strip()
            print(f"✅ Matched Image Line: {repr(line.strip())}")
            print(f"  - Extracted Image Tag: {image_tag}")
            sys.stdout.flush()

            image = image_tag.split('@')[0].split(':')[0].strip()
            tag = image_tag.split(':')[1].split('@')[0].strip() if ':' in image_tag else ""
            digest = image_tag.split('@')[1].strip() if '@' in image_tag else ""

            print(f"  - Image: {image}")
            print(f"  - Tag: {tag}")
            print(f"  - Digest: {digest}")
            sys.stdout.flush()

            images.append((image, tag, digest))
        else:
            print(f"❌ No match found for line: {repr(line.strip())}")
            sys.stdout.flush()

    print(f"📊 Extracted {len(images)} images from diff.")
    return images

def main():
    """Main function to extract image updates, preferring Helm diff if present."""
    helm_diff = os.path.exists(os.getenv("DIFF_TXT_PATH", "diff.txt"))

    if helm_diff:
        images = extract_images_from_helm_diff()
    else:
        images = extract_images_from_pr_diff()

    if not images:
        return

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