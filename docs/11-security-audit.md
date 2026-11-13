# 11. Security audit before publishing

[← Back to README](../README.md)

Before this repository and [k8s-agent-sandbox](https://github.com/miracaral/k8s-agent-sandbox) were published, I went through both with one question: what can someone do with them, and with the cluster they describe? This page holds the threat model, the self-attack results, the repository scan, and what was changed because of it. As everywhere else: only what was run is written down; the rest is marked.

## 11a. Threat model

**What is protected**

| Asset | Why it matters |
| --- | --- |
| The home network: hypervisor hosts, router, other devices | the cluster runs inside it; a pod that reaches it can reach machines that are not hardened like the cluster |
| The cluster: nodes, API server, Secrets | full control of every workload |
| Remote access (Tailscale, WireGuard) | the only way in from outside; also a way in for anyone who learns enough about it |
| Credentials: the Gemini API key, Redis passwords, the K3s join token | cost money or give access |
| The published repositories | anything in them, including their history, is public for good |

**Who the attacker is**

1. **A compromised pod**: an application with a flaw, or a malicious image (Phase 7).
2. **An AI agent that follows instructions it found in a file** (Phase 8): the same as 1, except the "attacker" is text in a repository or web page.
3. **A reader of these repositories**: anyone who learns addresses, host names, the remote-access layout or a leaked secret from them.

**Out of scope**: someone with physical access to the hardware; a compromise of Tailscale, GitHub or Google; a flaw in the Linux kernel or container runtime itself (Phase 7 tested configuration, not kernel exploits).

## 11b. Self-attack: an injected agent

Each row was measured in an earlier phase; the link says where. No new measurement was made for this table.

| Attempt | Before | After | Stopped by | Evidence |
| --- | --- | --- | --- | --- |
| Steal the Kubernetes ServiceAccount token | Phase 7: a token is mounted by default and read a Secret where its role allowed it | no token in task pods | `automountServiceAccountToken: false` | [doc 10, 8c](10-ai-agents.md#8c-before-and-after-what-a-stolen-credential-is-worth) |
| Leak the model API key into the stored result | not measured | `GEMINI_API_KEY=[REDACTED]` | key masking in the runner | [8e](10-ai-agents.md#8e-prompt-injection), "if the model had obeyed" |
| Send the key or data to another host | Phase 7: a pod without policy reaches the internet | `example.com`, `www.google.com`, `1.1.1.1` dropped (`EGRESS DENIED`) | Cilium egress by name | [8b](10-ai-agents.md#8b-before-and-after-what-a-pod-in-this-namespace-can-reach) |
| Send data through the allowed host (the Gemini API) | — | **possible**: the agent can put anything it reads into a prompt | nothing | not measured; listed below |
| Send data through GitHub | — | the task pod cannot reach GitHub; it cannot queue a fetch (no Redis password) | Cilium; credentials split across containers | 8b; [k8s-agent-sandbox threat model](https://github.com/miracaral/k8s-agent-sandbox/blob/main/docs/threat-model.md) |
| Send data through DNS | — | **possible**: any name may be looked up | nothing | observed in Hubble, not closed; listed below |
| Add a task to the Redis queue | not measured | `-NOAUTH` from the agent container; the runner's own user gets `NOPERM` for `RPUSH` | no password in the agent container; Redis ACL | 8c, 8e |
| Read Secrets with the ops agent | not measured | `403` for Secrets and ConfigMaps, in every namespace | RBAC | k8s-agent-sandbox, step 3b |
| Cross into another namespace | Phase 7: `foothold-api` open from a pod in another namespace (finding 1) | task pod: Redis in `jobs` no connection; ops agent: platform Redis no connection | Cilium in both namespaces | 8b |
| Reach the nodes, hypervisors, router | Phase 7: open on 6/6 nodes, 3/3 hypervisors, router | no connection (dummy task pod, same namespace) | Cilium default-deny | 8b ¹ |
| Break out of the container | Phase 7: privileged, hostPath, hostPID, hostNetwork, socket, capabilities all admitted without a label | `restricted` on `agents` and `agents-ops`: a root pod is refused | Pod Security | [doc 9, 7b](09-attack-scenarios.md#7b-scenario-a-breaking-out-of-the-container) |

## 11c. Exposure (standing rule: nothing is reachable from outside)

Measured on 2026-11-13: in `agents`, `agents-ops` and `jobs`, 0 services that are not ClusterIP, 0 external IPs, 0 Ingress objects, 0 pods with hostNetwork, 0 hostPorts. Cluster-wide: 0 Ingress objects, no service of type NodePort or LoadBalancer. No `kubectl port-forward` process on the control-plane node, the five workers or my machine (counted by process name). `labctl` reaches the cluster only by `ssh` to the control-plane node.

**Phase 7 script rerun** (`scripts/attack-test.sh` as committed, `NODE` set to the real worker, a fresh `attack-lab` with Pod Security `restricted` and default-deny): 7 of 7 breakout pods refused, 22 of 22 network targets no connection, all token requests no connection, nothing left behind; namespace deleted afterwards, the worker's container, mount and module counts unchanged.

**`jobs` Redis password rotated**: the password created in Phase 4 with `--from-literal` (visible in process arguments) was replaced by one created in memory. After restarting Redis and the worker, `scripts/jobs-test.sh`: no password `NOAUTH`, wrong password `WRONGPASS`, the new one `PONG`, not in the process arguments, KEDA and the worker drained 5 jobs. KEDA logged one `WRONGPASS` in the minute between the new Secret and the restart.

## 11d. Repository scan

| Check | homelab-k8s-security | k8s-agent-sandbox |
| --- | --- | --- |
| gitleaks 8.30.1, every file | 0 findings | 0 findings |
| gitleaks 8.30.1, full history (all branches) | 0 findings | 0 findings |
| LAN addresses, WireGuard addresses, node and hypervisor names in the files | 164 occurrences replaced by placeholders | 14 replaced |
| Same, in the history | **present** in commits already public and in local ones; see 11e | present in local commits (not pushed) |
| Python bytecode committed by mistake | — | removed from the whole history |
| Screenshots | 3 of 6 show node names or a shell prompt with user and host name; see 11e | none |

Placeholders used: `<LAN>.N` for the home subnet, `<WG>.N` for the WireGuard subnet, `cp-1` for the control-plane node, `worker-1` to `worker-5`, `hv-1` to `hv-3` for the hypervisor hosts. Scripts that need an address now take it from a variable (`LAN`, `GW`, `HUB`) and stop if it is not set.

## 11e. Not fixed by the audit (decisions for the owner)

- **History**: the addresses and names replaced above are still in older commits, two of which are already public on GitHub.
- **Screenshots**: `keda-10-workers.png` (node names), `pod-security-baseline.png` and `token-removed-and-policy-test.png` (shell prompt with user and host name).

## 11f. Not measured

- Data sent out through the Gemini API itself or through DNS: possible by design, not tried.
- A model that actually obeys an injection; the "obeyed" case was a script.
- A crash of the node that holds Redis.
- Why Hubble did not show some refused attempts of a fetcher-labelled test pod; why Tetragon's probes missed actions in a container's first moment.
