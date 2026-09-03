$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Wait-Http([string]$Uri, [int]$Seconds = 30) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try { return (Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 2).Content.Trim() } catch { Start-Sleep -Milliseconds 500 }
    }
    throw "timeout waiting for $Uri"
}

docker compose -f ./docker-compose.yml down -v 2>$null
try {
    docker compose -f ./docker-compose.yml up -d
    if ($LASTEXITCODE -ne 0) { throw 'compose startup failed' }
    [void](Wait-Http 'http://127.0.0.1:8080')
    $responses = 1..12 | ForEach-Object { (Invoke-WebRequest 'http://127.0.0.1:8080' -UseBasicParsing).Content.Trim() }
    if ($responses -notcontains 'Hello from APP-1' -or $responses -notcontains 'Hello from APP-2') { throw 'round robin not observed' }
    docker compose -f ./docker-compose.yml pause app1
    if ($LASTEXITCODE -ne 0) { throw 'failed to pause app1' }
    $unhealthy = $false
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and -not $unhealthy) {
        Start-Sleep -Seconds 1
        $clusters = (Invoke-WebRequest 'http://127.0.0.1:9901/clusters' -UseBasicParsing).Content
        $unhealthy = ($clusters -match 'app1[\s\S]*failed_active_hc')
    }
    if (-not $unhealthy) { throw 'app1 was not marked failed_active_hc within 15 seconds' }
    $survivors = 1..8 | ForEach-Object { (Invoke-WebRequest 'http://127.0.0.1:8080' -UseBasicParsing).Content.Trim() }
    if (@($survivors | Where-Object { $_ -ne 'Hello from APP-2' }).Count -gt 0) { throw 'unhealthy app1 still received traffic' }
    docker compose -f ./docker-compose.yml unpause app1
    if ($LASTEXITCODE -ne 0) { throw 'failed to unpause app1' }
    $recovered = $false
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and -not $recovered) {
        Start-Sleep -Seconds 1
        $recovered = ((Invoke-WebRequest 'http://127.0.0.1:8080' -UseBasicParsing).Content.Trim() -eq 'Hello from APP-1')
    }
    if (-not $recovered) { throw 'app1 did not recover within 20 seconds' }
    Write-Host 'PASS: round robin, unhealthy removal, and recovery verified'
} finally {
    docker compose -f ./docker-compose.yml down -v 2>$null
}
