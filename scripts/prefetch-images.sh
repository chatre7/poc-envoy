#!/usr/bin/env sh
# Pre-pull every image the labs use. Docker Hub limits anonymous pulls per IP,
# so images already present are skipped and failed pulls fall back to
# mirror.gcr.io, then are re-tagged to the name the Compose files expect.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mirror=${MIRROR:-mirror.gcr.io}

images=$(grep -rhE '^[[:space:]]*image:' --include=docker-compose.yml "$root/use-cases" "$root/docker-compose.yml" \
  | sed 's/.*image:[[:space:]]*//' | sort -u)

failed=0
for image in $images; do
  if docker image inspect "$image" >/dev/null 2>&1; then
    echo "present  $image"
    continue
  fi
  if docker pull -q "$image" >/dev/null 2>&1; then
    echo "pulled   $image"
    continue
  fi
  case "$image" in
    */*) source="$mirror/$image" ;;
    *)   source="$mirror/library/$image" ;;
  esac
  if docker pull -q "$source" >/dev/null 2>&1 && docker tag "$source" "$image"; then
    echo "mirrored $image (from $source)"
  else
    echo "FAILED   $image" >&2
    failed=1
  fi
done

[ "$failed" -eq 0 ] || { echo "Some images could not be pulled. Run 'docker login' or retry later." >&2; exit 1; }
echo "All lab images are available locally."
