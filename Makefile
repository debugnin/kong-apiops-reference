.DEFAULT_GOAL := help

SERVICES       := bookings flights
BUILD_DIR      := build
MERGED_FILE    := $(BUILD_DIR)/deck.yaml

# Plugin files are picked up automatically from two places — adding a new
# plugin file anywhere under either glob needs no Makefile edit:
#   - platform/kong/plugins/*.yaml      — plugins that aren't owned by one
#                                          service (currently just the
#                                          global correlation-id.yaml)
#   - services/<svc>/kong/plugins.yaml  — plugins scoped to that service's
#                                          own Routes/Service (route-level
#                                          or service-level), owned by the
#                                          platform team but kept alongside
#                                          the service they apply to
PLATFORM_PLUGIN_FILES := $(wildcard platform/kong/plugins/*.yaml)
SERVICE_PLUGIN_FILES  := $(wildcard services/*/kong/plugins.yaml)
PLUGIN_FILES          := $(PLATFORM_PLUGIN_FILES) $(SERVICE_PLUGIN_FILES)
CONSUMER_FILES        := platform/kong/consumers/consumers.yaml

# Partials are shared config blocks (e.g. Redis connection details) that
# plugins link to by name instead of repeating inline — platform-owned,
# platform-wide, same reasoning as consumers.yaml and correlation-id.yaml.
PARTIAL_FILES         := $(wildcard platform/kong/partials/*.yaml)

# Built up as: one services/<svc>/kong/service.yaml per service (Service +
# its Routes, nested, as `openapi2kong` naturally produces), then every
# plugin file (service-scoped and platform-scoped), then the platform
# team's consumer file. Order does not matter to `deck file merge` (it
# merges by entity type, not by file position) but keeping app-team files
# first and platform-team files last makes the ownership split easy to
# read here.
SERVICE_FILES   := $(foreach s,$(SERVICES),services/$(s)/kong/service.yaml)
ALL_FILES       := $(SERVICE_FILES) $(PLUGIN_FILES) $(PARTIAL_FILES) $(CONSUMER_FILES)

.PHONY: help generate merge validate diff sync clean all

help: ## Show this help
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t- /'

## --- Application team step -------------------------------------------------
# Each service owns one openapi.yaml. This target is how a new/changed
# OpenAPI spec turns into the one decK file a service needs:
# kong/service.yaml, with the Gateway Service and its Routes nested
# together exactly the way `deck file openapi2kong` produces them. Run
# this after editing any services/<name>/openapi.yaml and commit the
# regenerated file alongside it — that keeps PR diffs showing exactly
# what routing changed.
generate: ## Regenerate kong/service.yaml for every service from its openapi.yaml
	@for svc in $(SERVICES); do \
		echo "==> generating services/$$svc/kong/service.yaml"; \
		mkdir -p services/$$svc/kong; \
		deck file openapi2kong --inso-compatible \
			--spec services/$$svc/openapi.yaml \
			-o /tmp/$$svc-raw.yaml; \
		yq eval '{"_format_version": "3.0", "services": [.services[] | del(.plugins, .tags) | .routes = [.routes[] | del(.plugins, .tags)]]}' \
			/tmp/$$svc-raw.yaml -o yaml > services/$$svc/kong/service.yaml; \
		rm -f /tmp/$$svc-raw.yaml; \
	done

## --- Platform team step -----------------------------------------------------
# Plugin config never lives nested inside a service/route file. Instead:
#   - services/<svc>/kong/plugins.yaml holds every plugin scoped to that
#     one service — route-level (`route: <name>`) or service-level
#     (`service: <name>`) — see the comments in each file for which
#     routes/services and why.
#   - platform/kong/plugins/*.yaml holds plugins that apply across every
#     service (no `route:`/`service:` key at all), since those don't
#     belong to any single service's folder.
#   - platform/kong/partials/*.yaml holds shared config blocks (e.g. Redis
#     connection details) that plugins in either of the above link to via
#     a `partials:` foreign key, instead of repeating the same settings
#     inline in every plugin entry that needs them.

## --- Shared pipeline ---------------------------------------------------------
merge: ## Merge every service's kong/service.yaml / plugin file / consumers.yaml into build/deck.yaml
	@mkdir -p $(BUILD_DIR)
	deck file merge $(ALL_FILES) -o $(MERGED_FILE)

validate: merge ## Validate the merged config offline (schema + foreign keys)
	deck file validate $(MERGED_FILE)

diff: validate ## Show what would change on the control plane (requires DECK_KONNECT_TOKEN / DECK_KONNECT_CONTROL_PLANE_NAME)
	deck gateway diff $(MERGED_FILE) \
		--konnect-token "$(DECK_KONNECT_TOKEN)" \
		--konnect-control-plane-name "$(DECK_KONNECT_CONTROL_PLANE_NAME)"

sync: validate ## Apply the merged config to the control plane (requires DECK_KONNECT_TOKEN / DECK_KONNECT_CONTROL_PLANE_NAME)
	deck gateway sync $(MERGED_FILE) \
		--konnect-token "$(DECK_KONNECT_TOKEN)" \
		--konnect-control-plane-name "$(DECK_KONNECT_CONTROL_PLANE_NAME)"

clean: ## Remove generated build artifacts
	rm -rf $(BUILD_DIR)

all: generate validate ## Regenerate every service's files and validate the merged result
