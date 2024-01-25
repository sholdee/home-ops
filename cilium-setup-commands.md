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
cilium install --set=ipam.operator.clusterPoolIPv4PodCIDRList=10.52.0.0/16 --set k8sServiceHost=192.168.99.77 --set k8sServicePort=6443

cilium hubble enable --ui

cilium config set enable-bgp-control-plane true
cilium config set auto-direct-node-routes true
cilium config set routing-mode native
cilium config set ipv4-native-routing-cidr 10.52.0.0/16
cilium config set kube-proxy-replacement strict
cilium config set enable-bpf-masquerade true
cilium config set install-no-conntrack-iptables-rules true
cilium config set bpf-lb-mode hybrid
cilium config set bpf-lb-algorithm maglev
```

```bash
sudo kubectl delete pods --all -A

sudo kubectl apply -f CiliumBGPPeeringPolicy.yml

sudo nano /etc/systemd/system/k3s.service

# Add this to the list of server arguments
--disable-kube-proxy

sudo systemctl daemon-reload
sudo systemctl restart k3s
```
