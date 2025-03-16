## Add Repos

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add longhorn https://charts.longhorn.io
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
helm repo add jetstack https://charts.jetstack.io # cert-manager
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update
```

## Install and Configure Packages

```bash
helm upgrade --install argocd argo/argo-cd --create-namespace --namespace=argocd

helm upgrade --install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace --set defaultSettings.defaultDataLocality="best-effort"

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace --set controller.service.loadBalancerIP="192.168.77.20" --set controller.metrics.enabled=true --set-string controller.podAnnotations."prometheus\.io/scrape"="true" --set-string controller.podAnnotations."prometheus\.io/port"="10254"

helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard --create-namespace --namespace kubernetes-dashboard

helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.13.3 --set installCRDs=true --set extraArgs='{--dns01-recursive-nameservers-only=true,--dns01-recursive-nameservers=1.1.1.1:53\,1.0.0.1:53}'
```

## How to Install Helm and Arkade

```bash
# Ensure GIT is installed
apt -y install git  

# Fix kubeconfig file to prevent Helm errors
export KUBECONFIG=~/.kube/config  
mkdir ~/.kube 2> /dev/null  
sudo k3s kubectl config view --raw > "$KUBECONFIG"  
chmod 600 "$KUBECONFIG"  
echo "KUBECONFIG=$KUBECONFIG" >> /etc/environment  

# Switch to home directory
cd

# Create a directory for Helm and navigate into it
mkdir helm  
cd helm  

# Download Helm installer
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3  

# Modify permissions for execution
chmod 700 get_helm.sh  

# Install Helm
./get_helm.sh  

# Verify Helm installation
helm version

# Install Arkade
curl -sLS https://get.arkade.dev | sudo sh 

# Verify Arkade installation
arkade version
```
