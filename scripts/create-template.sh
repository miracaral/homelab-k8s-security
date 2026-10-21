#!/bin/bash
# Build a Proxmox VM template from the Ubuntu 22.04 cloud image.
# Usage (on a Proxmox host): ./create-template.sh <template-id> <user>
# The hosts have no shared storage, so each host gets its own template
# (I used 9000, 9010 and 9020).
set -euo pipefail
ID=${1:?template id}
CIUSER=${2:?vm user}
STORAGE=local-zfs
IMG=jammy-server-cloudimg-amd64.img

[ -f "$IMG" ] || wget -O "$IMG" https://cloud-images.ubuntu.com/jammy/current/$IMG

qm create "$ID" --name k3s-ubuntu-template --memory 6144 --cores 2 \
  --cpu host --net0 virtio,bridge=vmbr0
qm importdisk "$ID" "$IMG" "$STORAGE"
qm set "$ID" --scsihw virtio-scsi-pci --scsi0 "$STORAGE:vm-$ID-disk-0"
qm set "$ID" --ide2 "$STORAGE:cloudinit"
qm set "$ID" --boot c --bootdisk scsi0
qm set "$ID" --serial0 socket --vga serial0
qm disk resize "$ID" scsi0 25G
qm set "$ID" --ciuser "$CIUSER" --nameserver "1.1.1.1 8.8.8.8" --searchdomain lan
# SSH password login is disabled in Ubuntu cloud images: inject a public key instead
qm set "$ID" --sshkeys ./authorized_keys.pub
qm template "$ID"
