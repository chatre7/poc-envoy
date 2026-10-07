param([switch]$Runtime)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$useCases = Join-Path $root 'use-cases'
$labs = if (Test-Path -LiteralPath $useCases) {
    @(Get-ChildItem -LiteralPath $useCases -Directory |
        Where-Object Name -Match '^\d{2}-' |
        Sort-Object Name)
} else {
    @()
}

if ($labs.Count -ne 13) {
    throw "expected 13 labs, found $($labs.Count)"
}

$failures = [System.Collections.Generic.List[string]]::new()
try {
    foreach ($lab in $labs) {
        Write-Host "==> $($lab.Name)"
        Push-Location $lab.FullName
        try {
            foreach ($required in @('docker-compose.yml', 'envoy.yaml', 'README.md', 'test.ps1', 'test.sh')) {
                if (-not (Test-Path -LiteralPath $required)) {
                    $failures.Add("missing ${required}: $($lab.Name)")
                }
            }
            if ($failures | Where-Object { $_ -like "*: $($lab.Name)" }) { continue }

            docker compose -f ./docker-compose.yml config --quiet
            if ($LASTEXITCODE -ne 0) {
                $failures.Add("compose validation failed: $($lab.Name)")
                continue
            }

            if (Test-Path -LiteralPath './generate-certs.ps1') {
                & ./generate-certs.ps1
            }

            docker compose -f ./docker-compose.yml run --rm --no-deps envoy --mode validate -c /etc/envoy/envoy.yaml
            if ($LASTEXITCODE -ne 0) {
                $failures.Add("envoy validation failed: $($lab.Name)")
                continue
            }

            if ($Runtime) {
                & ./test.ps1
            }
        } catch {
            $failures.Add("$($lab.Name): $($_.Exception.Message)")
            if ($Runtime) { break }
        } finally {
            Pop-Location
        }
    }
} finally {
    if ($Runtime) {
        foreach ($lab in $labs) {
            docker compose -f (Join-Path $lab.FullName 'docker-compose.yml') down -v 2>$null
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "Validated $($labs.Count) Envoy labs."
