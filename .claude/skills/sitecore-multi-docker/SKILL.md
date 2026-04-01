---
name: sitecore-multi-docker
description: Set up N parallel Sitecore XM Cloud local Docker environments with a shared Traefik reverse proxy, unique hostnames, and independent Next.js rendering hosts. Use when running multiple XM Cloud starter kit instances simultaneously.
argument-hint: "[traefik-root-path] [codebase-path:instance-name:mssql-port:solr-port:site-name] [codebase-path:instance-name:mssql-port:solr-port:site-name] ..."
---

# Sitecore XM Cloud Multi-Docker Setup

You are an expert Docker and Sitecore XM Cloud architect. Your job is to set up N parallel Sitecore XM Cloud Docker environments on a single Windows machine, sharing a single Traefik reverse proxy for HTTPS ingress.

## Arguments

- `$0` : Path where the shared Traefik infrastructure should live (e.g., `C:\Projects\shared-traefik`)
- `$1` ... `$N` : One or more codebase specs in the format `path:instance-name:mssql-port:solr-port:site-name`

**Example invocation:**
```
/sitecore-multi-docker C:\Projects\shared-traefik C:\Projects\cb1:one:14331:8984:xmc-one C:\Projects\cb2:two:14332:8985:xmc-two
```

If arguments are not provided, ask the user for:
1. Where should the shared Traefik live?
2. For each codebase: path, short instance name, MSSQL port, Solr port, site name

## Architecture Overview

All instances share a single Traefik container on port 443/8079 that routes by hostname:
- CM instances: `{instance}.xmcloudcm.localhost` (e.g., `one.xmcloudcm.localhost`)
- Rendering hosts: `nextjs.xmc-{instance}.localhost` (e.g., `nextjs.xmc-one.localhost`)

A single `traefik-shared` Docker network (nat driver, Windows) connects Traefik to all CM and rendering containers. Each codebase's infrastructure services (MSSQL, Solr) stay on their project-default network.

## Execution Plan

Follow these steps in order. Do NOT skip steps. Do NOT ask for confirmation between steps unless you hit an error.

### Phase 1: Shared Traefik Infrastructure

1. **Create the shared Traefik directory** at the path from `$0`:
   ```
   {traefik-root}/
     docker-compose.yml
     traefik/
       config/dynamic/certs_config.yaml
       certs/          (generated certificates go here)
   ```

2. **Write `docker-compose.yml`** for the shared Traefik:
   ```yaml
   services:
     traefik:
       isolation: hyperv
       image: traefik:v3.6.4-windowsservercore-ltsc2022
       command:
         - "--ping"
         - "--api.insecure=true"
         - "--providers.docker.endpoint=npipe:////./pipe/docker_engine"
         - "--providers.docker.exposedByDefault=false"
         - "--providers.file.directory=C:/etc/traefik/config/dynamic"
         - "--entryPoints.websecure.address=:443"
         - "--entryPoints.websecure.forwardedHeaders.insecure"
       ports:
         - "443:443"
         - "8079:8080"
       healthcheck:
         test: ["CMD", "traefik", "healthcheck", "--ping"]
       volumes:
         - source: \\.\pipe\docker_engine\
           target: \\.\pipe\docker_engine\
           type: npipe
         - ./traefik:C:/etc/traefik
       networks:
         - traefik-shared
   networks:
     traefik-shared:
       name: traefik-shared
       external: true
   ```

3. **Create the Docker network** (nat driver required for Windows containers):
   ```powershell
   docker network create -d nat traefik-shared
   ```
   If it already exists, skip.

4. **Generate TLS certificates** with mkcert for all instances. For each codebase spec, generate:
   - `*.xmcloudcm.localhost` (only once, covers all CM subdomains)
   - `*.xmc-{instance}.localhost` (one per codebase, for rendering host)
   Place all `.pem` files in `{traefik-root}/traefik/certs/`.

5. **Write `certs_config.yaml`** referencing all generated certs:
   ```yaml
   tls:
     certificates:
       - certFile: C:\etc\traefik\certs\_wildcard.xmcloudcm.localhost.pem
         keyFile: C:\etc\traefik\certs\_wildcard.xmcloudcm.localhost-key.pem
       # One entry per codebase for rendering host wildcard cert
       - certFile: C:\etc\traefik\certs\_wildcard.xmc-{instance}.localhost.pem
         keyFile: C:\etc\traefik\certs\_wildcard.xmc-{instance}.localhost-key.pem
   ```

### Phase 2: Convert Each Codebase

For each codebase spec (`path:instance:mssql-port:solr-port:site-name`):

Each codebase is a clone of https://github.com/Sitecore/xmcloud-starter-js with Docker files in `local-containers/`.

6. **Patch `local-containers/docker-compose.yml`**:
   - Replace all Traefik label router/middleware/service names with `${COMPOSE_PROJECT_NAME}` prefix:
     - `force-STS-Header` -> `${COMPOSE_PROJECT_NAME}-force-STS-Header`
     - `cm-secure` -> `${COMPOSE_PROJECT_NAME}-cm-secure`
     - `traefik.http.services.cm.` -> `traefik.http.services.${COMPOSE_PROJECT_NAME}-cm.`
   - Replace MSSQL port `"14330:1433"` with `"${MSSQL_PORT:-14330}:1433"`
   - Replace Solr port `"8984:8983"` with `"${SOLR_PORT:-8984}:8983"`
   - **Do not modify if already parameterized** (idempotency check: look for `${COMPOSE_PROJECT_NAME}-force-STS`)

7. **Patch `local-containers/docker-compose.override.yml`**:
   - Replace rendering label names with `${COMPOSE_PROJECT_NAME}` prefix:
     - `rendering-secure-nextjs` -> `${COMPOSE_PROJECT_NAME}-rendering-secure-nextjs`
     - `traefik.http.services.rendering-nextjs.` -> `traefik.http.services.${COMPOSE_PROJECT_NAME}-rendering-nextjs.`

8. **Create `local-containers/docker-compose.multi.yml`**:
   ```yaml
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
         NEXT_PUBLIC_DEFAULT_SITE_NAME: ${SITE_NAME:-{site-name}}
       labels:
         - "traefik.docker.network=traefik-shared"
       networks:
         - default
         - traefik-shared
   networks:
     traefik-shared:
       name: traefik-shared
       external: true
   ```

9. **Update `local-containers/.env`**:
   | Variable | Value |
   |----------|-------|
   | `COMPOSE_PROJECT_NAME` | `xmc-{instance}` |
   | `COMPOSE_FILE` | `docker-compose.yml;docker-compose.override.yml;docker-compose.multi.yml` |
   | `CM_HOST` | `{instance}.xmcloudcm.localhost` |
   | `RENDERING_HOST_NEXTJS` | `nextjs.xmc-{instance}.localhost` |
   | `MSSQL_PORT` | `{mssql-port}` |
   | `SOLR_PORT` | `{solr-port}` |
   | `SITE_NAME` | `{site-name}` |
   | `SITECORE_API_KEY_APP_STARTER` | *(generate a new GUID)* |
   | `SITECORE_FedAuth_dot_Auth0_dot_RedirectBaseUrl` | `https://{instance}.xmcloudcm.localhost/` |

   **CRITICAL**: `COMPOSE_FILE` separator on Windows is `;` (semicolon), NOT `:` (colon).

10. **Update `examples/basic-nextjs/sitecore.config.ts`**:
    Replace `defineConfig({})` with:
    ```typescript
    export default defineConfig({
      api: {
        local: {
          apiKey: process.env.SITECORE_API_KEY || '',
          apiHost: process.env.SITECORE_API_HOST || '',
        },
      },
      defaultSite: process.env.NEXT_PUBLIC_DEFAULT_SITE_NAME || '{site-name}',
      defaultLanguage: 'en',
    });
    ```
    If already configured (does not contain `defineConfig({})`), skip.

11. **Patch `local-containers/scripts/up.ps1`**:
    - After the `$xmcloudDockerToolsImage` line, add:
      ```powershell
      $composeProjectName = ($envContent | Where-Object { $_ -imatch "^COMPOSE_PROJECT_NAME=.+" }).Split("=")[1]
      ```
    - Replace `routers/cm-secure@docker` with `routers/$composeProjectName-cm-secure@docker`
    - Replace `Start-Process https://xmcloudcm.localhost/sitecore/` with `Start-Process "https://$xmCloudHost/sitecore/"`

### Phase 3: Hosts File and Startup

12. **Add hosts file entries** for all instances:
    ```
    127.0.0.1  {instance}.xmcloudcm.localhost
    127.0.0.1  nextjs.xmc-{instance}.localhost
    ```
    File: `C:\Windows\System32\drivers\etc\hosts`. Requires admin privileges.

13. **Start the shared Traefik**:
    ```powershell
    cd {traefik-root}
    docker compose up -d
    ```

14. **For each codebase**, build and start:
    ```powershell
    cd {codebase-path}\local-containers
    docker compose build
    docker compose up -d
    ```

15. **Wait for CM health** - poll the Traefik API until the router is enabled:
    ```
    http://localhost:8079/api/http/routers/xmc-{instance}-cm-secure@docker
    ```

### Phase 4: Post-Startup (per codebase)

These steps require interactive browser authentication and must be done after CM is healthy.

16. **Register the Sitecore API key**:
    ```powershell
    cd {codebase-path}
    dotnet tool restore
    dotnet sitecore cloud login    # Opens browser for Auth0 device flow
    dotnet sitecore connect --ref xmcloud --cm https://{instance}.xmcloudcm.localhost --allow-write true -n default
    & ./local-containers/docker/build/cm/templates/import-templates.ps1 -RenderingSiteName '{site-name}' -SitecoreApiKey '{api-key-guid}'
    ```
    The `cloud login` requires the user to complete browser authentication. Pause and inform them.

17. **Restart rendering container** to pick up the registered API key:
    ```powershell
    cd {codebase-path}\local-containers
    docker compose restart rendering-nextjs
    ```

18. **Instruct user to create Sitecore site** in each CM's Content Editor:
    - Create site under `/sitecore/content/` with name `{site-name}`
    - Set the site's **Hostname** (in Site Grouping) to `nextjs.xmc-{instance}.localhost`
    - Create a Home page item under the site root

### Phase 5: Verification

19. **Test all endpoints**:
    - CM: `curl -sk -o /dev/null -w "%{http_code}" https://{instance}.xmcloudcm.localhost/sitecore/` -> expect 302
    - Rendering: `curl -sk -o /dev/null -w "%{http_code}" https://nextjs.xmc-{instance}.localhost/` -> expect 200
    - Traefik dashboard: `http://localhost:8079/dashboard/` -> should show 2 routers per instance

20. **Report results** in a summary table showing all instances, their hostnames, ports, and HTTP status codes.

## Critical Windows-Specific Details

- **Docker network driver**: Must use `nat`, not `bridge`. Command: `docker network create -d nat traefik-shared`
- **`COMPOSE_FILE` separator**: Use `;` (semicolon) on Windows, not `:` (colon)
- **Traefik image**: Must be the Windows Server Core variant: `traefik:v3.6.4-windowsservercore-ltsc2022`
- **Traefik isolation**: Use `hyperv` isolation for the Traefik container
- **Docker named pipe**: `\\.\pipe\docker_engine\` for Docker API access from Windows containers

## Common Errors and Fixes

| Error | Cause | Fix |
|-------|-------|-----|
| `CreateFile ... volume label syntax is incorrect` | `COMPOSE_FILE` uses `:` separator | Change to `;` separator |
| `could not find plugin bridge` | Wrong network driver | Use `docker network create -d nat` |
| `Configuration error: provide either Edge contextId or local credentials` | Empty `sitecore.config.ts` | Add `api.local` block with `apiKey` and `apiHost` |
| `Provided SSC API keyData is not valid` | API key GUID not registered in Sitecore | Run `import-templates.ps1` via Sitecore CLI |
| `Requested and resolved page mismatch: //en /en` | Missing `defaultSite` in config | Add `defaultSite` to `sitecore.config.ts` and pass `NEXT_PUBLIC_DEFAULT_SITE_NAME` env var |
| Rendering returns 404 but CM layout API works | Site hostname not bound | Set Hostname field in Sitecore Site Grouping to the rendering host domain |
| Traefik routes to wrong container | Duplicate router names across projects | Prefix all Traefik label names with `${COMPOSE_PROJECT_NAME}` |
