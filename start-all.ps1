<#
.SYNOPSIS
    Starts all three Sitecore XM Cloud environments with a shared Traefik ingress.

.DESCRIPTION
    1. Ensures Docker networks exist
    2. Starts the shared Traefik reverse proxy
    3. Starts each codebase's containers in parallel
    4. Waits for all CM instances to become healthy

.PARAMETER Codebases
    Array of codebase folder names to start. Defaults to all three.
#>
[CmdletBinding()]
Param (
    [Parameter(Mandatory = $false)]
    [string[]]$Codebases = @("codebase-1", "codebase-2", "codebase-3")
)

$ErrorActionPreference = "Stop"
$RootDir = $PSScriptRoot

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " Starting Multi-Instance XM Cloud" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

###############################################
# 1. Verify Docker networks exist
###############################################

$netName = "traefik-shared"
$existing = docker network ls --filter "name=^${netName}$" --format "{{.Name}}" 2>$null
if ($existing -ne $netName) {
    Write-Host "Creating Docker network '$netName' (nat driver)..." -ForegroundColor Yellow
    docker network create -d nat $netName
} else {
    Write-Host "Docker network '$netName' exists." -ForegroundColor Green
}

###############################################
# 2. Start shared Traefik
###############################################

Write-Host "Starting shared Traefik reverse proxy..." -ForegroundColor Green
Push-Location (Join-Path $RootDir "shared-traefik")
docker compose up -d
Pop-Location

# Wait for Traefik to be healthy
Write-Host "Waiting for Traefik to become healthy..." -ForegroundColor Green
$traefikReady = $false
$startTime = Get-Date
do {
    Start-Sleep -Milliseconds 500
    try {
        $response = Invoke-WebRequest "http://localhost:8079/api/overview" -UseBasicParsing -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 200) {
            $traefikReady = $true
        }
    } catch { }
} while (-not $traefikReady -and $startTime.AddSeconds(60) -gt (Get-Date))

if (-not $traefikReady) {
    Write-Warning "Traefik did not become healthy within 60 seconds. Continuing anyway..."
} else {
    Write-Host "Traefik is ready." -ForegroundColor Green
}

###############################################
# 3. Build and start each codebase
###############################################

$cmHosts = @{
    "codebase-1" = "one.xmcloudcm.localhost"
    "codebase-2" = "two.xmcloudcm.localhost"
    "codebase-3" = "three.xmcloudcm.localhost"
}

$projectNames = @{
    "codebase-1" = "xmc-one"
    "codebase-2" = "xmc-two"
    "codebase-3" = "xmc-three"
}

foreach ($codebase in $Codebases) {
    $containerDir = Join-Path $RootDir "$codebase\local-containers"

    if (-not (Test-Path $containerDir)) {
        Write-Warning "Codebase directory not found: $containerDir. Skipping."
        continue
    }

    Write-Host ""
    Write-Host "--- Starting $codebase ---" -ForegroundColor Cyan

    Push-Location $containerDir

    Write-Host "  Building containers..." -ForegroundColor Green
    docker compose build
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Container build failed for $codebase."
    }

    Write-Host "  Starting containers..." -ForegroundColor Green
    docker compose up -d
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Container start failed for $codebase."
    }

    Pop-Location
}

###############################################
# 4. Wait for CM instances
###############################################

Write-Host ""
Write-Host "Waiting for CM instances to become available via Traefik..." -ForegroundColor Green

foreach ($codebase in $Codebases) {
    $projectName = $projectNames[$codebase]
    $cmHost = $cmHosts[$codebase]
    $routerName = "$projectName-cm-secure"

    Write-Host "  Checking $codebase ($cmHost)..." -ForegroundColor White
    $startTime = Get-Date
    $isReady = $false
    do {
        Start-Sleep -Milliseconds 500
        try {
            $status = Invoke-RestMethod "http://localhost:8079/api/http/routers/${routerName}@docker" -ErrorAction SilentlyContinue
            if ($status.status -eq "enabled") {
                $isReady = $true
            }
        } catch { }
    } while (-not $isReady -and $startTime.AddSeconds(120) -gt (Get-Date))

    if ($isReady) {
        Write-Host "  [OK] $cmHost is available." -ForegroundColor Green
    } else {
        Write-Warning "  [TIMEOUT] $cmHost did not become available within 120 seconds."
    }
}

###############################################
# 5. Summary
###############################################

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " All environments started!" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "CM Instances:" -ForegroundColor White
foreach ($codebase in $Codebases) {
    $cmHost = $cmHosts[$codebase]
    Write-Host "  $codebase  ->  https://$cmHost/sitecore/" -ForegroundColor Green
}
Write-Host ""
Write-Host "Rendering Hosts:" -ForegroundColor White
Write-Host "  codebase-1  ->  https://nextjs.xmc-one.localhost/" -ForegroundColor Green
Write-Host "  codebase-2  ->  https://nextjs.xmc-two.localhost/" -ForegroundColor Green
Write-Host "  codebase-3  ->  https://nextjs.xmc-three.localhost/" -ForegroundColor Green
Write-Host ""
Write-Host "Traefik Dashboard: http://localhost:8079/dashboard/" -ForegroundColor White
Write-Host ""
