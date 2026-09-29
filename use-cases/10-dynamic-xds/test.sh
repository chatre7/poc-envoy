#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
compose='docker compose -f ./docker-compose.yml'
set_route() {
  case "$1" in routes-v1.yaml|routes-v2.yaml|routes-invalid.yaml) ;; *) return 1;; esac
  MSYS_NO_PATHCONV=1 $compose exec -T envoy sh -c "cp /etc/envoy/xds/$1 /etc/envoy/xds/routes-current.yaml.tmp && mv /etc/envoy/xds/routes-current.yaml.tmp /etc/envoy/xds/routes-current.yaml"
}
wait_body() { expected=$1; i=0; until [ "$(curl -fsS http://127.0.0.1:8080/ 2>/dev/null || true)" = "$expected" ]; do i=$((i+1)); [ "$i" -lt 30 ] || return 1; sleep 1; done; }
cleanup() { sh ./reset.sh >/dev/null 2>&1 || true; $compose down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
sh ./reset.sh
cleanup
$compose up -d
wait_body VERSION-1
container=$($compose ps -q envoy)
before=$(docker inspect --format '{{.Id}}' "$container")
set_route routes-v2.yaml
wait_body VERSION-2
after=$(docker inspect --format '{{.Id}}' "$container")
[ "$before" = "$after" ]
set_route routes-invalid.yaml
sleep 3
[ "$(curl -fsS http://127.0.0.1:8080/)" = VERSION-2 ]
curl -fsS 'http://127.0.0.1:9901/stats?filter=update_rejected' | grep -Eq 'update_rejected: [1-9]'
echo 'PASS: RDS changed v1 to v2 without restart and rejected invalid update'
