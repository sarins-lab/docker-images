# =============================================================================
# platform-base-debian — CIS-hardened Debian base image (version by build arg)
# =============================================================================
# A minimal Debian slim image with CIS Docker Benchmark v1.6 hardening applied.
# Prefer this over platform-base-ubuntu when you want a smaller glibc-based
# image without the Ubuntu-specific additions. The Debian slim variant strips
# documentation, locales, and some utilities, keeping the image lean.
#
# Provides:
#   • hermes non-root user (uid/gid 10001)
#   • SUID/SGID bits stripped from the base Debian filesystem
#   • HOME=/dev/null
#   • HEALTHCHECK NONE
#   • USER 10001:10001 as the final instruction
#
# Derived image responsibilities (CIS DI-4.3):
#   apt is intentionally left in place so derived images can install packages.
#   They MUST clean up in the same RUN layer as their final apt-get install:
#     RUN apt-get update && apt-get install -y --no-install-recommends <pkgs> \
#         && apt-get clean && rm -rf /var/lib/apt/lists/*
#
# Hardening applied by scripts/cis-harden.sh --container:
#   DI-4.1  Dedicated non-root user: hermes (uid/gid 10001)
#   DI-4.10 SUID/SGID bits stripped from the base filesystem
#
# Hardening set explicitly here:
#   DI-4.6  HEALTHCHECK NONE
#   DI-4.8  No secrets or credential stubs in ENV or ARG
#   DI-4.11 No EXPOSE
#
# ── Build (from repo root) ────────────────────────────────────────────────────
# IMPORTANT: build from the repo root so COPY can reach scripts/cis-harden.sh.
#
# Single-arch (development):
#   docker build --build-arg DEBIAN_VERSION=12-slim \
#     -f debian.dockerfile \
#     -t hardened-debian-base:1.0.0-debian12 \
#     .
#
# Multi-arch (production — requires buildx):
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     --build-arg DEBIAN_VERSION=12-slim \
#     -f debian.dockerfile \
#     -t <registry>/hardened-debian-base:1.0.0-debian12 \
#     --push .
#
# ── H-005 / Digest pinning ────────────────────────────────────────────────────
# After pushing, capture the immutable digest:
#   docker inspect --format='{{index .RepoDigests 0}}' \
#     <registry>/platform-base-debian:12
# Also pin the Debian base image (replace debian:12-slim with @sha256:<digest>).
# =============================================================================

# H-005 TODO: replace with pinned digest after first pull:
#   docker pull debian:12-slim
#   docker inspect --format='{{index .RepoDigests 0}}' debian:12-slim
ARG DEBIAN_VERSION=12-slim
FROM debian:${DEBIAN_VERSION}
ARG DEBIAN_VERSION

# OCI image labels
LABEL org.opencontainers.image.title="hardened-debian-base" \
    org.opencontainers.image.description="CIS-hardened Debian ${DEBIAN_VERSION} base: hermes non-root user, SUID/SGID stripped" \
    org.opencontainers.image.source="https://github.com/sarins-lab/docker-images" \
    org.opencontainers.image.vendor="sarins-lab" \
    org.opencontainers.image.base.name="debian:${DEBIAN_VERSION}"

# ── CIS hardening ─────────────────────────────────────────────────────────────
# --container selects Docker Benchmark controls only (DI-4.1 + DI-4.10).
# Host-only controls are skipped; they cannot be applied inside a container.
# CIS DI-4.9: COPY not ADD.
COPY scripts/cis-harden.sh /tmp/cis-harden.sh
RUN chmod +x /tmp/cis-harden.sh \
    && /tmp/cis-harden.sh --container \
    && rm -f /tmp/cis-harden.sh

# ── Environment ───────────────────────────────────────────────────────────────
# CIS DI-4.8: behaviour control only — prevents dotfile side-effects.
ENV HOME=/dev/null

# ── No ports ──────────────────────────────────────────────────────────────────
# CIS DI-4.11: no EXPOSE instruction.

# ── Healthcheck ───────────────────────────────────────────────────────────────
# CIS DI-4.6: init containers use exit code for health, not HEALTHCHECK.
HEALTHCHECK NONE

# ── Non-root enforcement ──────────────────────────────────────────────────────
# CIS DI-4.1: hermes (10001:10001). Derived images needing apt must:
#   USER root
#   RUN apt-get update && apt-get install -y --no-install-recommends <pkgs> \
#       && apt-get clean && rm -rf /var/lib/apt/lists/*
#   USER 10001:10001
USER 10001:10001
