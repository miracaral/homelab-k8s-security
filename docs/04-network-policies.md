# 4. Phase 2: security zones with Cilium network policies

[← Back to README](../README.md)

**Result:** six CiliumNetworkPolicies took the demo app from 7/7 paths open to only the 2 intended paths open. The attacker pod reaches nothing, and the API accepts only `GET /get` at L7.

## Demo app

[`manifests/phase2-network-policies/00-app.yaml`](../manifests/phase2-network-policies/00-app.yaml)

| Workload | Image | Zone label | Port |
| --- | --- | --- | --- |
| frontend | nicolaka/netshoot | `tier=web` | — |
| backend | mccutchen/go-httpbin + netshoot sidecar | `tier=api` | 8080 |
| db | redis:7-alpine | `tier=data` | 6379 |
| attacker | nicolaka/netshoot | none | — |

The backend has a second `shell` container so I can test traffic that originates from the backend's own identity.

## Policies

[`manifests/phase2-network-policies/01-policies.yaml`](../manifests/phase2-network-policies/01-policies.yaml)

| Policy | Effect |
| --- | --- |
| `default-deny` | Every pod in `demo` denied in both directions |
| `allow-dns` | Egress to kube-dns on port 53 only, with a DNS rule (gives DNS visibility in Hubble) |
| `frontend-to-backend` | Web zone → API zone on TCP 8080 |
| `backend-ingress-l7` | API zone accepts only `GET /get` from the web zone, enforced by Envoy |
| `backend-to-db` | API zone → data zone on TCP 6379 |
| `db-ingress` | Data zone accepts only the API zone |

`default-deny` uses `ingress: [{}]` and `egress: [{}]`: an empty rule selects nothing, which switches the pods into default-deny mode in both directions.

The L7 rule:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: backend-ingress-l7, namespace: demo}
spec:
  endpointSelector: {matchLabels: {app: backend}}
  ingress:
  - fromEndpoints: [{matchLabels: {app: frontend}}]
    toPorts:
    - ports: [{port: "8080", protocol: TCP}]
      rules:
        http:
        - method: GET
          path: "/get"
```

## Testing

[`scripts/policy-test.sh`](../scripts/policy-test.sh) runs each path from inside the pods and prints ALLOW or BLOCK.

```bash
kubectl apply -f manifests/phase2-network-policies/00-app.yaml
kubectl -n demo wait --for=condition=Available deploy --all --timeout=180s
./scripts/policy-test.sh          # baseline
kubectl apply -f manifests/phase2-network-policies/01-policies.yaml
./scripts/policy-test.sh          # with policies
```

| Path | No policies | With policies |
| --- | --- | --- |
| frontend → backend `GET /get` | ALLOW | ALLOW |
| frontend → backend `POST /post` | ALLOW | **BLOCK (L7)** |
| frontend → db :6379 | ALLOW | **BLOCK** |
| backend → db :6379 | ALLOW | ALLOW |
| attacker → backend `GET /get` | ALLOW | **BLOCK** |
| attacker → db :6379 | ALLOW | **BLOCK** |
| frontend → internet | ALLOW | **BLOCK** |

## L7 block vs L3 drop

The two kinds of BLOCK look different from inside the pod, and the difference shows where the decision is made:

```bash
# allowed peer, forbidden method → Envoy answers
kubectl -n demo exec deploy/frontend -- curl -s -X POST http://backend:8080/post
Access denied

# forbidden peer → dropped by eBPF in the kernel, no connection at all
kubectl -n demo exec deploy/attacker -- curl -s -m 4 -o /dev/null -w "%{http_code}\n" http://backend:8080/get
000
command terminated with exit code 28
```

The frontend gets a TCP connection and a 403 from the proxy, because the policy has to read the request. The attacker gets nothing: the packet never leaves the kernel datapath.
