# =============================================================================
# platform-base-rocky — CIS-hardened Rocky Linux 9 base image
# =============================================================================
# A minimal Rocky Linux 9 image with CIS Docker Benchmark v1.6 hardening
# applied. Use this as a base for init containers that require RPM-based
# tooling, FIPS-compliant libraries, or compatibility with RHEL environments.
#
# Provides:
#   • hermes non-root user (uid/gid 10001)
#   • SUID/SGID bits stripped from the base Rocky Linux filesystem
#   • HOME=/dev/null
#   • HEALTHCHECK NONE
#   • USER 10001:10001 as the final instruction
#
# Derived image responsibilities (CIS DI-4.3):
#   dnf is intentionally left in place so derived images can install packages.
#   They MUST clean up in the same RUN layer as their final dnf install:
#     RUN dnf install -y --setopt=install_weak_deps=False <pkgs> \
#         && dnf clean all && rm -rf /var/cache/dnf
#   Removing /var/cache/dnf and not providing yum.repos.d overrides effectively
#   prevents further dnf installs without a deliberate `dnf makecache` call.
#
# Hardening applied by scripts/cis-harden.sh --container:
#   DI-4.1  Dedicated non-root user: hermes (uid/gid 10001)
#   DI-4.10 SUID/SGID bits stripped from the base Rocky Linux filesystem
#
# Hardening set explicitly here:
#   DI-4.6  HEALTHCHECK NONE
#   DI-4.8  No secrets or credential stubs in ENV or ARG
#   DI-4.11 No EXPOSE
#
# Note on SELinux: SELinux is a kernel feature and cannot be enforced inside a
# container (the host kernel's SELinux policy applies). The full host hardening
# (cis-harden.sh without --container) does enforce SELinux on Rocky bare-metal
# or VM nodes via the Ansible play in ansible/site.yml.
#
# ── Build (from repo root) ────────────────────────────────────────────────────
# IMPORTANT: build from the repo root so COPY can reach scripts/cis-harden.sh.
#
# Single-arch (development):
#   docker build \
#     -f rocky.dockerfile \
#     -t hardened-rocky-base:1.0.0 \
#     .
#
# Multi-arch (production — requires buildx):
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     -f rocky.dockerfile \
#     -t <registry>/hardened-rocky-base:1.0.0 \
#     --push .
#
# ── H-005 / Digest pinning ────────────────────────────────────────────────────
# After pushing, capture the immutable digest:
#   docker inspect --format='{{index .RepoDigests 0}}' \
#     <registry>/platform-base-rocky:9
# Also pin the Rocky base image (replace rockylinux/rockylinux:9-minimal with @sha256:<digest>).
# =============================================================================

# H-005 TODO: replace with pinned digest after first pull:
#   docker pull rockylinux/rockylinux:9-minimal
#   docker inspect --format='{{index .RepoDigests 0}}' rockylinux/rockylinux:9-minimal
ARG ROCKY_VERSION=9-minimal
FROM rockylinux/rockylinux:${ROCKY_VERSION}
ARG ROCKY_VERSION

# OCI image labels
LABEL org.opencontainers.image.title="hardened-rocky-base" \
    org.opencontainers.image.description="CIS-hardened Rocky Linux ${ROCKY_VERSION} base: hermes non-root user, SUID/SGID stripped" \
    org.opencontainers.image.source="https://github.com/sarins-lab/docker-images" \
    org.opencontainers.image.vendor="sarins-lab" \
    org.opencontainers.image.base.name="rockylinux:${ROCKY_VERSION}"

# ── CIS hardening ─────────────────────────────────────────────────────────────
# --container selects Docker Benchmark controls only (DI-4.1 + DI-4.10).
# Host-only controls (SELinux, sysctl, SSH, firewalld, auditd) are skipped;
# they cannot be applied inside a container and would fail the build.
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
# CIS DI-4.1: hermes (10001:10001). Derived images needing dnf must:
#   USER root
#   RUN dnf install -y --setopt=install_weak_deps=False <pkgs> \
#       && dnf clean all && rm -rf /var/cache/dnf
#   USER 10001:10001
USER 10001:10001
