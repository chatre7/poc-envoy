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
failures=0; i=0
while [ "$i" -lt 20 ]; do code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/); [ "$code" = 503 ] && failures=$((failures+1)); i=$((i+1)); done
[ "$failures" -ge 2 ]
i=0
until curl -fsS 'http://127.0.0.1:9901/stats?filter=ejections_total' | grep -Eq 'ejections_total: [1-9]'; do i=$((i+1)); [ "$i" -lt 15 ] || exit 1; sleep 1; done
streak=0; i=0
while [ "$i" -lt 75 ] && [ "$streak" -lt 10 ]; do
  body=$(curl -sS http://127.0.0.1:8080/ 2>/dev/null || true)
  if [ "$body" = GOOD ]; then streak=$((streak+1)); else streak=0; fi
  i=$((i+1))
  [ "$streak" -ge 10 ] || sleep 0.2
done
[ "$streak" -ge 10 ]
echo 'PASS: consecutive 5xx caused passive host ejection'
