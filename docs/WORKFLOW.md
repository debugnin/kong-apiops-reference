# Kong Konnect APIOps Workflow

## Repository Ownership Model

```
┌──────────────────────────────────────────────────────────────────────┐
│                           Repository                                 │
│                                                                       │
│  ┌───────────────────────────┐   ┌──────────────────────────────┐    │
│  │  Application Team         │   │  Platform Team               │    │
│  │                           │   │                              │    │
│  │  services/<svc>/          │   │  platform/kong/              │    │
│  │  ├─ openapi.yaml ◄─ source │   │  ├─ plugins/                │    │
│  │  └─ kong.yaml    ◄─ generated│ │  │   ├─ key-auth.yaml       │    │
│  │      (Service + its       │   │  │   ├─ rate-limiting.yaml  │    │
│  │       Routes, nested)     │   │  │   └─ correlation-id.yaml │    │
│  │                           │   │  └─ consumers/               │    │
│  │  (declares WHAT routes    │   │      └─ consumers.yaml       │    │
│  │   exist, by name)         │   │                              │    │
│  │                           │   │  (decides WHICH routes get   │    │
│  │                           │   │   key-auth / rate limiting,  │    │
│  │                           │   │   by name — and which        │    │
│  │                           │   │   plugins apply globally)    │    │
│  │                           │   │                              │    │
│  │                           │   │  Makefile                    │    │
│  └───────────────────────────┘   └──────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

Only one side nests: a Service and its Routes live together, nested, in the same `kong.yaml` — they come from the same source (`openapi.yaml`) and change together, so there's no foreign key to maintain between them. A plugin file is the side that attaches by name instead, because it's owned by a different team and attaches to a subset of routes that may span multiple services. `deck file merge` is what combines everything into one config — see below.

## One Service, One File — Service and Routes Stay Nested

```
services/bookings/openapi.yaml
            │
            ▼  deck file openapi2kong --inso-compatible --spec openapi.yaml
               (make generate also tidies the empty plugins:[]/tags:[] arrays)
┌─────────────────────────────────────┐
│ services/bookings/kong.yaml           │
│                                       │
│ services:                            │
│   - name: Bookings_API                │
│     host: httpbin.konghq.com         │
│     routes:      ◄── nested, same file│
│       - name: ...-getBookings        │
│       - name: ...-createBooking       │
│       - name: ...-cancelBooking       │
│       - ...                           │
└─────────────────────────────────────┘
```

There's no foreign key between a Service and its own Routes to resolve at merge time — `deck file merge` takes this file as-is, alongside `kongair-flights/kong.yaml`, and concatenates the two `services:` arrays.

## How a Plugin File Attaches, Without Nesting

```
platform/kong/plugins/key-auth.yaml
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

Four routes nested in `bookings/kong.yaml` get an entry here; two CORS-preflight routes and the entire `kongair-flights` service get none. Nothing in either service's `kong.yaml` changes to make that true — coverage is entirely a property of which routes are *named* in this one plugin file. The same foreign-key mechanism decK uses here is used elsewhere for partial configuration — see [deck's tags documentation](https://developer.konghq.com/deck/gateway/tags/#partial-configuration-and-foreign-keys).

## Or No Foreign Key at All — the Global Plugin Pattern

```
platform/kong/plugins/correlation-id.yaml
┌─────────────────────────────────────────┐
│ plugins:                                  │
│   - name: correlation-id                  │
│     config: {header_name: Kong-Request-ID}│ ◄── no route:, no service: — global
└─────────────────────────────────────────┘
```

No `route:` or `service:` key means decK applies this plugin to every request through every Service and Route in the merged config, with nothing to name. This is the correct shape when a plugin is genuinely universal (request tracing, CORS, logging) — forcing it through the selective, name-every-route pattern above would add a line per route for zero actual selectivity.

## Merge + Validate + Sync Flow

```
┌──────────────────────────────────────────────────────────────────┐
│ make merge                                                         │
│                                                                    │
│  deck file merge                                                   │
│    services/bookings/kong.yaml                                     │
│    services/kongair-flights/kong.yaml                              │
│    platform/kong/plugins/{key-auth,rate-limiting,correlation-id}.yaml │
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
│  • every route-scoped plugin's route: foreign key resolves to a   │
│    nested Route (global plugins have no foreign key to check)     │
└──────────────────────────────────────────────────────────────────┘
                              │
                     ┌────────┴────────┐
                     ▼                 ▼
            make diff                make sync
      deck gateway diff        deck gateway sync
      (read-only preview)      (applies to Konnect)
```

Concretely, with the two services shipped in this repo, `build/deck.yaml` ends up with 2 Services (each with its Routes nested inside, 12 Routes total), 3 Consumers, and 8 top-level `plugins:` entries: 4 `key-auth` + 3 `rate-limiting-advanced`, each scoped to one named route, plus 1 `correlation-id` with no route/service scoping at all, applying to every one of the 12 routes.

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
        │    └─► decK reports the exact broken foreign key — a route: name in a plugin
        │        file with no matching Route nested in any service's kong.yaml
        │
        └──► make diff / make sync failed (auth)
             └─► Confirm DECK_KONNECT_TOKEN is valid and DECK_KONNECT_CONTROL_PLANE_NAME
                 matches the control plane name exactly
```

There is no cloud-provider credential exchange step in this repo — authentication to Kong Konnect itself is just a personal access token passed as `DECK_KONNECT_TOKEN`. (Kong's `key-auth` plugin, demonstrated on the booking routes, is a separate thing: it's how *API callers* authenticate to the gateway, not how this pipeline authenticates to Konnect.)

## Key Components

### Application team files (per service)

- `services/<svc>/openapi.yaml` — API spec; source of truth for routes and upstream URL
- `services/<svc>/kong.yaml` — generated, the Gateway Service with its Routes nested inside

### Platform team files

- `platform/kong/plugins/key-auth.yaml` — every route requiring `key-auth`, named explicitly
- `platform/kong/plugins/rate-limiting.yaml` — every route requiring rate limiting, named explicitly
- `platform/kong/plugins/correlation-id.yaml` — applied globally, no route/service scoping
- `platform/kong/consumers/consumers.yaml` — Kong consumers and their key-auth credentials
- `Makefile` — `generate` / `merge` / `validate` / `diff` / `sync` targets
