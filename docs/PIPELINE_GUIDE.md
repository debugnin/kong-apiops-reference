# Makefile / `deck` Reference Guide

This repo's pipeline is a plain `Makefile`, so it can be invoked identically from a laptop or from whatever CI system you plug it into (Bitbucket, GitHub Actions, GitLab CI, Jenkins — the `make` targets don't care).

## Targets

### `make generate`

For every directory under `services/`:

1. `deck file openapi2kong --inso-compatible --spec services/<svc>/openapi.yaml -o /tmp/<svc>-raw.yaml` — convert the OpenAPI spec to Kong config.
2. Tidy the raw output with `yq` (strip the empty `plugins: []`/`tags: []` arrays decK adds by default) and write it to `services/<svc>/kong.yaml` — one file per service, with the Gateway Service and its Routes nested together exactly as decK produced them.

Run this whenever `openapi.yaml` changes, and commit the regenerated file alongside it.

### `make merge`

```
deck file merge \
  services/kongair-bookings/kong.yaml \
  services/kongair-flights/kong.yaml \
  platform/kong/plugins/key-auth.yaml platform/kong/plugins/rate-limiting.yaml \
  platform/kong/consumers/consumers.yaml \
  -o build/deck.yaml
```

`deck file merge` combines entities by type regardless of which file they came from. Each service's `kong.yaml` contributes a Service with its Routes nested inside; the plugin files contribute top-level `plugins:` entries that reference those Routes by name; the output is one flat `build/deck.yaml` with every foreign key resolved.

### `make validate`

Runs `make merge`, then `deck file validate build/deck.yaml`. This is **offline** — no connection to Kong — and checks:

- YAML/schema validity of every entity
- That every foreign key (every `route: <name>` in a plugin file, every `service: { name: ... }` in a routes file) resolves to something that actually exists in the merged file

A typo in a plugin file's `route:` value — pointing at a route name that doesn't exist in any service's `kong.yaml` — fails here, before anything touches a real control plane.

### `make diff` / `make sync`

Both run `make validate` first, then:

```
deck gateway diff build/deck.yaml \
  --konnect-token "$DECK_KONNECT_TOKEN" \
  --konnect-control-plane-name "$DECK_KONNECT_CONTROL_PLANE_NAME"
```

```
deck gateway sync build/deck.yaml \
  --konnect-token "$DECK_KONNECT_TOKEN" \
  --konnect-control-plane-name "$DECK_KONNECT_CONTROL_PLANE_NAME"
```

`diff` is read-only and safe to run on every PR. `sync` applies the config and **removes anything in the target control plane that isn't in `build/deck.yaml`** — this repo's `build/deck.yaml` is meant to be the complete, authoritative state for the control plane it targets, so don't `sync` a partial file without decK's `select_tags` partial-config mechanism (see [deck's tags documentation](https://developer.konghq.com/deck/gateway/tags/)) if you need to manage only a subset.

### `make clean` / `make all`

`make clean` removes `build/`. `make all` runs `generate` then `validate` — the complete local loop with no Kong credentials needed, useful as a pre-commit or CI "does this even build" check.

## Wiring This Into CI

Any CI system that can run `make` and set two environment variables works:

```yaml
# illustrative — adapt to your CI's actual syntax
on: pull_request
steps:
  - run: make validate
  - run: make diff
    env:
      DECK_KONNECT_TOKEN: ${{ secrets.KONNECT_TOKEN }}
      DECK_KONNECT_CONTROL_PLANE_NAME: your-cp

on: push to main
steps:
  - run: make sync
    env:
      DECK_KONNECT_TOKEN: ${{ secrets.KONNECT_TOKEN }}
      DECK_KONNECT_CONTROL_PLANE_NAME: your-cp
```

Only `DECK_KONNECT_TOKEN` and `DECK_KONNECT_CONTROL_PLANE_NAME` are required — there's no cloud-provider-specific credential exchange (no AWS Secrets Manager, no CI-vendor OIDC) baked into this repo, since the only authentication plugin it demonstrates is Kong's own `key-auth`, not an external identity provider.

## Workflow Example — Adding a Service

```bash
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

make generate   # creates services/payments-api/kong.yaml
make validate   # confirms it merges cleanly with everything else

git add services/payments-api/
git commit -m "Add payments-api service"
git push origin feature/add-payments-api
# open a PR — CI runs `make diff` to show the control-plane impact
```

No file under `platform/kong/` needs to change unless `listPayments` requires `key-auth` or rate limiting — in which case add exactly one entry, naming `Payments_API-listPayments`, to the relevant plugin file.

## Workflow Example — Attaching a Plugin to One Route

```bash
vim platform/kong/plugins/rate-limiting.yaml
# add:
#   - name: rate-limiting-advanced
#     route: Payments_API-listPayments
#     config:
#       limit: [50]
#       window_size: [60]
#       sync_rate: -1
#       strategy: local

make validate   # confirms the route name resolves
git add platform/kong/plugins/rate-limiting.yaml
git commit -m "Rate limit payments-api listPayments"
```

This is the entire change — no other file is touched, and the plugin applies to exactly one route.

## Troubleshooting

### `make validate` fails with a foreign-key error
`deck file validate` reports exactly which reference is broken (e.g. a plugin's `route:` value). Check for a typo, or that the referenced service's `kong.yaml` was actually regenerated with `make generate` after a rename.

### `make generate` output doesn't match what's committed
`kong.yaml` is generated, deterministic output of `openapi.yaml` — if `make generate` followed by `git diff` shows unexpected changes, either `openapi.yaml` changed and the generated file is now stale (commit the new output), or the generated file was hand-edited out of band (regenerate and commit that instead).

### `make sync` removes something unexpectedly
`deck gateway sync` deletes anything on the control plane that isn't present in the file being synced. If this repo isn't meant to own the *entire* control plane, use `select_tags` to scope `sync`/`diff` to a subset — see [deck's tags documentation](https://developer.konghq.com/deck/gateway/tags/).

## Best Practices

1. **Never hand-edit `kong.yaml`** — regenerate it with `make generate` from `openapi.yaml`, which stays the single source of truth for routing.
2. **Every plugin attaches to a route by name, in its own file** — no selectors against `$..services[*]` or `$..routes[*]`, no plugin nested inside a service or route file.
3. **`make validate` before every commit** — it's fully offline and catches broken foreign keys immediately.
4. **Review `make diff` output, not just the YAML diff** — a small YAML change (e.g. a renamed route) can have a larger control-plane effect than the diff suggests if plugin files still reference the old name.

## Resources

- [deck Documentation](https://developer.konghq.com/deck/)
- [deck: Select tags and lookup tags](https://developer.konghq.com/deck/gateway/tags/)
- [deck: Managing plugins with decK](https://developer.konghq.com/deck/file/manipulation/plugins/)
- [deck file merge](https://developer.konghq.com/deck/file/merge/)
- [OpenAPI Specification](https://swagger.io/specification/)
