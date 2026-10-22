# Homelab Kubernetes Security Lab

A 6-node K3s cluster on three mini PCs, built to practise Kubernetes networking and security end to end: eBPF networking with encryption, zero-trust network policies, kernel-level runtime enforcement, event-driven autoscaling and Pod Security hardening. Every control is tested with a before/after result, not just installed.

I run the hardware at home and manage it remotely from abroad, so remote access and "don't lock yourself out" were part of the design from day one.

## Results at a glance

| Phase | What I built | Proof |
| --- | --- | --- |
| 1. Cluster | K3s in VMs, Cilium (eBPF, no kube-proxy), WireGuard pod encryption, Hubble | 6/6 nodes Ready, `Encryption: Wireguard (6/6 nodes)`, 83/83 connectivity tests passed |
| 2. Network policies | Default deny + L3/L4/L7 CiliumNetworkPolicies across web/api/data zones | 7/7 paths open → only the 2 intended paths open; attacker pod reaches nothing |
| 3. Runtime security | Tetragon TracingPolicy + Falco | `cat /etc/shadow` in a pod killed in the kernel (exit 137); Falco flags shells in containers |
| 4. Autoscaling | KEDA scaling a worker from a Redis queue | 0 → 10 replicas in seconds, queue drained, back to 0 after cooldown |
| 5. Hardening | Pod Security `restricted`, no SA tokens, kubelet locked down | Privileged/plain pods refused, token absent, kubelet 401 from network and unreachable from pods |

![Policy test after hardening](images/token-removed-and-policy-test.png)

## Architecture

```
                    laptop (abroad, mobile data)
                      │                    ┆
                Tailscale (default)    WireGuard via VPS (backup, split tunnel)
                      │                    ┆
   ┌──────────────────▼────────────────────▼────────────── home LAN 192.168.1.0/24 ──┐
   │  pve1 (gateway + subnet router)     pve2                  pve3                  │
   │  ├─ k3s-master   .110               ├─ k3s-worker-2 .112  ├─ k3s-worker-4 .114  │
   │  └─ k3s-worker-1 .111               └─ k3s-worker-3 .113  └─ k3s-worker-5 .115  │
   └─────────────────────────────────────────────────────────────────────────────────┘
        Pod traffic between nodes: Cilium eBPF datapath, WireGuard-encrypted
```

### Hardware

3 × Intel N100 mini PC (4 cores, 16 GB RAM, NVMe with ZFS), connected through a switch on the home LAN. Each runs Proxmox VE and hosts two VMs: 2 vCPU and 6 GB RAM each, so vCPUs map 1:1 to physical cores.

### Software

| Component | Version |
| --- | --- |
| Proxmox VE kernel | 6.17 |
| VM OS | Ubuntu 22.04 LTS cloud image |
| K3s | v1.36.5+k3s1 |
| Cilium | 1.20.1 (kube-proxy replacement, WireGuard, Hubble) |
| Tetragon, Falco (modern eBPF), KEDA | via Helm |

## Walkthrough

| # | Doc | Covers |
| --- | --- | --- |
| 1 | [Infrastructure](docs/01-infrastructure.md) | Moving K3s off the hypervisor, resource plan, ZFS ARC cap, Cloud-Init templates, the duplicate-IP bug, the `kvm64` CPU problem |
| 2 | [Remote access](docs/02-remote-access.md) | Diagnosing WireGuard drops hop by hop, Tailscale subnet router, split tunnel, mosh + tmux, SSH keys and the DNS chain reaction |
| 3 | [K3s + Cilium](docs/03-k3s-cilium.md) | Phase 1: CNI-less K3s, Cilium with WireGuard, connectivity tests, Hubble |
| 4 | [Network policies](docs/04-network-policies.md) | Phase 2: zones, default deny, L7 HTTP rules, L7 block vs L3 drop |
| 5 | [Runtime security](docs/05-runtime-security.md) | Phase 3: Tetragon detection and SIGKILL enforcement, Falco |
| 6 | [KEDA autoscaling](docs/06-keda-autoscaling.md) | Phase 4: scale-to-zero workers from a Redis queue, tainting the control plane |
| 7 | [Hardening](docs/07-hardening.md) | Phase 5: Pod Security Admission, ServiceAccount tokens, kubelet API, restricted pods |

## Repository layout

```
.
├── docs/            step-by-step write-up for each phase
├── manifests/
│   ├── phase2-network-policies/   demo app + 6 CiliumNetworkPolicies
│   ├── phase3-runtime-security/   Tetragon TracingPolicyNamespaced
│   ├── phase4-keda/               Redis queue, worker, ScaledObject
│   └── phase5-hardening/          demo app meeting Pod Security "restricted"
├── scripts/         Proxmox template/clone, K3s + Cilium install, worker join,
│                    policy test matrix, KEDA load + watch, VPN watchdog
└── images/          screenshots of results
```

## Reproduce the security labs

On any cluster running Cilium (with L7 proxy enabled, the default), from a machine with `kubectl` access:

```bash
kubectl apply -f manifests/phase2-network-policies/00-app.yaml
./scripts/policy-test.sh                                   # everything ALLOW
kubectl apply -f manifests/phase2-network-policies/01-policies.yaml
./scripts/policy-test.sh                                   # 2 ALLOW / 5 BLOCK

helm install tetragon cilium/tetragon -n kube-system
kubectl apply -f manifests/phase3-runtime-security/block-shadow.yaml
kubectl -n demo exec deploy/attacker -- cat /etc/shadow    # exit code 137

kubectl -n demo patch serviceaccount default -p '{"automountServiceAccountToken": false}'
kubectl apply -f manifests/phase5-hardening/00-app-hardened.yaml
kubectl label --overwrite ns demo pod-security.kubernetes.io/enforce=restricted
```

## Lessons learned

1. Run Kubernetes inside VMs, not on the hypervisor, so a breakout cannot reach Proxmox.
2. Cloned cloud images can share a DHCP identity. Give cluster nodes static IPs.
3. Ubuntu cloud images disable SSH password login; inject keys with Cloud-Init (`qm set --sshkeys`).
4. Changing Cloud-Init settings regenerates SSH host keys, so a "host key changed" warning is expected.
5. Cloud-Init copies DNS from the host. If the host uses Tailscale DNS, the VMs lose name resolution.
6. `curl -s` hides errors. Run install scripts without `-s` the first time.
7. Proxmox's default `kvm64` CPU hides x86-64-v2 features; modern eBPF tools need `--cpu host`.
8. Mobile carriers may throttle UDP. When a VPN drops, measure hop by hop before changing anything.
9. A full tunnel takes your whole internet down when it breaks. A split tunnel is enough for lab access.
10. Disable Tailscale key expiry on remote servers or you get locked out after 180 days.
11. Scope enforcement policies. A cluster-wide "kill on /etc/shadow read" also kills `sshd` and `sudo`.
12. `warn=restricted` before `enforce=restricted`: the warnings are a ready-made hardening checklist.
13. K3s does not taint its server node. Taint it if the control plane should not run workloads.

## Next steps

- Lower the server VM to 4 GB RAM
- Exclude the node IPs from the router's DHCP pool
- Make the VPN watchdog check handshake age instead of ping
- Lock down the `jobs` namespace from Phase 4: Redis there has no password and no network policy yet
- Attack scenarios: container breakout attempts and lateral movement, verified against these controls

## License

[MIT](LICENSE)
