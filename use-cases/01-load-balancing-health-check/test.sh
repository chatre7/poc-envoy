#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
cleanup() { docker compose -f ./docker-compose.yml down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup
docker compose -f ./docker-compose.yml up -d
i=0
until curl -fsS http://127.0.0.1:8080/ >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -lt 60 ] || { echo 'timeout waiting for Envoy' >&2; exit 1; }; sleep 0.5
done
responses=''; i=0
while [ "$i" -lt 12 ]; do responses="$responses $(curl -fsS http://127.0.0.1:8080/)"; i=$((i + 1)); done
printf '%s' "$responses" | grep -q 'Hello from APP-1'
printf '%s' "$responses" | grep -q 'Hello from APP-2'
docker compose -f ./docker-compose.yml pause app1
i=0
until curl -fsS http://127.0.0.1:9901/clusters | grep -A 12 'hostname::app1' | grep -q 'failed_active_hc'; do
  i=$((i + 1)); [ "$i" -lt 15 ] || { echo 'app1 was not marked failed_active_hc within 15 seconds' >&2; exit 1; }; sleep 1
done
i=0
while [ "$i" -lt 8 ]; do
  [ "$(curl -fsS http://127.0.0.1:8080/)" = 'Hello from APP-2' ] || { echo 'unhealthy app1 still received traffic' >&2; exit 1; }
  i=$((i + 1))
done
docker compose -f ./docker-compose.yml unpause app1
i=0
while [ "$i" -lt 20 ]; do
  [ "$(curl -fsS http://127.0.0.1:8080/)" = 'Hello from APP-1' ] && { echo 'PASS: round robin, unhealthy removal, and recovery verified'; exit 0; }
  i=$((i + 1)); sleep 1
done
echo 'app1 did not recover within 20 seconds' >&2
exit 1
