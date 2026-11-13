# Phase 8: AI agents

The manifests for this phase live in their own repository, [k8s-agent-sandbox](https://github.com/miracaral/k8s-agent-sandbox),
so the platform can be used without this homelab. Version 1 was deployed on this cluster from that repository's `manifests/`
in numeric order, with these homelab-specific choices:

| Choice | Why |
| --- | --- |
| Gemini runner and fetcher pinned to one worker by node affinity | no image registry before the security audit; images were loaded onto that worker directly |
| Images streamed from the control-plane node to the worker through the hypervisor on the local network | copies through the remote-access tunnel stalled (see the build log) |
| `labctl` run from my own machine over SSH to the control-plane node | standing rule: nothing is exposed; there is no Ingress, NodePort or port-forward |

Nothing in this directory is applied by hand. See [docs/10-ai-agents.md](../../docs/10-ai-agents.md) for what was tested.
