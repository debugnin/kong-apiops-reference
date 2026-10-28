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
│  │  ├─ openapi.yaml ◄── source│   │  ├─ plugins/                │    │
│  │  ├─ service.yaml ◄─ generated│ │  │   ├─ key-auth.yaml       │    │
│  │  └─ routes.yaml  ◄─ generated│ │  │   └─ rate-limiting.yaml  │    │
│  │                           │   │  └─ consumers/               │    │
│  │  (declares WHAT routes    │   │      └─ consumers.yaml       │    │
│  │   exist, by name)         │   │                              │    │
│  │                           │   │  (decides WHICH of those     │    │
│  │                           │   │   routes get key-auth /      │    │
│  │                           │   │   rate limiting, by name)    │    │
│  │                           │   │                              │    │
│  │                           │   │  Makefile                    │    │
│  └───────────────────────────┘   └──────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

Neither side nests inside the other. A plugin file names the routes it applies to; a routes file names the service it belongs to. `deck file merge` is what stitches the two sides back together — see below.

## The Split: One Service Becomes Two Files

```
services/kongair-bookings/openapi.yaml
            │
            ▼  deck file openapi2kong --inso-compatible --spec openapi.yaml
┌─────────────────────────────────────────────┐
│ services:                                    │
│   - name: KongAir_Bookings_API                │
│     host: httpbin.konghq.com                 │
│     routes:            ◄── nested, one file  │
│       - name: ...-getBookings                │
│       - name: ...-createBooking               │
│       - name: ...-cancelBooking               │
│       - ...                                   │
└─────────────────────────────────────────────┘
            │
            ▼  split with yq (make generate)
┌───────────────────────────┐   ┌────────────────────────────────────┐
│ services/kongair-bookings/ │   │ services/kongair-bookings/          │
│   service.yaml             │   │   routes.yaml                       │
│                             │   │                                      │
│ services:                  │   │ routes:                              │
│   - name: KongAir_Bookings_API│ │   - name: ...-getBookings            │
│     host: httpbin.konghq.com  │ │     service: {name: KongAir_Bookings_API} │
│     (no routes key)        │   │   - name: ...-createBooking         │
│                             │   │     service: {name: KongAir_Bookings_API} │
└───────────────────────────┘   └────────────────────────────────────┘
```

The Route → Service link survives the split as a foreign key (`service: {name: ...}`), which `deck file merge` resolves when it recombines files. This is the same foreign-key mechanism decK uses elsewhere for partial configuration — see [deck's tags documentation](https://developer.konghq.com/deck/gateway/tags/#partial-configuration-and-foreign-keys).

## How a Plugin File Attaches, Without Nesting

```
platform/kong/plugins/key-auth.yaml
┌─────────────────────────────────────────┐
│ plugins:                                  │
│   - name: key-auth                        │
│     route: KongAir_Bookings_API-getBookings│ ◄── foreign key, by name
│     config: {key_names: [apikey]}          │
│   - name: key-auth                         │
│     route: KongAir_Bookings_API-createBooking│
│     config: {key_names: [apikey]}          │
└─────────────────────────────────────────┘
```

Four routes in `kongair-bookings/routes.yaml` get an entry here; two CORS-preflight routes and the entire `kongair-flights` service get none. Nothing in `routes.yaml` or `service.yaml` changes to make that true — coverage is entirely a property of which routes are *named* in this one file.

## Merge + Validate + Sync Flow

```
┌──────────────────────────────────────────────────────────────────┐
│ make merge                                                         │
│                                                                    │
│  deck file merge                                                   │
│    services/kongair-bookings/{service,routes}.yaml                │
│    services/kongair-flights/{service,routes}.yaml                 │
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
│  • every route:/service: foreign key resolves                    │
└──────────────────────────────────────────────────────────────────┘
                              │
                     ┌────────┴────────┐
                     ▼                 ▼
            make diff                make sync
      deck gateway diff        deck gateway sync
      (read-only preview)      (applies to Konnect)
```

Concretely, with the two services shipped in this repo, `build/deck.yaml` ends up with 2 Services, 12 Routes, 3 Consumers, and 7 `plugins:` entries (4 `key-auth`, 3 `rate-limiting-advanced`) — fewer plugin entries than routes, because most routes have none.

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
        │        in a plugin/routes file with no matching entity in the merged set
        │
        └──► make diff / make sync failed (auth)
             └─► Confirm DECK_KONNECT_TOKEN is valid and DECK_KONNECT_CONTROL_PLANE_NAME
                 matches the control plane name exactly
```

There is no cloud-provider credential exchange step in this repo — authentication to Kong Konnect itself is just a personal access token passed as `DECK_KONNECT_TOKEN`. (Kong's `key-auth` plugin, demonstrated on the booking routes, is a separate thing: it's how *API callers* authenticate to the gateway, not how this pipeline authenticates to Konnect.)

## Key Components

### Application team files (per service)

- `services/<svc>/openapi.yaml` — API spec; source of truth for routes and upstream URL
- `services/<svc>/service.yaml` — generated, the Gateway Service only
- `services/<svc>/routes.yaml` — generated, the Routes only, each referencing its Service by name

### Platform team files

- `platform/kong/plugins/key-auth.yaml` — every route requiring `key-auth`, named explicitly
- `platform/kong/plugins/rate-limiting.yaml` — every route requiring rate limiting, named explicitly
- `platform/kong/consumers/consumers.yaml` — Kong consumers and their key-auth credentials
- `Makefile` — `generate` / `merge` / `validate` / `diff` / `sync` targets
