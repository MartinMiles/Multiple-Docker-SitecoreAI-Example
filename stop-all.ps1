<#
.SYNOPSIS
    Stops all three Sitecore XM Cloud environments and the shared Traefik.

.PARAMETER Codebases
    Array of codebase folder names to stop. Defaults to all three.

.PARAMETER KeepTraefik
    If set, keeps the shared Traefik running (useful when restarting individual codebases).
#>
[CmdletBinding()]
Param (
    [Parameter(Mandatory = $false)]
    [string[]]$Codebases = @("codebase-1", "codebase-2", "codebase-3"),

    [Parameter(Mandatory = $false)]
    [switch]$KeepTraefik
)

$ErrorActionPreference = "Stop"
$RootDir = $PSScriptRoot

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " Stopping Multi-Instance XM Cloud" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

###############################################
# 1. Stop each codebase
###############################################

foreach ($codebase in $Codebases) {
    $containerDir = Join-Path $RootDir "$codebase\local-containers"

    if (-not (Test-Path $containerDir)) {
        Write-Warning "Codebase directory not found: $containerDir. Skipping."
        continue
    }

    Write-Host "Stopping $codebase..." -ForegroundColor Yellow
    Push-Location $containerDir
    docker compose down
    Pop-Location
    Write-Host "  $codebase stopped." -ForegroundColor Green
}

###############################################
# 2. Stop shared Traefik
###############################################

if (-not $KeepTraefik) {
    Write-Host ""
    Write-Host "Stopping shared Traefik..." -ForegroundColor Yellow
    Push-Location (Join-Path $RootDir "shared-traefik")
    docker compose down
    Pop-Location
    Write-Host "  Shared Traefik stopped." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Keeping shared Traefik running (-KeepTraefik flag)." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "All environments stopped." -ForegroundColor Green
Write-Host ""
