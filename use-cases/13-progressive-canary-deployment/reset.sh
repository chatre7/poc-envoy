#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
xds_dir=$(cd xds && pwd)
target="$xds_dir/routes-current.yaml"
[ "$(dirname "$target")" = "$xds_dir" ] || { echo 'unsafe xDS target path' >&2; exit 1; }
cp "$xds_dir/routes-baseline.yaml" "$xds_dir/routes-current.yaml.tmp"
mv "$xds_dir/routes-current.yaml.tmp" "$target"
echo 'Reset routes-current.yaml to 0% canary'
