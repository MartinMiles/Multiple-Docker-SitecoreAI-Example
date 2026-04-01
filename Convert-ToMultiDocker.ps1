<#
.SYNOPSIS
    Converts a vanilla xmcloud-starter-js codebase into a multi-docker compatible instance.

.DESCRIPTION
    Run this script against any fresh clone of https://github.com/Sitecore/xmcloud-starter-js
    to make it work alongside other instances under a shared Traefik reverse proxy.

    What it does:
    - Parameterizes Traefik label router names with ${COMPOSE_PROJECT_NAME} in docker-compose files
    - Makes MSSQL and Solr host ports configurable via .env
    - Creates docker-compose.multi.yml (disables local Traefik, joins shared network)
    - Updates .env with unique project name, hostnames, ports, and site name
    - Updates sitecore.config.ts for local Docker API mode
    - Updates up.ps1 for dynamic Traefik router checks
    - Generates a unique Sitecore API key GUID

.PARAMETER CodebasePath
    Path to the vanilla xmcloud-starter-js root folder (containing local-containers/).

.PARAMETER InstanceName
    Short unique name for this instance (e.g., "one", "two", "four", "mvp").
    Used as a prefix/suffix throughout hostnames and project naming.

.PARAMETER MssqlPort
    Host port for MSSQL. Must be unique across all instances. Default: 14330.

.PARAMETER SolrPort
    Host port for Solr. Must be unique across all instances. Default: 8984.

.PARAMETER SiteName
    Sitecore site name to configure. Defaults to "xmc-<InstanceName>".

.EXAMPLE
    .\Convert-ToMultiDocker.ps1 -CodebasePath "C:\Projects\codebase-4" -InstanceName "four" -MssqlPort 14334 -SolrPort 8987
#>
[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [string]$CodebasePath,

    [Parameter(Mandatory = $true)]
    [string]$InstanceName,

    [Parameter(Mandatory = $false)]
    [int]$MssqlPort = 14330,

    [Parameter(Mandatory = $false)]
    [int]$SolrPort = 8984,

    [Parameter(Mandatory = $false)]
    [string]$SiteName
)

$ErrorActionPreference = "Stop"

# Derive names from InstanceName
$projectName = "xmc-$InstanceName"
$cmHost = "$InstanceName.xmcloudcm.localhost"
$renderingHost = "nextjs.xmc-$InstanceName.localhost"
if (-not $SiteName) { $SiteName = $projectName }

$localContainers = Join-Path $CodebasePath "local-containers"
$dockerCompose = Join-Path $localContainers "docker-compose.yml"
$dockerOverride = Join-Path $localContainers "docker-compose.override.yml"
$envFile = Join-Path $localContainers ".env"
$upScript = Join-Path $localContainers "scripts\up.ps1"
$sitecoreConfig = Join-Path $CodebasePath "examples\basic-nextjs\sitecore.config.ts"

# Validate paths
foreach ($path in @($dockerCompose, $dockerOverride, $envFile, $upScript, $sitecoreConfig)) {
    if (-not (Test-Path $path)) {
        throw "Required file not found: $path`nIs this a valid xmcloud-starter-js codebase?"
    }
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " Converting to Multi-Docker Instance" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Instance:   $InstanceName" -ForegroundColor White
Write-Host "  Project:    $projectName" -ForegroundColor White
Write-Host "  CM Host:    $cmHost" -ForegroundColor White
Write-Host "  Rendering:  $renderingHost" -ForegroundColor White
Write-Host "  MSSQL Port: $MssqlPort" -ForegroundColor White
Write-Host "  Solr Port:  $SolrPort" -ForegroundColor White
Write-Host "  Site Name:  $SiteName" -ForegroundColor White
Write-Host ""

$apiKey = [guid]::NewGuid().Guid
Write-Host "  Generated API Key: $apiKey" -ForegroundColor Green
Write-Host ""

###############################################
# Step 1: Parameterize docker-compose.yml
#         - Traefik labels: prefix router/middleware/service names with ${COMPOSE_PROJECT_NAME}
#         - MSSQL/Solr: make host ports configurable
###############################################

Write-Host "[1/8] Patching docker-compose.yml ..." -ForegroundColor Yellow

$dc = Get-Content $dockerCompose -Raw -Encoding UTF8

# Parameterize CM Traefik labels (only if not already parameterized)
if ($dc -notmatch '\$\{COMPOSE_PROJECT_NAME\}-force-STS') {
    $dc = $dc -replace 'traefik\.http\.middlewares\.force-STS-Header\.headers\.forceSTSHeader',       'traefik.http.middlewares.${COMPOSE_PROJECT_NAME}-force-STS-Header.headers.forceSTSHeader'
    $dc = $dc -replace 'traefik\.http\.middlewares\.force-STS-Header\.headers\.stsSeconds',            'traefik.http.middlewares.${COMPOSE_PROJECT_NAME}-force-STS-Header.headers.stsSeconds'
    $dc = $dc -replace 'traefik\.http\.routers\.cm-secure\.entrypoints',                               'traefik.http.routers.${COMPOSE_PROJECT_NAME}-cm-secure.entrypoints'
    $dc = $dc -replace 'traefik\.http\.routers\.cm-secure\.rule',                                      'traefik.http.routers.${COMPOSE_PROJECT_NAME}-cm-secure.rule'
    $dc = $dc -replace 'traefik\.http\.routers\.cm-secure\.tls',                                       'traefik.http.routers.${COMPOSE_PROJECT_NAME}-cm-secure.tls'
    $dc = $dc -replace 'traefik\.http\.routers\.cm-secure\.middlewares=force-STS-Header',              'traefik.http.routers.${COMPOSE_PROJECT_NAME}-cm-secure.middlewares=${COMPOSE_PROJECT_NAME}-force-STS-Header'
    $dc = $dc -replace 'traefik\.http\.services\.cm\.loadbalancer',                                    'traefik.http.services.${COMPOSE_PROJECT_NAME}-cm.loadbalancer'
}

# Make MSSQL port configurable (only if not already parameterized)
if ($dc -match '"14330:1433"') {
    $dc = $dc -replace '"14330:1433"', '"${MSSQL_PORT:-14330}:1433"'
}

# Make Solr port configurable (only if not already parameterized)
if ($dc -match '"8984:8983"') {
    $dc = $dc -replace '"8984:8983"', '"${SOLR_PORT:-8984}:8983"'
}

$dc | Set-Content $dockerCompose -Encoding UTF8 -NoNewline
Write-Host "  docker-compose.yml patched." -ForegroundColor Green

###############################################
# Step 2: Parameterize docker-compose.override.yml
#         - Rendering host Traefik labels
###############################################

Write-Host "[2/8] Patching docker-compose.override.yml ..." -ForegroundColor Yellow

$ov = Get-Content $dockerOverride -Raw -Encoding UTF8

if ($ov -notmatch '\$\{COMPOSE_PROJECT_NAME\}-rendering-secure') {
    $ov = $ov -replace 'traefik\.http\.routers\.rendering-secure-nextjs\.entrypoints',   'traefik.http.routers.${COMPOSE_PROJECT_NAME}-rendering-secure-nextjs.entrypoints'
    $ov = $ov -replace 'traefik\.http\.routers\.rendering-secure-nextjs\.rule',           'traefik.http.routers.${COMPOSE_PROJECT_NAME}-rendering-secure-nextjs.rule'
    $ov = $ov -replace 'traefik\.http\.routers\.rendering-secure-nextjs\.tls',            'traefik.http.routers.${COMPOSE_PROJECT_NAME}-rendering-secure-nextjs.tls'
    $ov = $ov -replace 'traefik\.http\.services\.rendering-nextjs\.loadbalancer',         'traefik.http.services.${COMPOSE_PROJECT_NAME}-rendering-nextjs.loadbalancer'
}

$ov | Set-Content $dockerOverride -Encoding UTF8 -NoNewline
Write-Host "  docker-compose.override.yml patched." -ForegroundColor Green

###############################################
# Step 3: Create docker-compose.multi.yml
#         - Disables local Traefik (replicas: 0)
#         - Connects CM + rendering to traefik-shared network
#         - Passes NEXT_PUBLIC_DEFAULT_SITE_NAME to rendering
###############################################

Write-Host "[3/8] Creating docker-compose.multi.yml ..." -ForegroundColor Yellow

$multiYml = @"
# Multi-instance override: disables local Traefik, connects CM and rendering
# to the shared Traefik network for centralized ingress routing.
services:
  traefik:
    deploy:
      replicas: 0

  cm:
    labels:
      - "traefik.docker.network=traefik-shared"
    networks:
      - default
      - traefik-shared

  rendering-nextjs:
    environment:
      NEXT_PUBLIC_DEFAULT_SITE_NAME: `${SITE_NAME:-$SiteName}
    labels:
      - "traefik.docker.network=traefik-shared"
    networks:
      - default
      - traefik-shared

networks:
  traefik-shared:
    name: traefik-shared
    external: true
"@

$multiYml | Set-Content (Join-Path $localContainers "docker-compose.multi.yml") -Encoding UTF8
Write-Host "  docker-compose.multi.yml created." -ForegroundColor Green

###############################################
# Step 4: Update .env
#         - COMPOSE_PROJECT_NAME, COMPOSE_FILE
#         - CM_HOST, RENDERING_HOST_NEXTJS
#         - MSSQL_PORT, SOLR_PORT, SITE_NAME
#         - Auth0 RedirectBaseUrl
#         - SITECORE_API_KEY_APP_STARTER
###############################################

Write-Host "[4/8] Updating .env ..." -ForegroundColor Yellow

$env = Get-Content $envFile -Encoding UTF8

# Helper: replace or append a variable in the .env content
function Set-EnvVar {
    param([string]$Name, [string]$Value, [ref]$Lines)
    $found = $false
    $result = @()
    foreach ($line in $Lines.Value) {
        if ($line -match "^$Name=") {
            $result += "$Name=$Value"
            $found = $true
        } else {
            $result += $line
        }
    }
    if (-not $found) { $result += "$Name=$Value" }
    $Lines.Value = $result
}

Set-EnvVar "COMPOSE_PROJECT_NAME" $projectName ([ref]$env)
Set-EnvVar "CM_HOST" $cmHost ([ref]$env)
Set-EnvVar "RENDERING_HOST_NEXTJS" $renderingHost ([ref]$env)
Set-EnvVar "SITECORE_FedAuth_dot_Auth0_dot_RedirectBaseUrl" "https://${cmHost}/" ([ref]$env)
Set-EnvVar "SITECORE_API_KEY_APP_STARTER" $apiKey ([ref]$env)

# Add COMPOSE_FILE if not present (use semicolons - Windows separator!)
if (-not ($env | Where-Object { $_ -match "^COMPOSE_FILE=" })) {
    # Insert after COMPOSE_PROJECT_NAME line
    $idx = 0
    for ($i = 0; $i -lt $env.Count; $i++) {
        if ($env[$i] -match "^COMPOSE_PROJECT_NAME=") { $idx = $i + 1; break }
    }
    $env = $env[0..($idx-1)] + "COMPOSE_FILE=docker-compose.yml;docker-compose.override.yml;docker-compose.multi.yml" + $env[$idx..($env.Count-1)]
}

# Add port and site name variables if not present
if (-not ($env | Where-Object { $_ -match "^MSSQL_PORT=" }))  { $env += "MSSQL_PORT=$MssqlPort" }   else { Set-EnvVar "MSSQL_PORT" "$MssqlPort" ([ref]$env) }
if (-not ($env | Where-Object { $_ -match "^SOLR_PORT=" }))   { $env += "SOLR_PORT=$SolrPort" }     else { Set-EnvVar "SOLR_PORT" "$SolrPort" ([ref]$env) }
if (-not ($env | Where-Object { $_ -match "^SITE_NAME=" }))   { $env += "SITE_NAME=$SiteName" }     else { Set-EnvVar "SITE_NAME" $SiteName ([ref]$env) }

$env | Set-Content $envFile -Encoding UTF8
Write-Host "  .env updated." -ForegroundColor Green

###############################################
# Step 5: Update sitecore.config.ts
#         - Add api.local config (apiKey, apiHost)
#         - Add defaultSite and defaultLanguage
###############################################

Write-Host "[5/8] Updating sitecore.config.ts ..." -ForegroundColor Yellow

$scConfig = Get-Content $sitecoreConfig -Raw -Encoding UTF8

# Only patch if it still has the bare defineConfig({})
if ($scConfig -match 'defineConfig\(\{}\)') {
    $newConfig = @"
import { defineConfig } from '@sitecore-content-sdk/nextjs/config';
/**
 * @type {import('@sitecore-content-sdk/nextjs/config').SitecoreConfig}
 * See the documentation for ``defineConfig``:
 * https://doc.sitecore.com/xmc/en/developers/content-sdk/the-sitecore-configuration-file.html
 */
export default defineConfig({
  api: {
    local: {
      apiKey: process.env.SITECORE_API_KEY || '',
      apiHost: process.env.SITECORE_API_HOST || '',
    },
  },
  defaultSite: process.env.NEXT_PUBLIC_DEFAULT_SITE_NAME || '$SiteName',
  defaultLanguage: 'en',
});
"@
    $newConfig | Set-Content $sitecoreConfig -Encoding UTF8 -NoNewline
    Write-Host "  sitecore.config.ts updated for local API mode." -ForegroundColor Green
} else {
    Write-Host "  sitecore.config.ts already configured, skipping." -ForegroundColor Yellow
}

###############################################
# Step 6: Update up.ps1
#         - Read COMPOSE_PROJECT_NAME from .env
#         - Use it in Traefik API router check
#         - Use CM_HOST for browser open
###############################################

Write-Host "[6/8] Patching up.ps1 ..." -ForegroundColor Yellow

$up = Get-Content $upScript -Raw -Encoding UTF8

# Add COMPOSE_PROJECT_NAME parsing (after TOOLS_IMAGE line, if not already present)
if ($up -notmatch 'composeProjectName') {
    $up = $up -replace '(\$xmcloudDockerToolsImage = \(.+?\)\.Split\("="\)\[1\])',
        "`$1`r`n`$composeProjectName = (`$envContent | Where-Object { `$_ -imatch `"^COMPOSE_PROJECT_NAME=.+`" }).Split(`"=`")[1]"
}

# Update Traefik API check to use parameterized router name
if ($up -match 'routers/cm-secure@docker') {
    $up = $up -replace 'routers/cm-secure@docker', 'routers/$composeProjectName-cm-secure@docker'
}

# Update browser open to use dynamic CM host
if ($up -match 'Start-Process https://xmcloudcm\.localhost/sitecore/') {
    $up = $up -replace 'Start-Process https://xmcloudcm\.localhost/sitecore/', 'Start-Process "https://$xmCloudHost/sitecore/"'
}

# Add full ser push (all modules) and dynamic site name for API key import
if ($up -match 'dotnet sitecore ser push -i nextjs-starter' -and $up -notmatch 'Pushing site content') {
    $up = $up -replace `
        '(dotnet sitecore ser push -i nextjs-starter)\r?\n\r?\nWrite-Host "Pushing sitecore API key"[^\r\n]*\r?\n[^\r\n]*import-templates\.ps1[^\r\n]*"App-Starter"[^\r\n]*', `
        "`$1`r`n`r`nWrite-Host `"Pushing site content and configuration...`" -ForegroundColor Green`r`ndotnet sitecore ser push`r`n`r`nWrite-Host `"Pushing sitecore API key`" -ForegroundColor Green`r`n`$siteName = (`$envContent | Where-Object { `$_ -imatch `"^SITE_NAME=.+`" }).Split(`"=`")[1]`r`nif ([string]::IsNullOrWhitespace(`$siteName)) { `$siteName = `"App-Starter`" }`r`n& `$RepoRoot\local-containers\docker\build\cm\templates\import-templates.ps1 -RenderingSiteName `$siteName -SitecoreApiKey `$sitecoreApiKey"
}

$up | Set-Content $upScript -Encoding UTF8 -NoNewline
Write-Host "  up.ps1 patched." -ForegroundColor Green

###############################################
# Step 7: Ensure hosts file entries exist
#         - Add 127.0.0.1 entries for CM and rendering hostnames
#         - Requires Administrator privileges
###############################################

Write-Host "[7/8] Checking hosts file entries ..." -ForegroundColor Yellow

$hostsFile = "C:\Windows\System32\drivers\etc\hosts"
$hostsContent = Get-Content $hostsFile -Raw -ErrorAction SilentlyContinue

$hostnames = @($cmHost, $renderingHost)
$hostsModified = $false

foreach ($hostname in $hostnames) {
    if ($hostsContent -notmatch [regex]::Escape($hostname)) {
        try {
            Add-Content -Path $hostsFile -Value "127.0.0.1`t$hostname" -Encoding ASCII -ErrorAction Stop
            Write-Host "  Added: 127.0.0.1  $hostname" -ForegroundColor Green
            $hostsModified = $true
        } catch {
            Write-Host "  SKIPPED: $hostname (run as Administrator to modify hosts file)" -ForegroundColor Red
        }
    } else {
        Write-Host "  Already present: $hostname" -ForegroundColor Yellow
    }
}

if (-not $hostsModified -and ($hostsContent -notmatch [regex]::Escape($cmHost) -or $hostsContent -notmatch [regex]::Escape($renderingHost))) {
    Write-Host "  To add missing entries manually, run as Administrator:" -ForegroundColor Yellow
    Write-Host "    Add-Content 'C:\Windows\System32\drivers\etc\hosts' '127.0.0.1`t$cmHost'" -ForegroundColor White
    Write-Host "    Add-Content 'C:\Windows\System32\drivers\etc\hosts' '127.0.0.1`t$renderingHost'" -ForegroundColor White
}

###############################################
# Step 8: Ensure traefik-shared Docker network exists
###############################################

Write-Host "[8/8] Checking Docker network ..." -ForegroundColor Yellow

$existingNet = docker network ls --filter "name=^traefik-shared$" --format "{{.Name}}" 2>$null
if ($existingNet -eq "traefik-shared") {
    Write-Host "  Network 'traefik-shared' already exists." -ForegroundColor Yellow
} else {
    docker network create -d nat traefik-shared 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Created network 'traefik-shared' (nat driver)." -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Failed to create network. Ensure Docker Desktop is running." -ForegroundColor Red
    }
}

###############################################
# Summary
###############################################

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " Conversion Complete!" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Instance '$InstanceName' is ready for multi-docker." -ForegroundColor Green
Write-Host ""
Write-Host "Endpoints (after starting):" -ForegroundColor White
Write-Host "  CM:        https://$cmHost/sitecore/" -ForegroundColor White
Write-Host "  Rendering: https://$renderingHost/" -ForegroundColor White
Write-Host "  MSSQL:     localhost:$MssqlPort" -ForegroundColor White
Write-Host "  Solr:      localhost:$SolrPort" -ForegroundColor White
Write-Host ""
Write-Host "API Key (add to Sitecore after CM is healthy):" -ForegroundColor White
Write-Host "  $apiKey" -ForegroundColor White
Write-Host ""
Write-Host "Remaining manual steps:" -ForegroundColor Yellow
Write-Host "  1. Generate TLS cert for rendering host (in shared Traefik certs dir):" -ForegroundColor White
Write-Host "       mkcert `"*.xmc-$InstanceName.localhost`"" -ForegroundColor White
Write-Host "     (*.xmcloudcm.localhost wildcard already covers the CM)" -ForegroundColor DarkGray
Write-Host "  2. After CM is healthy, register the API key:" -ForegroundColor White
Write-Host "       cd $CodebasePath" -ForegroundColor White
Write-Host "       dotnet sitecore cloud login" -ForegroundColor White
Write-Host "       dotnet sitecore connect --ref xmcloud --cm https://$cmHost --allow-write true -n default" -ForegroundColor White
Write-Host "       & ./local-containers/docker/build/cm/templates/import-templates.ps1 ``" -ForegroundColor White
Write-Host "           -RenderingSiteName '$SiteName' -SitecoreApiKey '$apiKey'" -ForegroundColor White
Write-Host "  3. Create a site in Sitecore CM with Hostname: $renderingHost" -ForegroundColor White
Write-Host ""
