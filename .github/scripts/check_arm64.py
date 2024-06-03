import sys
import os
import requests
import json

def get_dockerhub_token(image):
    if image.startswith('docker.io/'):
        image = image[len('docker.io/'):]
    
    if '/' not in image:
        image = f'library/{image}'
    
    auth_service = 'registry.docker.io'
    auth_scope = f'repository:{image}:pull'
    token_response = requests.get(f'https://auth.docker.io/token?service={auth_service}&scope={auth_scope}')
    
    try:
        token = token_response.json().get('token')
    except json.JSONDecodeError as e:
        print(f"Error decoding DockerHub token response: {e}")
        return None, image
    
    return token, image

def get_ghcr_token(image):
    user_image = image[len('ghcr.io/'):]
    token_response = requests.get(f'https://ghcr.io/token?scope=repository:{user_image}:pull')
    
    try:
        token = token_response.json().get('token')
    except json.JSONDecodeError as e:
        print(f"Error decoding GHCR token response: {e}")
        return None, user_image
    
    return token, user_image

def get_quay_token(image):
    user_image = image[len('quay.io/'):]
    token_response = requests.get(f'https://quay.io/v2/auth?service=quay.io&scope=repository:{user_image}:pull')
    
    try:
        token = token_response.json().get('token')
    except json.JSONDecodeError as e:
        print(f"Error decoding Quay token response: {e}")
        return None, user_image
    
    return token, user_image

def main(image, tag, digest):
    if image.startswith('ghcr.io'):
        token, image_name = get_ghcr_token(image)
        manifest_url = f'https://ghcr.io/v2/{image_name}/manifests/{digest or tag}'
    elif image.startswith('quay.io'):
        token, image_name = get_quay_token(image)
        manifest_url = f'https://quay.io/v2/{image_name}/manifests/{digest or tag}'
    else:
        token, image_name = get_dockerhub_token(image)
        manifest_url = f'https://registry-1.docker.io/v2/{image_name}/manifests/{digest or tag}'
    
    if not token:
        print("Failed to get token for the image registry")
        sys.exit(1)
    
    headers = {
        'Authorization': f'Bearer {token}',
        'Accept': 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
    }
    
    response = requests.get(manifest_url, headers=headers)
    
    if response.status_code == 404:
        print(f"Error fetching manifest: 404 Not Found. The manifest URL '{manifest_url}' could not be found.")
        sys.exit(1)
    
    if response.status_code != 200:
        try:
            error_message = response.json()
        except json.JSONDecodeError:
            error_message = response.text
        print(f"Error fetching manifest: {error_message}")
        sys.exit(1)
    
    try:
        manifests = response.json().get('manifests', [])
    except json.JSONDecodeError as e:
        print(f"Error decoding manifest response: {e}")
        sys.exit(1)
    
    arm64_exists = any(manifest['platform']['architecture'] == 'arm64' for manifest in manifests)
    
    if arm64_exists:
        print(f"ARM64 image is available for {image_name}:{tag}{'@' + digest if digest else ''}")
        sys.exit(0)
    else:
        print(f"ARM64 image is not available for {image_name}:{tag}{'@' + digest if digest else ''}")
        sys.exit(1)

if __name__ == "__main__":
    image = sys.argv[1]
    tag = sys.argv[2]
    digest = sys.argv[3]
    main(image, tag, digest)
