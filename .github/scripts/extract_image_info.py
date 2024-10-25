import sys
import requests
import json
import os
import re

def main():
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
    
    for file in files:
        if file['filename'].endswith('.yaml') or file['filename'].endswith('.yml'):
            patch = file['patch']
            lines = patch.split('\n')
            
            if re.search(r'^apps/.*/unifi-db.yml$', file['filename']):
                for line in lines:
                    match = re.match(r'^\+ *version: *"(.+)"', line, re.IGNORECASE)
                    if match:
                        version = match.group(1).strip()
                        
                        with open(os.environ['GITHUB_ENV'], 'a') as f:
                            f.write(f"IMAGE=mongodb/mongodb-community-server\n")
                            f.write(f"TAG={version}-ubi8\n")
                            f.write(f"DIGEST=\n")
                        break  # Exit after finding the new version line
            else:
                for line in lines:
                    match = re.match(r'^\+ *(?:image|[a-z_]+image|imageName): *(.+)', line, re.IGNORECASE)
                    if match:
                        image_tag = match.group(1).strip()
                        
                        image = image_tag.split('@')[0].split(':')[0].strip()
                        tag = image_tag.split(':')[1].split('@')[0].strip() if ':' in image_tag else ""
                        digest = image_tag.split('@')[1].strip() if '@' in image_tag else ""
                        
                        with open(os.environ['GITHUB_ENV'], 'a') as f:
                            f.write(f"IMAGE={image}\n")
                            f.write(f"TAG={tag}\n")
                            f.write(f"DIGEST={digest}\n")
                        break  # Exit after finding the new image line

if __name__ == "__main__":
    main()
