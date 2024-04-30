### Cilium [install commands](https://github.com/cilium/cilium-cli/blob/master/install/install.go) for:
* [BGP control plane](https://docs.cilium.io/en/stable/network/bgp-control-plane/)
* [LB IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/)
* [Native routing](https://docs.cilium.io/en/stable/network/concepts/routing/#native-routing) mode with auto direct routes
* [Strict kube-proxy replacement](https://docs.cilium.io/en/latest/network/kubernetes/kubeproxy-free/)
* [BPF masquerade](https://docs.cilium.io/en/stable/network/concepts/masquerading/)
* [Hybrid dsr](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#dsr-mode)
* [Maglev](https://cilium.io/blog/2020/11/10/cilium-19/#maglev) bpf lb algorithm
* [cilium-agent cmd reference](https://docs.cilium.io/en/stable/cmdref/cilium-agent/)

```bash
cilium install --version "v1.15.3" \
  --helm-set operator.replicas="1" \
  --helm-set ipam.operator.clusterPoolIPv4PodCIDRList="10.52.0.0/16" \
  --helm-set ipv4NativeRoutingCIDR="10.52.0.0/16" \
  --helm-set k8sServiceHost="127.0.0.1" \
  --helm-set k8sServicePort="6444" \
  --helm-set routingMode="native" \
  --helm-set autoDirectNodeRoutes="true" \
  --helm-set kubeProxyReplacement="true" \
  --helm-set bpf.masquerade="false" \
  --helm-set enableIPv4Masquerade="false" \
  --helm-set bgpControlPlane.enabled="true" \
  --helm-set hubble.enabled="true" \
  --helm-set hubble.relay.enabled="true" \
  --helm-set hubble.ui.enabled="true" \
  --helm-set bpf.loadBalancer.algorithm="maglev" \
  --helm-set bpf.loadBalancer.mode="hybrid" \
  --helm-set installNoConntrackIptablesRules="true"
```

```bash
sudo kubectl apply -f CiliumBGPPeeringPolicy.yml

sudo nano /etc/systemd/system/k3s.service

# Add this to the list of server arguments
--disable-kube-proxy

sudo systemctl daemon-reload
sudo systemctl restart k3s
```
