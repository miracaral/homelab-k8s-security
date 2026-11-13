#!/bin/bash
# Show that nothing in the given namespaces is reachable from outside the cluster:
# no NodePort/LoadBalancer Service, no externalIPs, no Ingress, no hostNetwork pod, no hostPort.
# Every count should be 0. Run on the control-plane node.   Usage: exposure-check.sh [namespace ...]
K=${KUBECTL:-"sudo k3s kubectl"}
count() { wc -w | tr -d ' '; }

for NS in "${@:-jobs}"; do
  echo "== Exposure check (namespace $NS)"
  $K -n "$NS" get svc -o custom-columns='SERVICE:.metadata.name,TYPE:.spec.type,EXTERNAL-IPS:.spec.externalIPs,NODEPORTS:.spec.ports[*].nodePort'
  printf "%-40s %s\n" "services that are not ClusterIP" "$($K -n "$NS" get svc -o jsonpath='{range .items[?(@.spec.type!="ClusterIP")]}{.metadata.name}{" "}{end}' | count)"
  printf "%-40s %s\n" "services with externalIPs"       "$($K -n "$NS" get svc -o jsonpath='{range .items[?(@.spec.externalIPs)]}{.metadata.name}{" "}{end}' | count)"
  printf "%-40s %s\n" "Ingress objects"                 "$($K -n "$NS" get ingress --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  printf "%-40s %s\n" "pods with hostNetwork"           "$($K -n "$NS" get pods -o jsonpath='{range .items[?(@.spec.hostNetwork==true)]}{.metadata.name}{" "}{end}' | count)"
  printf "%-40s %s\n" "containers with a hostPort"      "$($K -n "$NS" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{range .ports[*]}{.hostPort}{" "}{end}{end}{end}' | count)"
  echo
done
