## Commands to customize and install kube-prometheus

### Customization reference docs

[Customizing kube-prometheus](https://github.com/prometheus-operator/kube-prometheus/blob/main/docs/customizing.md)

[Monitoring additional namespaces](https://github.com/prometheus-operator/kube-prometheus/blob/main/docs/customizations/monitoring-additional-namespaces.md)

### Label ingress-nginx if scraping metrics from it

```bash
sudo kubectl label namespace ingress-nginx networking/namespace=ingress-nginx
```

### Prepare jsonnet environment and kube-prometheus manifests

```bash
# Install go
sudo apt-get install -y golang-go

# Add go to PATH
export PATH=$PATH:$(go env GOPATH)/bin

# Make a working directory for our files
mkdir my-kube-prometheus; cd my-kube-prometheus

# Install jssonnet
go install github.com/google/go-jsonnet/cmd/jsonnet@latest

GO111MODULE="on"

# Install jsonnet-bundler
go install github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb@latest

# Initialize our project
jb init

# Install kube-prometheus project libraries
jb install github.com/prometheus-operator/kube-prometheus/jsonnet/kube-prometheus@main

# Get base configuration file and yaml build script
wget https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/example.jsonnet -O example.jsonnet
wget https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/build.sh -O build.sh

# Copy base config to working file
cp example.jsonnet main.jsonnet

# Edit base configuration file per requirements
nano main.jsonnet

# Set executable permission on build script
chmod +x build.sh

# Install json to yaml conversion script dependency
go install github.com/brancz/gojsontoyaml@latest

# Execute build script to create customized manifests
./build.sh main.jsonnet
```

## Install or update kube-prometheus

```bash
# Apply and wait for resources
kubectl apply --server-side -f manifests/setup
kubectl wait \
	--for condition=Established \
	--all CustomResourceDefinition \
	--namespace=monitoring
kubectl apply -f manifests/

# If updating existing install, run this instead
kubectl replace -f manifests/
```

## Finding the prometheus datasource uid in grafana for custom dashboards exported from older versions

1. Open /datasources in your Grafana dashboard. You can do that by clicking Settings -> Data sources or just typing that URL in your browser.
2. Open your browser dev tools (F12) and go to Network tab. Filter XHR (AJAX) requests and find the "datasources" request.
3. Now open the response tab for that request and find your datasource's uid. If you have multiple datasources, just find the appropriate one in that data.
