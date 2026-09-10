$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$compose = @('compose', '-f', './docker-compose.yml')

function Wait-Uri([string]$Uri, [int]$Seconds = 60) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try { return Invoke-RestMethod -Uri $Uri -TimeoutSec 3 } catch { Start-Sleep -Seconds 1 }
    }
    throw "timeout waiting for $Uri"
}

function Wait-Body([string]$Expected, [int]$Seconds = 45) {
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

function Wait-State([string]$Expected, [switch]$RequireTelemetry, [int]$Seconds = 45) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $state = Invoke-RestMethod http://127.0.0.1:8080/deployment/api/state -TimeoutSec 6
            $telemetryReady = -not $RequireTelemetry -or (
                $state.telemetry.prometheus.healthy -and
                $state.telemetry.grafana.healthy -and
                $state.telemetry.jaeger.healthy -and
                $state.telemetry.alertmanager.healthy
            )
            if ($state.active -eq $Expected -and $telemetryReady) { return $state }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    throw "timeout waiting for active deployment $Expected"
}

function Wait-FailoverRequired([bool]$Expected, [int]$Seconds = 45) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $state = Invoke-RestMethod http://127.0.0.1:8080/deployment/api/state -TimeoutSec 6
            if ($state.failover.required -eq $Expected) { return $state }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    throw "timeout waiting for failover.required=$Expected"
}

function Wait-PrometheusAlert([string]$ExpectedState, [int]$Seconds = 45) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-RestMethod http://127.0.0.1:9090/api/v1/alerts -TimeoutSec 3
            $alert = $response.data.alerts | Where-Object { $_.labels.alertname -eq 'ActiveReleaseUnhealthy' -and $_.state -eq $ExpectedState } | Select-Object -First 1
            if ($alert) { return $alert }
        } catch {}
        Start-Sleep -Milliseconds 250
    }
    throw "timeout waiting for ActiveReleaseUnhealthy state $ExpectedState"
}

function Wait-PrometheusAlertCleared([int]$Seconds = 45) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-RestMethod http://127.0.0.1:9090/api/v1/alerts -TimeoutSec 3
            $alert = $response.data.alerts | Where-Object { $_.labels.alertname -eq 'ActiveReleaseUnhealthy' } | Select-Object -First 1
            if (-not $alert) { return }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    throw 'timeout waiting for ActiveReleaseUnhealthy to resolve'
}

function Wait-WebhookAlert([string]$ExpectedStatus, [int]$Seconds = 45) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $state = Invoke-RestMethod http://127.0.0.1:8080/deployment/api/state -TimeoutSec 6
            $alert = $state.alertmanager.alerts | Where-Object { $_.alertname -eq 'ActiveReleaseUnhealthy' -and $_.status -eq $ExpectedStatus } | Select-Object -First 1
            if ($alert) { return $alert }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    throw "timeout waiting for Alertmanager webhook status $ExpectedStatus"
}

function Switch-Traffic([string]$Target, [string]$ExpectedActive) {
    $body = @{ target = $Target; expected_active = $ExpectedActive } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8080/deployment/api/switch -ContentType application/json -Body $body
}

function Publish-InvalidRoute {
    & docker @compose exec -T envoy sh -c "cp /etc/envoy/xds/routes-invalid.yaml /etc/envoy/xds/routes-current.yaml.tmp && mv /etc/envoy/xds/routes-current.yaml.tmp /etc/envoy/xds/routes-current.yaml"
    if ($LASTEXITCODE -ne 0) { throw 'failed to publish invalid route fixture' }
}

& ./reset.ps1
& docker @compose down -v 2>$null
try {
    & docker @compose up -d
    if ($LASTEXITCODE -ne 0) { throw 'compose startup failed' }

    [void](Wait-Uri 'http://127.0.0.1:9901/ready')
    [void](Wait-Uri 'http://127.0.0.1:9090/-/ready')
    [void](Wait-Uri 'http://127.0.0.1:9093/-/ready')
    [void](Wait-Uri 'http://127.0.0.1:3000/api/health')
    [void](Wait-Uri 'http://127.0.0.1:16686/')
    Wait-Body 'VERSION-1'
    [void](Wait-State 'blue' -RequireTelemetry)

    $metricsText = (Invoke-WebRequest http://127.0.0.1:8080/deployment/metrics -UseBasicParsing).Content
    foreach ($metric in 'release_active','release_backend_healthy','release_failover_required','release_standby_ready','release_switch_total') {
        if ($metricsText -notmatch $metric) { throw "controller metric missing: $metric" }
    }
    $rules = (Invoke-WebRequest http://127.0.0.1:9090/api/v1/rules -UseBasicParsing).Content
    if ($rules -notmatch 'ActiveReleaseUnhealthy') { throw 'failover alert rules were not loaded' }
    $blockedStatus = & curl.exe -sS -o NUL -w '%{http_code}' -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:8080/deployment/api/alerts
    if ($blockedStatus -ne '404') { throw 'public Alertmanager webhook path is not blocked' }

    $container = (& docker @compose ps -q envoy).Trim()
    $before = (& docker inspect --format '{{.Id}}' $container).Trim()

    $requestId = '11111111-1111-4111-8111-111111111111'
    $tracedRequestIdPattern = '11111111-1111-[0-9a-f]111-8111-111111111111'
    & curl.exe -fsS -H "x-request-id: $requestId" -H 'x-envoy-force-trace: true' http://127.0.0.1:8080/ *> $null
    $line = $null
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and -not $line) {
        $logs = (& docker @compose logs --no-color envoy 2>&1) -join "`n"
        $line = ($logs -split "`n" | Where-Object { $_ -match $tracedRequestIdPattern -and $_ -match '\{' } | Select-Object -Last 1)
        if (-not $line) { Start-Sleep -Milliseconds 250 }
    }
    if (-not $line) { throw 'request ID missing from Envoy JSON access log' }
    $json = $line.Substring($line.IndexOf('{')) | ConvertFrom-Json
    foreach ($field in 'request_id','method','path','response_code','duration_ms','upstream_cluster') {
        if ($null -eq $json.$field) { throw "JSON access log missing $field" }
    }

    $metricFound = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not $metricFound) {
        try {
            $metrics = Invoke-RestMethod 'http://127.0.0.1:9090/api/v1/query?query=release_active' -TimeoutSec 3
            $metricFound = ($metrics.status -eq 'success' -and $metrics.data.result.Count -gt 0)
        } catch {}
        if (-not $metricFound) { Start-Sleep -Seconds 1 }
    }
    if (-not $metricFound) { throw 'release metrics missing in Prometheus' }

    $dashboard = Wait-Uri 'http://127.0.0.1:3000/api/search?query=Failover'
    if (-not ($dashboard | Where-Object uid -eq 'envoy-production')) { throw 'provisioned failover dashboard missing' }

    $traced = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not $traced) {
        try {
            $traces = Invoke-RestMethod 'http://127.0.0.1:16686/api/traces?service=production-blue-green-stack&limit=20' -TimeoutSec 3
            $traced = ($traces.data.Count -gt 0)
        } catch {}
        if (-not $traced) { Start-Sleep -Seconds 1 }
    }
    if (-not $traced) { throw 'Envoy trace missing in Jaeger' }

    & docker @compose stop backend-v1
    if ($LASTEXITCODE -ne 0) { throw 'failed to stop active Blue backend' }
    [void](Wait-PrometheusAlert 'pending')
    $failedState = Wait-FailoverRequired $true
    if ($failedState.active -ne 'blue' -or $failedState.backends.green.healthy -ne $true) { throw 'failover preconditions not reported correctly' }
    $failureStatus = & curl.exe -sS -o NUL -w '%{http_code}' http://127.0.0.1:8080/
    if ($failureStatus -ne '503') { throw "expected HTTP 503 while active Blue is unavailable, received $failureStatus" }

    [void](Wait-PrometheusAlert 'firing')
    [void](Wait-WebhookAlert 'firing')

    [void](Switch-Traffic 'green' 'blue')
    Wait-Body 'VERSION-2'
    [void](Wait-State 'green')
    [void](Wait-FailoverRequired $false)
    Wait-PrometheusAlertCleared
    [void](Wait-WebhookAlert 'resolved')

    $after = (& docker inspect --format '{{.Id}}' $container).Trim()
    if ($before -ne $after) { throw 'Envoy container restarted during failover' }

    & docker @compose start backend-v1
    if ($LASTEXITCODE -ne 0) { throw 'failed to restore Blue backend' }
    $deadline = (Get-Date).AddSeconds(45)
    do {
        $restored = Wait-State 'green'
        if ($restored.backends.blue.healthy) { break }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    if (-not $restored.backends.blue.healthy) { throw 'Blue backend did not recover' }

    Publish-InvalidRoute
    Start-Sleep -Seconds 3
    if ((& curl.exe -fsS http://127.0.0.1:8080/).Trim() -ne 'VERSION-2') { throw 'invalid update replaced last accepted route' }
    $stats = (Invoke-WebRequest 'http://127.0.0.1:9901/stats?filter=update_rejected' -UseBasicParsing).Content
    if ($stats -notmatch 'update_rejected:\s*[1-9]') { throw 'RDS rejection counter did not increase' }

    [void](Switch-Traffic 'blue' 'green')
    Wait-Body 'VERSION-1'
    [void](Wait-State 'blue')
    Write-Host 'PASS: failover detection, Pending/Firing/Resolved alerts, webhook delivery, manual recovery, telemetry, rejection safety, and rollback verified'
} finally {
    & docker @compose start backend-v1 2>$null
    & ./reset.ps1
    & docker @compose down -v 2>$null
}
