$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$compose = @('compose', '-f', './docker-compose.yml')
function Set-Route([string]$Source) {
    if ($Source -notmatch '^routes-(v1|v2|invalid)\.yaml$') { throw 'unsafe route fixture name' }
    & docker @compose exec -T envoy sh -c "cp /etc/envoy/xds/$Source /etc/envoy/xds/routes-current.yaml.tmp && mv /etc/envoy/xds/routes-current.yaml.tmp /etc/envoy/xds/routes-current.yaml"
    if ($LASTEXITCODE -ne 0) { throw "failed to publish $Source" }
}
function Wait-Body([string]$Expected, [int]$Seconds = 30) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $body = (& curl.exe -fsS http://127.0.0.1:8080/).Trim()
            if ($body -eq $Expected) { return }
        } catch {}
        Start-Sleep -Seconds 1
    }
    throw "timeout waiting for $Expected"
}
& ./reset.ps1
& docker @compose down -v 2>$null
try {
    & docker @compose up -d
    if ($LASTEXITCODE -ne 0) { throw 'compose startup failed' }
    Wait-Body 'VERSION-1'
    $container = (& docker @compose ps -q envoy).Trim()
    $before = (& docker inspect --format '{{.Id}}' $container).Trim()
    Set-Route 'routes-v2.yaml'
    Wait-Body 'VERSION-2'
    $after = (& docker inspect --format '{{.Id}}' $container).Trim()
    if ($before -ne $after) { throw 'Envoy container restarted during RDS update' }
    Set-Route 'routes-invalid.yaml'
    Start-Sleep -Seconds 3
    $body = (& curl.exe -fsS http://127.0.0.1:8080/).Trim()
    if ($body -ne 'VERSION-2') { throw 'invalid update replaced last accepted route' }
    $stats = (Invoke-WebRequest 'http://127.0.0.1:9901/stats?filter=update_rejected' -UseBasicParsing).Content
    if ($stats -notmatch 'update_rejected:\s*[1-9]') { throw 'RDS rejection counter did not increase' }
    Write-Host 'PASS: RDS changed v1 to v2 without restart and rejected invalid update'
} finally {
    & ./reset.ps1
    & docker @compose down -v 2>$null
}
