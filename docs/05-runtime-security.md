# 5. Phase 3: runtime detection and enforcement with Tetragon and Falco

[← Back to README](../README.md)

**Result:** Tetragon sees every process inside the pods at the kernel level, and a namespaced TracingPolicy kills any process in `demo` that tries to read `/etc/shadow` (exit 137, SIGKILL), while `sudo` on the nodes keeps working. Falco adds broad detection with its built-in rules.

## Tetragon

```bash
helm repo add cilium https://helm.cilium.io
helm install tetragon cilium/tetragon -n kube-system
kubectl -n kube-system rollout status ds/tetragon --timeout=300s
```

### Detection only

Tetragon runs one agent per node, so I attach to the agent on the attacker's node:

```bash
# terminal 1: defender
NODE=$(kubectl -n demo get pod -l app=attacker -o jsonpath='{.items[0].spec.nodeName}')
TPOD=$(kubectl -n kube-system get pod -l app.kubernetes.io/name=tetragon --field-selector spec.nodeName=$NODE -o name)
kubectl -n kube-system exec -it $TPOD -c tetragon -- tetra getevents -o compact --pods attacker

# terminal 2: attacker
kubectl -n demo exec deploy/attacker -- whoami
kubectl -n demo exec deploy/attacker -- cat /etc/shadow
kubectl -n demo exec deploy/attacker -- curl -s -m 3 http://backend:8080/get
```

```
🚀 process demo/attacker-546ff77776-727mz /usr/bin/whoami
💥 exit    demo/attacker-546ff77776-727mz /usr/bin/whoami  0
🚀 process demo/attacker-546ff77776-727mz /bin/cat /etc/shadow
💥 exit    demo/attacker-546ff77776-727mz /bin/cat /etc/shadow 0
🚀 process demo/attacker-546ff77776-727mz /usr/bin/curl "-s -m 3 http://backend:8080/get"
💥 exit    demo/attacker-546ff77776-727mz /usr/bin/curl "-s -m 3 http://backend:8080/get" 28
```

In this mode the read succeeds. The defender sees it, but only after the fact. (The curl exit code 28 is the Phase 2 policy at work.)

### Enforcement

[`manifests/phase3-runtime-security/block-shadow.yaml`](../manifests/phase3-runtime-security/block-shadow.yaml) hooks `security_file_permission`, the kernel's permission check, and sends SIGKILL when a process in `demo` asks to read `/etc/shadow` or `/etc/gshadow` (mask `4` = `MAY_READ`).

It is a `TracingPolicyNamespaced` on purpose. My first idea was a cluster-wide policy, until I realised it would also kill `sshd` and `sudo` on the nodes the moment they read `/etc/shadow`. On a cluster I can only reach remotely, that is a lockout.

```bash
kubectl apply -f manifests/phase3-runtime-security/block-shadow.yaml
kubectl -n demo exec deploy/attacker -- cat /etc/shadow
command terminated with exit code 137
```

```
🚀 process demo/attacker-546ff77776-727mz /bin/cat /etc/shadow
📚 read    demo/attacker-546ff77776-727mz /bin/cat /etc/shadow
💥 exit    demo/attacker-546ff77776-727mz /bin/cat /etc/shadow SIGKILL
```

Exit 137 = 128 + 9 (SIGKILL). The process dies inside the permission check, before a single byte reaches user space. And on the node:

```bash
sudo -v && echo "sudo works"
sudo works
```

## Falco

On K3s, containerd lives at a non-standard path. Passing the socket explicitly gives pod and container names in alerts.

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco -n falco --create-namespace \
  --set driver.kind=modern_ebpf --set tty=true \
  --set collectors.containerd.socket=/run/k3s/containerd/containerd.sock
```

All six Falco pods went into `Init:CrashLoopBackOff` at first. The cause was the Proxmox `kvm64` CPU model hiding x86-64-v2 features; see [Infrastructure](01-infrastructure.md#problem-falco-would-not-start-found-in-phase-3).

After switching the VMs to `--cpu host`:

```bash
kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco -f --max-log-requests 6 --since=1m   # defender
kubectl -n demo exec -it deploy/attacker -- sh -c 'echo merhaba'                                   # attacker
```

```
Notice A shell was spawned in a container with an attached terminal | evt_type=execve user=root
process=sh proc_exepath=/bin/busybox parent=containerd-shim command=sh -c echo merhaba
container_name=shell container_image_repository=docker.io/nicolaka/netshoot container_image_tag=v0.13
k8s_pod_name=attacker-546ff77776-727mz k8s_ns_name=demo
```

## Tetragon vs Falco

| | Tetragon | Falco |
| --- | --- | --- |
| Rules | Written by me (TracingPolicy) | Large built-in rule set |
| Can block | Yes, in the kernel | No, alerts only |
| Shown here | Killed `cat /etc/shadow` in `demo` | Flagged an interactive shell in a container |
| Best at | Targeted enforcement | Broad detection out of the box |
