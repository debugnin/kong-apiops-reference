# APIOps Pipeline — Application Team Onboarding Guide

> **Audience:** Application development teams onboarding a new service to Kong Gateway via the APIOps pipeline.
>
> **What you need to know about Kong:** Nothing. This guide covers everything you need to do. The platform team handles all Kong configuration.

---

## How It Works

The APIOps pipeline automatically configures Kong Gateway from one file you own per service:

| What | Where |
|---|---|
| `services/<your-service>/openapi.yaml` | Your API specification (OpenAPI 3.x) — committed to the repo |

The pipeline reads your OpenAPI spec, converts it into Kong route/service configuration, injects authentication (OIDC) and the platform's global plugins automatically, and syncs to Kong Konnect. You do not write Kong config directly.

### Ownership boundary

```
┌─────────────────────────────────────┬──────────────────────────────────────┐
│  Application team owns              │  Platform team owns                  │
├─────────────────────────────────────┼──────────────────────────────────────┤
│  services/<svc>/openapi.yaml        │  platform/kong/**                    │
│                                      │  bitbucket-pipelines.yml             │
└─────────────────────────────────────┴──────────────────────────────────────┘
```

This repo ships two example services playing the application-team role: `kongair-bookings` and `kongair-flights`, both pointed at `https://httpbin.konghq.com`. They're referenced throughout this guide as worked examples.

---

## Prerequisites

Before you start, confirm with the platform team that:

- [ ] A Bitbucket deployment environment exists for each target environment (dev / qa / uat / prod)
- [ ] Your upstream is reachable from the Kong data plane

---

## Step 1 — Point your spec at your upstream

Set `servers[0].url` in your `openapi.yaml` to your backend's URL:

```yaml
servers:
  - url: https://my-service-backend.example.com
```

If the URL is the same in every environment — as it is for both example services in this repo, which point at the public `https://httpbin.konghq.com` — that's all you need to do.

If your upstream URL differs per environment, use a `${<PREFIX>_UPSTREAM_URL}` placeholder instead and ask the platform team to set that variable on each Bitbucket deployment environment:

```yaml
servers:
  - url: ${MY_SERVICE_UPSTREAM_URL}
```

The prefix is derived from your service directory name — uppercase with hyphens replaced by underscores (e.g. `my-service` → `MY_SERVICE`, `kongair-bookings` → `KONGAIR_BOOKINGS`).

---

## Step 2 — Add your service

### Directory structure

```
services/
└── my-service/
    └── openapi.yaml        ← your API spec
```

Create the directory and file under `services/`. The folder name becomes the service identifier in Kong — use lowercase, hyphen-separated names (e.g. `kongair-loyalty`, `kongair-check-in`).

### Example

**`services/kongair-loyalty/openapi.yaml`**

```yaml
openapi: "3.1.0"
info:
  title: KongAir Loyalty
  version: "v1"
servers:
  - url: https://httpbin.konghq.com
paths:
  /v1/members/{id}/points:
    get:
      operationId: getMemberPoints
      summary: Get a loyalty member's points balance
      tags:
        - Loyalty
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
      responses:
        "200":
          description: Points balance
        "404":
          description: Not found
      security:
        - bearerAuth: []
components:
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
```

---

## Step 3 — Understand what the pipeline does for you

Once you push your `openapi.yaml`, the pipeline automatically:

1. Converts your `openapi.yaml` to Kong routes and services (`deck file openapi2kong`)
2. Injects OIDC authentication onto every route (`deck file add-plugins`) — no action needed from you
3. Merges your service config with global platform plugins and syncs to Kong Konnect

**You do not need to configure authentication, rate limiting, logging, or telemetry.** These are applied globally by the platform team.

---

## Step 4 — OpenAPI spec requirements

The pipeline relies on your spec being well-formed. Follow these rules:

| Rule | Detail |
|---|---|
| Use OpenAPI 3.x | 3.0.x or 3.1.x are both supported |
| Every operation needs a unique `operationId` | Used by the pipeline to generate Kong route names — duplicates cause failures |
| `operationId` must be unique across all services | Conflicts across services will cause a merge error |
| `servers[0].url` must be set | Your upstream's base URL, or a `${<PREFIX>_UPSTREAM_URL}` placeholder |
| Include all paths your service exposes | Routes in Kong are generated 1:1 from paths in the spec |
| Do not add Kong-specific extensions | The platform team manages `x-kong-*` annotations if needed |

---

## Step 5 — Deploy via branches

Each environment has a dedicated `releases/<env>` branch.

```
releases/dev   → dev Kong control plane   (automatic)
releases/qa    → qa Kong control plane    (automatic)
releases/uat   → uat Kong control plane   (manual approval required)
releases/prd   → prod Kong control plane  (manual approval required)
```

### Typical promotion workflow

```
1. Create a feature branch from main
   git checkout -b feature/add-kongair-loyalty

2. Add your OpenAPI spec
   services/kongair-loyalty/openapi.yaml

3. Open a Pull Request
   → Pipeline validates your config and shows a diff (no deployment)
   → Review the diff output in the pipeline logs

4. After PR approval, merge to main
   → Auto-deploys to dev

5. For qa: push/merge to releases/qa → auto-deploys
   For uat: push/merge to releases/uat → requires manual approval in Bitbucket
   For prd: push/merge to releases/prd → requires manual approval in Bitbucket
```

---

## Step 6 — Remove a service

To decommission a service from Kong, simply delete its directory from the branch:

```bash
git rm -r services/kongair-loyalty/
git commit -m "Remove kongair-loyalty service"
git push origin releases/prod   # or whichever environment
```

The pipeline will no longer include that service in the next sync. Kong Konnect will remove the routes and service on the next `deck gateway sync`.

> **Do this on each `releases/<env>` branch** that the service was deployed to. Removing from one branch only removes it from that environment.

---

## Validating locally before pushing

Install deck and validate your spec without needing pipeline access:

```bash
# Install deck (one-time)
curl -sL https://github.com/kong/deck/releases/download/v1.55.0/deck_1.55.0_linux_amd64.tar.gz | tar -xz
sudo mv deck /usr/local/bin/

# Convert your OAS to Kong config
deck file openapi2kong --inso-compatible \
  --spec services/my-service/openapi.yaml \
  -o /tmp/my-service.yaml

# Validate
deck file validate /tmp/my-service.yaml
```

Common errors caught here:
- Duplicate `operationId` values
- Invalid path parameter definitions (parameter in path but not declared)
- Malformed YAML

---

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| Duplicate `operationId` across operations | Pipeline fails at `openapi2kong` | Make every `operationId` unique across all your paths |
| Duplicate `operationId` across services | `deck file merge` fails | Prefix with service name, e.g. `kongairLoyalty_getMemberPoints` |
| `servers[0].url` left blank or unreachable | Kong routes correctly but requests fail | Verify the URL is reachable from the Kong data plane |
| `${<PREFIX>_UPSTREAM_URL}` left unset | Deploy fails with a clear error naming the missing variable | Ask the platform team to set it on the deployment environment |

---

## Getting help

| Question | Contact |
|---|---|
| Pipeline is failing and you're not sure why | Platform team — share the Bitbucket pipeline run URL |
| Want to add a custom plugin to your service | Platform team — plugins are platform-managed |
| Need a new environment or control plane | Platform team |
| OpenAPI spec validation errors | Check deck output; refer to deck docs at https://docs.konghq.com/deck/ |
