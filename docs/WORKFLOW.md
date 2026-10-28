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
│  │      (Service + its       │   │  │   └─ rate-limiting.yaml  │    │
│  │       Routes, nested)     │   │  └─ consumers/               │    │
│  │                           │   │      └─ consumers.yaml       │    │
│  │  (declares WHAT routes    │   │                              │    │
│  │   exist, by name)         │   │  (decides WHICH of those     │    │
│  │                           │   │   routes get key-auth /      │    │
│  │                           │   │   rate limiting, by name)    │    │
│  │                           │   │                              │    │
│  │                           │   │  Makefile                    │    │
│  └───────────────────────────┘   └──────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

Only one side nests: a Service and its Routes live together, nested, in the same `kong.yaml` — they come from the same source (`openapi.yaml`) and change together, so there's no foreign key to maintain between them. A plugin file is the side that attaches by name instead, because it's owned by a different team and attaches to a subset of routes that may span multiple services. `deck file merge` is what combines everything into one config — see below.

## One Service, One File — Service and Routes Stay Nested

```
services/kongair-bookings/openapi.yaml
            │
            ▼  deck file openapi2kong --inso-compatible --spec openapi.yaml
               (make generate also tidies the empty plugins:[]/tags:[] arrays)
┌───────────────────────────────────────────────┐
│ services/kongair-bookings/kong.yaml             │
│                                                 │
│ services:                                      │
│   - name: KongAir_Bookings_API                  │
│     host: httpbin.konghq.com                   │
│     routes:            ◄── nested, same file    │
│       - name: ...-getBookings                  │
│       - name: ...-createBooking                 │
│       - name: ...-cancelBooking                 │
│       - ...                                     │
└───────────────────────────────────────────────┘
```

There's no foreign key between a Service and its own Routes to resolve at merge time — `deck file merge` takes this file as-is, alongside `kongair-flights/kong.yaml`, and concatenates the two `services:` arrays.

## How a Plugin File Attaches, Without Nesting

```
platform/kong/plugins/key-auth.yaml
┌─────────────────────────────────────────────┐
│ plugins:                                      │
│   - name: key-auth                            │
│     route: KongAir_Bookings_API-getBookings    │ ◄── foreign key, by name
│     config: {key_names: [apikey]}              │
│   - name: key-auth                             │
│     route: KongAir_Bookings_API-createBooking  │
│     config: {key_names: [apikey]}              │
└─────────────────────────────────────────────┘
```

Four routes nested in `kongair-bookings/kong.yaml` get an entry here; two CORS-preflight routes and the entire `kongair-flights` service get none. Nothing in either service's `kong.yaml` changes to make that true — coverage is entirely a property of which routes are *named* in this one plugin file. The same foreign-key mechanism decK uses here is used elsewhere for partial configuration — see [deck's tags documentation](https://developer.konghq.com/deck/gateway/tags/#partial-configuration-and-foreign-keys).

## Merge + Validate + Sync Flow

```
┌──────────────────────────────────────────────────────────────────┐
│ make merge                                                         │
│                                                                    │
│  deck file merge                                                   │
│    services/kongair-bookings/kong.yaml                             │
│    services/kongair-flights/kong.yaml                              │
│    platform/kong/plugins/{key-auth,rate-limiting}.yaml            │
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
│  • every plugin route: foreign key resolves to a nested Route     │
└──────────────────────────────────────────────────────────────────┘
                              │
                     ┌────────┴────────┐
                     ▼                 ▼
            make diff                make sync
      deck gateway diff        deck gateway sync
      (read-only preview)      (applies to Konnect)
```

Concretely, with the two services shipped in this repo, `build/deck.yaml` ends up with 2 Services (each with its Routes nested inside, 12 Routes total), 3 Consumers, and 7 top-level `plugins:` entries (4 `key-auth`, 3 `rate-limiting-advanced`) — fewer plugin entries than routes, because most routes have none.

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
- `platform/kong/consumers/consumers.yaml` — Kong consumers and their key-auth credentials
- `Makefile` — `generate` / `merge` / `validate` / `diff` / `sync` targets
