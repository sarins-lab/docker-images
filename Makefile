SHELL := /usr/bin/env bash

DOCKER ?= docker
VERSION ?= 1.0.0

ALPINE_IMAGE := hardened-alpine-base
ROCKY_IMAGE := hardened-rocky-base
DEBIAN_IMAGE := hardened-debian-base
UBUNTU_IMAGE := hardened-ubuntu-base
TOOLS_IMAGE := platform-init-tools
GIT_SHA ?= $(shell git rev-parse --short=12 HEAD)

.PHONY: help build-all build-base build-tools \
	build-alpine321 build-alpine322 build-rocky9 build-rocky10 \
	build-debian12 build-debian13 build-ubuntu24 build-ubuntu26 build-init-tools \
	list-images \
	act-install act-secrets ci-list ci-dry-run ci-matrix ci-prepare \
	codeql-actions

help:
	@echo "Local build targets"
	@echo "  make build-all      Build all base images and init-tools"
	@echo "  make build-base     Build all base image variants"
	@echo "  make build-tools    Build tool images (depends on base alias tag)"
	@echo "  make list-images    Show expected local image tags"
	@echo ""
	@echo "Local CI targets (requires: gh cli + Docker Desktop)"
	@echo "  make act-install    Install gh-act extension (one-time)"
	@echo "  make act-secrets    Create .secrets template for act"
	@echo "  make ci-list        List all workflow jobs"
	@echo "  make ci-dry-run     Dry-run workflow without executing steps"
	@echo "  make ci-matrix      Run generate-matrix job (validates versions.yml)"
	@echo "  make ci-prepare     Run prepare job (validates semver logic)"
	@echo "                        VERSION=v1.2.3 overrides the default test version"
	@echo "  make codeql-actions Run CodeQL locally for GitHub Actions workflows"
	@echo ""
	@echo "Variables"
	@echo "  VERSION=<tag>       Default: $(VERSION)"
	@echo "  DOCKER=<binary>     Default: $(DOCKER)"

build-all: build-base build-tools

build-base: \
	build-alpine321 \
	build-alpine322 \
	build-rocky9 \
	build-rocky10 \
	build-debian12 \
	build-debian13 \
	build-ubuntu24 \
	build-ubuntu26

build-tools: build-init-tools

build-alpine321:
	$(DOCKER) build --build-arg ALPINE_VERSION=3.21.7 -f alpine.dockerfile -t $(ALPINE_IMAGE):$(VERSION)-alpine321 .

build-alpine322:
	$(DOCKER) build --build-arg ALPINE_VERSION=3.22.4 -f alpine.dockerfile -t $(ALPINE_IMAGE):$(VERSION)-alpine322 .
	$(DOCKER) tag $(ALPINE_IMAGE):$(VERSION)-alpine322 $(ALPINE_IMAGE):$(VERSION)

build-rocky9:
	$(DOCKER) build --build-arg ROCKY_VERSION=9-minimal -f rocky.dockerfile -t $(ROCKY_IMAGE):$(VERSION)-rocky9 .

build-rocky10:
	$(DOCKER) build --build-arg ROCKY_VERSION=10-minimal -f rocky.dockerfile -t $(ROCKY_IMAGE):$(VERSION)-rocky10 .

build-debian12:
	$(DOCKER) build --build-arg DEBIAN_VERSION=12-slim -f debian.dockerfile -t $(DEBIAN_IMAGE):$(VERSION)-debian12 .

build-debian13:
	$(DOCKER) build --build-arg DEBIAN_VERSION=13-slim -f debian.dockerfile -t $(DEBIAN_IMAGE):$(VERSION)-debian13 .

build-ubuntu24:
	$(DOCKER) build --build-arg UBUNTU_VERSION=24.04 -f ubuntu.dockerfile -t $(UBUNTU_IMAGE):$(VERSION)-ubuntu24 .

build-ubuntu26:
	$(DOCKER) build --build-arg UBUNTU_VERSION=26.04 -f ubuntu.dockerfile -t $(UBUNTU_IMAGE):$(VERSION)-ubuntu26 .

build-init-tools: build-alpine322
	$(DOCKER) build --build-arg BASE_IMAGE=$(ALPINE_IMAGE):$(VERSION)-alpine322 -f init-tools.dockerfile -t $(TOOLS_IMAGE):$(VERSION) -t $(TOOLS_IMAGE):sha-$(GIT_SHA) .

list-images:
	@echo "$(ALPINE_IMAGE):$(VERSION)-alpine321"
	@echo "$(ALPINE_IMAGE):$(VERSION)-alpine322"
	@echo "$(ROCKY_IMAGE):$(VERSION)-rocky9"
	@echo "$(ROCKY_IMAGE):$(VERSION)-rocky10"
	@echo "$(DEBIAN_IMAGE):$(VERSION)-debian12"
	@echo "$(DEBIAN_IMAGE):$(VERSION)-debian13"
	@echo "$(UBUNTU_IMAGE):$(VERSION)-ubuntu24"
	@echo "$(UBUNTU_IMAGE):$(VERSION)-ubuntu26"
	@echo "$(TOOLS_IMAGE):$(VERSION)"
	@echo "$(TOOLS_IMAGE):sha-$(GIT_SHA)"

# ── Local CI via gh act ───────────────────────────────────────────────────────
# Runs GitHub Actions workflow jobs locally inside Docker containers.
# Runner image matches ubuntu-latest more closely than the default micro image.
#
# First-time setup:
#   make act-install   — installs the gh extension
#   make act-secrets   — creates a .secrets file template (fill in GITHUB_TOKEN)
#
ACT_RUNNER  ?= catthehacker/ubuntu:act-22.04
ACT_FLAGS   ?= -P ubuntu-latest=$(ACT_RUNNER)
ACT_SECRETS ?= .secrets
# Passes --secret-file only when the file exists; silently skipped otherwise.
_ACT_SECRET_FLAG = $(if $(wildcard $(ACT_SECRETS)),--secret-file $(ACT_SECRETS),)

CODEQL          ?= codeql
CODEQL_CONFIG   ?= .github/codeql/codeql-config.yml
CODEQL_DB_DIR   ?= .codeql/databases/actions
CODEQL_RESULTS  ?= .codeql/results/actions.sarif

act-install:
	gh extension install https://github.com/nektos/gh-act

act-secrets:
	@if [ -f $(ACT_SECRETS) ]; then \
	  echo "$(ACT_SECRETS) already exists — edit it to update your token"; \
	else \
	  printf 'GITHUB_TOKEN=replace-with-your-token\n' > $(ACT_SECRETS) && \
	  echo "Created $(ACT_SECRETS) — replace the placeholder with a real token"; \
	fi

ci-list:
	gh act -l $(ACT_FLAGS)

ci-dry-run:
	gh act push -n $(ACT_FLAGS)

ci-matrix:
	gh act push -j generate-matrix $(ACT_FLAGS) $(_ACT_SECRET_FLAG)

ci-prepare:
	gh act workflow_dispatch -j prepare $(ACT_FLAGS) $(_ACT_SECRET_FLAG) \
	  --input version=$(if $(VERSION),$(VERSION),v0.0.0-local)

# ── Local CodeQL ──────────────────────────────────────────────────────────────
# Requires the CodeQL CLI in PATH, or set CODEQL=/path/to/codeql.
codeql-actions:
	@command -v "$(CODEQL)" >/dev/null 2>&1 || { \
	  echo "CodeQL CLI not found. Install it from https://github.com/github/codeql-cli-binaries/releases or set CODEQL=/path/to/codeql"; \
	  exit 127; \
	}
	@mkdir -p "$(dir $(CODEQL_DB_DIR))" "$(dir $(CODEQL_RESULTS))"
	$(CODEQL) database create --overwrite --language=actions --source-root . --codescanning-config="$(CODEQL_CONFIG)" "$(CODEQL_DB_DIR)"
	$(CODEQL) database analyze --format=sarif-latest --sarif-category=actions --output="$(CODEQL_RESULTS)" "$(CODEQL_DB_DIR)"
	@echo "CodeQL SARIF written to $(CODEQL_RESULTS)"
