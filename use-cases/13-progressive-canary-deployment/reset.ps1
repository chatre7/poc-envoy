$ErrorActionPreference = 'Stop'
$root = (Resolve-Path $PSScriptRoot).Path
$xds = (Resolve-Path (Join-Path $root 'xds')).Path
$target = Join-Path $xds 'routes-current.yaml'
$temp = Join-Path $xds 'routes-current.yaml.tmp'
if ((Split-Path -Parent $target) -ne $xds) { throw 'unsafe xDS target path' }
Copy-Item -LiteralPath (Join-Path $xds 'routes-baseline.yaml') -Destination $temp -Force
Move-Item -LiteralPath $temp -Destination $target -Force
Write-Host 'Reset routes-current.yaml to 0% canary'
