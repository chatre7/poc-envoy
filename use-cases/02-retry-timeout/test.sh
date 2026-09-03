#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
compose='docker compose -f ./docker-compose.yml'
headers="${TMPDIR:-/tmp}/envoy-retry-headers.$$"
cleanup() { rm -f "$headers"; $compose down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup
$compose up -d
i=0
until curl -fsS http://127.0.0.1:8080/ok >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -lt 60 ] || { echo 'timeout waiting for Envoy' >&2; exit 1; }; sleep 0.5
done
code=$(curl -sS -D "$headers" -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/fail-once)
[ "$code" = 200 ]
grep -Eqi '^x-backend-attempt:[[:space:]]*2' "$headers"
code=$(curl -sS -D "$headers" -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/slow-once)
[ "$code" = 200 ]
grep -Eqi '^x-backend-attempt:[[:space:]]*2' "$headers"
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 7 http://127.0.0.1:8080/always-slow)
[ "$code" = 504 ]
curl -fsS 'http://127.0.0.1:9901/stats?filter=upstream_rq_retry' | grep -Eq 'upstream_rq_retry: [1-9]'
echo 'PASS: 5xx retry, per-try timeout, and overall timeout verified'
