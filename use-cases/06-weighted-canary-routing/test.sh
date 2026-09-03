#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
compose='docker compose -f ./docker-compose.yml'
cleanup() { $compose down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup
$compose up -d
i=0
until curl -fsS http://127.0.0.1:9901/ready >/dev/null 2>&1; do i=$((i+1)); [ "$i" -lt 60 ] || exit 1; sleep 0.5; done
stable=0; canary=0; i=0
while [ "$i" -lt 100 ]; do
  value=$(curl -fsS http://127.0.0.1:8080/)
  [ "$value" = STABLE ] && stable=$((stable+1))
  [ "$value" = CANARY ] && canary=$((canary+1))
  i=$((i+1))
done
[ "$stable" -ge 55 ] && [ "$stable" -le 95 ] && [ "$canary" -ge 5 ] && [ "$canary" -le 45 ]
i=0
while [ "$i" -lt 5 ]; do [ "$(curl -fsS -H 'x-canary: always' http://127.0.0.1:8080/)" = CANARY ]; i=$((i+1)); done
echo "PASS: weighted stable=$stable canary=$canary; header override is deterministic"
