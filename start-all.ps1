<#
.SYNOPSIS
    Starts all Sitecore XM Cloud environments with a shared Traefik ingress.

.DESCRIPTION
    1. Ensures traefik-shared Docker network exists (nat driver)
    2. Ensures TLS certificates are generated for all instances
    3. Starts the shared Traefik reverse proxy
    4. Builds and starts each codebase's containers
    5. Waits for all CM instances to become healthy

.PARAMETER Codebases
    Array of codebase folder names to start. Defaults to all codebase-* folders found.
#>
[CmdletBinding()]
Param (
    [Parameter(Mandatory = $false)]
    [string[]]$Codebases
)

$ErrorActionPreference = "Stop"
$RootDir = $PSScriptRoot

# Auto-discover codebases if not specified
if (-not $Codebases) {
    $Codebases = Get-ChildItem -Path $RootDir -Directory -Filter "codebase-*" | Select-Object -ExpandProperty Name
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " Starting Multi-Instance XM Cloud" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Codebases: $($Codebases -join ', ')"
Write-Host ""

###############################################
# 1. Ensure Docker network exists
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
# 2. Ensure TLS certificates exist
###############################################

$certsDir = Join-Path $RootDir "shared-traefik\traefik\certs"
if (-not (Test-Path $certsDir)) {
    New-Item -ItemType Directory -Path $certsDir -Force | Out-Null
}

# Find or download mkcert
$mkcert = $null
if ($null -ne (Get-Command mkcert.exe -ErrorAction SilentlyContinue)) {
    $mkcert = "mkcert"
} elseif (Test-Path (Join-Path $certsDir "mkcert.exe")) {
    $mkcert = Join-Path $certsDir "mkcert.exe"
} else {
    # Check per-codebase certs dirs for mkcert
    foreach ($cb in $Codebases) {
        $cbMkcert = Join-Path $RootDir "$cb\local-containers\docker\traefik\certs\mkcert.exe"
        if (Test-Path $cbMkcert) {
            $mkcert = $cbMkcert
            break
        }
    }
}

# Collect all instance names from .env files
$instances = @()
foreach ($cb in $Codebases) {
    $envFile = Join-Path $RootDir "$cb\local-containers\.env"
    if (Test-Path $envFile) {
        $envContent = Get-Content $envFile
        $projName = ($envContent | Where-Object { $_ -imatch "^COMPOSE_PROJECT_NAME=.+" }).Split("=")[1]
        $cmHost = ($envContent | Where-Object { $_ -imatch "^CM_HOST=.+" }).Split("=")[1]
        $renderingHost = ($envContent | Where-Object { $_ -imatch "^RENDERING_HOST_NEXTJS=.+" }).Split("=")[1]
        # Extract instance name from COMPOSE_PROJECT_NAME (xmc-one -> one)
        $instanceName = $projName -replace '^xmc-', ''
        $instances += @{
            Codebase = $cb
            ProjectName = $projName
            InstanceName = $instanceName
            CmHost = $cmHost
            RenderingHost = $renderingHost
        }
    }
}

# Generate missing certificates
$needsCerts = $false
$wildcardCmCert = Join-Path $certsDir "_wildcard.xmcloudcm.localhost.pem"
if (-not (Test-Path $wildcardCmCert)) { $needsCerts = $true }
foreach ($inst in $instances) {
    $renderingCert = Join-Path $certsDir "_wildcard.xmc-$($inst.InstanceName).localhost.pem"
    if (-not (Test-Path $renderingCert)) { $needsCerts = $true }
}

if ($needsCerts) {
    if (-not $mkcert) {
        Write-Host "Downloading mkcert..." -ForegroundColor Yellow
        Invoke-WebRequest "https://github.com/FiloSottile/mkcert/releases/download/v1.4.1/mkcert-v1.4.1-windows-amd64.exe" -UseBasicParsing -OutFile (Join-Path $certsDir "mkcert.exe")
        $mkcert = Join-Path $certsDir "mkcert.exe"
    }

    Push-Location $certsDir
    try {
        $ErrorActionPreference = "Continue"
        & $mkcert -install *>&1 | Out-Null

        if (-not (Test-Path $wildcardCmCert)) {
            Write-Host "Generating cert: *.xmcloudcm.localhost" -ForegroundColor Yellow
            & $mkcert "*.xmcloudcm.localhost" *>&1 | Where-Object { $_ -match "certificate|Created" } | Write-Host
        }

        foreach ($inst in $instances) {
            $renderingCert = Join-Path $certsDir "_wildcard.xmc-$($inst.InstanceName).localhost.pem"
            if (-not (Test-Path $renderingCert)) {
                Write-Host "Generating cert: *.xmc-$($inst.InstanceName).localhost" -ForegroundColor Yellow
                & $mkcert "*.xmc-$($inst.InstanceName).localhost" *>&1 | Where-Object { $_ -match "certificate|Created" } | Write-Host
            }
        }
        $ErrorActionPreference = "Stop"
    } finally {
        Pop-Location
    }
    Write-Host "TLS certificates ready." -ForegroundColor Green
} else {
    Write-Host "TLS certificates exist." -ForegroundColor Green
}

###############################################
# 3. Start shared Traefik
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
# 4. Build and start each codebase
###############################################

foreach ($inst in $instances) {
    $containerDir = Join-Path $RootDir "$($inst.Codebase)\local-containers"

    Write-Host ""
    Write-Host "--- Starting $($inst.Codebase) ($($inst.ProjectName)) ---" -ForegroundColor Cyan

    Push-Location $containerDir

    Write-Host "  Building containers..." -ForegroundColor Green
    docker compose build
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Container build failed for $($inst.Codebase)."
    }

    Write-Host "  Starting containers..." -ForegroundColor Green
    docker compose up -d
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Container start failed for $($inst.Codebase)."
    }

    Pop-Location
}

###############################################
# 5. Wait for CM instances
###############################################

Write-Host ""
Write-Host "Waiting for CM instances to become available via Traefik..." -ForegroundColor Green

foreach ($inst in $instances) {
    $routerName = "$($inst.ProjectName)-cm-secure"
    Write-Host "  Checking $($inst.Codebase) ($($inst.CmHost))..." -ForegroundColor White
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
        Write-Host "  [OK] $($inst.CmHost) is available." -ForegroundColor Green
    } else {
        Write-Warning "  [TIMEOUT] $($inst.CmHost) did not become available within 120 seconds."
    }
}

###############################################
# 6. Summary
###############################################

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " All environments started!" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "CM Instances:" -ForegroundColor White
foreach ($inst in $instances) {
    Write-Host "  $($inst.Codebase)  ->  https://$($inst.CmHost)/sitecore/" -ForegroundColor Green
}
Write-Host ""
Write-Host "Rendering Hosts:" -ForegroundColor White
foreach ($inst in $instances) {
    Write-Host "  $($inst.Codebase)  ->  https://$($inst.RenderingHost)/" -ForegroundColor Green
}
Write-Host ""
Write-Host "Traefik Dashboard: http://localhost:8079/dashboard/" -ForegroundColor White
Write-Host ""
