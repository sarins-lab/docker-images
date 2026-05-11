# =============================================================================
# platform-base — CIS-hardened Alpine base image
# =============================================================================
# A minimal Alpine image with CIS Docker Benchmark v1.6 hardening applied.
# Intended as a base layer for any platform init container. Provides:
#   • hermes non-root user (uid/gid 10001)
#   • SUID/SGID bits stripped from the base Alpine filesystem
#   • HOME=/dev/null (prevents tools writing ~/.vault-token, ~/.step, etc.)
#   • HEALTHCHECK NONE
#   • USER 10001:10001 as the final instruction
#
# Derived image responsibilities (CIS DI-4.3):
#   apk is intentionally left in place so that derived images can call
#   'apk add'. They MUST remove apk state as their final privileged layer:
#     RUN apk add --no-cache <packages> \
#         && rm -rf /var/cache/apk /lib/apk /usr/share/apk /etc/apk /sbin/apk
#
# Hardening applied by scripts/cis-harden.sh:
#   DI-4.1  Dedicated non-root user: hermes (uid/gid 10001) — not "nobody"
#   DI-4.10 SUID/SGID bits stripped from the base Alpine filesystem
#
# Hardening set explicitly here:
#   DI-4.6  HEALTHCHECK NONE — init containers exit; health tracked via exit code
#   DI-4.8  No secrets or credential stubs in ENV or ARG
#   DI-4.11 No EXPOSE — init containers never listen on ports
#
# ── Build (from repo root) ────────────────────────────────────────────────────
# IMPORTANT: build from the repo root so COPY can reach scripts/cis-harden.sh.
#
# Single-arch (development):
#   docker build \
#     -f alpine.dockerfile \
#     -t hardened-alpine-base:1.0.0 \
#     .
#
# Multi-arch (production — requires buildx):
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     -f alpine.dockerfile \
#     -t <registry>/hardened-alpine-base:1.0.0 \
#     --push .
#
# ── H-005 / Digest pinning ────────────────────────────────────────────────────
# After pushing, capture the immutable digest and use it in derived Dockerfiles:
#   docker inspect --format='{{index .RepoDigests 0}}' <registry>/platform-base:1.0.0
# Also pin the Alpine base image (see comment below).
# =============================================================================

# ── Base image pinning ────────────────────────────────────────────────────────
# H-005 TODO: replace with pinned digest after first pull:
#   docker pull alpine:3.22.4
#   docker inspect --format='{{index .RepoDigests 0}}' alpine:3.22.4
# Example: FROM alpine@sha256:<digest>
ARG ALPINE_VERSION=3.22.4
FROM alpine:${ALPINE_VERSION}
ARG ALPINE_VERSION

# OCI image labels — enables SBOM tooling (Syft, Trivy) and supply-chain auditing.
LABEL org.opencontainers.image.title="hardened-alpine-base" \
    org.opencontainers.image.description="CIS-hardened Alpine ${ALPINE_VERSION} base: hermes non-root user, SUID/SGID stripped" \
    org.opencontainers.image.source="https://github.com/sarins-lab/docker-images" \
    org.opencontainers.image.vendor="sarins-lab" \
    org.opencontainers.image.base.name="alpine:${ALPINE_VERSION}"

# ── CIS hardening ─────────────────────────────────────────────────────────────
# scripts/cis-harden.sh auto-detects Alpine (via /etc/os-release) and applies:
#   DI-4.1  Creates dedicated non-root user: hermes (uid/gid 10001)
#   DI-4.10 Strips all SUID/SGID bits from the base Alpine filesystem
#
# The script is deleted after execution — it is not present in the final image.
# CIS DI-4.9: COPY not ADD (no URL-fetching side-effects).
COPY scripts/cis-harden.sh /tmp/cis-harden.sh
RUN chmod +x /tmp/cis-harden.sh \
    && /tmp/cis-harden.sh \
    && rm -f /tmp/cis-harden.sh

# ── Environment ───────────────────────────────────────────────────────────────
# CIS DI-4.8: HOME=/dev/null is a behaviour control, not a credential stub.
# Prevents curl (~/.curlrc), bao (~/.vault-token), and step (~/.step) from
# writing persistent state. With readOnlyRootFilesystem: true in the PodSpec
# these writes would fail anyway; HOME=/dev/null also silences the errors.
ENV HOME=/dev/null

# ── No ports ──────────────────────────────────────────────────────────────────
# CIS DI-4.11: init containers never listen on ports. No EXPOSE instruction.

# ── Healthcheck ───────────────────────────────────────────────────────────────
# CIS DI-4.6: init containers exit on completion; Kubernetes tracks health via
# exit code, not HEALTHCHECK. An active HEALTHCHECK would leave a zombie process
# in a completed init container.
HEALTHCHECK NONE

# ── Non-root enforcement ──────────────────────────────────────────────────────
# CIS DI-4.1: all subsequent instructions and the container entrypoint run as
# hermes (10001:10001). Derived images that need to call apk must temporarily
# escalate with USER root and then drop back with USER 10001:10001.
# Match in PodSpec:
#   securityContext:
#     runAsNonRoot: true
#     runAsUser: 10001
#     runAsGroup: 10001
USER 10001:10001
