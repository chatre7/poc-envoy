$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$compose = @('compose', '-f', './docker-compose.yml')
$api = 'http://127.0.0.1:8080/deployment/api'

function Get-State { Invoke-RestMethod "$api/state" -TimeoutSec 5 }
function Wait-Weight([int]$Expected, [int]$Seconds = 30) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $state = Get-State
            if ($state.weight -eq $Expected) { return $state }
        } catch {}
        Start-Sleep -Seconds 1
    }
    throw "timeout waiting for canary weight $Expected%"
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
function Invoke-Rollout([string]$Action, [int]$ExpectedWeight) {
    $body = @{ action = $Action; expected_weight = $ExpectedWeight } | ConvertTo-Json -Compress
    try {
        [void](Invoke-WebRequest -Method Post -Uri "$api/rollout" -ContentType application/json -Body $body -UseBasicParsing)
        return 200
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        throw
    }
}
function Step-Canary([int]$From) {
    $code = Invoke-Rollout 'advance' $From
    if ($code -ne 200) { throw "advance from $From% returned HTTP $code" }
}
function Send-CanarySamples([int]$Count) {
    # Deterministic canary samples through the x-canary override route.
    for ($i = 0; $i -lt $Count; $i++) { [void](& curl.exe -sS -o NUL -H 'x-canary: always' http://127.0.0.1:8080/ 2>$null) }
}
function Set-Fault([string]$Rate) {
    & docker @compose exec -T backend-canary python -c "import urllib.request; urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:9000/fault?rate=$Rate', method='POST'))"
    if ($LASTEXITCODE -ne 0) { throw 'failed to change canary fault rate' }
}

& ./reset.ps1
& docker @compose down -v 2>$null
try {
    & docker @compose up -d
    if ($LASTEXITCODE -ne 0) { throw 'compose startup failed' }
    Wait-Body 'VERSION-1'
    [void](Wait-Weight 0)
    $container = (& docker @compose ps -q envoy).Trim()
    $before = (& docker inspect --format '{{.Id}}' $container).Trim()

    Step-Canary 0
    [void](Wait-Weight 10)
    $stable = 0; $canary = 0
    for ($i = 0; $i -lt 200; $i++) {
        switch ((& curl.exe -fsS http://127.0.0.1:8080/).Trim()) {
            'VERSION-1' { $stable++ }
            'VERSION-2' { $canary++ }
        }
    }
    if ($canary -lt 5 -or $canary -gt 45) { throw "unexpected 10% split stable=$stable canary=$canary" }
    if ((& curl.exe -fsS -H 'x-canary: always' http://127.0.0.1:8080/).Trim() -ne 'VERSION-2') { throw 'x-canary override did not reach canary' }

    if ((Invoke-Rollout 'advance' 0) -ne 409) { throw 'stale expected_weight was not rejected' }

    Set-Fault '1'
    Send-CanarySamples 40
    $state = Wait-Weight 0
    if ($state.status -ne 'rolled_back') { throw "expected rolled_back, got $($state.status)" }
    if (-not ($state.events | Where-Object kind -eq 'auto_rollback')) { throw 'auto_rollback event missing' }
    Wait-Body 'VERSION-1'
    Set-Fault '0'

    Step-Canary 0
    [void](Wait-Weight 10)
    if ((Invoke-Rollout 'advance' 10) -ne 409) { throw 'advance without samples was not blocked' }
    foreach ($step in 10, 25, 50) {
        Send-CanarySamples 25
        Step-Canary $step
    }
    $state = Wait-Weight 100
    if ($state.status -ne 'promoted') { throw "expected promoted, got $($state.status)" }
    Wait-Body 'VERSION-2'

    & docker @compose exec -T envoy sh -c "cp /etc/envoy/xds/routes-invalid.yaml /etc/envoy/xds/routes-current.yaml.tmp && mv /etc/envoy/xds/routes-current.yaml.tmp /etc/envoy/xds/routes-current.yaml"
    if ($LASTEXITCODE -ne 0) { throw 'failed to publish invalid route fixture' }
    Start-Sleep -Seconds 3
    if ((& curl.exe -fsS http://127.0.0.1:8080/).Trim() -ne 'VERSION-2') { throw 'invalid update replaced last accepted route' }
    $stats = (Invoke-WebRequest 'http://127.0.0.1:9901/stats?filter=update_rejected' -UseBasicParsing).Content
    if ($stats -notmatch 'update_rejected:\s*[1-9]') { throw 'RDS rejection counter did not increase' }

    $after = (& docker inspect --format '{{.Id}}' $container).Trim()
    if ($before -ne $after) { throw 'Envoy container restarted during RDS updates' }
    Write-Host "PASS: canary 10% split stable=$stable canary=$canary, auto-rollback on 5xx, gated promotion to 100% without restarting Envoy"
} finally {
    & ./reset.ps1
    & docker @compose down -v 2>$null
}
