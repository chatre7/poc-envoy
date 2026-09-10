#!/usr/bin/env sh
set -eu

runtime=false
if [ "${1:-}" = "--runtime" ]; then
  runtime=true
elif [ "$#" -gt 0 ]; then
  echo "usage: $0 [--runtime]" >&2
  exit 2
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
use_cases="$root/use-cases"
labs=$(find "$use_cases" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9]-*' | sort)
count=$(printf '%s\n' "$labs" | sed '/^$/d' | wc -l | tr -d ' ')

if [ "$count" -ne 12 ]; then
  echo "expected 12 labs, found $count" >&2
  exit 1
fi

cleanup() {
  if [ "$runtime" = true ]; then
    printf '%s\n' "$labs" | while IFS= read -r lab; do
      [ -n "$lab" ] && docker compose -f "$lab/docker-compose.yml" down -v >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup EXIT INT TERM

failed=0
printf '%s\n' "$labs" | while IFS= read -r lab; do
  [ -n "$lab" ] || continue
  echo "==> $(basename "$lab")"
  (
    cd "$lab"
    for required in docker-compose.yml envoy.yaml README.md test.ps1 test.sh; do
      [ -f "$required" ] || { echo "missing $required: $(basename "$lab")" >&2; exit 10; }
    done
    if ! docker compose -f ./docker-compose.yml config --quiet; then
      echo "compose validation failed: $(basename "$lab")" >&2
      exit 10
    fi
    if [ -f ./generate-certs.sh ] && ! sh ./generate-certs.sh; then
      echo "certificate generation failed: $(basename "$lab")" >&2
      exit 10
    fi
    if ! MSYS_NO_PATHCONV=1 docker compose -f ./docker-compose.yml run -T --rm --no-deps envoy --mode validate -c /etc/envoy/envoy.yaml </dev/null; then
      echo "envoy validation failed: $(basename "$lab")" >&2
      exit 10
    fi
    if [ "$runtime" = true ] && ! sh ./test.sh </dev/null; then
      echo "runtime smoke test failed: $(basename "$lab")" >&2
      exit 10
    fi
  ) || exit 10
done || failed=$?

if [ "$failed" -ne 0 ]; then exit 1; fi
echo "Validated $count Envoy labs."
