#!/bin/bash
# Every 2 s: queue length, worker replicas, and which nodes the workers run on
while true; do
  clear
  date +%T
  echo "queue length: $(kubectl -n jobs exec deploy/redis -- redis-cli LLEN jobs 2>/dev/null)"
  kubectl -n jobs get deploy worker --no-headers | awk '{print "workers ready: "$2}'
  kubectl -n jobs get pods -l app=worker -o wide --no-headers | awk '{print "  "$1"  "$3"  "$7}'
  sleep 2
done
