# APIOps Pipeline — Application Team Onboarding Guide

> **Audience:** Application development teams onboarding a new service to Kong Gateway via the APIOps pipeline.
>
> **What you need to know about Kong:** Nothing. This guide covers everything you need to do. The platform team handles all Kong configuration.

---

## How It Works

The APIOps pipeline automatically configures Kong Gateway from one file you own per service plus environment variables set in Bitbucket:

| What | Where |
|---|---|
| `services/<your-service>/openapi.yaml` | Your API specification (OpenAPI 3.x) — committed to the repo |
| Bitbucket deployment variables | Upstream type and ARNs — set per environment in Bitbucket, not in code |

The pipeline reads your OpenAPI spec, reads service configuration from environment variables, converts your API spec into Kong route/service configuration, injects authentication (OIDC) and any upstream plugins automatically, and syncs to Kong Konnect. You do not write Kong config directly.

### Ownership boundary

```
┌─────────────────────────────────────┬──────────────────────────────────────┐
│  Application team owns              │  Platform team owns                  │
├─────────────────────────────────────┼──────────────────────────────────────┤
│  services/<svc>/openapi.yaml        │  platform/kong/**                    │
│  Bitbucket deployment variables     │  scripts/                            │
│  (<PREFIX>_UPSTREAM_TYPE, ARNs)     │  bitbucket-pipelines.yml             │
└─────────────────────────────────────┴──────────────────────────────────────┘
```

This repo ships two example services playing the application-team role: `kongair-bookings` (Lambda) and `kongair-flights` (ECS/ALB). They're referenced throughout this guide as worked examples.

---

## Prerequisites

Before you start, confirm with the platform team that:

- [ ] A Bitbucket deployment environment exists for each target environment (dev / qa / uat / prod)
- [ ] The IAM role for your Lambda function (if applicable) trusts the Kong invoker role — the platform team will provide the role ARN and set it as a Bitbucket variable
- [ ] Your ECS service / ALB is reachable from the Kong data plane (if ECS-backed)
- [ ] The platform team has added your service's environment variables (`<PREFIX>_UPSTREAM_TYPE`, etc.) to each Bitbucket deployment environment

---

## Step 1 — Understand the two service types

### Lambda-backed service

Your API is implemented as an AWS Lambda function. Kong invokes Lambda directly; there is no ALB in the request path.

```
Client → Kong Gateway → AWS Lambda
```

This repo's `kongair-bookings` service is an example of this pattern — see `services/kongair-bookings/openapi.yaml` and `upstream-examples/kongair-test-upstreams.yaml`.

**What you provide as Bitbucket deployment variables** (set per environment by the platform team on your behalf):

| Variable | Example value |
|---|---|
| `<PREFIX>_UPSTREAM_TYPE` | `lambda` |
| `<PREFIX>_LAMBDA_ARN` | `arn:aws:lambda:ap-southeast-2:123456789012:function:my-service-dev` |
| `<PREFIX>_IAM_ROLE_ARN` | `arn:aws:iam::123456789012:role/kong-my-service-invoker-role-dev` |

The prefix is derived from your service directory name — uppercase with hyphens replaced by underscores (e.g. `my-service` → `MY_SERVICE`, `kongair-bookings` → `KONGAIR_BOOKINGS`).

- `<PREFIX>_LAMBDA_ARN` — the full ARN of the Lambda function for this environment
- `<PREFIX>_IAM_ROLE_ARN` — the IAM role Kong assumes to invoke your function (platform team creates this; you provide the ARN)

**What you put in `openapi.yaml` for `servers`:**

Use any placeholder — the pipeline overwrites the host with the Lambda function name automatically.

```yaml
servers:
  - url: https://placeholder.example.com
```

---

### ECS/HTTP-backed service

Your API runs on ECS and is fronted by an Application Load Balancer (ALB).

```
Client → Kong Gateway → ALB → ECS task
```

This repo's `kongair-flights` service is an example of this pattern — see `services/kongair-flights/openapi.yaml`.

**What you provide as Bitbucket deployment variables:**

| Variable | Example value |
|---|---|
| `<PREFIX>_UPSTREAM_TYPE` | `ecs` |

That's it. No ARNs needed. (`ecs` is the default if the variable is not set.)

**What you put in `openapi.yaml` for `servers`:**

Set the `servers` URL to your ALB DNS name (or internal URL), or — if it differs per environment — a `${<PREFIX>_UPSTREAM_URL}` placeholder (see Step 5).

```yaml
servers:
  - url: https://my-service-alb-123456789.ap-southeast-2.elb.amazonaws.com
```

---

## Step 2 — Add your service

### Directory structure

```
services/
└── my-service/
    └── openapi.yaml        ← your API spec
```

Create the directory and file under `services/`. The folder name becomes the service identifier in Kong — use lowercase, hyphen-separated names (e.g. `kongair-loyalty`, `kongair-check-in`).

Ask the platform team to add the corresponding Bitbucket deployment variables for each environment.

---

### Example: Lambda-backed service

**Bitbucket deployment variables** (set per environment):

```
KONGAIR_LOYALTY_UPSTREAM_TYPE=lambda
KONGAIR_LOYALTY_LAMBDA_ARN=arn:aws:lambda:ap-southeast-2:123456789012:function:kongair-loyalty-dev
KONGAIR_LOYALTY_IAM_ROLE_ARN=arn:aws:iam::123456789012:role/kong-kongair-loyalty-invoker-role-dev
```

**`services/kongair-loyalty/openapi.yaml`**

```yaml
openapi: "3.1.0"
info:
  title: KongAir Loyalty
  version: "v1"
servers:
  - url: https://placeholder.example.com
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

### Example: ECS/HTTP-backed service

**Bitbucket deployment variables** (set per environment):

```
KONGAIR_CHECK_IN_UPSTREAM_TYPE=ecs
```

(Can be omitted — `ecs` is the default.)

**`services/kongair-check-in/openapi.yaml`**

```yaml
openapi: "3.1.0"
info:
  title: KongAir Check-In
  version: "v1"
servers:
  - url: https://kongair-check-in-alb-123456789.ap-southeast-2.elb.amazonaws.com
paths:
  /v1/check-in/{ticketNumber}:
    post:
      operationId: checkIn
      summary: Check in a passenger for their flight
      tags:
        - Check-In
      parameters:
        - name: ticketNumber
          in: path
          required: true
          schema:
            type: string
      responses:
        "200":
          description: Checked in successfully
        "400":
          description: Bad request
        "401":
          description: Unauthorized
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

Once you push your `openapi.yaml` (and the platform team has set your environment variables), the pipeline automatically:

1. Converts your `openapi.yaml` to Kong routes and services
2. Splits every route into two variants:
   - **`non-mtls`** — authenticated via Auth0 (standard bearer token)
   - **`mtls`** — authenticated via Cognito, with mTLS client certificate header matching
3. Injects OIDC authentication onto all routes (no action needed from you)
4. (Lambda only) Sets the Kong service to invoke your Lambda function with the correct IAM role
5. Merges your service config with global platform plugins and syncs to Kong Konnect

**You do not need to configure authentication, rate limiting, logging, or telemetry.** These are applied globally by the platform team.

---

## Step 4 — OpenAPI spec requirements

The pipeline relies on your spec being well-formed. Follow these rules:

| Rule | Detail |
|---|---|
| Use OpenAPI 3.x | 3.0.x or 3.1.x are both supported |
| Every operation needs a unique `operationId` | Used by the pipeline to generate Kong route names — duplicates cause failures |
| `operationId` must be unique across all services | Conflicts across services will cause a merge error |
| `servers[0].url` must be set | ECS: set to your ALB URL (or `${<PREFIX>_UPSTREAM_URL}` placeholder). Lambda: set to any placeholder |
| Include all paths your service exposes | Routes in Kong are generated 1:1 from paths in the spec |
| Do not add Kong-specific extensions | The platform team manages `x-kong-*` annotations if needed |

---

## Step 5 — Deploy via branches

Each environment has a dedicated `releases/<env>` branch. Environment-specific ARNs are stored as Bitbucket deployment variables — there are no environment-specific files in the repository.

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

3. Ask the platform team to add environment variables for each environment:
   KONGAIR_LOYALTY_UPSTREAM_TYPE=lambda
   KONGAIR_LOYALTY_LAMBDA_ARN=arn:aws:lambda:...:function:kongair-loyalty-<env>
   KONGAIR_LOYALTY_IAM_ROLE_ARN=arn:aws:iam::...:role/kong-kongair-loyalty-invoker-role-<env>

4. Open a Pull Request
   → Pipeline validates your config and shows a diff (no deployment)
   → Review the diff output in the pipeline logs

5. After PR approval, merge to main
   → Auto-deploys to dev

6. For qa: push/merge to releases/qa → auto-deploys
   For uat: push/merge to releases/uat → requires manual approval in Bitbucket
   For prd: push/merge to releases/prd → requires manual approval in Bitbucket
```

For ECS services, the upstream URL comes from `servers[0].url` in `openapi.yaml`. When it differs per environment, do **not** edit the spec per deploy — write it as a placeholder named after your service and let the pipeline substitute it:

```yaml
servers:
  - url: ${MY_SERVICE_UPSTREAM_URL}
```

Then ask the platform team to set `MY_SERVICE_UPSTREAM_URL` on each deployment environment. A referenced variable that is unset fails the deploy.

`MY_SERVICE` here is a stand-in for your own service's prefix, derived from the service directory name (uppercase, hyphens replaced by underscores). The services currently in this repo are:

| Service directory | Prefix | Upstream type |
|---|---|---|
| `services/kongair-bookings/` | `KONGAIR_BOOKINGS` | Lambda — placeholder host, pipeline overwrites it |
| `services/kongair-flights/` | `KONGAIR_FLIGHTS` | ECS — uses the `${KONGAIR_FLIGHTS_UPSTREAM_URL}` placeholder |

Only `kongair-flights` uses the placeholder today — `kongair-bookings` is Lambda-backed, so its `servers` URL stays a placeholder host that the pipeline overwrites with the Lambda function name.

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
| Lambda `servers` URL left as a real hostname | Won't break the pipeline, but misleading | Use `https://placeholder.example.com` |
| ECS `servers` URL is wrong or unreachable | Kong routes correctly but requests fail | Verify the ALB DNS and security group rules |
| Wrong Lambda ARN in Bitbucket variable | Runtime invocation error from Kong | Double-check ARN format: `arn:aws:lambda:<region>:<account>:function:<name>` |
| Lambda ARN for the wrong environment set in a Bitbucket deployment env | Requests hit the wrong function | Verify ARNs are set in the correct Bitbucket deployment environment |

---

## Getting help

| Question | Contact |
|---|---|
| Pipeline is failing and you're not sure why | Platform team — share the Bitbucket pipeline run URL |
| Need a new IAM invoker role for your Lambda | Platform team |
| Want to add a custom plugin to your service | Platform team — plugins are platform-managed |
| Need a new environment or control plane | Platform team |
| OpenAPI spec validation errors | Check deck output; refer to deck docs at https://docs.konghq.com/deck/ |
