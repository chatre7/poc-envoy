#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
compose='docker compose -f ./docker-compose.yml'
cleanup() { $compose down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup
$compose up -d
wait_uri() { i=0; until curl -fsS "$1" >/dev/null 2>&1; do i=$((i+1)); [ "$i" -lt 45 ] || return 1; sleep 1; done; }
wait_uri http://127.0.0.1:9901/ready
wait_uri http://127.0.0.1:9090/-/ready
wait_uri http://127.0.0.1:16686/
id=11111111-1111-4111-8111-111111111111
traced_id=11111111-1111-9111-8111-111111111111
curl -fsS -H "x-request-id: $id" -H 'x-envoy-force-trace: true' http://127.0.0.1:8080/ >/dev/null
sleep 2
logs=$($compose logs --no-color envoy)
printf '%s' "$logs" | grep "$traced_id" | grep -q '"method"'
printf '%s' "$logs" | grep "$traced_id" | grep -q '"response_code"'
i=0
until curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=envoy_http_downstream_rq_total' | grep -Eq '"result":\[\{'; do i=$((i+1)); [ "$i" -lt 30 ] || exit 1; sleep 1; done
i=0
until curl -fsS 'http://127.0.0.1:16686/api/traces?service=envoy&limit=20' | grep -Eq '"data":\[\{'; do i=$((i+1)); [ "$i" -lt 30 ] || exit 1; sleep 1; done
echo 'PASS: JSON log, Prometheus metric, and Jaeger trace verified'
