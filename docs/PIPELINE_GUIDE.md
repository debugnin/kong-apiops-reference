# Bitbucket Pipeline Reference Guide

## Pipeline Steps

### `deploy-kong` — Deploy to Konnect

**Triggers:** Push to `releases/dev`, `releases/qa`, or `main` (automatic); `releases/uat` and `releases/prd` require manual approval. Each release branch deploys **only** its own environment.

**Steps:**

1. Install AWS CLI v2 and deck CLI
2. Environment comes from the step's Bitbucket `deployment` (DEV / QA / UAT / Production), which selects that environment's deployment variables
3. Authenticate with AWS via Bitbucket OIDC, assume `AWS_ROLE_ARN`
4. Retrieve Kong credentials from `KONNECT_CONTROL_PLANE_SECRET_ARN` (Secrets Manager)
5. Pre-process `platform/kong/service-plugins/oidc.yaml` with the `OIDC_ISSUER` / `OIDC_AUDIENCE` variables
6. For each service directory in `services/*/` (`kongair-bookings/`, `kongair-flights/` in this repo):
   - `deck file openapi2kong` — convert OAS to Kong config
   - `deck file add-plugins` with `oidc.yaml` — inject OIDC into the service
7. `deck file merge` — combine all service configs with global plugins, consumers, patches
8. `deck file patch` — apply `platform/kong/patches/patches.yaml`
9. `deck file validate` — validate merged config
10. `deck gateway sync` — sync to Kong Konnect

### `validate-kong` — Validate on Pull Requests

**Triggers:** Pull requests

**Steps:** Same as above through step 9 (validate), then:

10. `deck gateway diff` — show changes against the dev control plane (no sync)

## Branch Deployment Strategy

| Branch | Environment | Trigger |
|---|---|---|
| `releases/dev` | dev | Automatic on push |
| `releases/qa` | qa | Automatic on push |
| `releases/uat` | uat | Manual approval in Bitbucket |
| `releases/prd` | prod | Manual approval in Bitbucket |
| `main` | dev (fallback) | Automatic on push |
| Pull requests | — | Validate + diff against dev only |

Each release branch maps to exactly one Bitbucket deployment environment and deploys only that environment — there is no promotion chain inside a single pipeline run. Promote by merging forward: `releases/dev` → `releases/qa` → `releases/uat` → `releases/prd`.

`services/*/openapi.yaml` is the **same file** in every environment. The two example services in this repo hardcode `https://httpbin.konghq.com` as their upstream, so nothing differs between environments for them. For a service whose real upstream does differ per environment, use the `${<PREFIX>_UPSTREAM_URL}` placeholder pattern described below.

## Bitbucket Deployment Variables

Set these per deployment environment in **Repository Settings → Pipelines → Deployments**:

| Variable | Required | Description |
|---|---|---|
| `AWS_ROLE_ARN` | Yes | IAM role assumed via OIDC |
| `KONNECT_CONTROL_PLANE_SECRET_ARN` | Yes | Secrets Manager ARN for Kong credentials |
| `AWS_REGION` | Yes | AWS region (e.g. `ap-southeast-2`) |
| `OIDC_ISSUER` | Yes | Issuer URL for the `openid-connect` plugin |
| `OIDC_AUDIENCE` | Yes | OIDC audience value |
| `ENVIRONMENT_NAME` | Yes | Label used in log/telemetry fields |
| `PRODUCT_NAME` | Yes | Product label used in telemetry/log fields |
| `NEW_RELIC_API_KEY` | No | New Relic API key for OpenTelemetry |
| `KONNECT_ADDR` | No | Konnect API address (default: `https://au.api.konghq.com`) |

No per-service variables are required by this template out of the box — neither example service needs one, since both hardcode `https://httpbin.konghq.com`. The optional pattern below is here for when you add a service whose upstream does vary.

## Environment-specific values in specs (optional pattern)

One `openapi.yaml` per service is deployed to every environment. If a service's upstream URL differs per environment, write it as a `${<PREFIX>_UPSTREAM_URL}` placeholder instead of hardcoding it, and have the pipeline substitute it at deploy time with `sed` — the same inline interpolation already used for `platform/kong/service-plugins/oidc.yaml` and the global plugins:

```yaml
servers:
  - url: ${MY_SERVICE_UPSTREAM_URL}
    description: Upstream server for my-service
```

Then set `MY_SERVICE_UPSTREAM_URL` on each deployment environment. Because `deck file openapi2kong` derives the Kong service `protocol`, `host`, `port` and `path` from `servers[0].url`, supplying the full URL is enough — no per-environment patching is required.

The variable name is derived from the service directory name — uppercase, hyphens replaced by underscores (e.g. `my-service` → `MY_SERVICE_UPSTREAM_URL`).

This repo's pipeline doesn't implement the substitution step itself (neither example service needs it), but it's a direct extension of the existing `sed` pattern used for the OIDC plugin and global plugins — add a loop over `services/*/` before the `openapi2kong` step that does:

```bash
upstream_url_var="$(echo "$service_name" | tr '[:lower:]-' '[:upper:]_')_UPSTREAM_URL"
eval "upstream_url=\${${upstream_url_var}}"
if grep -qF "\${${upstream_url_var}}" "$service/openapi.yaml"; then
  [ -z "$upstream_url" ] && echo "✗ ${upstream_url_var} is not set" && exit 1
  sed "s|\${${upstream_url_var}}|${upstream_url}|g" "$service/openapi.yaml" > "/tmp/specs/${service_name}.yaml"
fi
```

## AWS Secrets Manager Format

The secret at `KONNECT_CONTROL_PLANE_SECRET_ARN` must contain:

```json
{
  "konnect_token": "kpat_YOUR_TOKEN",
  "control_plane_name": "your-control-plane-name"
}
```

## Workflow Example — Adding a Service

```bash
# 1. Create feature branch
git checkout -b feature/add-payments-api

# 2. Create the service (app team's work — no Kong knowledge needed)
mkdir -p services/payments-api

cat > services/payments-api/openapi.yaml << 'EOF'
openapi: "3.0.0"
info:
  title: Payments API
  version: "1.0.0"
servers:
  - url: https://httpbin.konghq.com
paths:
  /payments:
    get:
      operationId: listPayments
      summary: List payments
      responses:
        "200":
          description: OK
EOF

# 3. Commit and open a PR — pipeline validates and shows diff
git add services/payments-api/openapi.yaml
git commit -m "Add payments-api service"
git push origin feature/add-payments-api

# 4. After PR approval, deploy to dev
git checkout releases/dev
git merge feature/add-payments-api
git push origin releases/dev

# 5. For qa: push to releases/qa (auto-deploys)
#    For uat/prd: push to releases/uat or releases/prd, then manually approve in Bitbucket
```

### Updating a platform plugin

```bash
git checkout -b feature/update-telemetry

# Edit the platform plugin
vim platform/kong/global-plugins/open-telemetry.yaml

git add platform/kong/global-plugins/open-telemetry.yaml
git commit -m "Update OpenTelemetry endpoint"
git push origin feature/update-telemetry

# Open PR to review diff, then merge to releases/<env>
```

## Pull Request Workflow

1. Push feature branch and open a PR
2. Pipeline runs `validate-kong` automatically — fix any errors before review
3. Review the diff output in the pipeline logs to confirm expected changes
4. Approve and merge
5. Pipeline on the target `releases/<env>` branch runs `deploy-kong`:
   - `releases/dev` and `releases/qa` — deploys automatically
   - `releases/uat` and `releases/prd` — requires a manual approval step in Bitbucket before deploying

## Troubleshooting

### Authentication failure

- Verify `AWS_ROLE_ARN` is set in the deployment environment variables
- Check the IAM trust policy allows `sts:AssumeRoleWithWebIdentity` from Bitbucket's OIDC provider
- Confirm the secret at `KONNECT_CONTROL_PLANE_SECRET_ARN` exists and is readable by the role
- Verify the secret JSON has `konnect_token` and `control_plane_name` keys

### Validation errors

- Run locally: `deck file openapi2kong --inso-compatible --spec services/<svc>/openapi.yaml -o /tmp/test.yaml && deck file validate /tmp/test.yaml`
- Check for duplicate `operationId` values across services
- Ensure all route paths in the OAS are unique within the same service

### Sync fails with conflicts

- Avoid manual changes in Kong Konnect — this is a GitOps pipeline
- If manual changes were made, export with `deck gateway dump` and reconcile with the repo

## Local Validation

```bash
# Install deck v1.55.0
curl -sL https://github.com/kong/deck/releases/download/v1.55.0/deck_1.55.0_linux_amd64.tar.gz | tar -xz
sudo mv deck /usr/local/bin/

# Convert a service OAS
deck file openapi2kong --inso-compatible --spec services/kongair-bookings/openapi.yaml -o /tmp/kongair-bookings.yaml

# Validate
deck file validate /tmp/kongair-bookings.yaml

# Diff against a live control plane
deck gateway diff /tmp/final-kong.yaml \
  --konnect-addr https://au.api.konghq.com \
  --konnect-control-plane-name your-cp \
  --konnect-token $KONNECT_TOKEN
```

## Best Practices

1. **Never push directly to `releases/*`** — always go through a PR so the diff is reviewed
2. **App teams don't touch `platform/`** — only update `openapi.yaml`
3. **Keep OpenAPI specs accurate** — they are the single source of truth for routes
4. **Use semantic commit messages** — they become the audit trail for Kong config changes

## Resources

- [deck Documentation](https://docs.konghq.com/deck/)
- [Kong Konnect](https://docs.konghq.com/konnect/)
- [OpenAPI Specification](https://swagger.io/specification/)
- [Bitbucket Pipelines](https://support.atlassian.com/bitbucket-cloud/docs/get-started-with-bitbucket-pipelines/)
