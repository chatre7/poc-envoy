$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$compose = @('compose', '-f', './docker-compose.yml')
function Invoke-TlsRequest([string]$Certificate = '', [string]$Key = '') {
    $openSslArgs = @('s_client', '-connect', '127.0.0.1:8080', '-CAfile', 'certs/ca.crt', '-quiet')
    if ($Certificate) { $openSslArgs += @('-cert', $Certificate, '-key', $Key) }
    $request = "GET / HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n"
    return (($request | & openssl @openSslArgs 2>&1) -join "`n")
}
& ./generate-certs.ps1
& docker @compose down -v 2>$null
try {
    & docker @compose up -d
    if ($LASTEXITCODE -ne 0) { throw 'compose startup failed' }
    $deadline = (Get-Date).AddSeconds(30)
    do {
        & curl.exe -fsS http://127.0.0.1:9901/ready *> $null
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    if ($LASTEXITCODE -ne 0) { throw 'timeout waiting for Envoy' }

    & curl.exe -fsS --max-time 3 http://127.0.0.1:8080/ *> $null
    if ($LASTEXITCODE -eq 0) { throw 'plaintext unexpectedly succeeded' }
    if ((Invoke-TlsRequest) -match 'mTLS OK') { throw 'request without client certificate unexpectedly succeeded' }
    if ((Invoke-TlsRequest 'certs/untrusted-client.crt' 'certs/untrusted-client.key') -match 'mTLS OK') { throw 'untrusted client unexpectedly succeeded' }
    $response = Invoke-TlsRequest 'certs/client.crt' 'certs/client.key'
    if ($response -notmatch 'mTLS OK') { throw "trusted client TLS request failed: $response" }
    Write-Host 'PASS: plaintext, missing, and untrusted clients rejected; trusted mTLS client accepted'
} finally {
    & docker @compose down -v 2>$null
}
