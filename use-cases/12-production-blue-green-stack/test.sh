#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
compose='docker compose -f ./docker-compose.yml'

wait_uri() { i=0; until curl -fsS "$1" >/dev/null 2>&1; do i=$((i+1)); [ "$i" -lt 60 ] || return 1; sleep 1; done; }
wait_body() { expected=$1; i=0; until [ "$(curl -fsS http://127.0.0.1:8080/ 2>/dev/null || true)" = "$expected" ]; do i=$((i+1)); [ "$i" -lt 45 ] || return 1; sleep 1; done; }
wait_state() { expected=$1; i=0; until curl -fsS http://127.0.0.1:8080/deployment/api/state 2>/dev/null | grep -q "\"active\":\"$expected\""; do i=$((i+1)); [ "$i" -lt 45 ] || return 1; sleep 1; done; }
wait_failover() { expected=$1; i=0; until curl -fsS http://127.0.0.1:8080/deployment/api/state 2>/dev/null | grep -q "\"required\":$expected"; do i=$((i+1)); [ "$i" -lt 45 ] || return 1; sleep 1; done; }
wait_alert_state() {
  expected=$1; i=0
  while [ "$i" -lt 90 ]; do
    alerts=$(curl -fsS http://127.0.0.1:9090/api/v1/alerts 2>/dev/null || true)
    if printf '%s' "$alerts" | grep -q '"alertname":"ActiveReleaseUnhealthy"' && printf '%s' "$alerts" | grep -q "\"state\":\"$expected\""; then return 0; fi
    i=$((i+1)); sleep 0.5
  done
  return 1
}
wait_alert_cleared() {
  i=0
  while [ "$i" -lt 90 ]; do
    alerts=$(curl -fsS http://127.0.0.1:9090/api/v1/alerts 2>/dev/null || true)
    if ! printf '%s' "$alerts" | grep -q '"alertname":"ActiveReleaseUnhealthy"'; then return 0; fi
    i=$((i+1)); sleep 0.5
  done
  return 1
}
wait_webhook_alert() {
  expected=$1; i=0
  while [ "$i" -lt 90 ]; do
    state=$(curl -fsS http://127.0.0.1:8080/deployment/api/state 2>/dev/null || true)
    if printf '%s' "$state" | grep -q '"alertname":"ActiveReleaseUnhealthy"' && printf '%s' "$state" | grep -q "\"status\":\"$expected\""; then return 0; fi
    i=$((i+1)); sleep 0.5
  done
  return 1
}
switch_traffic() { curl -fsS -H 'Content-Type: application/json' -d "{\"target\":\"$1\",\"expected_active\":\"$2\"}" http://127.0.0.1:8080/deployment/api/switch >/dev/null; }
publish_invalid_route() { MSYS_NO_PATHCONV=1 $compose exec -T envoy sh -c "cp /etc/envoy/xds/routes-invalid.yaml /etc/envoy/xds/routes-current.yaml.tmp && mv /etc/envoy/xds/routes-current.yaml.tmp /etc/envoy/xds/routes-current.yaml"; }
cleanup() { $compose start backend-v1 >/dev/null 2>&1 || true; sh ./reset.sh >/dev/null 2>&1 || true; $compose down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

sh ./reset.sh
cleanup
$compose up -d
wait_uri http://127.0.0.1:9901/ready
wait_uri http://127.0.0.1:9090/-/ready
wait_uri http://127.0.0.1:9093/-/ready
wait_uri http://127.0.0.1:3000/api/health
wait_uri http://127.0.0.1:16686/
wait_body VERSION-1
wait_state blue
state=$(curl -fsS http://127.0.0.1:8080/deployment/api/state)
printf '%s' "$state" | grep -q '"prometheus":{"healthy":true'
printf '%s' "$state" | grep -q '"grafana":{"healthy":true'
printf '%s' "$state" | grep -q '"jaeger":{"healthy":true'
printf '%s' "$state" | grep -q '"alertmanager":{"healthy":true'
metrics=$(curl -fsS http://127.0.0.1:8080/deployment/metrics)
printf '%s' "$metrics" | grep -q '^release_active'
printf '%s' "$metrics" | grep -q '^release_failover_required'
curl -fsS http://127.0.0.1:9090/api/v1/rules | grep -q 'ActiveReleaseUnhealthy'
[ "$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:8080/deployment/api/alerts)" = 404 ]

container=$($compose ps -q envoy)
before=$(docker inspect --format '{{.Id}}' "$container")
id=11111111-1111-4111-8111-111111111111
traced_id_pattern='11111111-1111-[0-9a-f]111-8111-111111111111'
curl -fsS -H "x-request-id: $id" -H 'x-envoy-force-trace: true' http://127.0.0.1:8080/ >/dev/null
sleep 2
logs=$($compose logs --no-color envoy)
printf '%s' "$logs" | grep -E "$traced_id_pattern" | grep -q '"upstream_cluster"'
i=0
until curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=release_active' | grep -Eq '"result":\[\{'; do i=$((i+1)); [ "$i" -lt 30 ] || exit 1; sleep 1; done
curl -fsS 'http://127.0.0.1:3000/api/search?query=Failover' | grep -q '"uid":"envoy-production"'
i=0
until curl -fsS 'http://127.0.0.1:16686/api/traces?service=production-blue-green-stack&limit=20' | grep -Eq '"data":\[\{'; do i=$((i+1)); [ "$i" -lt 30 ] || exit 1; sleep 1; done

$compose stop backend-v1
wait_alert_state pending
wait_failover true
failed_state=$(curl -fsS http://127.0.0.1:8080/deployment/api/state)
printf '%s' "$failed_state" | grep -q '"standby":"green","standby_ready":true'
[ "$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/)" = 503 ]
wait_alert_state firing
wait_webhook_alert firing
switch_traffic green blue
wait_body VERSION-2
wait_state green
wait_failover false
wait_alert_cleared
wait_webhook_alert resolved
after=$(docker inspect --format '{{.Id}}' "$container")
[ "$before" = "$after" ]

$compose start backend-v1
wait_uri http://127.0.0.1:8080/deployment/api/state
sleep 3
publish_invalid_route
sleep 3
[ "$(curl -fsS http://127.0.0.1:8080/)" = VERSION-2 ]
curl -fsS 'http://127.0.0.1:9901/stats?filter=update_rejected' | grep -Eq 'update_rejected: [1-9]'
switch_traffic blue green
wait_body VERSION-1
wait_state blue
echo 'PASS: failover detection, Pending/Firing/Resolved alerts, webhook delivery, manual recovery, telemetry, rejection safety, and rollback verified'
