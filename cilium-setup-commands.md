## Cilium install commands for BGP control plane, LB IPAM, native routing mode with auto direct routes, strict kube-proxy replacement, bpf masquerade, hybrid dsr, and maglev bpf lb algorithm

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

sudo kubectl delete pods --all -A

sudo kubectl apply -f CiliumBGPPeeringPolicy.yml

sudo nano /etc/systemd/system/k3s.service

# Add this to the list of server arguments
--disable-kube-proxy

sudo systemctl daemon-reload
sudo systemctl restart k3s
```