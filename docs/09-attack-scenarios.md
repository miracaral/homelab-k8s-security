# 9. Phase 7: attack scenarios

[← Back to README](../README.md)

Phases 2 to 6 built controls and tested that they hold. This phase starts from the other side: assume an attacker already has a pod, try what an attacker would try, and write down which control stops each attempt. Every table below is filled from runs on this cluster. What I did not run is listed in [7h](#7h-not-measured), not guessed.

## 7a. Method

A new namespace, `attack-lab`, starts with no controls at all. That is the "before". Controls are then added one at a time and the same attempt is repeated, so each row can name the control that made the difference:

1. no controls
2. Pod Security `restricted`
3. Cilium default-deny
4. ServiceAccount token, RBAC, Tetragon

`demo`, `foothold` and `jobs` are targets only; nothing in them was changed.

Rules for the tests, fixed before the first pod:

- Every pod is pinned to one worker with `nodeSelector` (`worker-5`, which runs no application workload). Never the control plane.
- Proofs only read. Every `hostPath` mount is `readOnly`, nothing is written on the node, no kernel module is loaded, no exploit is run.
- Sensitive files are tested for readability; their content is never printed. Tokens are passed to `curl` through a header file, so they never appear in a process argument (Tetragon logs those).
- One pod at a time: create, confirm the node, run the proof, delete, compare the node with a baseline taken before the first pod (container and sandbox counts, mounts, loaded modules, checksum of `core_pattern`). Every comparison matched.

Manifests: [`manifests/phase7-attacks/`](../manifests/phase7-attacks). Script: [`scripts/attack-test.sh`](../scripts/attack-test.sh).

## 7b. Scenario A: breaking out of the container

Seven pods ([`01-breakout-pods.yaml`](../manifests/phase7-attacks/01-breakout-pods.yaml)), each asking for one thing a normal workload does not need.

| # | The pod asks for | No controls | Pod Security `restricted` | Stopped by |
| --- | --- | --- | --- | --- |
| a0 | nothing special | admitted: root, 14 capabilities, no seccomp filter | **refused** | Pod Security |
| A1 | `privileged: true` | admitted: all capabilities, node disk visible, `/sys` and cgroup mounted writable | **refused** | Pod Security |
| A2 | `hostPath: /` | admitted: node files readable, including `/etc/shadow` | **refused** | Pod Security |
| A3 | `hostPID` | admitted: 131 node processes visible (environment and root of PID 1 refused) | **refused** | Pod Security |
| A4 | `hostNetwork` | admitted: the node's own localhost reachable (kubelet health port answers) | **refused** | Pod Security |
| A5 | the containerd socket | admitted: 29 containers and 12 running tasks listed | **refused** | Pod Security |
| A6 | `SYS_ADMIN`, `SYS_PTRACE`, `SYS_MODULE`, `NET_RAW` | admitted: capabilities present; `mount` still got `Permission denied` | **refused** | Pod Security |
| A7 | writable kernel paths | plain pod: `/proc/sys`, `/sys`, cgroup read-only. Privileged pod: writable | privileged pod **refused** | Pod Security |
| C6 | node credentials through A2 | kubelet key, kubeconfig and node password file readable | **refused** (same pod as A2) | Pod Security |

With no controls, all seven pods were admitted and scheduled. With the label on the namespace, all seven were refused by the API server, before a node was ever chosen. The refusal names the technique:

```text
pods "a2-hostpath" is forbidden: violates PodSecurity "restricted:latest": ...
restricted volume types (volume "host" uses restricted volume type "hostPath"), ...
```

Two notes on the "No controls" column:

- A6: the `mount` refusal with `SYS_ADMIN` present is, in my reading, the container runtime's default AppArmor profile (`cri-containerd.apparmor.d (enforce)` was the profile of the process). I did not confirm that from the node's audit log.
- A5 is the one that does not go through Kubernetes at all. Whoever holds the containerd socket talks to the runtime directly; Pod Security can only stop the pod that mounts it.

**What is left inside a pod that `restricted` admits** ([`04-restricted-pod.yaml`](../manifests/phase7-attacks/04-restricted-pod.yaml)): uid 65534, effective and bounding capability sets empty, `NoNewPrivs: 1`, seccomp filter active, 5 processes visible (its own), kernel paths read-only, no node disk in `/dev`, no containerd socket, no ServiceAccount token, `/etc/shadow` not readable.

## 7c. Scenario B: moving sideways from a compromised pod

A pod with network tools tries every direction. Pod Security changes the pod, so there are three columns: without the middle one, the effect of Pod Security and of the network policy could not be told apart.

| # | Target | 1: root pod, no policy | 2: `restricted` pod, no policy | 3: `restricted` pod, default-deny |
| --- | --- | --- | --- | --- |
| B1 | `redis` (jobs), `oracle` (foothold), `backend` and `db` (demo) | no connection | no connection | no connection |
| B1 | `foothold-api` (foothold) | **open** | **open** | no connection |
| B2 | kubelet `:10250`, 6 nodes | 6/6 answer, HTTP 401 | 6/6 answer, HTTP 401 | 6/6 no connection |
| B3 | API server, no token | HTTP 401 | HTTP 401 | no connection |
| B4 | node sshd `:22` | 6/6 open | 6/6 open | 6/6 no connection |
| B5 | hypervisor web UI and sshd, 3 hosts | 3/3 open | 3/3 open | 3/3 no connection |
| B5 | home router `:80` | open | open | no connection |
| B5 | home router `:443` | no connection | no connection | no connection |
| B6 | internet (`1.1.1.1:443`) | open | open | no connection |
| C4 | cloud metadata address | no connection | no connection | no connection |

- **Columns 1 and 2 are identical.** Pod Security `restricted` changes nothing on the network. A non-root pod with every capability dropped reaches the hypervisor's login page exactly as a root pod does.
- **The difference between 2 and 3 is Cilium alone** ([`06-policies.yaml`](../manifests/phase7-attacks/06-policies.yaml): default-deny plus DNS). Hubble, from the moment the policy existed: the only forwarded flows from the namespace went to CoreDNS; 66 flows were dropped, all `EGRESS DENIED`.
- Three rows prove nothing about the new policy, because they say "no connection" in every column: the four services already protected by their own ingress rules, the router's port 443, and the metadata address (nothing listens there on a home network).
- In B2 and B3 the kubelet and the API server were *reachable* before the policy and refused the request themselves (401). That is the Phase 5 hardening working, and the network policy adds a layer in front of it.

### Finding 1: the Foothold API accepted connections from any pod

In column 1 and 2, `foothold-api` was open from a pod in a different namespace. Phase 6 reported "attacker → API: BLOCK". Both are true: the two senders tested in Phase 6 were stopped by *their own* egress policies. The API's own ingress rule allows port 8080 with no `from`:

```text
$ kubectl -n foothold get networkpolicy api -o jsonpath='{.spec.ingress}'
[{"ports":[{"port":8080,"protocol":"TCP"}]}]
```

So any pod in a namespace without an egress policy reaches the API. The database behind it is not affected (Oracle accepts only the API). Status: **open**. The fix is a `from` restriction in the Foothold repo's `api` NetworkPolicy; a correction note was added under the Phase 6 table in [doc 8](08-real-workload.md). The lesson is about the test, not only the policy: a BLOCK has to be tried from a sender that nothing else is holding back.

### Finding 2: a pod could reach the home network

Rows B4 and B5. From a pod in a namespace with no network policy, the sshd of every node, the web UI and sshd of all three hypervisor hosts, and the home router's admin page were one TCP connection away. Nothing was attacked beyond the connection test, but this is the path from "one compromised container" to "the machines the cluster runs on".

Status: **closed for `attack-lab`** (column 3), **open elsewhere**. `demo`, `foothold` and `jobs` have their own default-deny. `default`, `keda`, `falco` and `kube-system` have no network policy, so a pod created there still gets column 1. Closing it for the whole cluster needs a cluster-wide default with exceptions for the system namespaces; on a cluster I can only reach remotely that deserves its own plan, and it is listed in [Next steps](../README.md#next-steps).

One detail that matters for any future egress rule: Cilium labels the hypervisor hosts and the router as `world`, the same identity as the internet. A rule that allows `0.0.0.0/0` "for internet access" allows the home network too. Egress rules should name FQDNs or exclude the LAN range.

## 7d. Scenario C: stolen credentials

**Before, with no controls.** The pod had a ServiceAccount token (C1). With the `default` ServiceAccount's token every request to the API was answered 403: RBAC already stops C2, because that account has no rights. With an over-privileged account ([`03-overprivileged-sa.yaml`](../manifests/phase7-attacks/03-overprivileged-sa.yaml): a Role that may read Secrets) the token read a (fake) Secret in its own namespace and got 403 everywhere else (C3).

**After.** Since 7c the API server cannot be reached from `attack-lab`, so every token test would say "no connection" and hide the other layers. The layers were therefore switched one at a time. The pod was `restricted`-compliant in all four rounds ([`07-token-layers.yaml`](../manifests/phase7-attacks/07-token-layers.yaml)); [`08-allow-apiserver.yaml`](../manifests/phase7-attacks/08-allow-apiserver.yaml) is a test aid that reopens the path to the API server, not a recommended policy.

| Round | Path to API server | Token mounted | RoleBinding | Read the fake Secret | Stopped by |
| --- | --- | --- | --- | --- | --- |
| 1 | closed | yes | yes | no connection | Cilium |
| 2 | open | yes | yes | **HTTP 200, read** | nothing (control round) |
| 3 | open | **no** | yes | HTTP 401 | `automountServiceAccountToken: false` |
| 4 | open | yes | **deleted** | HTTP 403 | RBAC |

- Round 2 is the control: with only the network reopened, the attack works again. So Cilium stopped round 1, and Pod Security does nothing against a stolen token.
- Round 3: nothing is mounted, so there is nothing to steal.
- Round 4: the token is still recognised (403, not 401) but worth nothing.
- In round 2 the same token got 403 for Secrets in `jobs` and `kube-system`. A Role instead of a ClusterRole kept the damage inside one namespace.

**C5: reading `/etc/shadow` inside the container, and what the runtime tools saw.**

| Pod | Tetragon rule in the namespace | Result | Stopped by |
| --- | --- | --- | --- |
| root | none | 29 lines read | nothing |
| uid 1000 (`restricted`) | none | `Permission denied` | file permissions (Pod Security forces non-root) |
| root | [`09-tetragon-shadow.yaml`](../manifests/phase7-attacks/09-tetragon-shadow.yaml) | `Killed`, exit code 137, 0 lines | Tetragon |

The last row needed a root pod, so the namespace was lowered to `baseline` for that one round and set back to `restricted` afterwards (verified: the same root pod is refused again). The result is consistent with [Phase 3](05-runtime-security.md), where the same rule was measured in `demo`; it is not a new finding. What Phase 7 adds is the first row: the Phase 3 rule is namespaced, and outside `demo` it does nothing.

During the "before" run, Tetragon recorded 65 process executions of the compromised pod with their arguments, and Falco raised one kind of alert 18 times (`Unexpected connection to K8s API Server from container`). Both saw the attack; neither stopped anything, and neither is configured to.

## 7e. Which control stops what

| Attempt | Pod Security `restricted` | Cilium default-deny | No token / RBAC | Tetragon |
| --- | --- | --- | --- | --- |
| A: privileged, host mounts, host namespaces, capabilities | **stops** (7/7 refused) | not tested | not tested | not tested |
| B: other namespaces, nodes, hypervisor, router, internet | no effect (columns 1 = 2) | **stops** | not tested | not tested |
| C2, C3: API calls with a stolen token | no effect (round 2) | **stops** from this namespace (round 1) | **stops** (rounds 3, 4) | not tested |
| C5: `/etc/shadow` in the container | **stops** for non-root | not tested | not tested | **stops** for root |

"Not tested" means the combination was not run, not that the control would fail. The table's point is the "no effect" cells: no single control covers two columns of attack, and the label on the namespace that stops every breakout does nothing about the network.

## 7f. Mistakes in my own tests

1. **`test -w` as root is not evidence.** It reported a kernel path as writable while the same output showed it mounted read-only. All such lines were discarded; A7 uses the mount flags instead.
2. **A count that was an error message.** The first containerd-socket run printed "1 container"; it was one line of error, because a symlink did not resolve inside the pod.
3. **A failure that was my test.** The first `mount` attempt failed because the target directory did not exist in the image, not because anything blocked it.
4. **A Hubble window that reached back too far.** The first query after the policy showed forwarded traffic to the internet; it was traffic from before the policy. Fixed by starting the window at the policy's creation time.

Same lesson as #15 in the README, from both sides: a failure has to be read before it counts as a BLOCK, and a success has to be read before it counts as a breach.

## 7g. Reproduce

On the control-plane node, from the repository root. The breakout pods really run if the namespace has no label; read the manifests first and use a cluster you own.

```bash
kubectl apply -f manifests/phase7-attacks/00-namespace.yaml
./scripts/attack-test.sh                # before: dry run of the breakout pods, network, token
kubectl label ns attack-lab pod-security.kubernetes.io/enforce=restricted
./scripts/attack-test.sh admission      # 7 x REFUSED
kubectl apply -f manifests/phase7-attacks/06-policies.yaml
./scripts/attack-test.sh network token  # everything "no connection"
kubectl delete ns attack-lab
```

The `admission` mode is a server-side dry run: it asks the API server whether each pod would be admitted and creates nothing. The numbers in 7b come from pods that actually ran, one at a time, with the checks in 7a.

The script itself was run once, at the end, against the namespace with Pod Security and default-deny both in place (the last two script lines above, in one call):

```text
== Scenario A: breakout pods, server-side dry run (namespace attack-lab)
a0 ... a6          REFUSED            (7 of 7)
== Scenario B: what a compromised pod can reach (namespace attack-lab)
22 targets                            no connection   (22 of 22)
== Scenario C: what a stolen ServiceAccount token is worth (namespace attack-lab)
-- pwned-token     token file: present     4 requests: no connection
-- pwned-notoken   token file: absent      4 requests: no connection
left in attack-lab: 0 pods/secrets/roles/rolebindings
```

That is a summary of its output, not a copy; two targets outside the cluster were passed in `LAN_TARGETS`. The script was not run against the namespace in its earlier states (no controls, Pod Security only); those columns come from the step-by-step runs.

The script in this repository differs from the one that ran in one thing: the column width in three `printf` lines, widened afterwards so long service names line up. That version, and a later one that takes the node name from `NODE` (the manifests now say `worker-5`, a placeholder), ran again during the [security audit](11-security-audit.md) on a fresh `attack-lab` with the same two controls: 7 of 7 refused, 22 of 22 no connection, every token request no connection; namespace deleted, worker unchanged.

## 7h. Not measured

- **A7:** an actual write to a kernel path. The evidence is the mount flag (writable in the privileged pod), nothing more.
- **A6:** loading a kernel module with `SYS_MODULE`; using `SYS_PTRACE` together with `hostPID`; the AppArmor explanation for the refused `mount`.
- **A, after:** a pod that is compliant except for one technique. Each breakout pod also broke the four general rules, so "this rule alone refuses it" is read from the refusal message.
- **A, cleanup:** the node check compares counts and one checksum, not a full file-system diff.
- **B1:** the four "no connection" services in columns 1 and 2 were not confirmed in Hubble as policy drops.
- **7c, Hubble:** three `INGRESS DENIED` lines seen in the first seconds after the policy was created were not identified.
- **C:** creating or changing objects with a token (all requests were reads); a token used from outside the cluster or from another namespace; token expiry.
- **C5:** whether the Tetragon rule also stops other ways to the same file (a copy, a hard link); why two `cat` runs produced six kprobe events; whether a default Falco rule should have fired for the port scan or the file read.
- **C4:** repeated only up to 7c; it was "no connection" in every column.
- **Finding 2 outside `attack-lab`:** that a pod in `default` reaches the home network today follows from "no policy there"; it was measured in `attack-lab` before its policy, not in `default`.

## 7i. Cleanup

Every pod was deleted right after its proof, and the node compared with the baseline each time. The fake Secret, ServiceAccount, Role, RoleBinding, the test-aid policy and the Tetragon rule were deleted at the end of their rounds, and the `attack-lab` namespace after the last test; the worker matched its baseline once more after that. The only Tetragon policy in the cluster is again the Phase 3 one in `demo`.
