# Plan

Working plan for the phases after Phase 6. Details and real output are in [BUILD_LOG.md](BUILD_LOG.md).

## Order

| Step | Repo | What | Output |
| --- | --- | --- | --- |
| 1 | homelab-k8s-security | Lock down the `jobs` namespace: Redis password, network policies, Pod Security `restricted` | `manifests/phase4b-jobs-lockdown/`, follow-up section in docs/06 |
| 2 | homelab-k8s-security | Phase 7: attack scenarios (container breakout, lateral movement) against the existing controls, before/after | `docs/09-attack-scenarios.md`, `manifests/phase7-attacks/`, README row |
| 3 | k8s-agent-sandbox (new) | The agent platform: `labctl`, runner images (Claude + Gemini), read-only ops agent, task format, audit log, budget and on/off controls, `labctl-manual.md`, its own README | new repo |
| 4 | homelab-k8s-security | Phase 8: deploy the platform under this cluster's controls and test it (egress, Tetragon logs, prompt injection), before/after | `docs/10-ai-agents.md`, `manifests/phase8-ai-agents/`, README row, link to repo B |
| 5 | both | Cross-check add-on: `labctl review <task-id> --with gemini` | after Step 4 |
| 6 | both | Security audit before publishing (standing rule 2) | threat model, self-attack results, repo scan, known limitations |

## Design fixes that Step 3 must include

1. GitHub is reachable only from an init container that has no token; the agent container has no GitHub access.
2. The docs say plainly that the OAuth token is visible in the agent's environment; the egress policy limits where it can go, it does not hide it.
3. The daily limit is enforced by `labctl` counting when it queues a task (task pods have no ServiceAccount token, so they cannot pause anything).
4. The ops agent can read logs only from a fixed list of namespaces.
5. `toFQDNs` rules come with the DNS rule they need, and Claude Code telemetry is switched off.

## Standing rules

1. **Nothing is exposed outside the cluster.** No Ingress, NodePort, LoadBalancer or port-forward for agents, Redis, `labctl` or the ops agent. `labctl` runs only from my machine over SSH (Tailscale/WireGuard). Proven with `scripts/exposure-check.sh`.
2. **Security audit before publishing**, for both repos: threat model, attacking it myself, repo scan (gitleaks over files and history), every finding fixed or listed as a known limitation. Nothing is pushed before this is done, and not without asking.
3. Every change to the cluster is shown first and applied only after an OK.
4. No token, key or password is printed, logged or committed. Secrets are created by hand.
5. Nothing is deleted without asking.
6. Only results that were actually run and seen are documented.

## Working rules from 2026-11-12 (replace the "ask before every cluster change" rule for Step 3 onward)

**Do without asking, summarise afterwards:**

- In the `agents` and `agents-ops` namespaces: apply manifests, run test pods, delete temporary resources I created myself
- Build images and load them onto the workers
- Write files, update docs and commit locally in repo A and repo B
- Read commands, tests, reading Hubble and Tetragon records
- Move from one sub-step of the approved plan to the next

**Stop and ask:**

- Any change that widens a security setting: Redis ACL, RBAC, network policy, Pod Security label, a new egress host
- Touching any namespace other than `agents` / `agents-ops` (including `foothold`, `jobs`, `demo`, `kube-system`, `keda`) or any node
- Deleting or changing anything I did not create, including files of older projects
- Anything that needs a Secret, token or API key (the owner creates Secrets; values are never read or printed)
- Any pod that is privileged, runs as root, uses hostPath/hostPID or loosens `restricted`
- The first run that makes a real model call (quota/money), and raising the daily limit
- `git push`, creating a remote repository, anything that exposes something (Ingress, NodePort, port-forward)
- Anything not in the plan, or a design decision I am not sure about

**Deleting files (2026-11-13):** `rm -rf` is never used with a variable that could be empty; only `"${VAR:?}"/...` or a literal path.

**Unchanged:** write nothing that was not measured; report my own mistakes openly; update BUILD_LOG and `labctl-manual.md` in every step; no push.

## Status

- [x] 1a discovery
- [x] 1b before-evidence
- [x] 1c Redis password
- [x] 1d network policies
- [x] 1e Pod Security `restricted`
- [x] 1f run `scripts/jobs-test.sh`, write the docs/06 follow-up, update the README, clean up the temporary pods
- [x] Step 1 committed locally (branch `pre-publish`, 28477a4), not pushed
- [x] 2a scenario A (breakout) before-runs on worker-5, all cleaned up
- [x] 2a scenarios B and C before-runs, `attack-lab` emptied
- [ ] Open question (decided 2026-11-11: note now, fix later): in the Foothold repo, add a `from` restriction to the `api` NetworkPolicy. Today it accepts ingress on 8080 from any pod in the cluster. Do not change Foothold during Step 2; write it up as a finding in the Phase 7 doc (docs/09)
- [x] 2b Pod Security `restricted` on `attack-lab`: 7/7 breakout pods refused
- [x] 2c Cilium default-deny on `attack-lab`: every path to nodes, Proxmox, router, internet dropped (Hubble: 66 EGRESS DENIED, only DNS forwarded)
- [x] 2d token/RBAC/Tetragon, layer by layer: network closed -> no connection; network open -> fake Secret read (control); no token -> 401; no RoleBinding -> 403; `/etc/shadow` as uid 1000 denied, as root killed by Tetragon (consistent with Phase 3)
- [x] 2e `scripts/attack-test.sh` (run once), `docs/09-attack-scenarios.md`, README rows, `attack-lab` deleted, worker-5 at baseline. Step 2 done
- [x] Final audit (done 2026-11-13, placeholders): LAN addresses (<LAN>.x) are already in published docs and scripts; decide there
- [x] Final audit: rotate the `jobs` Redis password (Step 1's suggested `--from-literal` command put it into kubectl's process arguments; not found in the kept Tetragon log, but that is not proof) and change the comment in `manifests/phase4b-jobs-lockdown/00-queue-secured.yaml` to the `--from-file` form
- [x] Final audit (done, history rewritten): repo B history contained `__pycache__/labctl*.pyc` (commits c5484e5, 02433c7; no secret); decide whether to rewrite history before the first push
- [x] Final audit (done, placeholders): repo B contained node names (`cp-1`, `worker-1`) in `labctl`'s default SSH host, the manual, the node affinity of two manifests and several tests; replace with placeholders or settings before publishing
- [x] Final audit: run `scripts/attack-test.sh` on the cluster again. The committed version differs from the one that ran (2e) by the `printf` column width only and has not been run since; needs a temporary `attack-lab` namespace, deleted afterwards
- [ ] Open question from 2c: namespaces without any network policy (`default`, `keda`, `falco`, `kube-system`) still reach the home network. Consider a cluster-wide default-deny with exceptions; risky on a remote-only cluster, plan separately
- [x] Note for Step 3/4: Cilium sees the LAN (Proxmox, router) as `world`. Done: agent egress uses FQDN rules only; no rule allows 0.0.0.0/0
- [ ] Open question from 2b: `default` namespace has no Pod Security label; decide whether to label it
- [x] Step 2 committed locally (branch `pre-publish`, fd7081c), not pushed
- [x] Step 3, version 1 (sub-steps below; 3g, 3i, 3k are version 2)
- [x] Step 4: `docs/10-ai-agents.md`, `manifests/phase8-ai-agents/`, README rows, link to repo B (commit c08b5b5)
- [x] Step 5 (`labctl review --with gemini`): version 2 (owner, 2026-11-13)
- [x] Step 6: final audit (checklist below); push only on the owner's word

## Scope change (2026-11-13): v1 first

Order for a publishable v1: 3e -> 3f -> 3h (Tetragon + prompt injection, with the Gemini runner) -> 3j -> Step 4 -> final audit. 3g, 3i and 3k are v2; README keeps them as "planned". The Claude Redis user and the `claude` key in `redis-runners` stay prepared but unused in v1.

## Step 3 sub-steps (repo `k8s-agent-sandbox`, local at `~/Documents/k8s-agent-sandbox`, no remote yet)

Decisions (2026-11-12): fetcher is a separate pod, because a network policy applies to a pod and not to a container (this is how design fix 1 is met); images are built on the Mac for linux/amd64 and imported into chosen workers with `k3s ctr images import` until the audit allows a registry; repo is local only until the audit.

- [x] 3a skeleton, README draft, `labctl --help`, namespaces, default-deny + DNS applied (exposure check 0, root pod refused; policies not yet tested with a pod)
- [x] 3b ops agent without a model: image on 5 workers, RBAC and network tested (5 works / 4 denied / 8 no / 16 no connection, Hubble 32 EGRESS DENIED), `labctl ops health` works (fix 4). Repo B not committed yet
- [x] 3c first half: Redis with per-role users on a persistent volume, tested; `labctl audit`
- [x] 3c second half: `labctl agents on|off|kill|status` tested with a dummy task pod and KEDA (pause annotation works on KEDA 2.21.0; one pod at a time; kill 14 s; queue survives)
- [x] 3d limits ConfigMap (10 / 900 s / 1 per runner), atomic daily counter, tripwire (request past the limit switches agents off), `labctl budget`; 18/18 tests, timeout enforced at 30 s on the dummy (fix 3)
- [x] 3e requirement (owner, 2026-11-12), done: one Redis user per runner, each able to read only its own queue (`queue:gemini`, `queue:claude`); today's `runner` user has `queue:*`, which is too wide
- [x] 3e task format, Gemini runner, `labctl run gemini`, `labctl result`, egress test (fix 5; FQDN rules only, never 0.0.0.0/0)
- [x] 3e (without a model): per-runner Redis users, Gemini runner (take/agent/report) on worker-1/2, egress by name, `labctl run/result`; dry-run test all passed. First real answer 2026-11-13 with `gemini-4-hydrogen` (after `gemini-2.5-flash` was refused as unavailable to new users)
- [ ] Question for later: DNS lookups (any name, also forwarded with `.lan` to the router) are a way out; closing it touches CoreDNS / `kube-system`
- [x] 3f fetcher pod for `--repo` (fix 1): fetcher reaches github.com only, agent pod cannot; real task on fastapi-todo-api answered
- [x] Redis restart bug fixed: snapshots (`appendonly no`, `save 60 1`), counter and queue verified across a config change and a pod restart; up to 60 s can be lost on a node crash (threat model)
- [ ] Open question: in the 3f check, refused attempts of the fetcher-labelled pod did not show as EGRESS DENIED in Hubble (the agent-labelled pod's did). Find out why before the audit relies on Hubble counts
- [ ] Note: images are loaded through hv-1 (`ssh hv-1 "ssh cp-1 'cat <tar>' | ssh worker-N 'sudo -n k3s ctr images import -'"`); copies through the tunnel stall (MTU suspected, not investigated). Gemini runner and fetcher run on worker-1 only; worker-2 later

## Where we are (2026-11-13)

Version 1 is built and documented in both repos, committed locally, nothing pushed. Platform OFF. Next: the final audit (Step 6). No push before it is finished, and not without asking.

## Final audit checklist (Step 6, standing rule 2)

**A. Threat model and self-attack** (before/after, measured only)

- [x] A1 Threat model for both repos: repo B `docs/threat-model.md` exists; repo A has none. Write repo A's (cluster, remote access, published docs)
- [x] A2 Self-attack with an injected agent, one row each: token/key leak; exfiltration through an allowed host (the Gemini API, GitHub through the fetcher); Redis task injection; ops agent reading Secrets; crossing namespaces. Much is measured already (3c to 3h, Phase 8); list what is new, ask before any new measurement or model call
- [x] A3 Exposure: rerun `tests/exposure-check.sh` (repo B) and `scripts/exposure-check.sh` (repo A) and the standing-rule-1 proof (nothing reachable from outside; `labctl` only over SSH)
- [x] A4 Rerun `scripts/attack-test.sh` (committed version never ran; needs a temporary `attack-lab`, deleted afterwards)
- [x] A5 (documented in docs/11, 11f; not resolved) Resolve or document: Hubble not showing some refused attempts of the fetcher-labelled pod; Tetragon probes missing a container's first moment

**B. Repository scan** (both repos, every file and the full history)

- [x] B1 gitleaks (or equivalent) over files and history; not installed on the Mac yet: ask before installing anything
- [x] B2 Tokens, passwords, private keys, kubeconfig: so far 0 in my own scans; confirm with the tool
- [x] B3 LAN addresses (`<LAN>.x`): already in repo A's published docs and scripts; decide: replace, or list as a known limitation
- [x] B4 Host names: node names in repo B (`labctl` default host, manual, node affinity, tests); `cp-1` / `hv-1` style names in repo A
- [x] B5 Tailscale/WireGuard details in repo A doc 2 (remote access): check for addresses, keys, node names
- [x] B6 Repo B history: `__pycache__/*.pyc` in two commits (no secret); decide whether to rewrite history before the first push
- [x] B7 (owner: screenshots stay as they are) Screenshots in `images/`: check for addresses and host names (one was blurred earlier)

**C. Fix or list as a known limitation** (README of each repo)

- [x] C1 Rotate the `jobs` Redis password and change the comment in `00-queue-secured.yaml` to the `--from-file` form
- [x] C2 Foothold `api` policy without `from` (finding 1): fix in the Foothold repo, or list
- [x] C3 Namespaces without a network policy reach the home network (finding 2), `default` without a Pod Security label: fix or list
- [x] C4 DNS as a way out from task pods: list (closing it touches CoreDNS)
- [x] C5 Every finding above ends either fixed or in a "Known limitations" section of the README

**D. Before any push**

- [ ] D1 Branch state: repo A `pre-publish` (main still equal to origin), repo B `main`, no remote
- [ ] D2 Ask the owner before every push; repo B's remote is created by the owner

