# Kong Konnect APIOps Workflow

## Repository Ownership Model

```
┌──────────────────────────────────────────────────────────────────────┐
│                           Repository                                 │
│                                                                       │
│  ┌───────────────────────────┐   ┌──────────────────────────────┐    │
│  │  Application Team          │   │  Platform Team                │    │
│  │                            │   │                                │    │
│  │  services/<svc>/           │   │  platform/kong/                │    │
│  │  ├─ openapi.yaml ◄─ source │   │  ├─ plugins/                   │    │
│  │  └─ kong/                  │   │  │   └─ correlation-id.yaml    │    │
│  │      ├─ service.yaml       │   │  │       (global — no one      │    │
│  │      │   ◄─ generated      │   │  │        service owns it)     │    │
│  │      │   (Service + its    │   │  ├─ partials/                  │    │
│  │      │    Routes, nested)  │   │  │   └─ redis.yaml              │    │
│  │      └─ plugins.yaml       │   │  │       (shared config, linked│    │
│  │          ◄─ platform-owned,│   │  │        from plugins by id:) │    │
│  │             lives here but │   │  └─ consumers/                 │    │
│  │             never edited   │   │      └─ consumers.yaml          │    │
│  │             by the app team│   │                                │    │
│  │                            │   │  (decides WHICH routes get     │    │
│  │  (declares WHAT routes     │   │   key-auth / rate limiting,    │    │
│  │   exist, by name)          │   │   by name, in each service's   │    │
│  │                            │   │   own plugins.yaml — and which │    │
│  │                            │   │   plugins apply everywhere,    │    │
│  │                            │   │   with no single owner)        │    │
│  │                            │   │                                │    │
│  │                            │   │  Makefile                      │    │
│  └───────────────────────────┘   └──────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

Only `service.yaml` nests: a Service and its Routes live together, nested, in the same file — they come from the same source (`openapi.yaml`) and change together, so there's no foreign key to maintain between them. A plugin file is the side that attaches by name instead, because it's platform-owned and attaches to a subset of routes. Plugins scoped to a single service sit in that service's own `kong/` folder, next to `service.yaml` but as a sibling file, not nested inside it — so the app team's directory still shows the full picture (routing + policy) without the platform team ever touching `service.yaml` to do it. Plugins with no single owning service sit under `platform/kong/`, outside any one service's folder. `deck file merge` is what combines everything into one config — see below.

## One Service, One Routing File — Service and Routes Stay Nested

```
services/bookings/openapi.yaml
            │
            ▼  deck file openapi2kong --inso-compatible --spec openapi.yaml
               (make generate also tidies the empty plugins:[]/tags:[] arrays)
┌───────────────────────────────────────┐
│ services/bookings/kong/service.yaml      │
│                                         │
│ services:                              │
│   - name: Bookings_API                  │
│     host: httpbin.konghq.com           │
│     routes:      ◄── nested, same file │
│       - name: ...-getBookings          │
│       - name: ...-createBooking         │
│       - name: ...-cancelBooking         │
│       - ...                             │
└───────────────────────────────────────┘
```

There's no foreign key between a Service and its own Routes to resolve at merge time — `deck file merge` takes this file as-is, alongside `flights/kong/service.yaml`, and concatenates the two `services:` arrays.

## How a Service-Scoped Plugin File Attaches, Without Nesting

```
services/bookings/kong/plugins.yaml
┌─────────────────────────────────────────┐
│ plugins:                                  │
│   - name: key-auth                        │
│     route: Bookings_API-getBookings        │ ◄── foreign key, by name
│     config: {key_names: [apikey]}          │
│   - name: key-auth                         │
│     route: Bookings_API-createBooking      │
│     config: {key_names: [apikey]}          │
└─────────────────────────────────────────┘
```

Four routes nested in `bookings/kong/service.yaml` get a `key-auth` entry here; two CORS-preflight routes get none. Nothing in `bookings/kong/service.yaml` changes to make that true — coverage is entirely a property of which routes are *named* in this sibling plugin file. The same foreign-key mechanism decK uses here is used elsewhere for partial configuration — see [deck's tags documentation](https://developer.konghq.com/deck/gateway/tags/#partial-configuration-and-foreign-keys).

Note this is `services/bookings/kong/plugins.yaml` — not a shared, repo-wide plugins folder. `services/flights/kong/plugins.yaml` is a completely separate file with its own entries (just one: `rate-limiting-advanced` on `Flights_API-getFlights`); nothing here references flights, and nothing in flights' file references bookings.

## Or by Service, Not by Route — the Service-Level Pattern

```
services/bookings/kong/plugins.yaml  (same file, a different entry)
┌─────────────────────────────────────────┐
│ plugins:                                 │
│   - name: request-size-limiting          │
│     service: Bookings_API                │ ◄── foreign key, one Service, all its Routes
│     config: {allowed_payload_size: 1}     │
└─────────────────────────────────────────┘
```

`service: Bookings_API` resolves the same way `route: <name>` does, just one level up the hierarchy — this one entry covers all six Routes nested in `bookings/kong/service.yaml` with nothing further to list. Because this entry lives in bookings' own `plugins.yaml`, it's immediately clear it's a bookings-specific decision — `services/flights/kong/plugins.yaml` has no `request-size-limiting` entry at all, and doesn't need one, since flights' routes have no request body. This is the right unit when a concern genuinely belongs to "this whole backend," not to individual endpoints of it — adding a new route to `bookings/openapi.yaml` and regenerating automatically picks up this plugin too, with no corresponding edit to this file.

## Or No Foreign Key, and No Single Owning Service — the Global Plugin Pattern

```
platform/kong/plugins/correlation-id.yaml
┌─────────────────────────────────────────┐
│ plugins:                                  │
│   - name: correlation-id                  │
│     config: {header_name: Kong-Request-ID}│ ◄── no route:, no service: — global
└─────────────────────────────────────────┘
```

No `route:` or `service:` key means decK applies this plugin to every request through every Service and Route in the merged config, with nothing to name. Because it isn't scoped to bookings or to flights in particular, it doesn't live in either service's `kong/` folder — a global plugin has no single service to sit next to, so it lives under `platform/kong/plugins/` instead, outside every service's directory. This is the correct shape when a plugin is genuinely universal (request tracing, CORS, logging) — forcing it through the selective, name-every-route pattern above would add a line per route for zero actual selectivity, and putting it in one service's folder would misrepresent it as belonging to that service alone.

## Partials — Shared Config, Linked by `id:` Instead of Repeated

The three patterns above all answer "which Routes does this plugin apply to." A Partial answers a different question entirely: "where does this plugin's shared *configuration* live, so three plugin entries don't each hardcode the same Redis host."

```
platform/kong/partials/redis.yaml
┌─────────────────────────────────────────────┐
│ partials:                                     │
│   - id: 9e8b1f1a-2b3c-4d5e-8f6a-1a2b3c4d5e6f  │ ◄── hardcoded, stable id
│     name: platform-redis                       │
│     type: redis-ee                             │
│     config: {host: redis.platform.internal}    │
└─────────────────────────────────────────────┘
                    │
                    │ linked by id:, not name: (decK does not do a name
                    │ lookup for plugins[].partials[].id — it's a literal id)
                    ▼
services/bookings/kong/plugins.yaml   services/flights/kong/plugins.yaml
┌───────────────────────────────┐    ┌───────────────────────────────┐
│ - name: rate-limiting-advanced │    │ - name: rate-limiting-advanced │
│   route: ...-createBooking     │    │   route: Flights_API-getFlights│
│   partials:                    │    │   partials:                    │
│     - id: 9e8b1f1a-...-5e6f    │    │     - id: 9e8b1f1a-...-5e6f    │
│       path: config.redis        │    │       path: config.redis        │
│   config: {strategy: redis}     │    │   config: {strategy: redis}     │
└───────────────────────────────┘    └───────────────────────────────┘
```

`path: config.redis` tells decK which part of the plugin's own config schema the Partial's `config` block fills in. Because the id is hardcoded rather than left for Kong to generate, it can be copied verbatim into every plugin entry across every service that needs this Redis connection — three plugin entries here, potentially many more in a larger repo — without any of them repeating `host`/`port`. Update `platform/kong/partials/redis.yaml` once, and every linked plugin picks up the change on the next sync. This lives under `platform/kong/`, not inside either service's `kong/` folder, for the same reason `correlation-id.yaml` does: it isn't owned by bookings or flights specifically, it's infrastructure the platform team runs once.

## Merge + Validate + Sync Flow

```
┌──────────────────────────────────────────────────────────────────┐
│ make merge                                                         │
│                                                                    │
│  deck file merge                                                   │
│    services/bookings/kong/service.yaml                             │
│    services/flights/kong/service.yaml                              │
│    services/bookings/kong/plugins.yaml                              │
│    services/flights/kong/plugins.yaml                               │
│    platform/kong/plugins/correlation-id.yaml                       │
│    platform/kong/partials/redis.yaml                               │
│    platform/kong/consumers/consumers.yaml                         │
│    -o build/deck.yaml                                             │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ make validate                                                       │
│                                                                    │
│  deck file validate build/deck.yaml                                │
│  • schema check                                                   │
│  • every route: foreign key resolves to a nested Route            │
│  • every service: foreign key resolves to a top-level Service     │
│  • every plugins[].partials[].id resolves to a Partial's id       │
│    (global plugins have no foreign key to check at all)           │
└──────────────────────────────────────────────────────────────────┘
                              │
                     ┌────────┴────────┐
                     ▼                 ▼
            make diff                make sync
      deck gateway diff        deck gateway sync
      (read-only preview)      (applies to Konnect)
```

Concretely, with the two services shipped in this repo, `build/deck.yaml` ends up with 2 Services (each with its Routes nested inside, 12 Routes total), 3 Consumers, 1 Partial (`platform-redis`), and 9 top-level `plugins:` entries: 4 `key-auth` + 2 `rate-limiting-advanced` from `services/bookings/kong/plugins.yaml` (route-level, each naming one bookings route), 1 `rate-limiting-advanced` from `services/flights/kong/plugins.yaml` (route-level, naming `Flights_API-getFlights`), 1 `request-size-limiting` from `services/bookings/kong/plugins.yaml` (service-level, naming `Bookings_API` and covering its 6 Routes with that single entry), and 1 `correlation-id` from `platform/kong/plugins/` with no route/service scoping at all, applying to every one of the 12 routes. All 3 `rate-limiting-advanced` entries additionally link to the one Partial by `id:`.

## Pull Request Validation Flow

```
┌────────────────────────────────────────────────────────────────┐
│                     Pull Request Created                       │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
        ┌─────────────────────────────────────┐
        │   make validate                      │
        │   • generate already committed       │
        │   • merge + offline schema/FK check   │
        └─────────────────────────────────────┘
                              │
                              ▼
        ┌─────────────────────────────────────┐
        │   make diff                          │
        │   • deck gateway diff                │
        │   • shows + additions                │
        │   • shows ~ modifications             │
        │   • shows - deletions                 │
        └─────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │  Approve & Merge │
                    └─────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │  make sync        │
                    └─────────────────┘
```

## Error Handling

```
make target failure
        │
        ├──► make generate failed
        │    └─► Check the OpenAPI spec is valid 3.0; openapi2kong reports the exact field
        │
        ├──► make merge / make validate failed
        │    └─► decK reports the exact broken foreign key — a route: or service: name
        │        in a plugins.yaml with no matching Route/Service nested in any
        │        service's kong/service.yaml, or a plugins[].partials[].id with no
        │        matching Partial id in platform/kong/partials/
        │
        └──► make diff / make sync failed (auth)
             └─► Confirm DECK_KONNECT_TOKEN is valid and DECK_KONNECT_CONTROL_PLANE_NAME
                 matches the control plane name exactly
```

There is no cloud-provider credential exchange step in this repo — authentication to Kong Konnect itself is just a personal access token passed as `DECK_KONNECT_TOKEN`. (Kong's `key-auth` plugin, demonstrated on the booking routes, is a separate thing: it's how *API callers* authenticate to the gateway, not how this pipeline authenticates to Konnect.)

## Key Components

### Application team files (per service)

- `services/<svc>/openapi.yaml` — API spec; source of truth for routes and upstream URL
- `services/<svc>/kong/service.yaml` — generated, the Gateway Service with its Routes nested inside
- `services/<svc>/kong/plugins.yaml` — platform-owned, but lives in the service's own folder; route-level and/or service-level plugins scoped to this service only

### Platform team files

- `services/bookings/kong/plugins.yaml` — 4 `key-auth` + 2 `rate-limiting-advanced` (route-level, each linking to `platform-redis` by `id:`), 1 `request-size-limiting` (service-level, `service: Bookings_API`)
- `services/flights/kong/plugins.yaml` — 1 `rate-limiting-advanced` (route-level, `route: Flights_API-getFlights`, also linking to `platform-redis`)
- `platform/kong/plugins/correlation-id.yaml` — global: applied everywhere, no route/service scoping, no single owning service
- `platform/kong/partials/redis.yaml` — the shared `platform-redis` Partial (hardcoded `id:`), linked to by every `rate-limiting-advanced` entry above
- `platform/kong/consumers/consumers.yaml` — Kong consumers and their key-auth credentials
- `Makefile` — `generate` / `merge` / `validate` / `diff` / `sync` targets
