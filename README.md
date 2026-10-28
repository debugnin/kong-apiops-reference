# Kong Konnect APIOps Reference

This repository is a reference template for managing Kong Gateway configuration with `deck`, driven by a plain `Makefile` rather than any particular CI vendor's pipeline syntax. It demonstrates one specific, opinionated best-practice workflow:

1. Each application team owns an `openapi.yaml` for their service.
2. `deck file openapi2kong` turns that spec into Kong config, which is then split into exactly two files: **`service.yaml`** (the Gateway Service) and **`routes.yaml`** (the Routes) — never one combined file.
3. Each plugin type gets its own file, owned by the platform team, under `platform/kong/plugins/`. A plugin file only contains entries for the specific Routes that need that plugin — there is no global/blanket plugin anywhere in this repo.
4. `deck file merge` combines every service's `service.yaml` + `routes.yaml` with the platform team's plugin and consumer files into one `build/deck.yaml`.
5. `deck file validate` checks the merged result offline, then `deck gateway sync` (or `diff`) applies it to Kong Konnect.

The two example services, **KongAir Bookings** and **KongAir Flights**, are fictional — part of the [KongAir](https://github.com/Kong/KongAir) demo airline used across Kong's reference material. Both point at [`httpbin.konghq.com`](https://httpbin.konghq.com), Kong's public httpbin instance, as their upstream, so the workflow in this repo runs against a real, reachable backend rather than a mocked one. Only two plugins are demonstrated — `key-auth` and `rate-limiting-advanced` — each applied to a hand-picked subset of routes to show *selective*, not blanket, application.

## Ownership Model

| Owner                | Files                                                           |
| --------------------- | ----------------------------------------------------------------- |
| **Application team** | `services/<service>/openapi.yaml` — API specification            |
| **Application team** | `services/<service>/service.yaml`, `routes.yaml` — generated, committed |
| **Platform team**    | `platform/kong/plugins/*.yaml` — one file per plugin type        |
| **Platform team**    | `platform/kong/consumers/consumers.yaml`                          |
| **Platform team**    | `Makefile` — the merge/validate/sync pipeline                    |

Application teams declare _what_ their service is via an OpenAPI spec, and run `make generate` to turn it into `service.yaml`/`routes.yaml`, which are committed so PRs show exactly what routing changed. The platform team owns everything about _which routes get which cross-cutting behaviour_ — auth, rate limiting — entirely in `platform/kong/plugins/`, without ever editing a service's files.

## Repository Structure

```
.
├── services/
│   ├── kongair-bookings/
│   │   ├── openapi.yaml            # OpenAPI specification (source of truth, app team)
│   │   ├── service.yaml            # Generated: Gateway Service only
│   │   └── routes.yaml             # Generated: Routes only, each referencing
│   │                                 #   its service by name (service: {name: ...})
│   └── kongair-flights/
│       ├── openapi.yaml
│       ├── service.yaml
│       └── routes.yaml
│
├── platform/
│   └── kong/
│       ├── plugins/
│       │   ├── key-auth.yaml           # Every route that needs key-auth, and only those
│       │   └── rate-limiting.yaml      # Every route that needs rate limiting, and only those
│       └── consumers/
│           └── consumers.yaml          # Consumers + their key-auth credentials
│
├── build/                          # `make merge` output — gitignored
│   └── deck.yaml
│
└── Makefile
```

## Why split `service.yaml` and `routes.yaml` into separate files?

`deck file openapi2kong` emits one file with each Route nested inside its Service. That's fine for a one-off conversion, but this repo splits the result into two files per service and keeps them that way, because:

- **decK doesn't require nesting.** A Route can live at the top level of its own file and point back at its Service with a foreign key — `service: { name: KongAir_Bookings_API }`. `deck file merge` resolves that reference across files, so splitting costs nothing at merge time (see [`deck gateway tags`](https://developer.konghq.com/deck/gateway/tags/#partial-configuration-and-foreign-keys) for the same foreign-key pattern applied to Consumers/Consumer Groups).
- **Different things change at different rates.** A Service's `host`/`protocol`/`port` is upstream infrastructure and changes rarely. Routes change every time an endpoint is added, renamed, or re-pathed. One file per concern means a PR that adds an endpoint touches `routes.yaml` only — the diff is the new route, not a 40-line reformat of a combined file.
- **Smaller, single-purpose diffs are easier to review.** A reviewer looking at `routes.yaml` is reviewing "what's exposed and how it's matched." A reviewer looking at `service.yaml` is reviewing "where does this service point." Mixing both into one file forces every reviewer to context-switch between infrastructure and API-surface concerns on every change.
- **It mirrors how the platform team's plugin files attach.** `platform/kong/plugins/key-auth.yaml` attaches to Routes by name, the same foreign-key mechanism used to attach `routes.yaml` to `service.yaml`. Keeping Services and Routes apart makes that pattern consistent top-to-bottom: every cross-cutting file (plugins, consumers) references the thing it applies to by name, rather than being nested inside it.
- **It scales to multiple Services per repo without re-nesting on every merge.** With N services each contributing a `service.yaml` + `routes.yaml`, `deck file merge` just concatenates — there's no need to merge nested arrays-of-arrays or worry about one service's routes accidentally nesting under another's service entry.

## Why one file per plugin, scoped to specific routes?

Each file in `platform/kong/plugins/` corresponds to exactly one plugin, and every entry in it names the Route it applies to via the top-level `plugins[].route` foreign key — for example:

```yaml
# platform/kong/plugins/key-auth.yaml
_format_version: "3.0"
plugins:
  - name: key-auth
    route: KongAir_Bookings_API-getBookings
    config:
      key_names:
        - apikey
```

This is deliberately *not* a blanket plugin applied to every service or route (the pattern you'd get from `deck file add-plugins --selector '$..services[*]'`). Instead:

- **The file itself is the inventory.** To know every route that requires `key-auth`, open `key-auth.yaml` — you don't need to grep every `routes.yaml` in the repo for a nested `plugins:` block.
- **Adding a new plugin never touches a service's files.** A platform engineer enabling rate limiting on a new route edits `rate-limiting.yaml` only; the application team's `routes.yaml` is untouched, and `git blame` on `routes.yaml` stays about routing, not security policy.
- **Coverage is explicit and reviewable.** A PR adding an entry to `key-auth.yaml` is a visible, auditable decision ("this route now requires an API key") rather than an implicit side effect of a route inheriting from a service-wide or global plugin.
- **Plugins can overlap or not apply at all, by design.** In this repo, `KongAir_Bookings_API-createBooking` has *both* `key-auth` and `rate-limiting-advanced` attached (two separate files, same route), while CORS preflight (`OPTIONS`) routes and the public flight-lookup routes have neither. A global plugin can't express that kind of per-route selectivity.

## The `deck` Conversion Flow

```
services/<service>/openapi.yaml
    │
    ▼  make generate
    │  deck file openapi2kong --inso-compatible --spec <openapi.yaml>
    │  → split into service.yaml (Service only) and routes.yaml (Routes only)
services/<service>/service.yaml + routes.yaml   (committed, per service)
    │
    ▼  make merge
    │  deck file merge <every service.yaml/routes.yaml> \
    │                  platform/kong/plugins/*.yaml \
    │                  platform/kong/consumers/consumers.yaml
build/deck.yaml   (one combined, gitignored file)
    │
    ▼  make validate
    │  deck file validate build/deck.yaml
Validated config
    │
    ▼  make diff   (review)        make sync   (apply)
    │  deck gateway diff ...        deck gateway sync ...
    ▼                                ▼
                 Kong Konnect
```

Try it yourself — see [Local Validation](#local-validation) below.

## Makefile Targets

| Target          | What it does |
| ---------------- | -------------------------------------------------------------------------- |
| `make generate`  | Regenerate `service.yaml` + `routes.yaml` for every service from its `openapi.yaml`. Run after any spec change. |
| `make merge`     | Combine every service/route/plugin/consumer file into `build/deck.yaml`. |
| `make validate`  | `make merge`, then validate the result offline (no Kong connection needed). |
| `make diff`      | `make validate`, then show what would change on the control plane. Requires `DECK_KONNECT_TOKEN` and `DECK_KONNECT_CONTROL_PLANE_NAME`. |
| `make sync`      | `make validate`, then apply the merged config to the control plane. Same env vars as `diff`. |
| `make clean`     | Remove `build/`. |
| `make all`       | `generate` + `validate` — the full local loop without talking to Kong. |

## Services in This Repo

| Service directory | Upstream | Notes |
|---|---|---|
| `services/kongair-bookings/` | `https://httpbin.konghq.com` | Create/list/cancel bookings |
| `services/kongair-flights/` | `https://httpbin.konghq.com` | List/get scheduled flights |

Both specs hardcode `https://httpbin.konghq.com` as `servers[0].url`, so `deck file openapi2kong` derives the Kong service `host`/`protocol`/`port` from the spec directly — no environment-specific substitution needed for this demo.

## Plugin Coverage

| Route | `key-auth` | `rate-limiting-advanced` |
|---|---|---|
| `GET /bookings` | ✅ | — |
| `POST /bookings` | ✅ | ✅ (10/min) |
| `GET /bookings/{ticketNumber}` | ✅ | — |
| `DELETE /bookings/{ticketNumber}` | ✅ | ✅ (10/min) |
| `OPTIONS /bookings*` (CORS preflight) | — | — |
| `GET /flights` | — | ✅ (100/min) |
| `GET /flights/{flightNumber}` | — | — |
| `GET /flights/{flightNumber}/details` | — | — |
| `OPTIONS /flights*` (CORS preflight) | — | — |

Booking routes carry customer data, so every non-preflight booking route requires `key-auth`. Flight schedules are public read-only data, so none of them require auth — but the top-level listing endpoint (`GET /flights`) is rate limited since it's the highest-traffic, unauthenticated route. The two state-changing booking routes (`createBooking`, `cancelBooking`) are rate limited to protect the upstream from abusive write traffic. This spread is intentional: it shows plugins stacking on one route, applying to only one service, and not applying at all — all from three small files.

## Adding a New Service

1. Create `services/my-service/openapi.yaml` with `servers[0].url` set to your upstream.
2. Run `make generate` — commit the resulting `services/my-service/service.yaml` and `routes.yaml`.
3. If any of its routes need `key-auth` or rate limiting, add entries (by route name) to the relevant file in `platform/kong/plugins/`. If not, add nothing — there is no default/global plugin to opt out of.
4. `make validate` locally, then open a PR. `make diff` in CI shows the control-plane impact before merge.

## Adding a New Plugin

1. Create `platform/kong/plugins/<plugin-name>.yaml` with `plugins:` at the top level.
2. Add one entry per Route that needs it, using `route: <route-name>` (the same name decK generated in that service's `routes.yaml`).
3. `make validate` — decK will report a broken foreign key if a route name is misspelled or doesn't exist yet.

## Local Validation

```bash
# Install deck
curl -sL https://github.com/kong/deck/releases/download/v1.55.0/deck_1.55.0_linux_amd64.tar.gz | tar -xz
sudo mv deck /usr/local/bin/

# Full local loop: regenerate every service's files, then validate the merge
make all

# Review the merged, validated file
cat build/deck.yaml

# Diff against a live control plane (requires Konnect credentials)
DECK_KONNECT_TOKEN=$KONNECT_TOKEN \
DECK_KONNECT_CONTROL_PLANE_NAME=your-cp \
  make diff
```

## Documentation

- [`docs/QUICKSTART.md`](docs/QUICKSTART.md) — set up and run the pipeline locally
- [`docs/PIPELINE_GUIDE.md`](docs/PIPELINE_GUIDE.md) — full `Makefile`/`deck` reference
- [`docs/WORKFLOW.md`](docs/WORKFLOW.md) — diagrams of the ownership model and file-merge flow
- [`docs/APPLICATION_TEAM_ONBOARDING.md`](docs/APPLICATION_TEAM_ONBOARDING.md) — onboarding guide for app teams who just need to ship an `openapi.yaml`

## Additional Resources

- [deck Documentation](https://developer.konghq.com/deck/)
- [deck: Select tags and lookup tags](https://developer.konghq.com/deck/gateway/tags/) — the foreign-key/partial-config pattern this repo relies on
- [deck: Managing plugins with decK](https://developer.konghq.com/deck/file/manipulation/plugins/)
- [Kong Konnect](https://docs.konghq.com/konnect/)
- [OpenAPI Specification](https://swagger.io/specification/)
- [KongAir](https://github.com/Kong/KongAir) — the demo airline these example services are drawn from
- [httpbin.konghq.com](https://httpbin.konghq.com) — the real public upstream both example services point at
