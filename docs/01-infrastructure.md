# 1. Infrastructure: Proxmox, VMs and Cloud-Init

[← Back to README](../README.md)

## Moving K3s off the hypervisor

Before this project, K3s was installed directly on the three Proxmox hosts (one server, two agents). That works, but it is a bad idea for a security lab:

- A container breakout lands directly on Proxmox, the most critical layer of the stack.
- The CNI's iptables/eBPF rules share the host network stack with Proxmox's own bridges (`vmbr0`).

So I removed it and rebuilt the cluster inside VMs. Agents first, then the server:

```bash
# pve2, pve3
/usr/local/bin/k3s-agent-uninstall.sh
# pve1
/usr/local/bin/k3s-uninstall.sh
```

### Rebooting hosts you cannot physically reach

The hardware is in another country, so every reboot had to be one I was sure would come back. Only pve1 runs the VPN, so I rebooted in the order pve3 → pve2 → pve1, testing on the least critical node first, and made sure the tunnel starts on boot:

```bash
# pve1
systemctl enable wg-quick@wg0
systemctl enable tailscaled
crontab -l | grep vpn-watchdog
```

A small watchdog ([`scripts/vpn-watchdog.sh`](../scripts/vpn-watchdog.sh)) runs every minute from cron and restarts the WireGuard tunnel if the hub stops answering.

## Resource plan

Each host is an Intel N100: 4 cores, no hyper-threading, 16 GB RAM, ZFS on NVMe.

| Option | VMs per host | vCPU : core | RAM per VM | Decision |
| --- | --- | --- | --- | --- |
| 12 workers | 4 | 2:1 | ~3.5 GB | No. Every node runs kubelet, containerd and CNI agents; the cores fill up with background load |
| 1 server + 8 workers | 3 | 1.5:1 | 4 GB | No. Too tight next to ZFS |
| **1 server + 5 workers** | **2** | **1:1** | **6 GB** | **Yes.** Leaves room for Cilium, Tetragon and Falco |

Why VMs and not LXC: LXC shares the host kernel, and Kubernetes networking changes kernel state (eBPF, iptables). In LXC that means constant workarounds and weak isolation.

### Capping the ZFS ARC

By default the ZFS ARC can take a large share of RAM. I capped it at 2 GB on each host so the VMs have room:

```bash
echo "options zfs zfs_arc_max=2147483648" > /etc/modprobe.d/zfs.conf   # persistent
update-initramfs -u -k all
echo 2147483648 > /sys/module/zfs/parameters/zfs_arc_max              # apply now
```

## Cloud-Init template

Instead of installing six VMs from an ISO, I built a template from the Ubuntu 22.04 cloud image and let Cloud-Init inject the user, IP, DNS and SSH key into every clone. There is no shared storage, so each host has its own template (9000, 9010, 9020).

See [`scripts/create-template.sh`](../scripts/create-template.sh) and [`scripts/clone-vm.sh`](../scripts/clone-vm.sh).

```bash
./create-template.sh 9000 <user>
./clone-vm.sh 9000 901 k3s-master   192.168.1.110
./clone-vm.sh 9000 902 k3s-worker-1 192.168.1.111
# ...same on pve2 (903, 904) and pve3 (905, 906)
```

## Problem: three clones, one IP address

The first boot used DHCP, and the router handed out the same addresses to different VMs even though their MAC addresses differed:

| VM | IP from DHCP |
| --- | --- |
| 901 server | 192.168.1.107 |
| 902 worker-1 | 192.168.1.108 |
| 903 worker-2 | 192.168.1.107 (conflict) |
| 904 worker-3 | 192.168.1.108 (conflict) |
| 905 worker-4 | 192.168.1.107 (conflict) |
| 906 worker-5 | 192.168.1.109 |

The cloud image's DHCP client identifies itself with a client ID derived from the machine ID, not the MAC. The clones shared it, so the router treated them as one device. Regenerating `/etc/machine-id` did not fully help because the router's lease cache kept the old identity.

The real fix was to stop using DHCP for cluster nodes. A Kubernetes node that comes back on a different IP after a power cut breaks the cluster anyway:

```bash
qm set 901 --ipconfig0 ip=192.168.1.110/24,gw=192.168.1.1
```

## Problem: Falco would not start (found in Phase 3)

Proxmox gives VMs the generic `kvm64` CPU model by default. It hides SSE4.2, POPCNT and the other x86-64-v2 features, even though the N100 supports them. Falco's init container refused to run:

```
This program can only be run on AMD64 processors with v2 microarchitecture support.
```

All three hosts have the same CPU, so passing the host CPU through costs nothing:

```bash
qm set 902 --cpu host
qm shutdown 902 --timeout 120 --forceStop 1; qm start 902

# and the templates, so future clones are right
qm set 9000 --cpu host

# verify: both vCPUs report sse4_2
grep -c sse4_2 /proc/cpuinfo
```

`qm reboot` timed out on a few VMs because K3s took longer to drain than Proxmox waited. `qm shutdown --forceStop` followed by `qm start` was reliable.
