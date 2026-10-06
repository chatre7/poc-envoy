# Pre-pull every image the labs use. Docker Hub limits anonymous pulls per IP,
# so images already present are skipped and failed pulls fall back to
# mirror.gcr.io, then are re-tagged to the name the Compose files expect.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$mirror = if ($env:MIRROR) { $env:MIRROR } else { 'mirror.gcr.io' }

$files = @(Get-ChildItem -LiteralPath (Join-Path $root 'use-cases') -Recurse -Filter docker-compose.yml) +
    @(Get-Item -LiteralPath (Join-Path $root 'docker-compose.yml'))
$images = $files | Select-String -Pattern '^\s*image:\s*(\S+)' |
    ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique

$failed = $false
foreach ($image in $images) {
    docker image inspect $image *> $null
    if ($LASTEXITCODE -eq 0) { Write-Host "present  $image"; continue }
    docker pull -q $image *> $null
    if ($LASTEXITCODE -eq 0) { Write-Host "pulled   $image"; continue }
    $source = if ($image.Contains('/')) { "$mirror/$image" } else { "$mirror/library/$image" }
    docker pull -q $source *> $null
    if ($LASTEXITCODE -eq 0) {
        docker tag $source $image
        Write-Host "mirrored $image (from $source)"
    } else {
        Write-Error "FAILED   $image" -ErrorAction Continue
        $failed = $true
    }
}
if ($failed) { throw "Some images could not be pulled. Run 'docker login' or retry later." }
Write-Host 'All lab images are available locally.'
