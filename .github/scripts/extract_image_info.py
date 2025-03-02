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
                    match = re.match(r'^\+ *version:\s*"?([^"\s]+)"?', line, re.IGNORECASE)
                    if match:
                        version = match.group(1).strip()
                        images.append(("mongodb/mongodb-community-server", f"{version}-ubi8", ""))
                        break  # Stop after first match
            else:
                for line in lines:
                    match = re.match(r'^\+\s*(?:image|[a-z_]+image|imageName):\s*"?([^"\s]+)"?', line, re.IGNORECASE)
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

    diff_txt_path = os.getenv("DIFF_TXT_PATH", "diff.txt")  # Default to diff.txt if not set

    if not os.path.exists(diff_txt_path):
        print(f"❌ {diff_txt_path} not found, skipping Helm image extraction.")
        return images

    print(f"📂 Reading {diff_txt_path} for image updates...")
    with open(diff_txt_path, "r") as f:
        diff_lines = f.readlines()

    print(f"🔍 Checking {len(diff_lines)} lines for image updates...")
    for line in diff_lines:
        print(f"🔎 Processing line: {line.strip()}")  # Debug print each line

        match = re.match(r'^\+\s*(?:image|[a-z_]+image|imageName):\s*"?([^"\s]+)"?', line, re.IGNORECASE)
        if match:
            image_tag = match.group(1).strip()
            print(f"✅ Matched Image Line: {line.strip()}")
            print(f"  - Extracted Image Tag: {image_tag}")

            image = image_tag.split('@')[0].split(':')[0].strip()
            tag = image_tag.split(':')[1].split('@')[0].strip() if ':' in image_tag else ""
            digest = image_tag.split('@')[1].strip() if '@' in image_tag else ""

            print(f"  - Image: {image}")
            print(f"  - Tag: {tag}")
            print(f"  - Digest: {digest}")

            images.append((image, tag, digest))
        else:
            print(f"❌ No match found for line: {line.strip()}")

    print(f"📊 Extracted {len(images)} images from diff.")
    return images

def main():
    """Main function to extract image updates, preferring Helm diff if present."""
    helm_diff = os.path.exists(os.getenv("DIFF_TXT_PATH", "diff.txt"))

    if helm_diff:
        print("🔍 Helm diff detected, extracting updated images.")
        images = extract_images_from_helm_diff()
    else:
        print("🔍 No Helm diff found, extracting updated image from PR.")
        images = extract_images_from_pr_diff()

    if not images:
        print("❌ No image updates detected.")
        return

    print(f"✅ Writing {len(images)} extracted images to GitHub Environment Variables.")
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