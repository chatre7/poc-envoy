#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
compose='docker compose -f ./docker-compose.yml'
api=http://127.0.0.1:8080/deployment/api

state() { curl -fsS "$api/state"; }
weight_is() { state | grep -q "^{\"weight\":$1,"; }
wait_weight() {
  i=0
  until weight_is "$1" 2>/dev/null; do i=$((i+1)); [ "$i" -lt 30 ] || { echo "timeout waiting for canary weight $1%" >&2; return 1; }; sleep 1; done
}
wait_body() { i=0; until [ "$(curl -fsS http://127.0.0.1:8080/ 2>/dev/null || true)" = "$1" ]; do i=$((i+1)); [ "$i" -lt 30 ] || return 1; sleep 1; done; }
# rollout ACTION EXPECTED_WEIGHT -> prints the HTTP status code
rollout() {
  curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    -d "{\"action\":\"$1\",\"expected_weight\":$2}" "$api/rollout"
}
advance() { code=$(rollout advance "$1"); [ "$code" = 200 ] || { echo "advance from $1% returned HTTP $code" >&2; return 1; }; }
# Deterministic canary samples through the x-canary override route.
canary_samples() { i=0; while [ "$i" -lt "$1" ]; do curl -sS -o /dev/null -H 'x-canary: always' http://127.0.0.1:8080/; i=$((i+1)); done; }
set_fault() {
  $compose exec -T backend-canary python -c "import urllib.request; urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:9000/fault?rate=$1', method='POST'))"
}
cleanup() { sh ./reset.sh >/dev/null 2>&1 || true; $compose down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

cleanup
$compose up -d
wait_body VERSION-1
wait_weight 0
container=$($compose ps -q envoy)
before=$(docker inspect --format '{{.Id}}' "$container")

# Step 0% -> 10% and verify the split without restarting Envoy.
advance 0
wait_weight 10
stable=0; canary=0; i=0
while [ "$i" -lt 200 ]; do
  case "$(curl -fsS http://127.0.0.1:8080/)" in
    VERSION-1) stable=$((stable+1)) ;;
    VERSION-2) canary=$((canary+1)) ;;
  esac
  i=$((i+1))
done
[ "$canary" -ge 5 ] && [ "$canary" -le 45 ] || { echo "unexpected 10% split stable=$stable canary=$canary" >&2; exit 1; }
[ "$(curl -fsS -H 'x-canary: always' http://127.0.0.1:8080/)" = VERSION-2 ]

# Stale expected_weight is rejected by the concurrency guard.
[ "$(rollout advance 0)" = 409 ]

# Injected failures must trigger an automatic rollback to 0%.
set_fault 1
canary_samples 40
wait_weight 0
state | grep -q '"status":"rolled_back"'
state | grep -q '"kind":"auto_rollback"'
wait_body VERSION-1
set_fault 0

# Healthy canary: 0 -> 10 needs no samples, later steps need MIN_SAMPLES each.
advance 0
wait_weight 10
[ "$(rollout advance 10)" = 409 ]
for step in 10 25 50; do
  canary_samples 25
  advance "$step"
done
wait_weight 100
state | grep -q '"status":"promoted"'
wait_body VERSION-2

# An invalid RDS file is rejected and the last accepted route keeps serving.
MSYS_NO_PATHCONV=1 $compose exec -T envoy sh -c "cp /etc/envoy/xds/routes-invalid.yaml /etc/envoy/xds/routes-current.yaml.tmp && mv /etc/envoy/xds/routes-current.yaml.tmp /etc/envoy/xds/routes-current.yaml"
sleep 3
[ "$(curl -fsS http://127.0.0.1:8080/)" = VERSION-2 ]
curl -fsS 'http://127.0.0.1:9901/stats?filter=update_rejected' | grep -Eq 'update_rejected: [1-9]'

after=$(docker inspect --format '{{.Id}}' "$container")
[ "$before" = "$after" ]
echo "PASS: canary 10% split stable=$stable canary=$canary, auto-rollback on 5xx, gated promotion to 100% without restarting Envoy"
