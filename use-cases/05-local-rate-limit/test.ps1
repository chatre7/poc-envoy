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
    throw 'timeout waiting for Envoy admin'
}
& docker @compose down -v 2>$null
try {
    & docker @compose up -d
    if ($LASTEXITCODE -ne 0) { throw 'compose startup failed' }
    Wait-Ready
    $codes = 1..5 | ForEach-Object { & curl.exe -sS -o NUL -w '%{http_code}' http://127.0.0.1:8080/ }
    if (@($codes | Where-Object { $_ -eq '200' }).Count -ne 2) { throw "expected two allowed requests: $($codes -join ',')" }
    if (@($codes | Where-Object { $_ -eq '429' }).Count -lt 3) { throw "expected at least three limited requests: $($codes -join ',')" }
    $headers = (& curl.exe -sSI http://127.0.0.1:8080/) -join "`n"
    if ($headers -notmatch 'x-local-rate-limit:\s*true') { throw 'rate-limit response header missing' }
    Start-Sleep -Seconds 6
    $code = & curl.exe -sS -o NUL -w '%{http_code}' http://127.0.0.1:8080/
    if ($code -ne '200') { throw "token did not refill: $code" }
    Write-Host 'PASS: local token bucket limited burst and refilled'
} finally {
    & docker @compose down -v 2>$null
}
