#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up the multi-instance Sitecore XM Cloud environment.
    Generates TLS certificates, creates Docker networks, and updates the hosts file.

.DESCRIPTION
    This script must be run ONCE before starting any of the three environments.
    It prepares all shared infrastructure required by the parallel Docker setups.

.PARAMETER LicenseXmlPath
    Path to a valid Sitecore license.xml file.
#>
[CmdletBinding()]
Param (
    [Parameter(Mandatory = $false, HelpMessage = "Path to a valid Sitecore license.xml file.")]
    [string]$LicenseXmlPath
)

$ErrorActionPreference = "Stop"
$RootDir = $PSScriptRoot

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " Multi-Instance XM Cloud Setup" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

###############################################
# 1. Create Docker networks
###############################################

Write-Host "Creating shared Docker network..." -ForegroundColor Green

$netName = "traefik-shared"
$existing = docker network ls --filter "name=^${netName}$" --format "{{.Name}}" 2>$null
if ($existing -eq $netName) {
    Write-Host "  Network '$netName' already exists, skipping." -ForegroundColor Yellow
} else {
    docker network create -d nat $netName
    Write-Host "  Created network '$netName' (nat driver)." -ForegroundColor Green
}

###############################################
# 2. Generate TLS certificates
###############################################

Write-Host ""
Write-Host "Generating TLS certificates..." -ForegroundColor Green

$certsDir = Join-Path $RootDir "shared-traefik\traefik\certs"
if (-not (Test-Path $certsDir)) {
    New-Item -ItemType Directory -Path $certsDir -Force | Out-Null
}

Push-Location $certsDir
try {
    $mkcert = ".\mkcert.exe"
    if ($null -ne (Get-Command mkcert.exe -ErrorAction SilentlyContinue)) {
        $mkcert = "mkcert"
    }
    elseif (-not (Test-Path $mkcert)) {
        Write-Host "  Downloading mkcert..." -ForegroundColor Green
        Invoke-WebRequest "https://github.com/FiloSottile/mkcert/releases/download/v1.4.1/mkcert-v1.4.1-windows-amd64.exe" -UseBasicParsing -OutFile mkcert.exe
        if ((Get-FileHash mkcert.exe).Hash -ne "1BE92F598145F61CA67DD9F5C687DFEC17953548D013715FF54067B34D7C3246") {
            Remove-Item mkcert.exe -Force
            throw "Invalid mkcert.exe file"
        }
    }

    Write-Host "  Installing mkcert root CA..." -ForegroundColor Green
    & $mkcert -install

    # Wildcard cert for all CM subdomains (one/two/three.xmcloudcm.localhost)
    Write-Host "  Generating cert: *.xmcloudcm.localhost" -ForegroundColor Green
    & $mkcert "*.xmcloudcm.localhost"

    # Wildcard certs for each rendering host domain
    Write-Host "  Generating cert: *.xmc-one.localhost" -ForegroundColor Green
    & $mkcert "*.xmc-one.localhost"

    Write-Host "  Generating cert: *.xmc-two.localhost" -ForegroundColor Green
    & $mkcert "*.xmc-two.localhost"

    Write-Host "  Generating cert: *.xmc-three.localhost" -ForegroundColor Green
    & $mkcert "*.xmc-three.localhost"

    $caRoot = "$(& $mkcert -CAROOT)\rootCA.pem"
}
catch {
    Write-Error "Failed to generate TLS certificates: $_"
}
finally {
    Pop-Location
}

###############################################
# 3. Add Windows hosts file entries
###############################################

Write-Host ""
Write-Host "Adding Windows hosts file entries..." -ForegroundColor Green

# Import SitecoreDockerTools for Add-HostsEntry if available, else do it manually
$useDockerTools = $false
try {
    Import-Module SitecoreDockerTools -RequiredVersion 10.2.7 -ErrorAction Stop
    $useDockerTools = $true
} catch {
    Write-Host "  SitecoreDockerTools not found, adding hosts entries manually." -ForegroundColor Yellow
}

$hostnames = @(
    "one.xmcloudcm.localhost",
    "two.xmcloudcm.localhost",
    "three.xmcloudcm.localhost",
    "nextjs.xmc-one.localhost",
    "nextjs.xmc-two.localhost",
    "nextjs.xmc-three.localhost"
)

if ($useDockerTools) {
    foreach ($hostname in $hostnames) {
        Add-HostsEntry $hostname
        Write-Host "  Added: $hostname" -ForegroundColor Green
    }
} else {
    $hostsFile = "C:\Windows\System32\drivers\etc\hosts"
    $hostsContent = Get-Content $hostsFile -Raw
    foreach ($hostname in $hostnames) {
        if ($hostsContent -notmatch [regex]::Escape($hostname)) {
            Add-Content -Path $hostsFile -Value "127.0.0.1`t$hostname" -Encoding ASCII
            Write-Host "  Added: $hostname" -ForegroundColor Green
        } else {
            Write-Host "  Already present: $hostname" -ForegroundColor Yellow
        }
    }
}

###############################################
# 4. Summary
###############################################

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " Setup Complete!" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Hosts file entries added for:" -ForegroundColor White
foreach ($h in $hostnames) { Write-Host "  - $h" -ForegroundColor White }
Write-Host ""
Write-Host "Docker network:" -ForegroundColor White
Write-Host "  - $netName" -ForegroundColor White
Write-Host ""
Write-Host "TLS certificates generated in:" -ForegroundColor White
Write-Host "  $certsDir" -ForegroundColor White
Write-Host ""

if ($caRoot) {
    Write-Host ("#" * 75) -ForegroundColor Cyan
    Write-Host "To avoid HTTPS errors, set the NODE_EXTRA_CA_CERTS environment variable:" -ForegroundColor Cyan
    Write-Host "  setx NODE_EXTRA_CA_CERTS `"$caRoot`"" -ForegroundColor White
    Write-Host "Restart your terminal or VS Code for it to take effect." -ForegroundColor Cyan
    Write-Host ("#" * 75) -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Green
Write-Host "  1. Run init.ps1 for each codebase (if not already done)" -ForegroundColor White
Write-Host "  2. Run .\start-all.ps1 to start all three environments" -ForegroundColor White
Write-Host ""
