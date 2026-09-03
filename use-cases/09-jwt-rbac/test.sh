#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
compose='docker compose -f ./docker-compose.yml'
body="${TMPDIR:-/tmp}/envoy-jwt-body.$$"
cleanup() { rm -f "$body"; $compose down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup
$compose up -d
i=0
until curl -fsS http://127.0.0.1:9901/ready >/dev/null 2>&1; do i=$((i+1)); [ "$i" -lt 60 ] || exit 1; sleep 0.5; done
[ "$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/)" = 401 ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer broken' http://127.0.0.1:8080/)" = 401 ]
viewer=$(cat fixtures/unauthorized.token)
[ "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $viewer" http://127.0.0.1:8080/)" = 403 ]
admin=$(cat fixtures/authorized.token)
[ "$(curl -sS -o "$body" -w '%{http_code}' -H "Authorization: Bearer $admin" http://127.0.0.1:8080/)" = 200 ]
[ "$(cat "$body")" = AUTHORIZED ]
echo 'PASS: JWT authentication returned 401; RBAC returned 403/200 by role'
