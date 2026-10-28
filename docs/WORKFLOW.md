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
│  │                         │  │  │   └─ oidc.yaml           │  │
│  │  (declares WHAT)        │  │  ├─ global-plugins/         │  │
│  │                         │  │  ├─ consumers/              │  │
│  │                         │  │  └─ patches/                │  │
│  │                         │  │                             │  │
│  │                         │  │  bitbucket-pipelines.yml    │  │
│  │                         │  │  (decides HOW)              │  │
│  └─────────────────────────┘  └─────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

In this repo, `kongair-bookings` and `kongair-flights` play the role of two application teams on the left. Everything on the right applies identically to both.

## Pipeline Processing Flow (per service)

```
┌──────────────────────────────────────────────────────────────────┐
│ For each services/<svc>/ directory                               │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. deck file openapi2kong                                       │
│     openapi.yaml ──► /tmp/kong-configs/<svc>.yaml               │
│                                                                  │
│  2. deck file add-plugins                                       │
│     platform/kong/service-plugins/oidc.yaml                     │
│     └─► OIDC auth applied to every route                       │
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
│                                                                  │
│  deck file patch    ──► platform/kong/patches/patches.yaml      │
│  deck file validate ──► /tmp/final-kong.yaml                    │
│  deck gateway sync  ──► Kong Konnect                            │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

Concretely, with the two services shipped in this repo:

```
services/kongair-bookings/openapi.yaml  ──► steps 1, 2
services/kongair-flights/openapi.yaml   ──► steps 1, 2
```

Both resolve to `https://httpbin.konghq.com`, so step 1 converts a real, reachable upstream for each service without any extra setup.

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

Environment labels (`ENVIRONMENT_NAME`, `PRODUCT_NAME`) and OIDC settings are stored as Bitbucket deployment variables — there are no environment-specific files in the repository. The pipeline extracts the environment name directly from the branch name.

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
        │   • add-plugins (oidc)              │
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

- `services/<svc>/openapi.yaml` — API spec; defines routes and upstream URL

### Platform team files

- `platform/kong/service-plugins/oidc.yaml` — OIDC auth injected into every service
- `platform/kong/global-plugins/*.yaml` — Gateway-wide plugins (correlation-id, telemetry, etc.)
- `platform/kong/consumers/consumers.yaml` — Kong consumers
- `platform/kong/patches/patches.yaml` — Post-merge patches
- `bitbucket-pipelines.yml` — Full pipeline definition
