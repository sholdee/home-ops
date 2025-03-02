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
                    match = re.match(r'^\+ *version: *"(.+)"', line, re.IGNORECASE)
                    if match:
                        version = match.group(1).strip()
                        images.append(("mongodb/mongodb-community-server", f"{version}-ubi8", ""))
                        break  # Stop after first match
            else:
                for line in lines:
                    match = re.match(r'^\+ *(?:image|[a-z_]+image|imageName): *(.+)', line, re.IGNORECASE)
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
        print(f"{diff_txt_path} not found, skipping Helm image extraction.")
        return images

    with open(diff_txt_path, "r") as f:
        diff_lines = f.readlines()

    for line in diff_lines:
        match = re.match(r'^\+ *(?:image|[a-z_]+image|imageName): *(.+)', line, re.IGNORECASE)
        if match:
            image_tag = match.group(1).strip()

            image = image_tag.split('@')[0].split(':')[0].strip()
            tag = image_tag.split(':')[1].split('@')[0].strip() if ':' in image_tag else ""
            digest = image_tag.split('@')[1].strip() if '@' in image_tag else ""

            images.append((image, tag, digest))

    return images

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
