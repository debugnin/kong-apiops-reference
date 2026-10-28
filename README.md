# Kong Konnect APIOps Pipeline Reference

This repository is a reference template for managing Kong Gateway configuration via an APIOps pipeline, using `deck` and a Bitbucket Pipelines workflow. It demonstrates two upstream patterns — **AWS Lambda** and **ECS/ALB HTTP** — and is designed around a clear ownership boundary between application teams and the platform team.

The two example services, **KongAir Bookings** and **KongAir Flights**, are fictional — part of the [KongAir](https://github.com/Kong/KongAir) demo airline used across Kong's reference material. They stand in for two real application teams: one shipping a Lambda function, the other an ECS/ALB-fronted HTTP service.

## Ownership Model

| Owner                | Files                                                     |
| --------------------- | --------------------------------------------------------- |
| **Application team** | `services/<service>/openapi.yaml` — API specification     |
| **Platform team**    | `platform/kong/**` — all Kong plugin and config templates |
| **Platform team**    | `bitbucket-pipelines.yml` — pipeline definition           |
| **Platform team**    | `scripts/` — pipeline utilities                           |

Application teams declare _what_ their service is via OpenAPI specs. Service upstream configuration (type, ARNs) is supplied as Bitbucket deployment environment variables. The pipeline decides _how_ to configure Kong.

## Repository Structure

```
.
├── services/
│   ├── kongair-bookings/           # Lambda-backed service example
│   │   └── openapi.yaml            # OpenAPI specification (app team)
│   └── kongair-flights/            # ECS/ALB HTTP service example
│       └── openapi.yaml
│
├── platform/
│   └── kong/
│       ├── service-plugins/        # Plugin templates injected by the pipeline
│       │   ├── oidc.yaml           # OIDC auth — applied to every service
│       │   ├── aws-lambda.yaml     # AWS Lambda plugin — applied to lambda services
│       │   └── header-cert-auth.yaml  # mTLS client-cert auth — applied to mtls routes
│       ├── global-plugins/         # Gateway-wide plugins
│       │   ├── correlation-id.yaml
│       │   ├── cors.yaml
│       │   ├── file-log.yaml
│       │   ├── open-telemetry.yaml
│       │   ├── pre-function.yaml
│       │   ├── rate-limiting-advanced.yaml
│       │   ├── request-size-limiting.yaml       # 5 MiB inbound body cap
│       │   ├── request-transformer-advanced.yaml
│       │   └── response-transformer-advanced.yaml
│       ├── ca-certs/
│       │   └── ca-certs.yaml
│       ├── consumers/
│       │   └── consumers.yaml
│       └── patches/
│           └── patches.yaml
│
├── scripts/
│   └── duplicate-routes.py         # mTLS / non-mTLS route duplication
├── upstream-examples/
│   └── kongair-test-upstreams.yaml # Test Lambda + ECS/ALB stubs for both services
└── bitbucket-pipelines.yml
```

## Service Configuration via Environment Variables

Service upstream configuration is supplied as Bitbucket deployment environment variables rather than checked-in files. The pipeline derives the variable names from the service directory name by uppercasing it and replacing hyphens with underscores (e.g. `kongair-bookings` → `KONGAIR_BOOKINGS`).

### Lambda service

| Variable | Description |
| -------------------------------- | ----------------------------------------------- |
| `<PREFIX>_UPSTREAM_TYPE=lambda` | Marks the service as Lambda-backed |
| `<PREFIX>_LAMBDA_ARN` | Full ARN of the Lambda function |
| `<PREFIX>_IAM_ROLE_ARN` | IAM role ARN Kong assumes to invoke the function |

### ECS/HTTP service

| Variable | Description |
| -------------------------------- | ----------------------------------------------- |
| `<PREFIX>_UPSTREAM_TYPE=ecs` | Marks the service as ECS/HTTP-backed (default) |

The upstream URL for ECS services comes from the `servers` field in `openapi.yaml`. If `<PREFIX>_UPSTREAM_TYPE` is not set, `ecs` is assumed.

When the upstream URL differs per environment, write it as a `${<PREFIX>_UPSTREAM_URL}` placeholder rather than hardcoding it. The pipeline substitutes it at deploy time from that environment's Bitbucket deployment variable, so one spec serves dev, qa, uat and prd. An unset variable, or any placeholder left unsubstituted, fails the deploy.

## Example Services in This Repo

| Service directory | Upstream type | Prefix |
|---|---|---|
| `services/kongair-bookings/` | Lambda | `KONGAIR_BOOKINGS` |
| `services/kongair-flights/` | ECS/ALB | `KONGAIR_FLIGHTS` |

`kongair-flights/openapi.yaml` uses `${KONGAIR_FLIGHTS_UPSTREAM_URL}` as its `servers[0].url` placeholder. `kongair-bookings/openapi.yaml` keeps a placeholder host, since the pipeline overwrites it with the Lambda function name at deploy time.

See [`upstream-examples/`](upstream-examples/) for a CloudFormation stack that deploys working test upstreams for both.

## Pipeline Overview

For each service, the pipeline:

1. Reads `<PREFIX>_UPSTREAM_TYPE` from environment variables to determine upstream type
2. Substitutes `${<PREFIX>_UPSTREAM_URL}` in `openapi.yaml` from the environment's deployment variables, then converts it → Kong config via `deck file openapi2kong`
3. **Lambda only**: patches the Kong service host to the Lambda function name
4. Duplicates routes into `mtls` and `non-mtls` variants
5. Injects `platform/kong/service-plugins/oidc.yaml` (all services)
6. **Lambda only**: injects `platform/kong/service-plugins/aws-lambda.yaml`
7. Merges global plugins, consumers, and patches
8. Validates and syncs to Kong Konnect

## Branch → Environment Mapping

| Branch         | Environment    | Trigger              |
| -------------- | -------------- | --------------------- |
| `releases/dev` | dev            | Automatic            |
| `releases/qa`  | qa             | Automatic            |
| `releases/uat` | uat            | Manual (approval)    |
| `releases/prd` | prod           | Manual (approval)    |
| `main`         | dev (fallback) | Automatic            |
| Pull requests  | —              | Validate + diff only |

Environment-specific ARNs and upstream configuration are set as Bitbucket deployment environment variables per environment — there are no environment-specific files in the repository.

## Required Bitbucket Variables

Set these in **Repository Settings → Pipelines → Deployments** per environment:

### Platform variables

| Variable                           | Description                                                |
| ----------------------------------- | ------------------------------------------------------------ |
| `AWS_ROLE_ARN`                     | IAM role the pipeline assumes via OIDC                     |
| `KONNECT_CONTROL_PLANE_SECRET_ARN` | AWS Secrets Manager ARN for Kong Konnect credentials       |
| `AWS_REGION`                       | AWS region (e.g. `ap-southeast-2`)                         |
| `OIDC_ISSUER_AUTH0`                | Auth0 OIDC issuer URL (non-mTLS routes)                    |
| `OIDC_ISSUER_COGNITO`              | Cognito OIDC issuer URL (mTLS routes)                      |
| `OIDC_AUDIENCE`                    | OIDC audience value                                        |
| `ENVIRONMENT_NAME`                 | Environment label used in mTLS certificate validation      |
| `PRODUCT_NAME`                     | Product label used in telemetry/log fields (e.g. `kongair`) |
| `NEW_RELIC_API_KEY`                | New Relic API key for OpenTelemetry (optional)             |
| `KONNECT_ADDR`                     | Konnect API address (default: `https://au.api.konghq.com`) |

### Per-service variables

For each service directory, set variables using the service name as a prefix (uppercase, hyphens → underscores):

| Variable | Description |
| -------------------------------- | ----------------------------------------------- |
| `<PREFIX>_UPSTREAM_TYPE` | `lambda` or `ecs` (defaults to `ecs` if unset) |
| `<PREFIX>_LAMBDA_ARN` | Lambda function ARN (**Lambda only**) |
| `<PREFIX>_IAM_ROLE_ARN` | IAM role ARN for Lambda invocation (**Lambda only**) |
| `<PREFIX>_UPSTREAM_URL` | Upstream base URL (**ECS only**, when it differs per environment) |

**Examples** for services `kongair-bookings` (Lambda) and `kongair-flights` (ECS):

```
KONGAIR_BOOKINGS_UPSTREAM_TYPE=lambda
KONGAIR_BOOKINGS_LAMBDA_ARN=arn:aws:lambda:ap-southeast-2:123456789012:function:kongair-bookings-api-dev
KONGAIR_BOOKINGS_IAM_ROLE_ARN=arn:aws:iam::123456789012:role/kong-kongair-bookings-lambda-invoker-role-dev

KONGAIR_FLIGHTS_UPSTREAM_TYPE=ecs
KONGAIR_FLIGHTS_UPSTREAM_URL=http://kongair-flights-alb-dev.ap-southeast-2.elb.amazonaws.com
```

## AWS Secrets Manager Format

The secret referenced by `KONNECT_CONTROL_PLANE_SECRET_ARN` must contain:

```json
{
  "konnect_token": "kpat_YOUR_TOKEN",
  "control_plane_name": "your-control-plane-name"
}
```

## Adding a New Service

### Lambda-backed service

1. Create `services/my-service/openapi.yaml` — your OpenAPI spec. Set `servers` to a placeholder (the pipeline overwrites the host with the Lambda function name).
2. In Bitbucket, add the following deployment environment variables for each environment:
   ```
   MY_SERVICE_UPSTREAM_TYPE=lambda
   MY_SERVICE_LAMBDA_ARN=arn:aws:lambda:ap-southeast-2:123456789012:function:my-service-<env>
   MY_SERVICE_IAM_ROLE_ARN=arn:aws:iam::123456789012:role/kong-my-service-invoker-role-<env>
   ```
   The prefix is derived from the directory name: `my-service` → `MY_SERVICE`.

### ECS/HTTP-backed service

1. Create `services/my-service/openapi.yaml` with `servers[0].url` set to `${MY_SERVICE_UPSTREAM_URL}` (or a literal URL if it is the same in every environment), and have the platform team set that variable per deployment environment.
2. Optionally set `MY_SERVICE_UPSTREAM_TYPE=ecs` in Bitbucket deployment variables (this is the default and can be omitted).
3. Done — no additional configuration needed.

## mTLS / Non-mTLS Route Splitting

The `scripts/duplicate-routes.py` script duplicates every route into two variants:

- **`non-mtls`** — standard route, authenticated via Auth0 OIDC
- **`mtls`** — adds `X-Amzn-Mtls-Clientcert-Issuer` header matching, authenticated via Cognito OIDC

The `platform/kong/service-plugins/oidc.yaml` platform plugin uses JSONPath selectors on these tags to apply the correct issuer per route type.

## Request Payload Limit

Inbound request bodies are capped at **5 MiB (5,242,880 bytes)** across every service and route, enforced by `platform/kong/global-plugins/request-size-limiting.yaml`.

Three points for integrators:

- **The rejection status is `413` or `417`.** Kong returns `417 Expectation Failed` instead of `413 Payload Too Large` when the request carries an `Expect: 100-continue` header, which many HTTP clients add automatically for larger uploads. Both carry the body `{"message":"Request size limit exceeded"}` — handle both.
- **The error body is Kong's own** and does not match the error envelope the services return. Treat it as a gateway-level rejection rather than an application error.
- **Authentication is evaluated first**, so an oversized request with an invalid token returns `401`, not `413`.

Requests without a `Content-Length` header, including chunked transfers, are still measured — Kong sizes the buffered body, or stats the temporary file when nginx has spilled it to disk.

The limit governs inbound requests only — response sizes are unaffected. For a service that legitimately needs more headroom (e.g. bulk uploads), bind a route-level override of this plugin at that route rather than raising the global ceiling.

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
