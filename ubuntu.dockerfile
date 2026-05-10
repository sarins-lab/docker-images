# =============================================================================
# platform-base-ubuntu — CIS-hardened Ubuntu base image (version by build arg)
# =============================================================================
# A minimal Ubuntu LTS image with CIS Docker Benchmark v1.6 hardening applied.
# Intended as a base layer for platform init containers that require apt,
# glibc, or Ubuntu-specific tooling not available in Alpine.
#
# Provides:
#   • hermes non-root user (uid/gid 10001)
#   • SUID/SGID bits stripped from the base Ubuntu filesystem
#   • HOME=/dev/null (prevents tools writing ~/.config, ~/.vault-token, etc.)
#   • HEALTHCHECK NONE
#   • USER 10001:10001 as the final instruction
#
# Derived image responsibilities (CIS DI-4.3):
#   apt is intentionally left in place so derived images can install packages.
#   They MUST clean up in the same RUN layer as their final apt-get install:
#     RUN apt-get update && apt-get install -y --no-install-recommends <pkgs> \
#         && apt-get clean && rm -rf /var/lib/apt/lists/*
#   Note: unlike Alpine, the apt binary cannot be fully removed without
#   breaking system integrity; cleaning the cache is the equivalent control.
#
# Hardening applied by scripts/cis-harden.sh --container:
#   DI-4.1  Dedicated non-root user: hermes (uid/gid 10001) — not "nobody"
#   DI-4.10 SUID/SGID bits stripped from the base filesystem
#
# Hardening set explicitly here:
#   DI-4.6  HEALTHCHECK NONE
#   DI-4.8  No secrets or credential stubs in ENV or ARG
#   DI-4.11 No EXPOSE — init containers never listen on ports
#
# ── Build (from repo root) ────────────────────────────────────────────────────
# IMPORTANT: build from the repo root so COPY can reach scripts/cis-harden.sh.
#
# Single-arch (development):
#   docker build --build-arg UBUNTU_VERSION=24.04 \
#     -f ubuntu.dockerfile \
#     -t hardened-ubuntu-base:1.0.0-ubuntu24 \
#     .
#
# Multi-arch (production — requires buildx):
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     --build-arg UBUNTU_VERSION=24.04 \
#     -f ubuntu.dockerfile \
#     -t <registry>/hardened-ubuntu-base:1.0.0-ubuntu24 \
#     --push .
#
# ── H-005 / Digest pinning ────────────────────────────────────────────────────
# After pushing, capture the immutable digest:
#   docker inspect --format='{{index .RepoDigests 0}}' \
#     <registry>/platform-base-ubuntu:24.04
# Use this digest in derived FROM lines and in values.yaml.
# Also pin the Ubuntu base image (replace ubuntu:24.04 with @sha256:<digest>).
# =============================================================================

# H-005 TODO: replace with pinned digest after first pull:
#   docker pull ubuntu:24.04
#   docker inspect --format='{{index .RepoDigests 0}}' ubuntu:24.04
ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}
ARG UBUNTU_VERSION

# OCI image labels — enables SBOM tooling (Syft, Trivy) and supply-chain auditing.
LABEL org.opencontainers.image.title="hardened-ubuntu-base" \
    org.opencontainers.image.description="CIS-hardened Ubuntu ${UBUNTU_VERSION} base: hermes non-root user, SUID/SGID stripped" \
    org.opencontainers.image.source="https://github.com/sarins-lab/docker-images" \
    org.opencontainers.image.vendor="sarins-lab" \
    org.opencontainers.image.base.name="ubuntu:${UBUNTU_VERSION}"

# ── CIS hardening ─────────────────────────────────────────────────────────────
# --container selects the Docker Benchmark subset of controls.
# Host-only controls (sysctl, SSH daemon, auditd, UFW, services) are skipped —
# they cannot be applied inside a container and would fail the build.
#
# The script is deleted after execution — it is not present in the final image.
# CIS DI-4.9: COPY not ADD.
COPY scripts/cis-harden.sh /tmp/cis-harden.sh

RUN chmod +x /tmp/cis-harden.sh \
    && /tmp/cis-harden.sh --container \
    && rm -f /tmp/cis-harden.sh

# ── Environment ───────────────────────────────────────────────────────────────
# CIS DI-4.8: HOME=/dev/null is a behaviour control, not a credential stub.
# Prevents curl (~/.netrc), and any other tool from writing persistent dotfiles.
ENV HOME=/dev/null

# ── No ports ──────────────────────────────────────────────────────────────────
# CIS DI-4.11: init containers never listen on ports. No EXPOSE instruction.

# ── Healthcheck ───────────────────────────────────────────────────────────────
# CIS DI-4.6: init containers exit on completion; health tracked via exit code.
HEALTHCHECK NONE

# ── Non-root enforcement ──────────────────────────────────────────────────────
# CIS DI-4.1: all subsequent instructions and the container entrypoint run as
# hermes (10001:10001). Derived images that need apt must temporarily escalate:
#   USER root
#   RUN apt-get update && apt-get install -y ... && apt-get clean && rm -rf /var/lib/apt/lists/*
#   USER 10001:10001
# Match in PodSpec:
#   securityContext:
#     runAsNonRoot: true
#     runAsUser: 10001
#     runAsGroup: 10001
USER 10001:10001
