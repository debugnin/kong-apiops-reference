# Kong Konnect APIOps Pipeline Reference

This repository is a reference template for managing Kong Gateway configuration via an APIOps pipeline, using `deck` and a Bitbucket Pipelines workflow. It's a minimal demo of the common `deck` conversion flow — `openapi2kong` → `add-plugins` → `merge` → `validate` → `sync`/`diff` — and of the ownership boundary between application teams and the platform team.

The two example services, **KongAir Bookings** and **KongAir Flights**, are fictional — part of the [KongAir](https://github.com/Kong/KongAir) demo airline used across Kong's reference material. Both point at [`httpbin.konghq.com`](https://httpbin.konghq.com), Kong's public httpbin instance, as their upstream, so the pipeline in this repo deploys against a real, reachable backend rather than a mocked one.

## Ownership Model

| Owner                | Files                                                     |
| --------------------- | --------------------------------------------------------- |
| **Application team** | `services/<service>/openapi.yaml` — API specification     |
| **Platform team**    | `platform/kong/**` — all Kong plugin and config templates |
| **Platform team**    | `bitbucket-pipelines.yml` — pipeline definition           |

Application teams declare _what_ their service is via an OpenAPI spec. The platform team owns everything about _how_ that spec becomes Kong configuration — authentication, logging, rate limiting, telemetry — via the plugin templates in `platform/kong/`.

## Repository Structure

```
.
├── services/
│   ├── kongair-bookings/           # Service example #1
│   │   └── openapi.yaml            # OpenAPI specification (app team)
│   └── kongair-flights/            # Service example #2
│       └── openapi.yaml
│
├── platform/
│   └── kong/
│       ├── service-plugins/
│       │   └── oidc.yaml           # OIDC auth — applied to every service
│       ├── global-plugins/         # Gateway-wide plugins
│       │   ├── correlation-id.yaml
│       │   ├── cors.yaml
│       │   ├── file-log.yaml
│       │   ├── open-telemetry.yaml
│       │   ├── rate-limiting-advanced.yaml
│       │   └── request-size-limiting.yaml       # 5 MiB inbound body cap
│       ├── consumers/
│       │   └── consumers.yaml
│       └── patches/
│           └── patches.yaml
│
└── bitbucket-pipelines.yml
```

## The `deck` Conversion Flow

Both services in this repo go through the same sequence of `deck` commands — this is the flow the pipeline automates, and the one worth understanding if you're new to `deck`:

```
openapi.yaml
    │
    ▼  deck file openapi2kong --inso-compatible --spec <file>
Kong service + routes (per service)
    │
    ▼  deck file add-plugins -s <file> platform/kong/service-plugins/oidc.yaml
Kong service + routes + OIDC plugin (per service)
    │
    ▼  deck file merge <all services> consumers.yaml global-plugins/*.yaml
One combined Kong config
    │
    ▼  deck file patch -s <file> platform/kong/patches/patches.yaml
    ▼  deck file validate <file>
Validated final config
    │
    ▼  deck gateway sync / deck gateway diff
Kong Konnect
```

Try it yourself without the pipeline — see [Local Validation](#local-validation) below.

## Services in This Repo

| Service directory | Upstream | Notes |
|---|---|---|
| `services/kongair-bookings/` | `https://httpbin.konghq.com` | Create/list/cancel bookings |
| `services/kongair-flights/` | `https://httpbin.konghq.com` | List/get scheduled flights |

Both specs hardcode `https://httpbin.konghq.com` as `servers[0].url`, so `deck file openapi2kong` derives the Kong service `host`/`protocol`/`port` from the spec directly — no environment-specific substitution needed for this demo. In a real repo you'd typically point this at your own per-environment upstream (see [`docs/PIPELINE_GUIDE.md`](docs/PIPELINE_GUIDE.md#environment-specific-values-in-specs) for the `${<PREFIX>_UPSTREAM_URL}` placeholder pattern this template supports).

## Pipeline Overview

For each service, the pipeline:

1. `deck file openapi2kong` — convert `openapi.yaml` → Kong service/routes
2. `deck file add-plugins` — inject `platform/kong/service-plugins/oidc.yaml`

Then, once per run:

3. `deck file merge` — combine every service's config with global plugins, consumers, and patches
4. `deck file patch` — apply `platform/kong/patches/patches.yaml`
5. `deck file validate` — validate the merged config
6. `deck gateway sync` (or `deck gateway diff` on pull requests) — apply to Kong Konnect

## Branch → Environment Mapping

| Branch         | Environment    | Trigger              |
| -------------- | -------------- | --------------------- |
| `releases/dev` | dev            | Automatic            |
| `releases/qa`  | qa             | Automatic            |
| `releases/uat` | uat            | Manual (approval)    |
| `releases/prd` | prod           | Manual (approval)    |
| `main`         | dev (fallback) | Automatic            |
| Pull requests  | —              | Validate + diff only |

## Required Bitbucket Variables

Set these in **Repository Settings → Pipelines → Deployments** per environment:

| Variable                           | Description                                                |
| ----------------------------------- | ------------------------------------------------------------ |
| `AWS_ROLE_ARN`                     | IAM role the pipeline assumes via OIDC                     |
| `KONNECT_CONTROL_PLANE_SECRET_ARN` | AWS Secrets Manager ARN for Kong Konnect credentials       |
| `AWS_REGION`                       | AWS region (e.g. `ap-southeast-2`)                         |
| `OIDC_ISSUER`                      | OIDC issuer URL used by the `openid-connect` plugin        |
| `OIDC_AUDIENCE`                    | OIDC audience value                                        |
| `ENVIRONMENT_NAME`                 | Environment label used in log/telemetry fields             |
| `PRODUCT_NAME`                     | Product label used in telemetry/log fields (e.g. `kongair`) |
| `NEW_RELIC_API_KEY`                | New Relic API key for OpenTelemetry (optional)             |
| `KONNECT_ADDR`                     | Konnect API address (default: `https://au.api.konghq.com`) |

No per-service variables are required for the two example services, since both hardcode their upstream. See [`docs/PIPELINE_GUIDE.md`](docs/PIPELINE_GUIDE.md) for the optional `${<PREFIX>_UPSTREAM_URL}` pattern if you add a service whose upstream differs per environment.

## AWS Secrets Manager Format

The secret referenced by `KONNECT_CONTROL_PLANE_SECRET_ARN` must contain:

```json
{
  "konnect_token": "kpat_YOUR_TOKEN",
  "control_plane_name": "your-control-plane-name"
}
```

## Adding a New Service

1. Create `services/my-service/openapi.yaml` with `servers[0].url` set to your upstream (a literal URL, or a `${MY_SERVICE_UPSTREAM_URL}` placeholder if it differs per environment — see [`docs/PIPELINE_GUIDE.md`](docs/PIPELINE_GUIDE.md#environment-specific-values-in-specs)).
2. Open a pull request — the pipeline validates the spec and shows a diff.
3. Merge to `releases/<env>` to deploy.

No platform changes are needed — OIDC, CORS, logging, telemetry and rate limiting apply automatically to every service.

## Request Payload Limit

Inbound request bodies are capped at **5 MiB (5,242,880 bytes)** across every service and route, enforced by `platform/kong/global-plugins/request-size-limiting.yaml`.

Three points for integrators:

- **The rejection status is `413` or `417`.** Kong returns `417 Expectation Failed` instead of `413 Payload Too Large` when the request carries an `Expect: 100-continue` header, which many HTTP clients add automatically for larger uploads. Both carry the body `{"message":"Request size limit exceeded"}` — handle both.
- **The error body is Kong's own** and does not match the error envelope the services return. Treat it as a gateway-level rejection rather than an application error.
- **Authentication is evaluated first**, so an oversized request with an invalid token returns `401`, not `413`.

Requests without a `Content-Length` header, including chunked transfers, are still measured — Kong sizes the buffered body, or stats the temporary file when nginx has spilled it to disk.

The limit governs inbound requests only — response sizes are unaffected. For a service that legitimately needs more headroom, bind a route-level override of this plugin at that route rather than raising the global ceiling.

Kong's own `client_max_body_size` on the data planes sits above this limit so the plugin governs the boundary and returns consistent JSON; if it were set at or below 5 MiB, nginx would reject first with an HTML error page instead.

## Local Validation

```bash
# Install deck
curl -sL https://github.com/kong/deck/releases/download/v1.55.0/deck_1.55.0_linux_amd64.tar.gz | tar -xz
sudo mv deck /usr/local/bin/

# Convert a service OAS
deck file openapi2kong --inso-compatible --spec services/kongair-bookings/openapi.yaml -o /tmp/kongair-bookings.yaml

# Validate
deck file validate /tmp/kongair-bookings.yaml

# Inject the OIDC plugin (substitute the placeholders first)
sed -e "s|\${OIDC_ISSUER}|https://your-issuer.example.com/|g" \
    -e "s|\${OIDC_AUDIENCE}|your-audience|g" \
    platform/kong/service-plugins/oidc.yaml > /tmp/oidc.yaml
deck file add-plugins -s /tmp/kongair-bookings.yaml /tmp/oidc.yaml -o /tmp/kongair-bookings.yaml

# Diff against a live control plane
deck gateway diff /tmp/kongair-bookings.yaml \
  --konnect-addr https://au.api.konghq.com \
  --konnect-control-plane-name your-cp \
  --konnect-token $KONNECT_TOKEN
```

## Documentation

- [`docs/QUICKSTART.md`](docs/QUICKSTART.md) — set up the pipeline and deploy your first service
- [`docs/PIPELINE_GUIDE.md`](docs/PIPELINE_GUIDE.md) — full Bitbucket pipeline reference
- [`docs/WORKFLOW.md`](docs/WORKFLOW.md) — diagrams of the ownership model, pipeline flow, and branch strategy
- [`docs/APPLICATION_TEAM_ONBOARDING.md`](docs/APPLICATION_TEAM_ONBOARDING.md) — onboarding guide for app teams who just need to ship an `openapi.yaml`

## Additional Resources

- [deck Documentation](https://docs.konghq.com/deck/)
- [Kong Konnect](https://docs.konghq.com/konnect/)
- [OpenAPI Specification](https://swagger.io/specification/)
- [Bitbucket Pipelines](https://support.atlassian.com/bitbucket-cloud/docs/get-started-with-bitbucket-pipelines/)
- [KongAir](https://github.com/Kong/KongAir) — the demo airline these example services are drawn from
- [httpbin.konghq.com](https://httpbin.konghq.com) — the real public upstream both example services point at
