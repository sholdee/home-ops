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
            for line in lines:
                if re.match(r'^\+ *image: ', line):
                    image_tag = line.split('image: ')[1]
                    image = image_tag.split('@')[0].split(':')[0]
                    tag = image_tag.split(':')[1].split('@')[0] if ':' in image_tag else ""
                    digest = image_tag.split('@')[1] if '@' in image_tag else ""
            
                    with open(os.environ['GITHUB_ENV'], 'a') as f:
                        f.write(f"IMAGE={image}\n")
                        f.write(f"TAG={tag}\n")
                        f.write(f"DIGEST={digest}\n")
                    break  # Exit after finding the new image line

if __name__ == "__main__":
    main()
