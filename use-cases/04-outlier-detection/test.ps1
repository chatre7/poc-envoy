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
    $failures = 0
    1..20 | ForEach-Object {
        $code = & curl.exe -sS -o NUL -w '%{http_code}' http://127.0.0.1:8080/
        if ($code -eq '503') { $failures++ }
    }
    if ($failures -lt 2) { throw "expected failing host responses, saw $failures" }
    $ejected = $false
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and -not $ejected) {
        $stats = (Invoke-WebRequest 'http://127.0.0.1:9901/stats?filter=ejections_total' -UseBasicParsing).Content
        $ejected = ($stats -match 'ejections_total:\s*[1-9]')
        if (-not $ejected) { Start-Sleep -Seconds 1 }
    }
    if (-not $ejected) { throw 'bad backend was not ejected' }
    $consecutiveGood = 0
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and $consecutiveGood -lt 10) {
        $response = ((& curl.exe -sS http://127.0.0.1:8080/ 2>$null) -join '').Trim()
        if ($LASTEXITCODE -eq 0 -and $response -eq 'GOOD') { $consecutiveGood++ } else { $consecutiveGood = 0 }
        if ($consecutiveGood -lt 10) { Start-Sleep -Milliseconds 200 }
    }
    if ($consecutiveGood -lt 10) { throw 'did not observe ten consecutive GOOD responses after ejection' }
    Write-Host 'PASS: consecutive 5xx caused passive host ejection'
} finally {
    & docker @compose down -v 2>$null
}
