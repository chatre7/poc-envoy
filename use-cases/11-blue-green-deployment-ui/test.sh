#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
compose='docker compose -f ./docker-compose.yml'
publish_invalid_route() {
  MSYS_NO_PATHCONV=1 $compose exec -T envoy sh -c "cp /etc/envoy/xds/routes-invalid.yaml /etc/envoy/xds/routes-current.yaml.tmp && mv /etc/envoy/xds/routes-current.yaml.tmp /etc/envoy/xds/routes-current.yaml"
}
wait_body() { expected=$1; i=0; until [ "$(curl -fsS http://127.0.0.1:8080/ 2>/dev/null || true)" = "$expected" ]; do i=$((i+1)); [ "$i" -lt 30 ] || return 1; sleep 1; done; }
wait_active() {
  expected=$1
  i=0
  until curl -fsS http://127.0.0.1:8080/deployment/api/state 2>/dev/null | grep -q "\"active\":\"$expected\""; do
    i=$((i+1))
    [ "$i" -lt 30 ] || return 1
    sleep 1
  done
}
switch_traffic() {
  curl -fsS -H 'Content-Type: application/json' \
    -d "{\"target\":\"$1\",\"expected_active\":\"$2\"}" \
    http://127.0.0.1:8080/deployment/api/switch >/dev/null
}
cleanup() { ./reset.sh >/dev/null 2>&1 || true; $compose down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
./reset.sh
cleanup
$compose up -d
wait_body VERSION-1
wait_active blue
container=$($compose ps -q envoy)
before=$(docker inspect --format '{{.Id}}' "$container")
switch_traffic green blue
wait_body VERSION-2
after=$(docker inspect --format '{{.Id}}' "$container")
[ "$before" = "$after" ]
publish_invalid_route
sleep 3
[ "$(curl -fsS http://127.0.0.1:8080/)" = VERSION-2 ]
curl -fsS 'http://127.0.0.1:9901/stats?filter=update_rejected' | grep -Eq 'update_rejected: [1-9]'
switch_traffic blue green
wait_body VERSION-1
wait_active blue
echo 'PASS: Release Console promoted Green, preserved the accepted route after rejection, and rolled back Blue'
