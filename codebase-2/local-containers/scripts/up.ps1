$ErrorActionPreference = "Stop";

# Set the root of the repository
$RepoRoot = Resolve-Path "$PSScriptRoot\..\.."

# Store the location of the .env file
$envFileLocation = "$RepoRoot/local-containers/.env"

. $RepoRoot\local-containers\scripts\upFunctions.ps1

Validate-LicenseExpiry -EnvFileName $envFileLocation

$envContent = Get-Content $envFileLocation -Encoding UTF8
$xmCloudHost = $envContent | Where-Object { $_ -imatch "^CM_HOST=.+" }
$sitecoreDockerRegistry = $envContent | Where-Object { $_ -imatch "^SITECORE_DOCKER_REGISTRY=.+" }
$sitecoreVersion = $envContent | Where-Object { $_ -imatch "^SITECORE_VERSION=.+" }
$ClientCredentialsLogin = $envContent | Where-Object { $_ -imatch "^SITECORE_FedAuth_dot_Auth0_dot_ClientCredentialsLogin=.+" }
$sitecoreApiKey = ($envContent | Where-Object { $_ -imatch "^SITECORE_API_KEY_APP_STARTER=.+" }).Split("=")[1]
$xmcloudDockerToolsImage = ($envContent | Where-Object { $_ -imatch "^TOOLS_IMAGE=.+" }).Split("=")[1]
$composeProjectName = ($envContent | Where-Object { $_ -imatch "^COMPOSE_PROJECT_NAME=.+" }).Split("=")[1]

$xmCloudHost = $xmCloudHost.Split("=")[1]
$sitecoreDockerRegistry = $sitecoreDockerRegistry.Split("=")[1]
$sitecoreVersion = $sitecoreVersion.Split("=")[1]
$ClientCredentialsLogin = $ClientCredentialsLogin.Split("=")[1]
if ($ClientCredentialsLogin -eq "true") {
    $xmCloudClientCredentialsLoginDomain = $envContent | Where-Object { $_ -imatch "^SITECORE_FedAuth_dot_Auth0_dot_Domain=.+" }
    $xmCloudClientCredentialsLoginAudience = $envContent | Where-Object { $_ -imatch "^SITECORE_FedAuth_dot_Auth0_dot_ClientCredentialsLogin_Audience=.+" }
    $xmCloudClientCredentialsLoginClientId = $envContent | Where-Object { $_ -imatch "^SITECORE_FedAuth_dot_Auth0_dot_ClientCredentialsLogin_ClientId=.+" }
    $xmCloudClientCredentialsLoginClientSecret = $envContent | Where-Object { $_ -imatch "^SITECORE_FedAuth_dot_Auth0_dot_ClientCredentialsLogin_ClientSecret=.+" }
    $xmCloudClientCredentialsLoginDomain = $xmCloudClientCredentialsLoginDomain.Split("=")[1]
    $xmCloudClientCredentialsLoginAudience = $xmCloudClientCredentialsLoginAudience.Split("=")[1]
    $xmCloudClientCredentialsLoginClientId = $xmCloudClientCredentialsLoginClientId.Split("=")[1]
    $xmCloudClientCredentialsLoginClientSecret = $xmCloudClientCredentialsLoginClientSecret.Split("=")[1]
}

#set node version
$xmCloudBuild = Get-Content "$RepoRoot/xmcloud.build.json" | ConvertFrom-Json
$nodeVersion = $xmCloudBuild.renderingHosts.nextjsstarter.nodeVersion
if (![string]::IsNullOrWhitespace($nodeVersion)) {
    Set-EnvFileVariable "NODEJS_VERSION" -Value $xmCloudBuild.renderingHosts.nextjsstarter.nodeVersion -Path $envFileLocation
}

# Double check whether init has been run
$envCheckVariable = "HOST_LICENSE_FOLDER"
$envCheck = $envContent | Where-Object { $_ -imatch "^$envCheckVariable=.+" }
if (-not $envCheck) {
    throw "$envCheckVariable does not have a value. Did you run 'init.ps1 -InitEnv'?"
}

Write-Host "Keeping XM Cloud base image up to date" -ForegroundColor Green
docker pull "$($sitecoreDockerRegistry)sitecore-xmcloud-cm:$($sitecoreVersion)"

Write-Host "Keeping XM Cloud Tools image up to date" -ForegroundColor Green
docker pull "$($xmcloudDockerToolsImage):$($sitecoreVersion)"

# Moving into the Local Containers Folder
Write-Host "Moving location into Local Containers folder..." -ForegroundColor Green
Push-Location $RepoRoot\local-containers

# Build all containers in the Sitecore instance, forcing a pull of latest base containers
Write-Host "Building containers..." -ForegroundColor Green
docker compose build
if ($LASTEXITCODE -ne 0) {
    Write-Error "Container build failed, see errors above."
}

# Start the Sitecore instance
Write-Host "Starting Sitecore environment..." -ForegroundColor Green
docker compose up -d

# Wait for Traefik to expose CM route (CM needs time for DB init on first run)
Write-Host "Waiting for CM to become available..." -ForegroundColor Green
$startTime = Get-Date
$timeoutSeconds = 300
do {
    Start-Sleep -Seconds 2
    try {
        $status = Invoke-RestMethod "http://localhost:8079/api/http/routers/$composeProjectName-cm-secure@docker" -ErrorAction SilentlyContinue
    } catch {
        $status = $null
    }
} while (($null -eq $status -or $status.status -ne "enabled") -and $startTime.AddSeconds($timeoutSeconds) -gt (Get-Date))
if ($null -eq $status -or $status.status -ne "enabled") {
    Write-Error "Timeout waiting for Sitecore CM to become available via Traefik proxy after $timeoutSeconds seconds. Check CM container logs."
}

# Return to the original directory
Pop-Location

Write-Host "Restoring Sitecore CLI..." -ForegroundColor Green
dotnet tool restore
Write-Host "Installing Sitecore CLI Plugins..."
dotnet sitecore --help | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Unexpected error installing Sitecore CLI Plugins"
}

#####################################

Write-Host "Logging into Sitecore..." -ForegroundColor Green
if ($ClientCredentialsLogin -eq "true") {
    dotnet sitecore cloud login --client-id $xmCloudClientCredentialsLoginClientId --client-secret $xmCloudClientCredentialsLoginClientSecret --client-credentials true
    dotnet sitecore login --authority $xmCloudClientCredentialsLoginDomain --audience $xmCloudClientCredentialsLoginAudience --client-id $xmCloudClientCredentialsLoginClientId --client-secret $xmCloudClientCredentialsLoginClientSecret --cm https://$xmCloudHost --client-credentials true --allow-write true
}
else {
    dotnet sitecore cloud login
    dotnet sitecore connect --ref xmcloud --cm https://$xmCloudHost --allow-write true -n default
}

if ($LASTEXITCODE -ne 0) {
    Write-Error "Unable to log into Sitecore, did the Sitecore environment start correctly? See logs above."
}

# Populate Solr managed schemas to avoid errors during item deploy
Write-Host "Populating Solr managed schema..." -ForegroundColor Green
dotnet sitecore index schema-populate
if ($LASTEXITCODE -ne 0) {
    Write-Error "Populating Solr managed schema failed, see errors above."
}

# Rebuild indexes
Write-Host "Rebuilding indexes ..." -ForegroundColor Green
dotnet sitecore index rebuild

Write-Host "Pushing Default rendering host configuration" -ForegroundColor Green
dotnet sitecore ser push -i nextjs-starter

Write-Host "Pushing site content and configuration..." -ForegroundColor Green
dotnet sitecore ser push

Write-Host "Pushing sitecore API key" -ForegroundColor Green
$siteName = ($envContent | Where-Object { $_ -imatch "^SITE_NAME=.+" }).Split("=")[1]
if ([string]::IsNullOrWhitespace($siteName)) { $siteName = "App-Starter" }
& $RepoRoot\local-containers\docker\build\cm\templates\import-templates.ps1 -RenderingSiteName $siteName -SitecoreApiKey $sitecoreApiKey

if ($ClientCredentialsLogin -ne "true") {
    Write-Host "Opening site..." -ForegroundColor Green
    
    Start-Process "https://$xmCloudHost/sitecore/"
}

Write-Host ""
Write-Host "Use the following command to monitor your Rendering Host:" -ForegroundColor Green
Write-Host "docker compose logs -f rendering"
Write-Host ""
