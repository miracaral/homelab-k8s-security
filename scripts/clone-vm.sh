#!/bin/bash
# Clone a K3s node from the local template with a static IP.
# Usage: ./clone-vm.sh <template-id> <vm-id> <name> <ip>
#   ./clone-vm.sh 9000 901 cp-1 <LAN>.110
# Static IPs on purpose: cloned cloud images share a DHCP client ID,
# so the router handed several clones the same address.
set -euo pipefail
TPL=${1:?template id}; ID=${2:?vm id}; NAME=${3:?name}; IP=${4:?ip}
GW=${GW:?set GW to the router address, for example GW=10.0.0.1}

qm clone "$TPL" "$ID" --name "$NAME" --full 1
qm set "$ID" --ipconfig0 "ip=$IP/24,gw=$GW"
qm start "$ID"
