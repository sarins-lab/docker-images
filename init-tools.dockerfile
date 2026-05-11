# =============================================================================
# platform-init-tools — platform init container with bao + step + curl + jq
# =============================================================================
# Extends platform-base with the runtime tools needed by platform init scripts:
#   curl               — HTTP client (Kubernetes API + OpenBao REST API)
#   jq                 — JSON parsing (vault auth responses, token extraction)
#   gettext (envsubst) — template substitution
#   bao (OpenBao CLI)  — vault operations; cleaner than raw curl in scripts
#   step (step-cli)    — certificate inspection and step-ca provisioning
#
# Multi-stage build:
#   Stage 1 (fetcher): downloads, SHA-256 verifies, and extracts bao + step
#   Stage 2 (final):   extends platform-base; installs packages; re-strips SUID
#
# CIS hardening inherited from platform-base (docker/platform-base/Dockerfile):
#   DI-4.1   hermes (uid/gid 10001) dedicated non-root user
#   DI-4.6   HEALTHCHECK NONE
#   DI-4.8   HOME=/dev/null (no credential-file side effects)
#   DI-4.11  No EXPOSE
#
# Additional CIS hardening applied in this Dockerfile:
#   DI-4.3   apk removed after package installs (cannot be used post-compromise)
#   DI-4.4   Third-party binaries verified with hardcoded SHA-256 (immune to
#            compromised release servers — not just the downloaded checksum file)
#   DI-4.7   All installs in a single RUN with --no-cache
#   DI-4.9   COPY not ADD — deterministic, no URL-fetching side-effects
#   DI-4.10  SUID/SGID re-stripped after all binaries are in place
#
# ── Build order ───────────────────────────────────────────────────────────────
# 1. Build hardened-alpine-base locally first (see alpine.dockerfile):
#      docker build --build-arg ALPINE_VERSION=3.22.4 \
#        -f alpine.dockerfile -t hardened-alpine-base:dev .
#
# 2. Build platform-init-tools:
#
#    Single-arch (development):
#      docker build \
#        --build-arg BASE_IMAGE=hardened-alpine-base:dev \
#        -f init-tools.dockerfile \
#        -t platform-init-tools:dev \
#        .
#
#    Multi-arch (production — requires buildx):
#      docker buildx build --platform linux/amd64,linux/arm64 \
#        --build-arg BASE_IMAGE=ghcr.io/<owner>/hardened-alpine-base:<ver>-<track-suffix> \
#        -f init-tools.dockerfile \
#        -t <registry>/platform-init-tools:<ver> \
#        --push .
#
# ── H-005 / Digest pinning ────────────────────────────────────────────────────
# After pushing, capture and commit the immutable digest:
#   docker inspect --format='{{index .RepoDigests 0}}' \
#     <registry>/platform-init-tools:1.0.0
# Replace the image tag in values.yaml with this digest reference.
# =============================================================================

# ── Version ARGs — single place to bump ──────────────────────────────────────
# OpenBao releases: https://github.com/openbao/openbao/releases
# step-cli releases: https://github.com/smallstep/cli/releases
# BASE_IMAGE: fully-qualified reference to hardened-alpine-base (set by CI or
#   locally via --build-arg). Must be registry-qualified for multi-arch builds.
ARG BASE_IMAGE=hardened-alpine-base:sha-required
ARG OPENBAO_VERSION=2.5.3
ARG STEP_VERSION=0.30.2

# ── Expected SHA-256 digests (hardcoded — not derived from the release server) ─
# These are the KNOWN-GOOD hashes for the above versions. The build fails if the
# downloaded archive does not match, catching compromised release servers or
# MITM attacks. Verify these independently before bumping versions:
#   curl -fsSL https://github.com/openbao/openbao/releases/download/v2.5.3/checksums-linux.txt
#   curl -fsSL https://github.com/smallstep/cli/releases/download/v0.30.2/checksums.txt
ARG OPENBAO_AMD64_SHA256=74e8ce7753ac205528f93148c47c91f417bea1ce21ddb126969bf3ef5598cadd
ARG OPENBAO_ARM64_SHA256=202ea312516baabe653f2d10d4bee7815c8fa1192c463fd6b443fba3744301de
ARG STEP_AMD64_SHA256=abf5ffe9a39c01c7b4e777d50a96f30f33f5bd8eeafa2dfeef22b8a4abeee14a
ARG STEP_ARM64_SHA256=7d66fa62949d64142b053db1c86ee29037088919cd329ac7966b15b09e914230

# =============================================================================
# Stage 1 — fetcher
# Downloads and verifies third-party CLI binaries.
# This stage is NOT present in the final image.
# =============================================================================
FROM alpine:3.22.4 AS fetcher

# Re-declare version and checksum ARGs so they are visible in this stage.
ARG OPENBAO_VERSION
ARG STEP_VERSION
ARG OPENBAO_AMD64_SHA256
ARG OPENBAO_ARM64_SHA256
ARG STEP_AMD64_SHA256
ARG STEP_ARM64_SHA256
# Docker BuildKit sets TARGETARCH automatically for cross-platform builds:
#   linux/amd64 → amd64,  linux/arm64 → arm64
ARG TARGETARCH=amd64

# Install only what fetching + verification needs; not in the final image.
RUN apk add --no-cache curl tar

# ── OpenBao CLI ───────────────────────────────────────────────────────────────
# OpenBao uses title-cased "Linux" and full arch names in its asset filenames:
#   amd64 → bao_<ver>_Linux_x86_64.tar.gz
#   arm64 → bao_<ver>_Linux_arm64.tar.gz
# Checksums are in a single file: checksums-linux.txt
#
# Supply-chain: we verify against the HARDCODED expected hash in the ARG above.
# The downloaded checksums file is cross-checked only as belt-and-suspenders;
# it is not trusted as the source of truth.
#
# Optional stronger verification (not scripted here):
#   gpg --verify bao_<ver>_Linux_<arch>.tar.gz.gpgsig bao_<ver>_Linux_<arch>.tar.gz
#   Key: https://github.com/openbao/openbao/blob/main/openbao-gpg-pub-20240618.asc
RUN set -eux; \
    # Map Docker arch → OpenBao asset arch name
    case "${TARGETARCH}" in \
    amd64) ARCH="x86_64"; EXPECTED_SHA="${OPENBAO_AMD64_SHA256}" ;; \
    arm64) ARCH="arm64";  EXPECTED_SHA="${OPENBAO_ARM64_SHA256}" ;; \
    *)     echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    ARCHIVE="bao_${OPENBAO_VERSION}_Linux_${ARCH}.tar.gz"; \
    BASE_URL="https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}"; \
    \
    curl -fsSL "${BASE_URL}/${ARCHIVE}" -o /tmp/bao.tar.gz; \
    \
    # Primary verification: hardcoded hash
    echo "${EXPECTED_SHA}  /tmp/bao.tar.gz" | sha256sum -c -; \
    \
    # Belt-and-suspenders: cross-check against official checksums file
    curl -fsSL "${BASE_URL}/checksums-linux.txt" -o /tmp/bao.checksums; \
    awk -v archive="${ARCHIVE}" '$2 == archive { print $1 "  /tmp/bao.tar.gz" }' /tmp/bao.checksums \
    | sha256sum -c -; \
    \
    # Extract binary — OpenBao tarballs place 'bao' at the archive root
    tar -xzf /tmp/bao.tar.gz -C /tmp bao 2>/dev/null || { \
    echo "ERROR: 'bao' not at archive root. Archive contents:"; \
    tar -tzf /tmp/bao.tar.gz; \
    exit 1; \
    }; \
    chmod 0755 /tmp/bao; \
    # Sanity-check: binary executes and identifies itself
    /tmp/bao version; \
    rm -f /tmp/bao.tar.gz /tmp/bao.checksums

# ── Smallstep CLI ─────────────────────────────────────────────────────────────
# step uses lowercase arch names matching Docker's TARGETARCH (amd64, arm64).
# Tarball internal path: step_<ver>/bin/step
#
# Optional stronger verification (not scripted here):
#   cosign verify-blob --bundle step_linux_<ver>_<arch>.tar.gz.sigstore.json \
#     --certificate-oidc-issuer https://token.actions.githubusercontent.com \
#     --certificate-identity-regexp 'https://github.com/smallstep/cli/.github/workflows/.*' \
#     step_linux_<ver>_<arch>.tar.gz
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64) EXPECTED_SHA="${STEP_AMD64_SHA256}" ;; \
    arm64) EXPECTED_SHA="${STEP_ARM64_SHA256}" ;; \
    *)     echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    ARCHIVE="step_linux_${STEP_VERSION}_${TARGETARCH}.tar.gz"; \
    BASE_URL="https://github.com/smallstep/cli/releases/download/v${STEP_VERSION}"; \
    \
    curl -fsSL "${BASE_URL}/${ARCHIVE}" -o /tmp/step.tar.gz; \
    \
    # Primary verification: hardcoded hash
    echo "${EXPECTED_SHA}  /tmp/step.tar.gz" | sha256sum -c -; \
    \
    # Belt-and-suspenders: cross-check against official checksums file
    curl -fsSL "${BASE_URL}/checksums.txt" -o /tmp/step.checksums; \
    awk -v archive="${ARCHIVE}" '$2 == archive { print $1 "  /tmp/step.tar.gz" }' /tmp/step.checksums \
    | sha256sum -c -; \
    \
    # Extract binary from known path inside tarball
    tar -xzf /tmp/step.tar.gz -C /tmp "step_${STEP_VERSION}/bin/step"; \
    mv /tmp/step_${STEP_VERSION}/bin/step /tmp/step; \
    chmod 0755 /tmp/step; \
    # Sanity-check: binary executes and identifies itself
    /tmp/step version; \
    rm -rf /tmp/step.tar.gz /tmp/step.checksums /tmp/step_${STEP_VERSION}

# =============================================================================
# Stage 2 — final runtime image
# Extends hardened-alpine-base with runtime tools.
# =============================================================================
# BASE_IMAGE provides: hermes user (10001:10001), SUID/SGID-stripped Alpine
# filesystem, ENV HOME=/dev/null, HEALTHCHECK NONE, USER 10001:10001.
# H-005 TODO: replace the version tag in BASE_IMAGE with a pinned digest after push.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG OPENBAO_VERSION
ARG STEP_VERSION

# OCI image labels — enables SBOM tooling (Syft, Trivy) and supply-chain auditing.
# Update org.opencontainers.image.source to your actual repository URL.
LABEL org.opencontainers.image.title="platform-init-tools" \
    org.opencontainers.image.description="CIS-hardened platform init container: curl + jq + bao + step" \
    org.opencontainers.image.source="https://github.com/sarins-lab/docker-images" \
    org.opencontainers.image.documentation="https://github.com/sarins-lab/docker-images/blob/main/init-tools.dockerfile" \
    org.opencontainers.image.vendor="sarins-lab" \
    io.openbao.version="${OPENBAO_VERSION}" \
    io.step.version="${STEP_VERSION}"

# ── Temporarily elevate to root ───────────────────────────────────────────────
# hardened-alpine-base ends with USER 10001:10001; we need root to call apk and to
# set binary ownership. We drop back to hermes at the end of this stage.
USER root

# ── Runtime packages ──────────────────────────────────────────────────────────
# CIS DI-4.3 / DI-4.7: single RUN, --no-cache, full apk cleanup in the same
# layer. After this layer apk is non-functional — it cannot be used for
# post-compromise package installs even if the container is hijacked.
#   curl:    HTTP client (K8s API + OpenBao REST API calls)
#   jq:      JSON parsing (extract tokens from vault responses)
#   gettext: provides envsubst (template substitution if needed by scripts)
RUN apk add --no-cache curl jq gettext \
    && rm -rf \
    /var/cache/apk \
    /lib/apk \
    /usr/share/apk \
    /etc/apk \
    /sbin/apk

# ── Third-party CLIs ──────────────────────────────────────────────────────────
# CIS DI-4.9: COPY not ADD — binaries were SHA-256 verified in the fetcher stage.
# The fetcher layer itself is discarded; only the verified binaries are kept.
COPY --from=fetcher /tmp/bao  /usr/local/bin/bao
COPY --from=fetcher /tmp/step /usr/local/bin/step

# ── Lock down binary ownership ────────────────────────────────────────────────
# Owned by root:root so the running non-root user (hermes) cannot replace or
# overwrite them even though they are world-executable.
RUN chown root:root /usr/local/bin/bao /usr/local/bin/step

# ── CIS DI-4.10: re-strip SUID/SGID ─────────────────────────────────────────
# Re-run after all binaries are in place. Catches any SUID bits introduced by
# the apk packages (curl, jq) or the copied binaries (bao, step).
# platform-base already stripped the base Alpine filesystem; this layer only
# needs to catch what was added since.
RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} +

# ── Runtime credentials (injected via PodSpec only) ───────────────────────────
# CIS DI-4.8: do NOT set runtime secrets as ENV stubs. Even empty values
# (ENV BAO_TOKEN="") trigger Docker BuildKit's sensitive-variable scanner and
# appear in `docker inspect` output, polluting audit trails.
# All credentials are injected at runtime via PodSpec secretKeyRef / plain env:
#   BAO_ADDR         — OpenBao server URL  (e.g. https://platform-openbao:8200)
#   BAO_CACERT       — Path to CA bundle   (mounted emptyDir or configMap)
#   BAO_TOKEN        — Vault token         (secretKeyRef — never baked in)
#   STEP_CA_URL      — step-ca server URL  (e.g. https://step-ca:9000)
#   STEP_FINGERPRINT — step-ca root fingerprint (non-secret, but runtime config)

# ── Restore non-root user ─────────────────────────────────────────────────────
# ENV HOME=/dev/null and HEALTHCHECK NONE are inherited from platform-base.
# USER is re-stated explicitly (it was overridden by USER root above).
USER 10001:10001
