SHELL := /usr/bin/env bash

DOCKER ?= docker
BUILD_FLAGS ?= --pull --no-cache
PYTHON ?= python
VERSIONS_FILE ?= versions.yml
VERSION ?= $(shell $(PYTHON) -c 'from pathlib import Path; from scripts.images_from_versions import load_versions; print(load_versions(Path("$(VERSIONS_FILE)"))["version"])')
IMAGE_SCRIPT ?= scripts/images_from_versions.py
TRIVY_SCRIPT ?= scripts/trivy_images.py
TRIVY ?= trivy
TRIVY_CACHE_DIR ?= .trivy-cache
TRIVY_RESULTS_DIR ?= .trivy/results
TRIVY_IGNOREFILE ?= /dev/null
TRIVY_SEVERITY ?= UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL
TRIVY_SCANNERS ?= vuln
TRIVY_IGNORE_UNFIXED ?= false
TRIVY_EXIT_CODE ?= 0
TRIVY_IMAGES ?=
GIT_SHA ?= $(shell git rev-parse --short=12 HEAD)
JENKINS_TRACK ?= jenkins-lts-alpine-jdk25
JENKINS_IMAGE ?= $(shell $(PYTHON) -c 'from pathlib import Path; from scripts.images_from_versions import ImageResolver, load_versions; root = Path("."); config = load_versions(root / "$(VERSIONS_FILE)"); track = next(t for t in config["base-tracks"] if t["suffix"] == "$(JENKINS_TRACK)" and t["dockerfile"] == "jenkins.dockerfile" and t["status"] != "eol"); print(ImageResolver(root).base_tag(track, "$(VERSION)"))')
JENKINS_BUILD_FLAGS ?= --pull --no-cache

.PHONY: help build-all build-base build-tools \
	list-images trivy-images build-jenkins test-jenkins test-images \
	act-install act-secrets ci-list ci-dry-run ci-matrix ci-prepare \
	codeql-actions

help:
	@echo "Local build targets"
	@echo "  make build-all      Build every live track in versions.yml"
	@echo "  make build-base     Build all base image variants"
	@echo "  make build-tools    Build tool images (depends on base alias tag)"
	@echo "  make list-images    Show expected local image tags"
	@echo "  make test-images    Test inventory, build flags and scan arguments"
	@echo "  make test-jenkins   Build Jenkins and test hardened startup and restart"
	@echo "  make trivy-images   Build live images and write .trivy/results/all-cves.md"
	@echo ""
	@echo "Local CI targets (requires: gh cli + Docker Desktop)"
	@echo "  make act-install    Install gh-act extension (one-time)"
	@echo "  make act-secrets    Create .secrets template for act"
	@echo "  make ci-list        List all workflow jobs"
	@echo "  make ci-dry-run     Dry-run workflow without executing steps"
	@echo "  make ci-matrix      Run generate-matrix job (validates versions.yml)"
	@echo "  make ci-prepare     Run prepare job (validates semver logic)"
	@echo "                        VERSION=v1.2.3 overrides the default test version"
	@echo "  make trivy-images   Build and scan all local Docker images with Trivy"
	@echo "                        Markdown and JSON reports are written under .trivy/results/"
	@echo "  make codeql-actions Run CodeQL locally for GitHub Actions workflows"
	@echo ""
	@echo "Variables"
	@echo "  VERSION=<tag>       Default: $(VERSION)"
	@echo "  DOCKER=<binary>     Default: $(DOCKER)"
	@echo "  BUILD_FLAGS=<flags> Default: $(BUILD_FLAGS)"
	@echo "  PYTHON=<binary>     Default: $(PYTHON)"
	@echo "  JENKINS_TRACK=<suffix> Default: $(JENKINS_TRACK)"
	@echo "  TRIVY_IGNORE_UNFIXED=<bool> Default: $(TRIVY_IGNORE_UNFIXED)"
	@echo "  TRIVY_EXIT_CODE=<n> Default: $(TRIVY_EXIT_CODE)"

build-all:
	$(PYTHON) $(IMAGE_SCRIPT) build-all --versions-file "$(VERSIONS_FILE)" --version "$(VERSION)" --docker "$(DOCKER)" --git-sha "$(GIT_SHA)" --build-flags="$(BUILD_FLAGS)"

test-images:
	$(PYTHON) -m unittest discover -s scripts -p 'test_images.py'

build-jenkins:
	@set -eu; arg=$$($(PYTHON) -c 'from pathlib import Path; from scripts.images_from_versions import load_versions; print(next(t["build-arg"] for t in load_versions(Path("$(VERSIONS_FILE)"))["base-tracks"] if t["suffix"] == "$(JENKINS_TRACK)" and t["dockerfile"] == "jenkins.dockerfile" and t["status"] != "eol"))'); \
	$(DOCKER) build $(JENKINS_BUILD_FLAGS) --build-arg "$$arg" -f jenkins.dockerfile -t "$(JENKINS_IMAGE)" .

test-jenkins: build-jenkins
	DOCKER="$(DOCKER)" bash scripts/test-jenkins.sh "$(JENKINS_IMAGE)"

build-base:
	$(PYTHON) $(IMAGE_SCRIPT) build-base --versions-file "$(VERSIONS_FILE)" --version "$(VERSION)" --docker "$(DOCKER)" --build-flags="$(BUILD_FLAGS)"

build-tools:
	$(PYTHON) $(IMAGE_SCRIPT) build-tools --versions-file "$(VERSIONS_FILE)" --version "$(VERSION)" --docker "$(DOCKER)" --git-sha "$(GIT_SHA)" --build-dependencies --build-flags="$(BUILD_FLAGS)"

list-images:
	@$(PYTHON) $(IMAGE_SCRIPT) images --versions-file "$(VERSIONS_FILE)" --version "$(VERSION)" --git-sha "$(GIT_SHA)" --include-git-sha-tag

trivy-images: build-all
	$(PYTHON) $(TRIVY_SCRIPT) --versions-file "$(VERSIONS_FILE)" --version "$(VERSION)" --git-sha "$(GIT_SHA)" --trivy "$(TRIVY)" --cache-dir "$(TRIVY_CACHE_DIR)" --results-dir "$(TRIVY_RESULTS_DIR)" --ignore-file "$(TRIVY_IGNOREFILE)" --severity "$(TRIVY_SEVERITY)" --scanners "$(TRIVY_SCANNERS)" --ignore-unfixed "$(TRIVY_IGNORE_UNFIXED)" --exit-code "$(TRIVY_EXIT_CODE)" $(if $(TRIVY_IMAGES),--images $(TRIVY_IMAGES),)

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
