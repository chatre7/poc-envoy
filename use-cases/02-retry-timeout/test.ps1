$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$compose = @('compose', '-f', './docker-compose.yml')

function Wait-Ready {
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        & curl.exe -fsS http://127.0.0.1:8080/ok *> $null
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
    $headers = Join-Path ([System.IO.Path]::GetTempPath()) 'envoy-retry-headers.txt'
    $status = & curl.exe -sS -D $headers -o NUL -w '%{http_code}' http://127.0.0.1:8080/fail-once
    if ($status -ne '200') { throw "fail-once returned $status" }
    if (-not (Select-String -Path $headers -Pattern '^x-backend-attempt:\s*2' -CaseSensitive:$false)) { throw '5xx retry attempt header not observed' }
    $status = & curl.exe -sS -D $headers -o NUL -w '%{http_code}' http://127.0.0.1:8080/slow-once
    if ($status -ne '200') { throw "slow-once returned $status" }
    if (-not (Select-String -Path $headers -Pattern '^x-backend-attempt:\s*2' -CaseSensitive:$false)) { throw 'timeout retry attempt header not observed' }
    $status = & curl.exe -sS -o NUL -w '%{http_code}' --max-time 7 http://127.0.0.1:8080/always-slow
    if ($status -ne '504') { throw "always-slow returned $status instead of 504" }
    $stats = (Invoke-WebRequest 'http://127.0.0.1:9901/stats?filter=upstream_rq_retry' -UseBasicParsing).Content
    if ($stats -notmatch 'upstream_rq_retry:\s*[1-9]') { throw 'retry counter did not increase' }
    Write-Host 'PASS: 5xx retry, per-try timeout, and overall timeout verified'
} finally {
    & docker @compose down -v 2>$null
}
