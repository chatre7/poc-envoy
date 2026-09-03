$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$compose = @('compose', '-f', './docker-compose.yml')
function Wait-Ready {
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        & curl.exe -fsS http://127.0.0.1:9901/ready *> $null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Milliseconds 500
    }
    throw 'timeout waiting for Envoy'
}
& docker @compose down -v 2>$null
try {
    & docker @compose up -d
    if ($LASTEXITCODE -ne 0) { throw 'compose startup failed' }
    Wait-Ready
    $responses = 1..100 | ForEach-Object { (& curl.exe -fsS http://127.0.0.1:8080/).Trim() }
    $stable = @($responses | Where-Object { $_ -eq 'STABLE' }).Count
    $canary = @($responses | Where-Object { $_ -eq 'CANARY' }).Count
    if ($stable -lt 55 -or $stable -gt 95 -or $canary -lt 5 -or $canary -gt 45) { throw "unexpected distribution stable=$stable canary=$canary" }
    $forced = 1..5 | ForEach-Object { (& curl.exe -fsS -H 'x-canary: always' http://127.0.0.1:8080/).Trim() }
    if (@($forced | Where-Object { $_ -ne 'CANARY' }).Count -gt 0) { throw 'header override did not select canary' }
    Write-Host "PASS: weighted stable=$stable canary=$canary; header override is deterministic"
} finally {
    & docker @compose down -v 2>$null
}
