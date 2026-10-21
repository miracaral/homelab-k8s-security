#!/bin/bash
# Phase 2 access matrix for the "demo" namespace: ALLOW = connection succeeded, BLOCK = it did not
run() { local from=$1; shift
  if timeout 8 kubectl -n demo exec deploy/$from -c shell -- "$@" >/dev/null 2>&1; then echo "ALLOW"; else echo "BLOCK"; fi; }
printf "%-34s %s\n" "TEST" "RESULT"
printf "%-34s %s\n" "frontend -> backend GET /get"   "$(run frontend curl -sf -m 4 http://backend:8080/get)"
printf "%-34s %s\n" "frontend -> backend POST /post" "$(run frontend curl -sf -m 4 -X POST http://backend:8080/post)"
printf "%-34s %s\n" "frontend -> db :6379"           "$(run frontend nc -z -w 3 db 6379)"
printf "%-34s %s\n" "backend  -> db :6379"           "$(run backend nc -z -w 3 db 6379)"
printf "%-34s %s\n" "attacker -> backend GET /get"   "$(run attacker curl -sf -m 4 http://backend:8080/get)"
printf "%-34s %s\n" "attacker -> db :6379"           "$(run attacker nc -z -w 3 db 6379)"
printf "%-34s %s\n" "frontend -> internet"           "$(run frontend curl -sf -m 4 -o /dev/null https://1.1.1.1)"
