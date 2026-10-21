#!/bin/bash
# Push N jobs (default 200) onto the queue
N=${1:-200}
kubectl -n jobs exec deploy/redis -- sh -c "for i in \$(seq 1 $N); do redis-cli LPUSH jobs job-\$i >/dev/null; done; echo queued: \$(redis-cli LLEN jobs)"
