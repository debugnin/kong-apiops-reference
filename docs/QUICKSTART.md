# Quick Start Guide

Get up and running with this repo's `deck` workflow, using the two example services — **KongAir Bookings** and **KongAir Flights**, both backed by [`httpbin.konghq.com`](https://httpbin.konghq.com) — as a walkthrough.

## Prerequisites

- [`deck`](https://developer.konghq.com/deck/installation/) v1.55+
- [`yq`](https://github.com/mikefarah/yq) (the Go version, `mikefarah/yq`) — used by `make generate` to tidy `openapi2kong`'s output into `kong.yaml`
- `make`
- A Kong Konnect account with a control plane, if you want to run `make diff` / `make sync` against a real control plane. Everything else in this guide works fully offline.

## Step 1: Run the Local Loop

Everything up to (but not including) talking to Kong works with no credentials at all:

```bash
make all       # = make generate + make validate
cat build/deck.yaml
```

`make generate` reads every `services/<svc>/openapi.yaml`, runs `deck file openapi2kong`, and writes the result to `services/<svc>/kong.yaml` — one file per service, with the Gateway Service and its Routes nested together exactly as decK produces them. `make validate` then merges those with the platform team's plugin and consumer files into `build/deck.yaml` and validates it offline.

## Step 2: Deploy the Example Services

Set Konnect credentials as environment variables:

```bash
export DECK_KONNECT_TOKEN=kpat_YOUR_TOKEN
export DECK_KONNECT_CONTROL_PLANE_NAME=your-control-plane
```

Get a token from https://cloud.konghq.com/settings/personal-access-tokens, then:

```bash
make diff    # review what would change
make sync    # apply it
```

Both example services point `servers[0].url` at `https://httpbin.konghq.com`, a real, publicly reachable upstream, so there's nothing else to stand up to try this end to end.

## Step 3: Add a Service of Your Own

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

make generate   # creates services/my-service/kong.yaml
git add services/my-service/
```

If none of the new routes need `key-auth` or rate limiting, you're done — commit and open a PR. If they do, see Step 4.

## Step 4: Attach a Plugin to Specific Routes

Plugins are never added globally. Open the relevant file under `platform/kong/plugins/` and add an entry naming the exact route(s) that need it — the route names are whatever `make generate` put in that service's `kong.yaml` (pattern: `<ServiceName>-<operationId>`):

```yaml
# platform/kong/plugins/key-auth.yaml
  - name: key-auth
    route: My_Service_API-getHealth
    config:
      key_names:
        - apikey
```

Run `make validate` — decK reports a broken foreign key immediately if the route name doesn't match any route nested in a `kong.yaml`.

## Step 5: Validate and Open a PR

```bash
make all
git checkout -b feature/add-my-service
git add .
git commit -m "Add my-service"
git push origin feature/add-my-service
```

Open a pull request. In CI, `make diff` (with Konnect credentials set as pipeline secrets) shows the control-plane impact before merge; merging and running `make sync` applies it.

## Files Reference

| File | Owner | Purpose |
|---|---|---|
| `services/<svc>/openapi.yaml` | Application team | API specification (source of truth) |
| `services/<svc>/kong.yaml` | Application team | Generated: Gateway Service + its Routes, nested |
| `platform/kong/plugins/key-auth.yaml` | Platform team | Every route requiring `key-auth`, by name |
| `platform/kong/plugins/rate-limiting.yaml` | Platform team | Every route requiring rate limiting, by name |
| `platform/kong/consumers/consumers.yaml` | Platform team | Kong consumers + credentials |
| `Makefile` | Platform team | `generate` / `merge` / `validate` / `diff` / `sync` targets |

## Troubleshooting

### `make validate` fails with a foreign key / "not found" error
A plugin file references a route name that doesn't exist. Check the exact name in the relevant service's `kong.yaml` — it's always `<ServiceName>-<operationId>`, taken verbatim from the OpenAPI spec's `operationId`.

### `make generate` produces a diff you didn't expect
This means `openapi.yaml` changed since `kong.yaml` was last generated. Re-run `make generate` and review the diff — it should be exactly the routing change you made to the spec, nothing else.

### `make diff` / `make sync` fail with an auth error
Confirm `DECK_KONNECT_TOKEN` and `DECK_KONNECT_CONTROL_PLANE_NAME` are set and the token is valid for that control plane.

## Need Help?

- **README**: [README.md](../README.md)
- **Workflow diagrams**: [WORKFLOW.md](WORKFLOW.md)
- **Makefile reference**: [PIPELINE_GUIDE.md](PIPELINE_GUIDE.md)
- **deck docs**: https://developer.konghq.com/deck/
