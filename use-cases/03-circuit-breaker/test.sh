#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
compose='docker compose -f ./docker-compose.yml'
tmp="${TMPDIR:-/tmp}/envoy-circuit.$$"
cleanup() { rm -rf "$tmp"; $compose down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup
mkdir -p "$tmp"
$compose up -d
i=0
until curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1; do i=$((i+1)); [ "$i" -lt 60 ] || exit 1; sleep 0.5; done
i=1
while [ "$i" -le 8 ]; do (curl -sS -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8080/hold >"$tmp/$i") & i=$((i+1)); done
wait
grep -Rqx 200 "$tmp"
grep -Rqx 503 "$tmp"
curl -fsS 'http://127.0.0.1:9901/stats?filter=upstream_rq_.*overflow' | grep -Eq 'upstream_rq_(pending|active)_overflow: [1-9]'
echo 'PASS: circuit breaker returned 200 and 503; overflow counter increased'
