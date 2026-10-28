# Quick Start Guide

Get up and running with the Kong Konnect APIOps pipeline, using the two example services in this repo — **KongAir Bookings** (Lambda) and **KongAir Flights** (ECS/ALB) — as a walkthrough.

## Prerequisites

- Bitbucket repository access
- Kong Konnect account with a control plane
- AWS account (Secrets Manager + IAM OIDC configured for Bitbucket)

## Step 1: Configure Bitbucket Deployment Variables

In Bitbucket go to **Repository Settings → Pipelines → Deployments** and create a deployment environment per environment (dev, qa, uat, prod). Add these variables to each:

### Platform variables

| Variable | Description |
|---|---|
| `AWS_ROLE_ARN` | IAM role the pipeline assumes via OIDC |
| `KONNECT_CONTROL_PLANE_SECRET_ARN` | AWS Secrets Manager ARN for Kong credentials |
| `AWS_REGION` | AWS region (e.g. `ap-southeast-2`) |
| `OIDC_ISSUER_AUTH0` | Auth0 OIDC issuer URL (non-mTLS routes) |
| `OIDC_ISSUER_COGNITO` | Cognito OIDC issuer URL (mTLS routes) |
| `OIDC_AUDIENCE` | OIDC audience value |
| `ENVIRONMENT_NAME` | Environment label used in mTLS certificate validation |
| `PRODUCT_NAME` | Product label used in telemetry/log fields (e.g. `kongair`) |
| `KONNECT_ADDR` | Konnect API address (default: `https://au.api.konghq.com`) |

### Per-service variables

For each service, add variables using a prefix derived from the service directory name (uppercase, hyphens → underscores). For example, `kongair-bookings` → `KONGAIR_BOOKINGS`:

| Variable | Description |
|---|---|
| `<PREFIX>_UPSTREAM_TYPE` | `lambda` or `ecs` (defaults to `ecs` if unset) |
| `<PREFIX>_LAMBDA_ARN` | Lambda function ARN (**Lambda services only**) |
| `<PREFIX>_IAM_ROLE_ARN` | IAM role ARN for Lambda invocation (**Lambda services only**) |
| `<PREFIX>_UPSTREAM_URL` | Upstream base URL (**ECS services only**, when it differs per environment) |

## Step 2: Store Kong Credentials in AWS Secrets Manager

Create a secret for each environment:

```bash
aws secretsmanager create-secret \
  --name dev/kong/konnect-credentials \
  --secret-string '{"konnect_token":"kpat_YOUR_TOKEN","control_plane_name":"dev-control-plane"}'
```

Use the returned ARN as `KONNECT_CONTROL_PLANE_SECRET_ARN` in Bitbucket.

Get your Konnect token from: https://cloud.konghq.com/settings/personal-access-tokens

## Step 3: Deploy the Example Services

This repo already ships both example services — `services/kongair-bookings/openapi.yaml` (Lambda) and `services/kongair-flights/openapi.yaml` (ECS). You don't need to write new specs to try the pipeline end to end; you just need upstreams for them to point at.

### Option A — use the provided test upstreams

[`upstream-examples/kongair-test-upstreams.yaml`](../upstream-examples/kongair-test-upstreams.yaml) is a CloudFormation stack that stands up a working Lambda for Bookings and an ECS/ALB (httpbin) stand-in for Flights. See [`upstream-examples/README.md`](../upstream-examples/README.md) for the deploy steps and the Bitbucket variables its outputs map to.

### Option B — point at your own upstreams

Set the Bitbucket deployment variables directly:

```
KONGAIR_BOOKINGS_UPSTREAM_TYPE=lambda
KONGAIR_BOOKINGS_LAMBDA_ARN=arn:aws:lambda:ap-southeast-2:123456789012:function:kongair-bookings-dev
KONGAIR_BOOKINGS_IAM_ROLE_ARN=arn:aws:iam::123456789012:role/kong-kongair-bookings-invoker-role-dev

KONGAIR_FLIGHTS_UPSTREAM_TYPE=ecs
KONGAIR_FLIGHTS_UPSTREAM_URL=https://your-flights-alb.ap-southeast-2.elb.amazonaws.com
```

### Adding a service of your own

```bash
mkdir -p services/my-service

cat > services/my-service/openapi.yaml << 'EOF'
openapi: "3.0.0"
info:
  title: My Service
  version: "1.0.0"
servers:
  - url: https://placeholder.example.com
paths:
  /health:
    get:
      operationId: getHealth
      summary: Health check
      responses:
        "200":
          description: OK
EOF
```

Then add the Bitbucket deployment variables for whichever upstream type it uses (see the table above).

## Step 4: Test with a Pull Request

```bash
git checkout -b feature/add-my-service
git add services/my-service/openapi.yaml
git commit -m "Add my-service"
git push origin feature/add-my-service
```

Open a pull request — the pipeline validates the configuration and shows a diff against the target environment. No deployment happens on PRs.

## Step 5: Deploy

Merge to (or push to) a `releases/<env>` branch to deploy:

```bash
git checkout releases/dev
git merge feature/add-my-service
git push origin releases/dev   # auto-deploys to dev
```

| Branch | Environment | Trigger |
|---|---|---|
| `releases/dev` | dev | Automatic |
| `releases/qa` | qa | Automatic |
| `releases/uat` | uat | Manual approval |
| `releases/prd` | prod | Manual approval |

## Local Validation

```bash
# Install deck
curl -sL https://github.com/kong/deck/releases/download/v1.55.0/deck_1.55.0_linux_amd64.tar.gz | tar -xz
sudo mv deck /usr/local/bin/

# Convert and validate a service spec
deck file openapi2kong --inso-compatible --spec services/kongair-bookings/openapi.yaml -o /tmp/test.yaml
deck file validate /tmp/test.yaml
```

## Files Reference

| File | Owner | Purpose |
|---|---|---|
| `services/<svc>/openapi.yaml` | Application team | API specification |
| Bitbucket deployment variables | Application + Platform team | Upstream type and ARNs per environment |
| `platform/kong/service-plugins/oidc.yaml` | Platform team | OIDC auth — injected into all services |
| `platform/kong/service-plugins/aws-lambda.yaml` | Platform team | Lambda plugin — injected into lambda services |
| `platform/kong/global-plugins/*.yaml` | Platform team | Gateway-wide plugins |
| `platform/kong/consumers/consumers.yaml` | Platform team | Kong consumers |
| `platform/kong/patches/patches.yaml` | Platform team | Configuration patches |
| `bitbucket-pipelines.yml` | Platform team | Pipeline definition |

## Troubleshooting

### Pipeline fails with authentication error
- Verify `AWS_ROLE_ARN` is set and the IAM trust policy allows Bitbucket OIDC
- Confirm `KONNECT_CONTROL_PLANE_SECRET_ARN` points to a valid secret with `konnect_token` and `control_plane_name` keys

### Validation fails
- Check the OpenAPI spec is valid OpenAPI 3.0
- Run local validation with `deck file validate`

## Need Help?

- **README**: [README.md](../README.md)
- **Workflow diagrams**: [WORKFLOW.md](WORKFLOW.md)
- **Pipeline reference**: [PIPELINE_GUIDE.md](PIPELINE_GUIDE.md)
- **deck docs**: https://docs.konghq.com/deck/
