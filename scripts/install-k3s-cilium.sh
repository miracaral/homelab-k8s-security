#!/bin/bash
# Run on the control-plane VM. K3s without flannel, kube-proxy, traefik and
# servicelb; Cilium replaces them and encrypts pod traffic with WireGuard.
set -euo pipefail
NODE_IP=${1:?control-plane IP, e.g. 192.168.1.110}

curl -fL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --flannel-backend=none --disable-network-policy --disable-kube-proxy \
  --disable=traefik --disable=servicelb \
  --node-ip=$NODE_IP --write-kubeconfig-mode=644" sh -

# cilium CLI, checksum verified
CLI_VER=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -fL --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CLI_VER}/cilium-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz{,.sha256sum}

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cilium install \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$NODE_IP" --set k8sServicePort=6443 \
  --set encryption.enabled=true --set encryption.type=wireguard \
  --set ipam.operator.clusterPoolIPv4PodCIDRList=10.42.0.0/16 \
  --set operator.replicas=1
cilium status --wait
