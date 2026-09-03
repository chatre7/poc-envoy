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
codes=''; i=0
while [ "$i" -lt 5 ]; do codes="$codes $(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/)"; i=$((i+1)); done
[ "$(printf '%s' "$codes" | grep -o 200 | wc -l | tr -d ' ')" -eq 2 ]
[ "$(printf '%s' "$codes" | grep -o 429 | wc -l | tr -d ' ')" -ge 3 ]
curl -sSI http://127.0.0.1:8080/ | grep -Eqi '^x-local-rate-limit:[[:space:]]*true'
sleep 6
[ "$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/)" = 200 ]
echo 'PASS: local token bucket limited burst and refilled'
