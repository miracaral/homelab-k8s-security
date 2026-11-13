#!/bin/bash
# Phase 4 follow-up: verify the lockdown of the "jobs" namespace (Redis password, network policies, Pod Security).
# ALLOW = connection succeeded, BLOCK = it did not. Run on the control-plane node.
K=${KUBECTL:-"sudo k3s kubectl"}

# Two throwaway pods, each testing a different rule:
#   jobs-test-probe in "default": no policy applies there, so only Redis's ingress rule can stop it.
#   jobs-test-rogue in "jobs": meets Pod Security "restricted" but is not the worker; default-deny stops it at egress.
ROGUE_OVERRIDES='{"spec":{"automountServiceAccountToken":false,"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"jobs-test-rogue","image":"busybox:1.36","command":["sleep","300"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
$K -n default run jobs-test-probe --image=busybox:1.36 --restart=Never -- sleep 300 >/dev/null 2>&1
$K -n jobs run jobs-test-rogue --image=busybox:1.36 --restart=Never --overrides="$ROGUE_OVERRIDES" >/dev/null 2>&1
$K -n default wait --for=condition=Ready pod/jobs-test-probe --timeout=60s >/dev/null 2>&1
$K -n jobs wait --for=condition=Ready pod/jobs-test-rogue --timeout=60s >/dev/null 2>&1

REDIS_IP=$($K -n jobs get svc redis -o jsonpath='{.spec.clusterIP}')

ok() { if "$@" >/dev/null 2>&1; then echo "ALLOW"; else echo "BLOCK"; fi; }
probe() { $K -n default exec jobs-test-probe -- sh -c "$1"; }
rogue() { $K -n jobs exec jobs-test-rogue -- sh -c "$1"; }
redis() { $K -n jobs exec deploy/redis -- sh -c "$1"; }

echo "== Network policies (namespace jobs)"
printf "%-48s %s\n" "TEST" "RESULT"
printf "%-48s %s\n" "probe (default) -> redis:6379 (by service IP)" "$(ok probe "nc -z -w 3 $REDIS_IP 6379")"
printf "%-48s %s\n" "rogue (jobs)    -> redis:6379 (by service IP)" "$(ok rogue "nc -z -w 3 $REDIS_IP 6379")"
printf "%-48s %s\n" "rogue (jobs)    -> internet (1.1.1.1:443)"     "$(ok rogue "nc -z -w 3 1.1.1.1 443")"

# The expected ALLOW: KEDA has to read the queue to start a worker, and the worker has to reach Redis to drain it.
redis 'for i in 1 2 3 4 5; do redis-cli LPUSH jobs test-$i; done' >/dev/null 2>&1
LEFT=5
for i in $(seq 1 12); do
  sleep 5
  LEFT=$(redis 'redis-cli LLEN jobs' 2>/dev/null)
  [ "$LEFT" = "0" ] && break
done
printf "%-48s %s\n" "KEDA + worker -> redis (5 jobs drained)" "$([ "$LEFT" = "0" ] && echo ALLOW || echo "BLOCK ($LEFT left)")"

echo
echo "== Redis password"
printf "%-48s %s\n" "redis-cli PING without a password"   "$(redis 'env -u REDISCLI_AUTH redis-cli PING' 2>&1 | head -n1)"
printf "%-48s %s\n" "redis-cli PING with a wrong password" "$(redis 'REDISCLI_AUTH=wrong redis-cli PING' 2>&1 | grep -o 'WRONGPASS' | head -n1)"
printf "%-48s %s\n" "redis-cli PING with the Secret"       "$(redis 'redis-cli PING' 2>&1 | head -n1)"
printf "%-48s %s\n" "password in the process arguments?"   "$(redis 'tr "\0" " " < /proc/1/cmdline | grep -q requirepass' >/dev/null 2>&1 && echo YES || echo NO)"

echo
echo "== Pod Security restricted (namespace jobs)"
printf "%-48s %s\n" "privileged pod admitted?" \
  "$($K -n jobs run privtest --image=busybox:1.36 --privileged --dry-run=server -- sleep 1 >/dev/null 2>&1 && echo YES || echo "NO (refused)")"
printf "%-48s %s\n" "plain pod (root, no securityContext)?" \
  "$($K -n jobs run plaintest --image=busybox:1.36 --dry-run=server -- sleep 1 >/dev/null 2>&1 && echo YES || echo "NO (refused)")"
printf "%-48s %s\n" "redis runs as"                           "$(redis 'id -u' 2>/dev/null) (non-root)"
printf "%-48s %s\n" "redis can write to its root filesystem?" "$(redis 'touch /probe' >/dev/null 2>&1 && echo YES || echo "NO (read-only)")"
printf "%-48s %s\n" "redis has a ServiceAccount token?"       "$(redis 'ls /var/run/secrets/kubernetes.io/serviceaccount' >/dev/null 2>&1 && echo YES || echo NO)"

$K -n default delete pod jobs-test-probe --now >/dev/null 2>&1
$K -n jobs delete pod jobs-test-rogue --now >/dev/null 2>&1
