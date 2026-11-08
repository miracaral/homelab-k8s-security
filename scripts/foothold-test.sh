#!/bin/bash
# Phase 6: verify the controls around a real workload (Foothold API + Oracle in the "foothold" namespace).
# ALLOW = connection succeeded, BLOCK = it did not. Run on the control-plane node.
K=${KUBECTL:-"sudo k3s kubectl"}

# A pod inside the foothold namespace that is NOT the API (as if an attacker got a pod scheduled there).
# It satisfies Pod Security "restricted", so admission lets it in; only the network policies stop it.
ROGUE_OVERRIDES='{"spec":{"automountServiceAccountToken":false,"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"rogue","image":"busybox:1.36","command":["sleep","300"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
$K -n foothold run rogue --image=busybox:1.36 --restart=Never --overrides="$ROGUE_OVERRIDES" >/dev/null 2>&1
$K -n foothold wait --for=condition=Ready pod/rogue --timeout=60s >/dev/null 2>&1

ORACLE_IP=$($K -n foothold get svc oracle -o jsonpath='{.spec.clusterIP}')
API_IP=$($K -n foothold get svc foothold-api -o jsonpath='{.spec.clusterIP}')

# The timeout runs inside the container: `timeout` cannot call the shell functions below.
ok() { if "$@" >/dev/null 2>&1; then echo "ALLOW"; else echo "BLOCK"; fi; }
api()   { $K -n foothold exec deploy/foothold-api -- bash -c "$1"; }
rogue() { $K -n foothold exec rogue -- sh -c "$1"; }
atk()   { $K -n demo exec deploy/attacker -c shell -- sh -c "$1"; }

echo "== Network policies (namespace foothold)"
printf "%-44s %s\n" "TEST" "RESULT"
printf "%-44s %s\n" "api      -> oracle:1521"                 "$(ok api "timeout 5 bash -c 'exec 3<>/dev/tcp/oracle/1521'")"
printf "%-44s %s\n" "api      -> internet (1.1.1.1:443)"      "$(ok api "timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'")"
printf "%-44s %s\n" "rogue    -> oracle:1521 (by service IP)" "$(ok rogue "nc -z -w 3 $ORACLE_IP 1521")"
printf "%-44s %s\n" "rogue    -> api:80 (by service IP)"      "$(ok rogue "nc -z -w 3 $API_IP 80")"
printf "%-44s %s\n" "attacker -> oracle:1521 (from demo)"     "$(ok atk "nc -z -w 3 $ORACLE_IP 1521")"
printf "%-44s %s\n" "attacker -> api:80 (from demo)"          "$(ok atk "nc -z -w 3 $API_IP 80")"

echo
echo "== Pod Security restricted (namespace foothold)"
printf "%-44s %s\n" "privileged pod admitted?" \
  "$($K -n foothold run privtest --image=busybox:1.36 --privileged --dry-run=server -- sleep 1 >/dev/null 2>&1 && echo YES || echo "NO (refused)")"
printf "%-44s %s\n" "plain pod (root, no securityContext)?" \
  "$($K -n foothold run plaintest --image=busybox:1.36 --dry-run=server -- sleep 1 >/dev/null 2>&1 && echo YES || echo "NO (refused)")"
printf "%-44s %s\n" "api runs as"                             "$(api 'id -u' 2>/dev/null) (non-root)"
printf "%-44s %s\n" "api can write to its root filesystem?"   "$(api 'touch /probe' >/dev/null 2>&1 && echo YES || echo "NO (read-only)")"
printf "%-44s %s\n" "api has a ServiceAccount token?"         "$(api 'ls /var/run/secrets/kubernetes.io/serviceaccount' >/dev/null 2>&1 && echo YES || echo NO)"

echo
echo "== Health"
$K -n foothold exec deploy/foothold-api -- bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080; printf "GET /health HTTP/1.0\r\n\r\n" >&3; tail -n1 <&3'; echo

$K -n foothold delete pod rogue --now >/dev/null 2>&1
