# =============================================================================
# nexus-init.dockerfile — One-shot container for Nexus REST API bootstrap
#
# Invoked via docker run (not as a Jenkins agent). Calls the Nexus REST API
# to set the admin password on first boot and create a docker-hosted repo.
#
# Single-stage Alpine image — no compiled tools, no Jenkins agent JAR.
#
# Security posture:
#   - No credentials baked in; all secrets injected at runtime via env vars
#   - Extends hardened-alpine-base (hermes 10001:10001, SUID/SGID stripped)
#   - SUID/SGID re-stripped after apk installs
#   - HOME=/dev/null, HEALTHCHECK NONE inherited from base
# =============================================================================

ARG BASE_IMAGE=hardened-alpine-base:sha-required

FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="nexus-init" \
      org.opencontainers.image.description="One-shot container that bootstraps Nexus Repository Manager via REST API" \
      org.opencontainers.image.vendor="sarins-lab" \
      org.opencontainers.image.source="https://github.com/sarins-lab/docker-images" \
      org.opencontainers.image.licenses="MIT"

USER root

# ── Runtime packages ──────────────────────────────────────────────────────────
RUN apk add --no-cache curl jq ca-certificates \
 && rm -rf \
    /var/cache/apk \
    /lib/apk \
    /usr/share/apk \
    /etc/apk \
    /sbin/apk

# ── CIS DI-4.10: re-strip SUID/SGID after apk installs ───────────────────────
RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} +

USER 10001:10001
