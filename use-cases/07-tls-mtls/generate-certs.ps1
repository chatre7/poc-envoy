$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$certDir = Join-Path $PSScriptRoot 'certs'
New-Item -ItemType Directory -Force -Path $certDir | Out-Null
Get-ChildItem -LiteralPath $certDir -File | Where-Object Name -ne '.gitkeep' | Remove-Item -Force

function Invoke-OpenSSL([string[]]$OpenSslArgs) {
    & openssl @OpenSslArgs
    if ($LASTEXITCODE -ne 0) { throw "openssl failed: $($OpenSslArgs -join ' ')" }
}

Invoke-OpenSSL @('req','-x509','-newkey','rsa:2048','-nodes','-sha256','-days','1','-subj','/CN=Envoy Lab CA','-keyout','certs/ca.key','-out','certs/ca.crt','-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign')
Invoke-OpenSSL @('req','-newkey','rsa:2048','-nodes','-sha256','-subj','/CN=localhost','-keyout','certs/server.key','-out','certs/server.csr')
Set-Content -LiteralPath 'certs/server.ext' -Value "subjectAltName=DNS:localhost,IP:127.0.0.1`nextendedKeyUsage=serverAuth`nkeyUsage=digitalSignature,keyEncipherment"
Invoke-OpenSSL @('x509','-req','-in','certs/server.csr','-CA','certs/ca.crt','-CAkey','certs/ca.key','-CAcreateserial','-days','1','-sha256','-extfile','certs/server.ext','-out','certs/server.crt')
Invoke-OpenSSL @('req','-newkey','rsa:2048','-nodes','-sha256','-subj','/CN=trusted-client','-keyout','certs/client.key','-out','certs/client.csr')
Set-Content -LiteralPath 'certs/client.ext' -Value "extendedKeyUsage=clientAuth`nkeyUsage=digitalSignature"
Invoke-OpenSSL @('x509','-req','-in','certs/client.csr','-CA','certs/ca.crt','-CAkey','certs/ca.key','-CAcreateserial','-days','1','-sha256','-extfile','certs/client.ext','-out','certs/client.crt')
Invoke-OpenSSL @('pkcs12','-export','-passout','pass:','-inkey','certs/client.key','-in','certs/client.crt','-certfile','certs/ca.crt','-out','certs/client.p12')
Invoke-OpenSSL @('req','-x509','-newkey','rsa:2048','-nodes','-sha256','-days','1','-subj','/CN=Untrusted Lab CA','-keyout','certs/untrusted-ca.key','-out','certs/untrusted-ca.crt','-addext','basicConstraints=critical,CA:TRUE')
Invoke-OpenSSL @('req','-newkey','rsa:2048','-nodes','-sha256','-subj','/CN=untrusted-client','-keyout','certs/untrusted-client.key','-out','certs/untrusted-client.csr')
Invoke-OpenSSL @('x509','-req','-in','certs/untrusted-client.csr','-CA','certs/untrusted-ca.crt','-CAkey','certs/untrusted-ca.key','-CAcreateserial','-days','1','-sha256','-extfile','certs/client.ext','-out','certs/untrusted-client.crt')
Invoke-OpenSSL @('pkcs12','-export','-passout','pass:','-inkey','certs/untrusted-client.key','-in','certs/untrusted-client.crt','-certfile','certs/untrusted-ca.crt','-out','certs/untrusted-client.p12')
Remove-Item -Force certs/*.csr, certs/*.ext, certs/*.srl
Write-Host 'Generated local-only certificates in certs/'
