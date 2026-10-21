# 2. Remote access: from WireGuard to Tailscale

[← Back to README](../README.md)

I manage this lab from abroad, usually over mobile data. Access went through a lot of iterations, and the debugging was one of the most useful parts of the project.

## The original setup

```
laptop (10.50.0.50) ── WireGuard ── VPS hub (10.50.0.1) ── WireGuard ── pve1 (10.50.0.11) ── home LAN
```

pve1 is the gateway; pve2 and pve3 are reached through it. Proxmox web UIs are forwarded over SSH.

## Symptom: SSH lags and drops

```
Read from remote host 10.50.0.11: Connection reset by peer
```

First I ruled out the server with a single non-interactive command (load, memory, OOM kills, ZFS ARC, watchdog log, last WireGuard handshake):

```bash
ssh -o ClearAllForwardings=yes pve1-remote 'uptime; free -h; dmesg -T | grep -iE "out of memory|killed process" | tail -5; tail -15 /var/log/vpn-watchdog.log; wg show wg0 | grep -E "handshake|transfer"'
```

The server was idle and healthy. So I measured the path hop by hop:

| Test | WireGuard | Loss | Note |
| --- | --- | --- | --- |
| laptop → VPS hub | on | 70% | 13 s outage |
| laptop → pve1 | on | 5% | |
| large packets (`ping -D -s 1352`) | on | 60% | big packets pass; loss comes from outages, not MTU |
| laptop → 1.1.1.1 | on (full tunnel) | 57% | 15 s outages |
| laptop → 1.1.1.1 | off | 5% | no outages |
| laptop → pve1 over Tailscale | off | **0%** | relayed via DERP |

Conclusion: the mobile carrier was throttling WireGuard's UDP traffic. `PersistentKeepalive = 25` did not help. And because the tunnel was a full tunnel (`AllowedIPs = 0.0.0.0/0`), all internet traffic went down with it.

## The fix

**1. Tailscale became the default path.** On mobile data it cannot form a direct connection, so it goes through a DERP relay (~110–140 ms), but with zero loss. I disabled key expiry for the servers in the admin console; otherwise access silently stops after 180 days.

**2. WireGuard became a split-tunnel backup:**

```diff
- AllowedIPs = 0.0.0.0/0
+ AllowedIPs = 10.50.0.0/24
```

**3. pve1 became a subnet router**, so the laptop reaches every VM directly:

```bash
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-tailscale.conf
sysctl -p /etc/sysctl.d/99-tailscale.conf
tailscale set --advertise-routes=192.168.1.0/24
# then approve the route in the admin console
```

**4. mosh + tmux for the terminal.** At 140 ms every keystroke lags. mosh echoes locally and survives drops; tmux keeps the session alive on the server.

```bash
# ~/.zshrc on the laptop
pve1() {
  pgrep -f "fN.*pve1-ts" >/dev/null || ssh -fN -o ExitOnForwardFailure=yes pve1-ts   # web UI forwards
  mosh --ssh="ssh -o ClearAllForwardings=yes" pve1-ts -- tmux new -A -s main
}
```

`ClearAllForwardings` matters: without it, mosh's inner SSH tries to open the same port forwards again and fails.

Tip learned the hard way: long pastes get garbled over mosh. For anything longer than a few lines I write the file locally and `scp` it.

## SSH keys through Cloud-Init

`ssh-copy-id` failed on every VM with `Permission denied (publickey)`: Ubuntu cloud images disable SSH password login, so there is no way in to install a key. Proxmox can inject keys through Cloud-Init instead:

```bash
cat ~/.ssh/id_ed25519.pub laptop.pub > vm-keys.pub
for id in 901 902; do qm set $id --sshkeys vm-keys.pub && qm reboot $id; done
```

After the reboot SSH warned `REMOTE HOST IDENTIFICATION HAS CHANGED`. Not an attack: when Cloud-Init config changes, it runs again and regenerates the VM's host keys.

```bash
for ip in 110 111 112 113 114 115; do ssh-keygen -R 192.168.1.$ip; done
for ip in 110 111 112 113 114 115; do ssh -o StrictHostKeyChecking=accept-new <user>@192.168.1.$ip hostname; done
```

## Problem: the VMs lost DNS

The K3s installer finished silently and `kubectl` did not exist.

```bash
ping -c 2 1.1.1.1                          # works
ping -c 2 get.k3s.io                       # Temporary failure in name resolution
resolvectl status | grep -i "dns servers"  # 100.100.100.100
```

The chain of events:

1. `tailscale up` on pve1 replaced the host's resolver with Tailscale's (100.100.100.100).
2. When the VMs rebooted for the SSH keys, Cloud-Init copied the host's DNS settings.
3. The VMs are not on the tailnet, so that resolver was unreachable.
4. `curl -s` in the install one-liner hid the error.

Fix in two parts:

```bash
# on each Proxmox host
tailscale set --accept-dns=false

# give the VMs explicit resolvers
qm set 901 --nameserver "1.1.1.1 8.8.8.8" --searchdomain lan
```
