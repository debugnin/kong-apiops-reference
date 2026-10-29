# Kong Konnect APIOps Reference

This repository is a reference template for managing Kong Gateway configuration with `deck`, driven by a plain `Makefile` rather than any particular CI vendor's pipeline syntax. It demonstrates one specific, opinionated best-practice workflow:

1. Each application team owns an `openapi.yaml` for their service.
2. `deck file openapi2kong` turns that spec into one `services/<service>/kong/service.yaml` per service — the Gateway Service with its Routes nested inside, exactly as decK produces it.
3. Plugins live under a `kong/` folder too — but as their own file(s), never nested inside `service.yaml`. Plugins scoped to one service (route-level or service-level) live in that service's own `services/<service>/kong/plugins.yaml`; plugins that apply everywhere (global, no service in particular) live in `platform/kong/plugins/`.
4. `deck file merge` combines every service's `kong/service.yaml`, every `kong/plugins.yaml`, the platform-wide plugin files, and the consumer file into one `build/deck.yaml`.
5. `deck file validate` checks the merged result offline, then `deck gateway sync` (or `diff`) applies it to Kong Konnect.

The two example services, **Bookings** and **Flights**, are fictional — part of the [KongAir](https://github.com/Kong/KongAir) demo airline used across Kong's reference material. Both point at [`httpbin.konghq.com`](https://httpbin.konghq.com), Kong's public httpbin instance, as their upstream, so the workflow in this repo runs against a real, reachable backend rather than a mocked one. Four plugins are demonstrated, one per scoping pattern: `key-auth` and `rate-limiting-advanced` are route-level, each applied to a hand-picked subset of routes; `request-size-limiting` is service-level, applied to every route under one Service without naming them; and `correlation-id` is global, applied to every route in every Service. All three `rate-limiting-advanced` entries also link to one shared `platform-redis` [Partial](https://developer.konghq.com/gateway/entities/partial/) by its hardcoded `id:`, instead of each repeating Redis connection details inline.

## Ownership Model

| Owner                | Files                                                           |
| --------------------- | ----------------------------------------------------------------- |
| **Application team** | `services/<service>/openapi.yaml` — API specification            |
| **Application team** | `services/<service>/kong/service.yaml` — generated, committed    |
| **Platform team**    | `services/<service>/kong/plugins.yaml` — route-level and service-level plugins for that one service |
| **Platform team**    | `platform/kong/plugins/*.yaml` — plugins that apply across every service (global) |
| **Platform team**    | `platform/kong/partials/*.yaml` — shared config blocks (e.g. Redis connection) that plugins link to by `id:` |
| **Platform team**    | `platform/kong/consumers/consumers.yaml`                          |
| **Platform team**    | `Makefile` — the merge/validate/sync pipeline                    |

Application teams declare _what_ their service is via an OpenAPI spec, and run `make generate` to turn it into `kong/service.yaml` (Service + Routes, nested), which is committed so PRs show exactly what routing changed. The platform team owns everything about _which Services/Routes get which cross-cutting behaviour_ — auth, rate limiting, payload limits — in `kong/plugins.yaml` files that sit next to (but never inside) the service they govern, plus `platform/kong/plugins/` for anything with no single owning service, plus `platform/kong/partials/` for shared config those plugins link to instead of repeating inline. Either way, a service's own `openapi.yaml`/`kong/service.yaml` is never edited to add a plugin.

## Repository Structure

```
.
├── services/
│   ├── bookings/
│   │   ├── openapi.yaml           # OpenAPI specification (source of truth, app team)
│   │   └── kong/
│   │       ├── service.yaml       # Generated: Gateway Service + its Routes, nested
│   │       └── plugins.yaml       # key-auth (route-level), rate-limiting-advanced
│   │                               # (route-level), request-size-limiting (service-level)
│   └── flights/
│       ├── openapi.yaml
│       └── kong/
│           ├── service.yaml
│           └── plugins.yaml       # rate-limiting-advanced (route-level) only
│
├── platform/
│   └── kong/
│       ├── plugins/
│       │   └── correlation-id.yaml # global: no route:/service: key, every Route everywhere
│       ├── partials/
│       │   └── redis.yaml          # shared Redis config, linked to by id: from plugins
│       └── consumers/
│           └── consumers.yaml      # Consumers + their key-auth credentials
│
├── build/                          # `make merge` output — gitignored
│   └── deck.yaml
│
└── Makefile
```

## Services and Routes stay nested — plugins get their own files, next to the service they apply to

`deck file openapi2kong` produces one file per service with each Route nested inside its Service (`services[].routes[]`), and this repo keeps that shape as-is in `services/<service>/kong/service.yaml` rather than splitting it. A Service and its Routes are declared and versioned together because they come from the same source (`openapi.yaml`) and change together — a new endpoint is a new entry in the same file's `routes:` array, not a cross-file foreign-key edit.

What *does* get its own file is cross-cutting policy — plugins — because those are owned by a different team and attach by name rather than by nesting. Plugins scoped to one service live in that service's own folder (`services/<service>/kong/plugins.yaml`), so a reviewer looking at a service's directory sees its routing *and* its policy side by side, without the two being merged into one file. Plugins with no single owning service (genuinely global ones) have nowhere sensible to sit inside any one service's folder, so those stay under `platform/kong/plugins/`. See below.

## Why one file per service for plugins, and three different scoping patterns

Each service's `kong/plugins.yaml` holds every plugin that applies to that service, but never nests a plugin inside `service.yaml` itself. Most entries name the Route they apply to via the top-level `plugins[].route` foreign key — for example:

```yaml
# services/bookings/kong/plugins.yaml
_format_version: "3.0"
plugins:
  - name: key-auth
    route: Bookings_API-getBookings
    config:
      key_names:
        - apikey
```

This is deliberately *not* a blanket plugin applied to every service or route (the pattern you'd get from `deck file add-plugins --selector '$..services[*]'`), and it is *not* nested inside the route itself in `service.yaml` either. Instead:

- **The file itself is the inventory, scoped to one service.** To know every route in bookings that requires `key-auth`, open `services/bookings/kong/plugins.yaml` — you don't need to grep `service.yaml` for a nested `plugins:` block, and you don't need to search a repo-wide plugins folder for entries that happen to reference this service's routes.
- **Adding a new plugin never touches a service's routing file.** A platform engineer enabling rate limiting on a new bookings route edits `services/bookings/kong/plugins.yaml` only; `services/bookings/kong/service.yaml` is untouched, and `git blame` on it stays about routing, not security policy.
- **Coverage is explicit and reviewable.** A PR adding an entry to `services/bookings/kong/plugins.yaml` is a visible, auditable decision ("this route now requires an API key") rather than an implicit side effect of a route inheriting from a service-wide or global plugin.
- **Plugins can overlap or not apply at all, by design.** In this repo, `Bookings_API-createBooking` has *both* `key-auth` and `rate-limiting-advanced` attached (two separate entries in the same file, same route), while CORS preflight (`OPTIONS`) routes and the public flight-lookup routes have neither. A route-scoped plugin can express that kind of per-route selectivity; a global plugin, by design, cannot.

Not every plugin needs route-level precision, though. Sometimes the right unit is "every route under this one Service" rather than individual routes. The same `services/bookings/kong/plugins.yaml` file also has a `request-size-limiting` entry using `service: <name>` instead of `route: <name>`:

```yaml
# services/bookings/kong/plugins.yaml (same file, a different entry)
_format_version: "3.0"
plugins:
  - name: request-size-limiting
    service: Bookings_API
    config:
      allowed_payload_size: 1
      size_unit: megabytes
```

This applies to every Route currently under `Bookings_API` (and any new one added later, with zero changes to this file) without naming a single one of them. This is the right scope when a concern genuinely belongs to "this whole service" (a payload-size ceiling makes sense per-backend, not per-endpoint). Because it lives in bookings' own `kong/plugins.yaml`, it's obvious at a glance that it's a bookings-specific decision — `services/flights/kong/plugins.yaml` has no such entry at all, since flights doesn't need it.

And some plugins shouldn't be scoped to any one service at all. `platform/kong/plugins/correlation-id.yaml` is the third shape: a `plugins:` entry with **no** `route:` or `service:` key, which decK treats as applying globally, to every request through every service. Because it isn't owned by bookings or by flights specifically, it doesn't live in either service's folder — it lives in `platform/kong/plugins/`, the one place reserved for plugins with no single owning service:

```yaml
# platform/kong/plugins/correlation-id.yaml
_format_version: "3.0"
plugins:
  - name: correlation-id
    config:
      header_name: Kong-Request-ID
      generator: uuid#counter
      echo_downstream: true
```

Request tracing is a textbook case for this: every request should get a correlation ID, so there's no selectivity to express — scoping it per route or per service would just mean listing every one of them in the repo, with no benefit. The three patterns aren't in tension with each other — the choice of route-level, service-level, or global is made once per plugin, based on what unit "needs this, and nothing outside that unit" actually describes. Route-level and service-level plugins live with the one service they apply to; global plugins, having no such owner, live under `platform/kong/plugins/` instead.

| Pattern | Key used | Where it lives | Example | Applies to |
|---|---|---|---|---|
| Route-level | `route: <route-name>` | the service's own `kong/plugins.yaml` | `key-auth` in `services/bookings/kong/plugins.yaml` | Exactly the named Route(s) |
| Service-level | `service: <service-name>` | the service's own `kong/plugins.yaml` | `request-size-limiting` in `services/bookings/kong/plugins.yaml` | Every Route under the named Service |
| Global | *(neither key)* | `platform/kong/plugins/` | `correlation-id.yaml` | Every Route in every Service |

## Partials — Shared Config a Plugin Links To, Instead of Repeating

Route-level, service-level, and global are all answers to "which Routes does this plugin apply to." A [Partial](https://developer.konghq.com/gateway/entities/partial/) answers a different question: "where does this plugin's *shared configuration* live, so it isn't copy-pasted into every plugin entry that needs it." `platform/kong/partials/redis.yaml` defines one:

```yaml
# platform/kong/partials/redis.yaml
_format_version: "3.0"
partials:
  - id: 9e8b1f1a-2b3c-4d5e-8f6a-1a2b3c4d5e6f
    name: platform-redis
    type: redis-ee
    config:
      host: redis.platform.internal
      port: 6379
```

All three `rate-limiting-advanced` entries in this repo (two in `services/bookings/kong/plugins.yaml`, one in `services/flights/kong/plugins.yaml`) use `strategy: redis` and link to this one Partial instead of each declaring their own `config.redis.host`/`port`:

```yaml
# services/bookings/kong/plugins.yaml (one of the rate-limiting-advanced entries)
  - name: rate-limiting-advanced
    route: Bookings_API-createBooking
    partials:
      - id: 9e8b1f1a-2b3c-4d5e-8f6a-1a2b3c4d5e6f
        path: config.redis
    config:
      limit: [10]
      window_size: [60]
      sync_rate: -1
      strategy: redis
```

Notice the plugin links to the Partial by `id:`, not `name:`. Unlike `plugins[].route`/`plugins[].service` (which decK resolves as plain string *names*), `plugins[].partials[].id` is a literal id — decK doesn't do a name lookup for it. That id is hardcoded in this repo (a fixed UUID picked once, not left for Kong to generate) precisely so it can be copied verbatim into every plugin entry that needs this Partial, and so renaming the Partial's `name:` field later wouldn't break anything that links to it by `id:`. `path: config.redis` tells decK which part of the plugin's own config schema the Partial's `config` block fills in — `rate-limiting-advanced`'s schema has a `config.redis` object exactly as big as what the Partial supplies.

The result: the platform team can update Redis connection details in exactly one file (`platform/kong/partials/redis.yaml`) and have it apply to every plugin across every service that links to it, the same "one place to change it" benefit `correlation-id.yaml` gets from being global — just for shared *configuration* instead of shared *behaviour*. And because a Partial is checked with the same offline foreign-key validation as `route:`/`service:`, a typo'd `id:` fails `make validate` immediately rather than surfacing as a runtime error against a real Redis.

## The `deck` Conversion Flow

```
services/<service>/openapi.yaml
    │
    ▼  make generate
    │  deck file openapi2kong --inso-compatible --spec <openapi.yaml>
services/<service>/kong/service.yaml   (Service + nested Routes, committed, per service)
    │
    ▼  make merge
    │  deck file merge <every service's kong/service.yaml> \
    │                  <every service's kong/plugins.yaml> \
    │                  platform/kong/plugins/*.yaml \
    │                  platform/kong/partials/*.yaml \
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
| `make generate`  | Regenerate `kong/service.yaml` for every service from its `openapi.yaml`. Run after any spec change. |
| `make merge`     | Combine every service/plugin/partial/consumer file into `build/deck.yaml`. |
| `make validate`  | `make merge`, then validate the result offline (no Kong connection needed). |
| `make diff`      | `make validate`, then show what would change on the control plane. Requires `DECK_KONNECT_TOKEN` and `DECK_KONNECT_CONTROL_PLANE_NAME`. |
| `make sync`      | `make validate`, then apply the merged config to the control plane. Same env vars as `diff`. |
| `make clean`     | Remove `build/`. |
| `make all`       | `generate` + `validate` — the full local loop without talking to Kong. |

## Services in This Repo

| Service directory | Upstream | Notes |
|---|---|---|
| `services/bookings/` | `https://httpbin.konghq.com` | Create/list/cancel bookings |
| `services/flights/` | `https://httpbin.konghq.com` | List/get scheduled flights |

Both specs hardcode `https://httpbin.konghq.com` as `servers[0].url`, so `deck file openapi2kong` derives the Kong service `host`/`protocol`/`port` from the spec directly — no environment-specific substitution needed for this demo.

## Plugin Coverage

| Route | `key-auth` (route) | `rate-limiting-advanced` (route) | `request-size-limiting` (service) |
|---|---|---|---|
| `GET /bookings` | ✅ | — | ✅ (1 MB, via `Bookings_API`) |
| `POST /bookings` | ✅ | ✅ (10/min) | ✅ (1 MB, via `Bookings_API`) |
| `GET /bookings/{ticketNumber}` | ✅ | — | ✅ (1 MB, via `Bookings_API`) |
| `DELETE /bookings/{ticketNumber}` | ✅ | ✅ (10/min) | ✅ (1 MB, via `Bookings_API`) |
| `OPTIONS /bookings*` (CORS preflight) | — | — | ✅ (1 MB, via `Bookings_API`) |
| `GET /flights` | — | ✅ (100/min) | — |
| `GET /flights/{flightNumber}` | — | — | — |
| `GET /flights/{flightNumber}/details` | — | — | — |
| `OPTIONS /flights*` (CORS preflight) | — | — | — |

All six bookings rows come from `services/bookings/kong/plugins.yaml`; the one flights row comes from `services/flights/kong/plugins.yaml`. Every `request-size-limiting` ✅ above comes from the *same single entry* in bookings' `kong/plugins.yaml`, naming `service: Bookings_API` — not five separate route entries. `correlation-id` isn't in the table at all: it has no `route:`/`service:` key, so it applies to every row including both CORS preflight routes, with nothing to name. Every `rate-limiting-advanced` ✅ above also links to the same `platform-redis` Partial (`platform/kong/partials/redis.yaml`) by `id:` — not shown as its own column, since it's shared config a plugin depends on, not a separate scoping decision about which routes get rate limited.

Booking routes carry customer data, so every non-preflight booking route requires `key-auth`. Flight schedules are public read-only data, so none of them require auth — but the top-level listing endpoint (`GET /flights`) is rate limited since it's the highest-traffic, unauthenticated route. The two state-changing booking routes (`createBooking`, `cancelBooking`) are rate limited to protect the upstream from abusive write traffic, and the entire bookings service has a 1 MB request body cap since it's the only service accepting a JSON body at all. This spread is intentional: it shows plugins stacking on one route, applying to a whole service, applying globally, and not applying at all — all from a handful of small, service-scoped files plus one global one, with Redis connection details for every rate-limited route centralized in one Partial rather than copy-pasted three times.

## Adding a New Service

1. Create `services/my-service/openapi.yaml` with `servers[0].url` set to your upstream.
2. Run `make generate` — commit the resulting `services/my-service/kong/service.yaml`.
3. If any of its routes need `key-auth` or rate limiting, create `services/my-service/kong/plugins.yaml` and add entries (by route name). If the whole new service needs something uniformly (e.g. a payload-size cap), add one entry in that same file naming the Service instead — see `services/bookings/kong/plugins.yaml`'s `request-size-limiting` entry. If neither applies, don't create the file at all — there's no default to opt out of. Globally-applied plugins like `correlation-id` already cover the new service automatically, since they have no route/service scoping to extend.
4. `make validate` locally, then open a PR. `make diff` in CI shows the control-plane impact before merge.

## Adding a New Plugin

1. Decide whether the plugin belongs to one service or to every service:
   - **Scoped to one service** (route-level or service-level): add the entry to that service's `services/<service>/kong/plugins.yaml`, creating the file if it doesn't exist yet.
   - **Global** (plugins that truly apply everywhere, e.g. tracing, CORS): create `platform/kong/plugins/<plugin-name>.yaml` instead.
2. Within a service-scoped file, decide between the two remaining patterns:
   - **Route-level** (most plugins): one entry per Route that needs it, using `route: <route-name>` (the same name decK generated under that service's `routes:` array in `kong/service.yaml`) — see `key-auth` in `services/bookings/kong/plugins.yaml`.
   - **Service-level** (applies uniformly to the whole service, not individual routes): one entry using `service: <service-name>` instead of `route:` — see `request-size-limiting` in the same file.
3. `make validate` — for route-level and service-level entries, decK will report a broken foreign key if the name is misspelled or doesn't exist yet.
4. If the plugin needs shared configuration that other plugins also need (most commonly a Redis connection, for plugins with a `strategy: redis`-style option), don't repeat it inline — add a Partial to `platform/kong/partials/<name>.yaml` (or reuse `platform-redis` if a Redis Partial already exists) and reference it from the plugin via `partials: [{id: <the-partial's-id>, path: <config-path>}]`. See the [Partials](#partials--shared-config-a-plugin-links-to-instead-of-repeating) section above for the full example and why `id:`, not `name:`, is what plugins link by.

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
- [Kong Gateway: Partials](https://developer.konghq.com/gateway/entities/partial/) — the shared-config entity `platform/kong/partials/redis.yaml` uses
- [Kong Konnect](https://docs.konghq.com/konnect/)
- [OpenAPI Specification](https://swagger.io/specification/)
- [KongAir](https://github.com/Kong/KongAir) — the demo airline these example services are drawn from
- [httpbin.konghq.com](https://httpbin.konghq.com) — the real public upstream both example services point at
