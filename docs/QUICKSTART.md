# Quick Start Guide

Get up and running with the Kong Konnect APIOps pipeline, using the two example services in this repo — **KongAir Bookings** and **KongAir Flights**, both backed by [`httpbin.konghq.com`](https://httpbin.konghq.com) — as a walkthrough.

## Prerequisites

- Bitbucket repository access
- Kong Konnect account with a control plane
- AWS account (Secrets Manager + IAM OIDC configured for Bitbucket)

## Step 1: Configure Bitbucket Deployment Variables

In Bitbucket go to **Repository Settings → Pipelines → Deployments** and create a deployment environment per environment (dev, qa, uat, prod). Add these variables to each:

| Variable | Description |
|---|---|
| `AWS_ROLE_ARN` | IAM role the pipeline assumes via OIDC |
| `KONNECT_CONTROL_PLANE_SECRET_ARN` | AWS Secrets Manager ARN for Kong credentials |
| `AWS_REGION` | AWS region (e.g. `ap-southeast-2`) |
| `OIDC_ISSUER` | OIDC issuer URL used by the `openid-connect` plugin |
| `OIDC_AUDIENCE` | OIDC audience value |
| `ENVIRONMENT_NAME` | Environment label used in log/telemetry fields |
| `PRODUCT_NAME` | Product label used in telemetry/log fields (e.g. `kongair`) |
| `KONNECT_ADDR` | Konnect API address (default: `https://au.api.konghq.com`) |

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

This repo already ships both example services — `services/kongair-bookings/openapi.yaml` and `services/kongair-flights/openapi.yaml`. Both point `servers[0].url` at `https://httpbin.konghq.com`, a real, publicly reachable upstream, so there's nothing else to stand up to try the pipeline end to end.

Once the Bitbucket variables from Step 1 are set, push to `releases/dev` and the pipeline deploys both services as-is.

### Adding a service of your own

```bash
mkdir -p services/my-service

cat > services/my-service/openapi.yaml << 'EOF'
openapi: "3.0.0"
info:
  title: My Service
  version: "1.0.0"
servers:
  - url: https://httpbin.konghq.com
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

If your real upstream differs per environment, use a `${MY_SERVICE_UPSTREAM_URL}` placeholder instead and set that variable per Bitbucket deployment environment — see [`PIPELINE_GUIDE.md`](PIPELINE_GUIDE.md#environment-specific-values-in-specs).

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
| `platform/kong/service-plugins/oidc.yaml` | Platform team | OIDC auth — injected into all services |
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
