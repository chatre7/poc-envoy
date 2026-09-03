$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$compose = @('compose', '-f', './docker-compose.yml')
function Wait-Uri([string]$Uri, [int]$Seconds = 45) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try { return Invoke-RestMethod -Uri $Uri -TimeoutSec 3 } catch { Start-Sleep -Seconds 1 }
    }
    throw "timeout waiting for $Uri"
}
& docker @compose down -v 2>$null
try {
    & docker @compose up -d
    if ($LASTEXITCODE -ne 0) { throw 'compose startup failed' }
    [void](Wait-Uri 'http://127.0.0.1:9901/ready')
    [void](Wait-Uri 'http://127.0.0.1:9090/-/ready')
    [void](Wait-Uri 'http://127.0.0.1:16686/')
    $requestId = '11111111-1111-4111-8111-111111111111'
    $tracedRequestId = '11111111-1111-9111-8111-111111111111'
    & curl.exe -fsS -H "x-request-id: $requestId" -H 'x-envoy-force-trace: true' http://127.0.0.1:8080/ *> $null
    Start-Sleep -Seconds 2
    $logs = (& docker @compose logs --no-color envoy) -join "`n"
    $line = ($logs -split "`n" | Where-Object { $_ -match $tracedRequestId -and $_ -match '\{' } | Select-Object -Last 1)
    if (-not $line) { throw 'request ID missing from Envoy access log' }
    $json = $line.Substring($line.IndexOf('{')) | ConvertFrom-Json
    foreach ($field in 'request_id','method','path','response_code','duration_ms') {
        if ($null -eq $json.$field) { throw "JSON access log missing $field" }
    }
    $metricFound = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not $metricFound) {
        try {
            $metrics = Invoke-RestMethod 'http://127.0.0.1:9090/api/v1/query?query=envoy_http_downstream_rq_total' -TimeoutSec 3
            $metricFound = ($metrics.status -eq 'success' -and $metrics.data.result.Count -gt 0)
        } catch {}
        if (-not $metricFound) { Start-Sleep -Seconds 1 }
    }
    if (-not $metricFound) { throw 'Envoy metric missing in Prometheus' }
    $traced = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not $traced) {
        try {
            $traces = Invoke-RestMethod 'http://127.0.0.1:16686/api/traces?service=envoy&limit=20' -TimeoutSec 3
            $traced = ($traces.data.Count -gt 0)
        } catch {}
        if (-not $traced) { Start-Sleep -Seconds 1 }
    }
    if (-not $traced) { throw 'Envoy trace missing in Jaeger' }
    Write-Host 'PASS: JSON log, Prometheus metric, and Jaeger trace verified'
} finally {
    & docker @compose down -v 2>$null
}
