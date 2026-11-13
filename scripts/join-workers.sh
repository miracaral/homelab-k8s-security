#!/bin/bash
# Run from a machine that can SSH to every VM (I used the gateway host).
# The join token is read from the server and passed straight to the agents;
# it is never printed or written to disk.
set -euo pipefail
USER_NAME=${1:?vm user}
LAN=${LAN:?set LAN to the first three octets of the node subnet, for example LAN=10.0.0}
SERVER=$LAN.110
WORKERS="111 112 113 114 115"

TOKEN=$(ssh "$USER_NAME@$SERVER" 'sudo cat /var/lib/rancher/k3s/server/node-token')
for ip in $WORKERS; do
  echo "===== $LAN.$ip ====="
  # -n: nothing typed into the terminal during the loop can leak into ssh's stdin
  ssh -n "$USER_NAME@$LAN.$ip" \
    "curl -fL https://get.k3s.io | K3S_URL=https://$SERVER:6443 K3S_TOKEN=$TOKEN INSTALL_K3S_EXEC='agent --node-ip=$LAN.$ip' sh -"
done
