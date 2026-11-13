#!/bin/bash
# Phase 7: repeat the attack scenarios against the "attack-lab" namespace in whatever state it is in
# (no controls, Pod Security, network policies), so the same script gives the "before" and the "after".
# Run on the control-plane node, from the repository root.   Usage: attack-test.sh [admission|network|token] ...
#   admission  server-side dry run of the seven breakout pods: nothing is created, nothing runs on a node
#   network    one compliant pod on the lab worker, connection attempts, pod deleted
#   token      fake Secret + over-privileged ServiceAccount + two pods (token mounted / not mounted), all deleted
# Required: NODE=<worker name>. Optional: LAN_TARGETS="host:port host:port" adds targets outside the cluster (hypervisor, router) to "network".
#           NO_ROLEBINDING=1 removes the RoleBinding before the "token" requests.
# Proofs only read. The token is never printed and never appears in a process argument.
K=${KUBECTL:-"sudo k3s kubectl"}
M=${MANIFESTS:-manifests/phase7-attacks}
NS=attack-lab
NODE=${NODE:?set NODE to the worker that may run the test pods (the manifests say worker-5, a placeholder)}
# The manifests pin every pod to "worker-5"; this puts the real node name in their place on the way to the cluster.
pin() { sed "s|kubernetes.io/hostname: worker-5}|kubernetes.io/hostname: $NODE}|"; }

$K get ns $NS >/dev/null 2>&1 || { echo "namespace $NS not found: kubectl apply -f $M/00-namespace.yaml"; exit 1; }

start() {   # wait for a pod and stop if it is not on the lab worker
  $K -n $NS wait --for=condition=Ready pod/$1 --timeout=120s >/dev/null 2>&1 || { echo "pod $1 did not start (refused by admission?)"; return 1; }
  [ "$($K -n $NS get pod $1 -o jsonpath='{.spec.nodeName}')" = "$NODE" ] || { echo "STOP: $1 is not on $NODE"; return 1; }
}

admission() {
  echo "== Scenario A: breakout pods, server-side dry run (namespace $NS)"
  printf "%-18s %s\n" "POD" "RESULT"
  for a in a0 a1 a2 a3 a4 a5 a6; do
    out=$($K apply --dry-run=server -f $M/01-breakout-pods.yaml -l attack=$a 2>&1)
    if echo "$out" | grep -q "is forbidden"; then r="REFUSED"; elif echo "$out" | grep -q "created (server dry run)"; then r="ADMITTED"; else r="ERROR: $out"; fi
    printf "%-18s %s\n" "$a" "$r"
  done
  echo
}

network() {
  echo "== Scenario B: what a compromised pod can reach (namespace $NS)"
  pin < $M/05-compromised-restricted.yaml | $K apply -f - >/dev/null 2>&1
  if start pwned-restricted; then
    NODES=$($K get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}')
    $K -n $NS exec -i pwned-restricted -- sh -s -- "$NODES" "$LAN_TARGETS" <<'EOF'
t() { if nc -z -w 3 $2 $3 >/dev/null 2>&1; then r="open"; else r="no connection"; fi; printf "%-72s %s\n" "$1 $2:$3" "$r"; }
h() { c=$(curl -sk -m 4 -o /dev/null -w '%{http_code}' "$2" 2>/dev/null); [ "$c" = "000" ] && c="no connection" || c="HTTP $c"; printf "%-72s %s\n" "$1" "$c"; }
printf "%-72s %s\n" "TARGET" "RESULT"
t "B1 redis (jobs)" redis.jobs.svc.cluster.local 6379
t "B1 oracle (foothold)" oracle.foothold.svc.cluster.local 1521
t "B1 foothold-api (foothold)" foothold-api.foothold.svc.cluster.local 80
t "B1 backend (demo)" backend.demo.svc.cluster.local 8080
t "B1 db (demo)" db.demo.svc.cluster.local 6379
for n in $1; do h "B2 kubelet $n:10250" https://$n:10250/pods; done
h "B3 API server (no token)" https://kubernetes.default.svc/version
for n in $1; do t "B4 node sshd" $n 22; done
for x in $2; do t "B5 outside the cluster" ${x%:*} ${x#*:}; done
t "B6 internet" 1.1.1.1 443
t "C4 metadata address" 169.254.169.254 80
EOF
  fi
  $K -n $NS delete pod pwned-restricted --now --wait=true >/dev/null 2>&1
  echo
}

token() {
  echo "== Scenario C: what a stolen ServiceAccount token is worth (namespace $NS)"
  sed '/^# The same compromised pod/,$d' $M/03-overprivileged-sa.yaml | pin | $K apply -f - >/dev/null 2>&1
  pin < $M/07-token-layers.yaml | $K apply -f - >/dev/null 2>&1
  [ -n "$NO_ROLEBINDING" ] && $K -n $NS delete rolebinding too-much-reads-secrets >/dev/null 2>&1 && sleep 4
  echo "RoleBinding present: $($K -n $NS get rolebinding too-much-reads-secrets --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  for p in pwned-token pwned-notoken; do
    echo "-- $p"
    start $p || continue
    $K -n $NS exec -i $p -- sh -s <<'EOF'
T=/var/run/secrets/kubernetes.io/serviceaccount/token
if [ -r $T ]; then echo "token file: present"; printf 'Authorization: Bearer %s' "$(cat $T)" > /tmp/h; else echo "token file: absent"; printf 'X-Lab: no-token' > /tmp/h; fi
req() { c=$(curl -sk -m 6 -H @/tmp/h -o /tmp/b -w '%{http_code}' "https://kubernetes.default.svc$2"); [ "$c" = "000" ] && c="no connection" || c="HTTP $c"; printf "%-44s %s\n" "$1" "$c"; }
req "read the fake Secret (attack-lab)" /api/v1/namespaces/attack-lab/secrets/dummy-secret
req "list pods in attack-lab" /api/v1/namespaces/attack-lab/pods
req "list Secrets in jobs" /api/v1/namespaces/jobs/secrets
req "list Secrets in kube-system" /api/v1/namespaces/kube-system/secrets
rm -f /tmp/h /tmp/b
EOF
  done
  $K -n $NS delete pod pwned-token pwned-notoken --now --wait=true >/dev/null 2>&1
  $K -n $NS delete rolebinding/too-much-reads-secrets role/read-secrets serviceaccount/too-much secret/dummy-secret >/dev/null 2>&1
  echo
}

for mode in "${@:-admission network token}"; do
  for m in $mode; do case $m in admission|network|token) $m ;; *) echo "unknown mode: $m"; exit 1 ;; esac; done
done
echo "left in $NS: $($K -n $NS get pods,secrets,roles,rolebindings --no-headers 2>/dev/null | wc -l | tr -d ' ') pods/secrets/roles/rolebindings"
