# Kong Konnect APIOps Workflow

## Repository Ownership Model

```
┌─────────────────────────────────────────────────────────────────┐
│                    Bitbucket Repository                         │
│                                                                 │
│  ┌─────────────────────────┐  ┌─────────────────────────────┐  │
│  │  Application Team       │  │  Platform Team              │  │
│  │                         │  │                             │  │
│  │  services/<svc>/        │  │  platform/kong/             │  │
│  │  └─ openapi.yaml        │  │  ├─ service-plugins/        │  │
│  │                         │  │  │   ├─ oidc.yaml           │  │
│  │  Bitbucket variables:   │  │  │   └─ aws-lambda.yaml     │  │
│  │  <PREFIX>_UPSTREAM_TYPE │  │  ├─ global-plugins/         │  │
│  │  <PREFIX>_LAMBDA_ARN    │  │  ├─ consumers/              │  │
│  │  <PREFIX>_IAM_ROLE_ARN  │  │  └─ patches/                │  │
│  │                         │  │                             │  │
│  │  (declares WHAT)        │  │  bitbucket-pipelines.yml    │  │
│  │                         │  │  scripts/                   │  │
│  │                         │  │                             │  │
│  │                         │  │  (decides HOW)              │  │
│  └─────────────────────────┘  └─────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

In this repo, `kongair-bookings` (Lambda) and `kongair-flights` (ECS/ALB) play the role of two application teams on the left. Everything on the right applies identically to both.

## Pipeline Processing Flow (per service)

```
┌──────────────────────────────────────────────────────────────────┐
│ For each services/<svc>/ directory                               │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. Read <PREFIX>_UPSTREAM_TYPE env var                          │
│     └─► upstream_type: lambda | ecs (default: ecs)             │
│                                                                  │
│  2. deck file openapi2kong                                       │
│     openapi.yaml ──► /tmp/kong-configs/<svc>.yaml               │
│                                                                  │
│  3. (lambda only) Patch service host                            │
│     └─► host = last segment of lambda_arn                      │
│         path = /                                                 │
│                                                                  │
│  4. scripts/duplicate-routes.py                                  │
│     Every route ──► non-mtls variant + mtls variant             │
│                                                                  │
│  5. deck file add-plugins (all services)                        │
│     platform/kong/service-plugins/oidc.yaml                     │
│     └─► non-mtls routes: Auth0 OIDC                            │
│     └─► mtls routes: Cognito OIDC                              │
│                                                                  │
│  6. (lambda only) deck file add-plugins                         │
│     platform/kong/service-plugins/aws-lambda.yaml               │
│     └─► function_name = <PREFIX>_LAMBDA_ARN                    │
│     └─► aws_assume_role_arn = <PREFIX>_IAM_ROLE_ARN            │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ Merge + Finalize                                                 │
│                                                                  │
│  deck file merge  ──► all service configs                       │
│       + platform/kong/global-plugins/*.yaml                     │
│       + platform/kong/consumers/consumers.yaml                  │
│       + platform/kong/patches/patches.yaml                      │
│                                                                  │
│  deck file validate ──► /tmp/final-kong.yaml                    │
│  deck gateway sync  ──► Kong Konnect                            │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

Concretely, with the two services shipped in this repo:

```
services/kongair-bookings/openapi.yaml  ──► Lambda path (steps 1,2,3,4,5,6)
services/kongair-flights/openapi.yaml   ──► ECS path    (steps 1,2,4,5)
```

## Branch-Based Environment Flow

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│  feature/* ────► Pull Request ────► (validate + diff only)    │
│                                                                │
│  releases/dev  ──► auto-deploy ──► dev  control plane         │
│  releases/qa   ──► auto-deploy ──► qa   control plane         │
│  releases/uat  ──► manual approval ──► uat  control plane     │
│  releases/prd  ──► manual approval ──► prod control plane     │
│  main          ──► auto-deploy ──► dev  (fallback)            │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

Environment-specific ARNs are stored as Bitbucket deployment variables — there are no environment-specific files in the repository. The pipeline extracts the environment name directly from the branch name.

## mTLS / Non-mTLS Route Splitting

```
┌─────────────────────────────────────────────────────────────────┐
│  Original route from OAS: GET /bookings                        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ scripts/duplicate-routes.py
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│  GET /bookings [tag: non-mtls]       GET /bookings [tag: mtls]  │
│  Standard route                      Adds header match:         │
│  OIDC: Auth0                         X-Amzn-Mtls-Clientcert-    │
│                                      Issuer = <env>             │
│                                      OIDC: Cognito              │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

The `platform/kong/service-plugins/oidc.yaml` uses JSONPath selectors on route tags to apply the correct OIDC issuer per variant.

## Pull Request Validation Flow

```
┌────────────────────────────────────────────────────────────────┐
│                     Pull Request Created                       │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
        ┌─────────────────────────────────────┐
        │   Validate Configuration            │
        │   • openapi2kong for each service   │
        │   • add-plugins (oidc + lambda)     │
        │   • merge global configs            │
        │   • deck file validate              │
        └─────────────────────────────────────┘
                              │
                              ▼
        ┌─────────────────────────────────────┐
        │   Preview Changes (diff)            │
        │   • deck gateway diff vs dev        │
        │   • shows + additions               │
        │   • shows ~ modifications           │
        │   • shows - deletions               │
        └─────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │  Approve & Merge │
                    └─────────────────┘
```

## Authentication Flow

```
┌────────────────────────────────────────────────────────────────┐
│  Bitbucket Pipeline                                            │
│  1. Step starts with OIDC token (BITBUCKET_STEP_OIDC_TOKEN)   │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  AWS STS                                                       │
│  2. Exchanges OIDC token for temporary credentials             │
│  3. Assumes AWS_ROLE_ARN                                       │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  AWS Secrets Manager                                           │
│  4. Retrieves KONNECT_CONTROL_PLANE_SECRET_ARN                 │
│  5. Returns { konnect_token, control_plane_name }              │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  Kong Konnect API                                              │
│  6. deck gateway sync --konnect-token $KONNECT_TOKEN           │
└────────────────────────────────────────────────────────────────┘
```

## Error Handling

```
Pipeline Step Failure
        │
        ├──► openapi2kong failed
        │    └─► Check OpenAPI spec is valid 3.0; run deck file validate locally
        │
        ├──► add-plugins failed
        │    └─► Check platform plugin YAML syntax
        │
        ├──► merge / validate failed
        │    └─► Review deck output; check for duplicate resource names
        │
        ├──► AWS auth failed
        │    └─► Check OIDC trust policy; verify AWS_ROLE_ARN is correct
        │
        ├──► Secrets Manager failed
        │    └─► Verify KONNECT_CONTROL_PLANE_SECRET_ARN and IAM permissions
        │
        └──► Konnect sync failed
             └─► Check control_plane_name matches exactly in Konnect
                 Verify konnect_token is valid and not expired
```

## Key Components

### Application team files (per service)

- `services/<svc>/openapi.yaml` — API spec; defines routes and upstream URL (ECS) or placeholder (lambda)
- Bitbucket deployment variables — `<PREFIX>_UPSTREAM_TYPE`, `<PREFIX>_LAMBDA_ARN`, `<PREFIX>_IAM_ROLE_ARN` (lambda only)

### Platform team files

- `platform/kong/service-plugins/oidc.yaml` — OIDC auth injected into every service
- `platform/kong/service-plugins/aws-lambda.yaml` — Lambda plugin injected into lambda services
- `platform/kong/service-plugins/header-cert-auth.yaml` — mTLS client-cert auth injected into mtls routes
- `platform/kong/global-plugins/*.yaml` — Gateway-wide plugins (correlation-id, telemetry, etc.)
- `platform/kong/consumers/consumers.yaml` — Kong consumers
- `platform/kong/patches/patches.yaml` — Post-merge patches
- `scripts/duplicate-routes.py` — mTLS/non-mTLS route duplication
- `bitbucket-pipelines.yml` — Full pipeline definition
