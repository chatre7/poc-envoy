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
    $missing = & curl.exe -sS -o NUL -w '%{http_code}' http://127.0.0.1:8080/
    $broken = & curl.exe -sS -o NUL -w '%{http_code}' -H 'Authorization: Bearer broken' http://127.0.0.1:8080/
    $viewer = (Get-Content -Raw fixtures/unauthorized.token).Trim()
    $forbidden = & curl.exe -sS -o NUL -w '%{http_code}' -H "Authorization: Bearer $viewer" http://127.0.0.1:8080/
    $admin = (Get-Content -Raw fixtures/authorized.token).Trim()
    $bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) 'envoy-jwt-body.txt'
    $allowed = & curl.exe -sS -o $bodyFile -w '%{http_code}' -H "Authorization: Bearer $admin" http://127.0.0.1:8080/
    if ($missing -ne '401' -or $broken -ne '401' -or $forbidden -ne '403' -or $allowed -ne '200') {
        throw "unexpected matrix missing=$missing broken=$broken viewer=$forbidden admin=$allowed"
    }
    if ((Get-Content -Raw $bodyFile).Trim() -ne 'AUTHORIZED') { throw 'authorized response body mismatch' }
    Write-Host 'PASS: JWT authentication returned 401; RBAC returned 403/200 by role'
} finally {
    & docker @compose down -v 2>$null
}
