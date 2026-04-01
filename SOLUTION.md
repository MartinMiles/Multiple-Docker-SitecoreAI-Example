# Running Three Sitecore XM Cloud Docker Instances in Parallel

## Table of Contents

- [Problem Statement](#problem-statement)
- [Architecture Overview](#architecture-overview)
- [Strategic Decisions](#strategic-decisions)
- [Network Design](#network-design)
- [File Changes Summary](#file-changes-summary)
- [Detailed Changes](#detailed-changes)
- [Next.js Rendering Host Configuration](#nextjs-rendering-host-configuration)
- [Sitecore Site Setup](#sitecore-site-setup)
- [Hosts File Entries](#hosts-file-entries)
- [Execution Flow](#execution-flow)
- [Testing Plan](#testing-plan)
- [Gotchas and Lessons Learned](#gotchas-and-lessons-learned)
- [Post-Implementation Analysis](#post-implementation-analysis)

---

## Problem Statement

Running a single Sitecore XM Cloud Docker environment locally is straightforward. Running **three simultaneously** on the same machine introduces two critical conflicts:

1. **CM Hostname Collision**: The XM Cloud identity server (Auth0) hardcodes callbacks to `xmcloudcm.localhost` or `*.xmcloudcm.localhost`. All three instances would compete for the same hostname.

2. **Traefik Port Conflict**: Each codebase ships its own Traefik reverse proxy, all binding to host port `443` (HTTPS) and `8079` (API). Only the first to start would succeed.

Secondary conflicts include MSSQL (port `14330`) and Solr (port `8984`) all binding to identical host ports.

---

## Architecture Overview

```
                    +-----------------------+
                    |   Shared Traefik      |
                    |   (Port 443, 8079)    |
                    +---+-------+-------+---+
                        |       |       |
                   traefik-shared (nat network)
                        |       |       |
   +----------+--+  +---+------+---+  +--+----------+
   | codebase-1  |  | codebase-2   |  | codebase-3  |
   |  (xmc-one)  |  |  (xmc-two)   |  | (xmc-three) |
   |             |  |              |  |              |
   | CM          |  | CM           |  | CM           |
   | Rendering   |  | Rendering    |  | Rendering    |
   | MSSQL:14331 |  | MSSQL:14332  |  | MSSQL:14333  |
   | Solr:8984   |  | Solr:8985    |  | Solr:8986    |
   +-------------+  +--------------+  +--------------+
```

### Hostname Mapping

| Codebase | CM Host | Rendering Host | MSSQL Port | Solr Port |
|----------|---------|----------------|------------|-----------|
| codebase-1 | `one.xmcloudcm.localhost` | `nextjs.xmc-one.localhost` | 14331 | 8984 |
| codebase-2 | `two.xmcloudcm.localhost` | `nextjs.xmc-two.localhost` | 14332 | 8985 |
| codebase-3 | `three.xmcloudcm.localhost` | `nextjs.xmc-three.localhost` | 14333 | 8986 |

---

## Strategic Decisions

### Why Shared Traefik (Not Per-Instance Traefik with Different Ports)?

- **Standard HTTPS port**: All CM and rendering instances are reachable on port 443 (the standard HTTPS port), so no port numbers in URLs.
- **Auth0 compatibility**: Sitecore's identity server expects callbacks on standard port 443 to `*.xmcloudcm.localhost`.
- **Single point of TLS**: One set of wildcard certificates covers all instances.
- **Resource efficiency**: One Traefik container instead of three.

### Why Third-Level Subdomains?

- `one.xmcloudcm.localhost`, `two.xmcloudcm.localhost`, `three.xmcloudcm.localhost` all match the `*.xmcloudcm.localhost` wildcard pattern that Auth0 accepts.
- A single wildcard TLS certificate covers all three.
- Clean, memorable, and requires no port numbers.

### Why Parameterized Traefik Labels?

When Traefik discovers containers via the Docker API, it uses label-defined router names. If three CM containers all define a router named `cm-secure`, Traefik merges them unpredictably. By prefixing router names with `${COMPOSE_PROJECT_NAME}` (e.g., `xmc-one-cm-secure`, `xmc-two-cm-secure`), each router is globally unique. This change is backward-compatible with single-instance usage.

### Why a Single Shared Network (Not Three Separate Ones)?

Windows containers use the `nat` network driver (not `bridge`). A container using `nat` cannot reliably connect to multiple `nat` networks simultaneously. We therefore use a **single `traefik-shared` network** created with the `nat` driver that all CM, rendering, and shared Traefik containers join. Internal services (MSSQL, Solr) remain on their project-default networks only and are not exposed to the shared network.

---

## Network Design

Each codebase operates on two Docker networks:

1. **Default project network** (`xmc-one_default`, `xmc-two_default`, `xmc-three_default`): Created automatically by Docker Compose. All services within a codebase communicate here. Completely isolated from other codebases.

2. **Shared Traefik network** (`traefik-shared`): A single `nat`-driver network that only the CM and rendering-nextjs services join (alongside the shared Traefik). This allows Traefik to route traffic to them. Internal infrastructure services (MSSQL, Solr, init containers) stay exclusively on their project-default network and are not reachable from the shared network.

**Key guarantee**: Codebase-1's MSSQL is not exposed to the shared network. Only CM and rendering containers participate in the shared network for Traefik routing.

---

## File Changes Summary

### New Files (at root)

| File | Purpose |
|------|---------|
| `shared-traefik/docker-compose.yml` | Shared Traefik reverse proxy |
| `shared-traefik/traefik/config/dynamic/certs_config.yaml` | TLS certificate configuration |
| `codebase-*/local-containers/docker-compose.multi.yml` | Per-codebase override: disables local Traefik, joins shared network, sets rendering site name |
| `setup-multi.ps1` | One-time setup: certs, networks, hosts file |
| `start-all.ps1` | Start shared Traefik + all three codebases |
| `stop-all.ps1` | Stop everything |

### Modified Files (per codebase)

| File | Changes |
|------|---------|
| `docker-compose.yml` | Parameterize Traefik labels with `${COMPOSE_PROJECT_NAME}`, make MSSQL/Solr ports configurable |
| `docker-compose.override.yml` | Parameterize rendering Traefik labels with `${COMPOSE_PROJECT_NAME}` |
| `scripts/up.ps1` | Read `COMPOSE_PROJECT_NAME`, use in Traefik API check, dynamic browser URL |
| `.env` | Set unique `COMPOSE_PROJECT_NAME`, hostnames, ports, `COMPOSE_FILE`, Auth0 redirect, `SITE_NAME` |
| `examples/basic-nextjs/sitecore.config.ts` | Add `api.local` config with `apiKey`/`apiHost`, set `defaultSite` and `defaultLanguage` |

---

## Detailed Changes

### 1. Shared Traefik (`shared-traefik/docker-compose.yml`)

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

> **Important**: The `traefik-shared` network must be created beforehand with the `nat` driver:
> ```powershell
> docker network create -d nat traefik-shared
> ```

### 2. TLS Certificate Config (`shared-traefik/traefik/config/dynamic/certs_config.yaml`)

```yaml
tls:
  certificates:
    - certFile: C:\etc\traefik\certs\_wildcard.xmcloudcm.localhost.pem
      keyFile: C:\etc\traefik\certs\_wildcard.xmcloudcm.localhost-key.pem
    - certFile: C:\etc\traefik\certs\_wildcard.xmc-one.localhost.pem
      keyFile: C:\etc\traefik\certs\_wildcard.xmc-one.localhost-key.pem
    - certFile: C:\etc\traefik\certs\_wildcard.xmc-two.localhost.pem
      keyFile: C:\etc\traefik\certs\_wildcard.xmc-two.localhost-key.pem
    - certFile: C:\etc\traefik\certs\_wildcard.xmc-three.localhost.pem
      keyFile: C:\etc\traefik\certs\_wildcard.xmc-three.localhost-key.pem
```

### 3. Per-Codebase Multi Override (`docker-compose.multi.yml`)

Example for codebase-1 (codebase-2 and codebase-3 differ only in the `SITE_NAME` default):

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
      NEXT_PUBLIC_DEFAULT_SITE_NAME: ${SITE_NAME:-xmc-one}
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

### 4. docker-compose.yml Label Changes (all codebases, identical)

**Before:**
```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.middlewares.force-STS-Header.headers.forceSTSHeader=true"
  - "traefik.http.middlewares.force-STS-Header.headers.stsSeconds=31536000"
  - "traefik.http.routers.cm-secure.entrypoints=websecure"
  - "traefik.http.routers.cm-secure.rule=Host(`${CM_HOST}`)"
  - "traefik.http.routers.cm-secure.tls=true"
  - "traefik.http.routers.cm-secure.middlewares=force-STS-Header"
  - "traefik.http.services.cm.loadbalancer.server.port=80"
```

**After:**
```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.middlewares.${COMPOSE_PROJECT_NAME}-force-STS-Header.headers.forceSTSHeader=true"
  - "traefik.http.middlewares.${COMPOSE_PROJECT_NAME}-force-STS-Header.headers.stsSeconds=31536000"
  - "traefik.http.routers.${COMPOSE_PROJECT_NAME}-cm-secure.entrypoints=websecure"
  - "traefik.http.routers.${COMPOSE_PROJECT_NAME}-cm-secure.rule=Host(`${CM_HOST}`)"
  - "traefik.http.routers.${COMPOSE_PROJECT_NAME}-cm-secure.tls=true"
  - "traefik.http.routers.${COMPOSE_PROJECT_NAME}-cm-secure.middlewares=${COMPOSE_PROJECT_NAME}-force-STS-Header"
  - "traefik.http.services.${COMPOSE_PROJECT_NAME}-cm.loadbalancer.server.port=80"
```

### 5. docker-compose.yml Port Changes (all codebases)

```yaml
# MSSQL: was "14330:1433"
ports:
  - "${MSSQL_PORT:-14330}:1433"

# Solr: was "8984:8983"
ports:
  - "${SOLR_PORT:-8984}:8983"
```

### 6. docker-compose.override.yml Label Changes (all codebases)

```yaml
# Before
- "traefik.http.routers.rendering-secure-nextjs.entrypoints=websecure"
- "traefik.http.routers.rendering-secure-nextjs.rule=Host(`${RENDERING_HOST_NEXTJS}`)"
- "traefik.http.routers.rendering-secure-nextjs.tls=true"
- "traefik.http.services.rendering-nextjs.loadbalancer.server.port=3000"

# After
- "traefik.http.routers.${COMPOSE_PROJECT_NAME}-rendering-secure-nextjs.entrypoints=websecure"
- "traefik.http.routers.${COMPOSE_PROJECT_NAME}-rendering-secure-nextjs.rule=Host(`${RENDERING_HOST_NEXTJS}`)"
- "traefik.http.routers.${COMPOSE_PROJECT_NAME}-rendering-secure-nextjs.tls=true"
- "traefik.http.services.${COMPOSE_PROJECT_NAME}-rendering-nextjs.loadbalancer.server.port=3000"
```

### 7. .env Differences Per Codebase

| Variable | codebase-1 | codebase-2 | codebase-3 |
|----------|------------|------------|------------|
| `COMPOSE_PROJECT_NAME` | `xmc-one` | `xmc-two` | `xmc-three` |
| `COMPOSE_FILE` | `docker-compose.yml;docker-compose.override.yml;docker-compose.multi.yml` | (same) | (same) |
| `CM_HOST` | `one.xmcloudcm.localhost` | `two.xmcloudcm.localhost` | `three.xmcloudcm.localhost` |
| `RENDERING_HOST_NEXTJS` | `nextjs.xmc-one.localhost` | `nextjs.xmc-two.localhost` | `nextjs.xmc-three.localhost` |
| `MSSQL_PORT` | `14331` | `14332` | `14333` |
| `SOLR_PORT` | `8984` | `8985` | `8986` |
| `SITE_NAME` | `xmc-one` | `xmc-two` | `xmc-three` |
| `SITECORE_API_KEY_APP_STARTER` | *(unique GUID)* | *(unique GUID)* | *(unique GUID)* |
| `...RedirectBaseUrl` | `https://one.xmcloudcm.localhost/` | `https://two.xmcloudcm.localhost/` | `https://three.xmcloudcm.localhost/` |

> **Critical**: The `COMPOSE_FILE` separator on Windows is **`;`** (semicolon), not `:` (colon). Using colons causes `CreateFile` errors because Windows interprets them as drive letter separators.

### 8. up.ps1 Changes (all codebases)

Added `COMPOSE_PROJECT_NAME` parsing and used it in the Traefik API router check:

```powershell
# Added line (after existing .env parsing)
$composeProjectName = ($envContent | Where-Object { $_ -imatch "^COMPOSE_PROJECT_NAME=.+" }).Split("=")[1]

# Changed Traefik API check (was: cm-secure@docker)
$status = Invoke-RestMethod "http://localhost:8079/api/http/routers/$composeProjectName-cm-secure@docker"

# Changed browser open (was: hardcoded xmcloudcm.localhost)
Start-Process "https://$xmCloudHost/sitecore/"
```

---

## Next.js Rendering Host Configuration

Getting the CM to respond on a subdomain is only half the battle. The Next.js rendering host requires several additional steps to serve Sitecore pages correctly.

### 1. Configure `sitecore.config.ts` for Local Mode

The stock `sitecore.config.ts` ships as `defineConfig({})` with no API configuration. The Content SDK's build tools (`sitecore-tools project build`) will fail with:

```
Error: Configuration error: provide either Edge contextId or local credentials (api.local.apiHost + api.local.apiKey).
```

Update each codebase's `examples/basic-nextjs/sitecore.config.ts`:

```typescript
import { defineConfig } from '@sitecore-content-sdk/nextjs/config';

export default defineConfig({
  api: {
    local: {
      apiKey: process.env.SITECORE_API_KEY || '',
      apiHost: process.env.SITECORE_API_HOST || '',
    },
  },
  defaultSite: process.env.NEXT_PUBLIC_DEFAULT_SITE_NAME || 'xmc-one',
  defaultLanguage: 'en',
});
```

The `defaultSite` setting is essential. Without it, the multisite/locale middleware produces a `Requested and resolved page mismatch: //en /en` error and every page returns 404.

### 2. Generate and Register API Keys

The `SITECORE_API_KEY_APP_STARTER` in `.env` must be a valid GUID **and** must be registered in each CM's Sitecore database. An unregistered key causes:

```
ClientError: Provided SSC API keyData is not valid.
```

**Generate a key** (one per codebase):
```powershell
[guid]::NewGuid().Guid
```

**Register it in Sitecore** using the CLI:
```powershell
cd codebase-1
dotnet tool restore
dotnet sitecore cloud login              # Browser auth required
dotnet sitecore connect --ref xmcloud --cm https://one.xmcloudcm.localhost --allow-write true -n default

# Push the API key item to Sitecore
& ./local-containers/docker/build/cm/templates/import-templates.ps1 `
  -RenderingSiteName 'xmc-one' `
  -SitecoreApiKey 'your-guid-here'
```

This creates the item at `/sitecore/system/Settings/Services/API Keys/xmc-one` with CORS and controller access set to `*`.

### 3. Pass `NEXT_PUBLIC_DEFAULT_SITE_NAME` to the Rendering Container

The `docker-compose.multi.yml` passes this environment variable:

```yaml
rendering-nextjs:
  environment:
    NEXT_PUBLIC_DEFAULT_SITE_NAME: ${SITE_NAME:-xmc-one}
```

And the `.env` defines:
```
SITE_NAME=xmc-one
```

---

## Sitecore Site Setup

After the CM instances are running, create a Sitecore site in each CM's Content Editor:

1. Log in to `https://one.xmcloudcm.localhost/sitecore/`
2. Create a new site (e.g., `xmc-one`) under `/sitecore/content/`
3. In the site's **Settings > Site Grouping** item, set the **Hostname** field to:
   ```
   nextjs.xmc-one.localhost
   ```
4. Ensure a **Home** item exists under `/sitecore/content/xmc-one/Home`

Repeat for each codebase with the corresponding site name and hostname.

The hostname binding is what tells Sitecore which site to resolve when a request arrives at the rendering host. Without it, the layout service returns no route data and Next.js shows "Page not found."

---

## Hosts File Entries

Add to `C:\Windows\System32\drivers\etc\hosts`:

```
127.0.0.1	one.xmcloudcm.localhost
127.0.0.1	two.xmcloudcm.localhost
127.0.0.1	three.xmcloudcm.localhost
127.0.0.1	nextjs.xmc-one.localhost
127.0.0.1	nextjs.xmc-two.localhost
127.0.0.1	nextjs.xmc-three.localhost
```

The `setup-multi.ps1` script adds these automatically when run as Administrator.

---

## Execution Flow

### First-Time Setup

```powershell
# 1. Run the one-time multi-instance setup (requires Administrator)
cd C:\Projects\SHIFT-AI\Multiple-Docker
.\setup-multi.ps1

# 2. Run init.ps1 per codebase
cd codebase-1\local-containers\scripts
.\init.ps1 -InitEnv -LicenseXmlPath C:\License\license.xml -AdminPassword "YourPassword"
cd ..\..\..\codebase-2\local-containers\scripts
.\init.ps1 -InitEnv -LicenseXmlPath C:\License\license.xml -AdminPassword "YourPassword"
cd ..\..\..\codebase-3\local-containers\scripts
.\init.ps1 -InitEnv -LicenseXmlPath C:\License\license.xml -AdminPassword "YourPassword"

# 3. Start all environments
cd C:\Projects\SHIFT-AI\Multiple-Docker
.\start-all.ps1

# 4. Register API keys (after CMs are healthy)
# For each codebase: cloud login, connect, push API key
cd codebase-1
dotnet sitecore cloud login
dotnet sitecore connect --ref xmcloud --cm https://one.xmcloudcm.localhost --allow-write true -n default
& ./local-containers/docker/build/cm/templates/import-templates.ps1 -RenderingSiteName 'xmc-one' -SitecoreApiKey '<guid-from-env>'
# Repeat for codebase-2 and codebase-3

# 5. Restart rendering containers to pick up valid API keys
cd codebase-1\local-containers && docker compose restart rendering-nextjs
cd ..\..\codebase-2\local-containers && docker compose restart rendering-nextjs
cd ..\..\codebase-3\local-containers && docker compose restart rendering-nextjs

# 6. Create sites in each CM's Content Editor with hostname bindings
```

### Starting All Environments

```powershell
cd C:\Projects\SHIFT-AI\Multiple-Docker
.\start-all.ps1
```

### Starting a Single Environment

```powershell
.\start-all.ps1 -Codebases @("codebase-1")
```

### Stopping All Environments

```powershell
.\stop-all.ps1
```

### Stopping While Keeping Traefik Running

```powershell
.\stop-all.ps1 -KeepTraefik
```

---

## Testing Plan

### 1. Verify Traefik Dashboard

Navigate to `http://localhost:8079/dashboard/`

**Expected**: Dashboard shows 6 registered routers:
- `xmc-one-cm-secure@docker` -> `Host(one.xmcloudcm.localhost)`
- `xmc-two-cm-secure@docker` -> `Host(two.xmcloudcm.localhost)`
- `xmc-three-cm-secure@docker` -> `Host(three.xmcloudcm.localhost)`
- `xmc-one-rendering-secure-nextjs@docker` -> `Host(nextjs.xmc-one.localhost)`
- `xmc-two-rendering-secure-nextjs@docker` -> `Host(nextjs.xmc-two.localhost)`
- `xmc-three-rendering-secure-nextjs@docker` -> `Host(nextjs.xmc-three.localhost)`

### 2. Verify CM Instances

Navigate to each CM instance:
- `https://one.xmcloudcm.localhost/sitecore/` - Should redirect to Auth0 login (HTTP 302)
- `https://two.xmcloudcm.localhost/sitecore/` - Should redirect to Auth0 login (HTTP 302)
- `https://three.xmcloudcm.localhost/sitecore/` - Should redirect to Auth0 login (HTTP 302)

### 3. Verify Rendering Hosts

Navigate to each rendering host:
- `https://nextjs.xmc-one.localhost/` - Should show the Sitecore site home page (HTTP 200)
- `https://nextjs.xmc-two.localhost/` - Should show the Sitecore site home page (HTTP 200)
- `https://nextjs.xmc-three.localhost/` - Should show the Sitecore site home page (HTTP 200)

### 4. Verify Port Isolation

```powershell
# Each MSSQL should be accessible on its unique port
Test-NetConnection localhost -Port 14331  # codebase-1
Test-NetConnection localhost -Port 14332  # codebase-2
Test-NetConnection localhost -Port 14333  # codebase-3

# Each Solr should be accessible
Invoke-WebRequest http://localhost:8984/solr/  # codebase-1
Invoke-WebRequest http://localhost:8985/solr/  # codebase-2
Invoke-WebRequest http://localhost:8986/solr/  # codebase-3
```

---

## Gotchas and Lessons Learned

### Windows-Specific

1. **`COMPOSE_FILE` separator is `;` on Windows, not `:`**. Using colons causes `CreateFile` errors because Windows interprets them as drive letter separators.

2. **Docker networks must use the `nat` driver**, not `bridge`. Windows containers don't support the `bridge` driver. Create networks with `docker network create -d nat traefik-shared`.

3. **A single shared `nat` network** is more reliable than three separate ones. Windows containers have limitations connecting to multiple `nat` networks simultaneously.

### Traefik

4. **Router names are global across all Docker containers** that Traefik discovers. Two containers defining `cm-secure` creates a silent conflict. Prefix with `${COMPOSE_PROJECT_NAME}`.

5. **Docker Compose labels merge, they don't replace**. You can't remove labels from a base file via an override. This is why parameterization in the base file is cleaner than override-based label replacement.

6. **The `traefik.docker.network` label is essential** when a container is on multiple networks. Without it, Traefik may route via the wrong network and fail silently.

### Next.js / Content SDK

7. **`sitecore.config.ts` must have `api.local` config** for Docker development. The empty `defineConfig({})` works for Edge/cloud mode but fails at build time in local mode.

8. **`defaultSite` must be set** in the config. Without it, the multisite/locale middleware generates double-slash paths (`//en` vs `/en`) and every page returns 404.

9. **The `SITECORE_API_KEY_APP_STARTER` must be registered in Sitecore**, not just set in `.env`. An unregistered GUID causes `Provided SSC API keyData is not valid` errors. Use the `import-templates.ps1` script with `dotnet sitecore ser push` to create the API key item.

10. **Sitecore sites need hostname bindings** in the Site Grouping settings. Without the rendering host's hostname in the **Hostname** field, the layout service returns no route data.

---

## Post-Implementation Analysis

### Strengths

1. **Minimal invasiveness**: Parameterized labels and configurable ports are backward-compatible with single-instance usage.
2. **Standard ports**: All HTTPS traffic uses port 443 - no port numbers in URLs.
3. **Single cert management**: One wildcard cert covers all CM subdomains; per-site certs cover rendering hosts.
4. **Selective startup**: Can start 1, 2, or 3 codebases independently.
5. **Clean separation**: All multi-instance infrastructure lives at the root level.
6. **Full end-to-end**: Both CM and Next.js rendering hosts are fully functional on unique hostnames.

### Tradeoffs

1. **Shared network**: CM and rendering containers across codebases share the `traefik-shared` network, so they can theoretically discover each other by container name. Infrastructure services (MSSQL, Solr) remain isolated.
2. **Resource usage**: Running three full Sitecore stacks requires significant memory (~16GB+ recommended).
3. **Sitecore CLI login**: Each codebase requires a separate `dotnet sitecore cloud login` for API key registration.

### Possible Simplifications

1. **Environment variable template**: A script that generates `.env` files for N codebases.
2. **Single-codebase fallback**: Remove the `COMPOSE_FILE` line from `.env` to revert any codebase to standalone mode with its own Traefik.
3. **Docker Compose profiles**: Instead of `deploy.replicas: 0`, use Compose profiles to toggle between standalone and multi-instance modes.
