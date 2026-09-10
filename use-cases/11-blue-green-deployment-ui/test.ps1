$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$compose = @('compose', '-f', './docker-compose.yml')
function Publish-InvalidRoute {
    & docker @compose exec -T envoy sh -c "cp /etc/envoy/xds/routes-invalid.yaml /etc/envoy/xds/routes-current.yaml.tmp && mv /etc/envoy/xds/routes-current.yaml.tmp /etc/envoy/xds/routes-current.yaml"
    if ($LASTEXITCODE -ne 0) { throw 'failed to publish invalid route fixture' }
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
function Wait-Active([string]$Expected, [int]$Seconds = 30) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $state = Invoke-RestMethod http://127.0.0.1:8080/deployment/api/state -TimeoutSec 3
            if ($state.active -eq $Expected) { return $state }
        } catch {}
        Start-Sleep -Seconds 1
    }
    throw "timeout waiting for active deployment $Expected"
}
function Switch-Traffic([string]$Target, [string]$ExpectedActive) {
    $body = @{ target = $Target; expected_active = $ExpectedActive } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8080/deployment/api/switch -ContentType application/json -Body $body
}
& ./reset.ps1
& docker @compose down -v 2>$null
try {
    & docker @compose up -d
    if ($LASTEXITCODE -ne 0) { throw 'compose startup failed' }
    Wait-Body 'VERSION-1'
    [void](Wait-Active 'blue')
    $container = (& docker @compose ps -q envoy).Trim()
    $before = (& docker inspect --format '{{.Id}}' $container).Trim()
    [void](Switch-Traffic 'green' 'blue')
    Wait-Body 'VERSION-2'
    $after = (& docker inspect --format '{{.Id}}' $container).Trim()
    if ($before -ne $after) { throw 'Envoy container restarted during RDS update' }
    Publish-InvalidRoute
    Start-Sleep -Seconds 3
    $body = (& curl.exe -fsS http://127.0.0.1:8080/).Trim()
    if ($body -ne 'VERSION-2') { throw 'invalid update replaced last accepted route' }
    $stats = (Invoke-WebRequest 'http://127.0.0.1:9901/stats?filter=update_rejected' -UseBasicParsing).Content
    if ($stats -notmatch 'update_rejected:\s*[1-9]') { throw 'RDS rejection counter did not increase' }
    [void](Switch-Traffic 'blue' 'green')
    Wait-Body 'VERSION-1'
    [void](Wait-Active 'blue')
    Write-Host 'PASS: Release Console promoted Green, preserved the accepted route after rejection, and rolled back Blue'
} finally {
    & ./reset.ps1
    & docker @compose down -v 2>$null
}
