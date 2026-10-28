.DEFAULT_GOAL := help

SERVICES       := bookings kongair-flights
BUILD_DIR      := build
MERGED_FILE    := $(BUILD_DIR)/deck.yaml

# Every file under platform/kong/plugins/ is picked up automatically —
# adding a new plugin (global or route-scoped) means adding a file here,
# not editing this list.
PLUGIN_FILES    := $(wildcard platform/kong/plugins/*.yaml)
CONSUMER_FILES  := platform/kong/consumers/consumers.yaml

# Built up as: one kong.yaml per service (Service + its Routes, nested, as
# `openapi2kong` naturally produces), then the platform-owned plugin and
# consumer files. Order does not matter to `deck file merge` (it merges by
# entity type, not by file position) but keeping app-team files first and
# platform-team files last makes the ownership split easy to read here.
SERVICE_FILES   := $(foreach s,$(SERVICES),services/$(s)/kong.yaml)
ALL_FILES       := $(SERVICE_FILES) $(PLUGIN_FILES) $(CONSUMER_FILES)

.PHONY: help generate merge validate diff sync clean all

help: ## Show this help
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t- /'

## --- Application team step -------------------------------------------------
# Each service owns one openapi.yaml. This target is how a new/changed
# OpenAPI spec turns into the one decK file a service needs: kong.yaml,
# with the Gateway Service and its Routes nested together exactly the way
# `deck file openapi2kong` produces them. Run this after editing any
# services/<name>/openapi.yaml and commit the regenerated file alongside
# it — that keeps PR diffs showing exactly what routing changed.
generate: ## Regenerate kong.yaml for every service from its openapi.yaml
	@for svc in $(SERVICES); do \
		echo "==> generating services/$$svc/kong.yaml"; \
		deck file openapi2kong --inso-compatible \
			--spec services/$$svc/openapi.yaml \
			-o /tmp/$$svc-raw.yaml; \
		yq eval '{"_format_version": "3.0", "services": [.services[] | del(.plugins, .tags) | .routes = [.routes[] | del(.plugins, .tags)]]}' \
			/tmp/$$svc-raw.yaml -o yaml > services/$$svc/kong.yaml; \
		rm -f /tmp/$$svc-raw.yaml; \
	done

## --- Platform team step -----------------------------------------------------
# Plugin config lives in one file per plugin type (platform/kong/plugins/),
# never nested inside a service/route file. Each entry in those files
# attaches to a specific Route by name — see the comments in
# platform/kong/plugins/*.yaml for which routes and why. There is no
# global/blanket plugin application anywhere in this repo.

## --- Shared pipeline ---------------------------------------------------------
merge: ## Merge every service's kong.yaml / plugin file / consumers.yaml into build/deck.yaml
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
