$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$compose = @('compose', '-f', './docker-compose.yml')

function Wait-Ready {
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        & curl.exe -fsS http://127.0.0.1:8080/health *> $null
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
    $jobs = 1..8 | ForEach-Object {
        Start-Job -ScriptBlock { curl.exe -sS -o NUL -w '%{http_code}' --max-time 10 http://127.0.0.1:8080/hold }
    }
    $codes = @($jobs | Wait-Job -Timeout 15 | Receive-Job)
    $jobs | Remove-Job -Force
    if ($codes -notcontains '200') { throw "no successful request: $($codes -join ',')" }
    if ($codes -notcontains '503') { throw "circuit breaker did not reject a request: $($codes -join ',')" }
    $stats = (Invoke-WebRequest 'http://127.0.0.1:9901/stats?filter=upstream_rq_.*overflow' -UseBasicParsing).Content
    if ($stats -notmatch 'upstream_rq_(pending|active)_overflow:\s*[1-9]') { throw 'overflow counter did not increase' }
    Write-Host "PASS: circuit breaker returned 200 and 503; overflow counter increased"
} finally {
    Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
    & docker @compose down -v 2>$null
}
