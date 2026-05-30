# =============================================================================
# toolbox.dockerfile — Jenkins inbound agent for artifact transport,
#                      vault operations, image signing, and scanning
#
# Build stages:
#   fetcher  — Alpine; downloads and SHA-256 verifies all third-party binaries
#   final    — Hardened Alpine 3.22 base; installs runtime packages
#
# Security posture:
#   - All downloaded binaries verified with hardcoded SHA-256 before use
#   - Extends hardened-alpine-base (hermes 10001:10001, SUID/SGID stripped)
#   - SUID/SGID re-stripped after all installs
#   - HOME=/dev/null, HEALTHCHECK NONE inherited from base
#   - No secrets or credential stubs in ENV
# =============================================================================

# ── Version ARGs ─────────────────────────────────────────────────────────────
ARG BASE_IMAGE=hardened-alpine-base:sha-required

ARG CRANE_VERSION=0.20.6
ARG CRANE_AMD64_SHA256=c1d593d01551f2c9a3df5ca0a0be4385a839bd9b86d4a76e18d7b17d16559127
ARG CRANE_ARM64_SHA256=fc0515857bc38e4ddd2d37a5ab03fb5959449c7b2d4ad759bcc1174ac0cad91b

ARG ORAS_VERSION=1.2.3
ARG ORAS_AMD64_SHA256=b4efc97a91f471f323f193ea4b4d63d8ff443ca3aab514151a30751330852827
ARG ORAS_ARM64_SHA256=90e24e234dc6dffe73365533db66fd14449d2c9ae77381081596bf92f40f6b82

ARG COSIGN_VERSION=2.5.0
ARG COSIGN_AMD64_SHA256=1f6c194dd0891eb345b436bb71ff9f996768355f5e0ce02dde88567029ac2188
ARG COSIGN_ARM64_SHA256=080a998f9878f22dafdb9ad54d5b2e2b8e7a38c53527250f9d89a6763a28d545

ARG TRIVY_VERSION=0.70.0
ARG TRIVY_AMD64_SHA256=8b4376d5d6befe5c24d503f10ff136d9e0c49f9127a4279fd110b727929a5aa9
ARG TRIVY_ARM64_SHA256=2f6bb988b553a1bbac6bdd1ce890f5e412439564e17522b88a4541b4f364fc8d

# step — same version as init-tools.dockerfile for consistency
ARG STEP_VERSION=0.30.2
ARG STEP_AMD64_SHA256=abf5ffe9a39c01c7b4e777d50a96f30f33f5bd8eeafa2dfeef22b8a4abeee14a
ARG STEP_ARM64_SHA256=7d66fa62949d64142b053db1c86ee29037088919cd329ac7966b15b09e914230

# Bitwarden CLI — amd64 only; no official arm64 binary published
ARG BW_VERSION=2025.4.0
ARG BW_AMD64_SHA256=10a9c1389cc18af474e2d78cbbdacb497805e8bdf926767c07a8504be412c60e

ARG JENKINS_REMOTING_VERSION=3256.v88a_f6e922152
ARG JENKINS_REMOTING_SHA256=430cde2fc6352a508efa31d5d0bcb329d40c8fea90f629fa8e2c899764795b1f

# platform-events — first-party event-bus client (built+published in phase 1).
# Fetched from the internal Nexus raw repo, not the internet. SHA values are
# emitted by clients/go `make publish` (SHA256SUMS) and pinned here.
# ARTIFACT_BASE_URL points at the Nexus platform-raw repo for this version.
ARG PLATFORM_EVENTS_VERSION=0.1.0
ARG ARTIFACT_BASE_URL=http://nexus:8081/repository/platform-raw/platform-events/0.1.0
ARG PLATFORM_EVENTS_AMD64_SHA256=REPLACE_WITH_PUBLISHED_AMD64_SHA256
ARG PLATFORM_EVENTS_ARM64_SHA256=REPLACE_WITH_PUBLISHED_ARM64_SHA256

# =============================================================================
# Stage 1 — fetcher
# =============================================================================
FROM alpine:3.22.4 AS fetcher

ARG CRANE_VERSION
ARG CRANE_AMD64_SHA256
ARG CRANE_ARM64_SHA256
ARG ORAS_VERSION
ARG ORAS_AMD64_SHA256
ARG ORAS_ARM64_SHA256
ARG COSIGN_VERSION
ARG COSIGN_AMD64_SHA256
ARG COSIGN_ARM64_SHA256
ARG TRIVY_VERSION
ARG TRIVY_AMD64_SHA256
ARG TRIVY_ARM64_SHA256
ARG STEP_VERSION
ARG STEP_AMD64_SHA256
ARG STEP_ARM64_SHA256
ARG BW_VERSION
ARG BW_AMD64_SHA256
ARG JENKINS_REMOTING_VERSION
ARG JENKINS_REMOTING_SHA256
ARG PLATFORM_EVENTS_VERSION
ARG ARTIFACT_BASE_URL
ARG PLATFORM_EVENTS_AMD64_SHA256
ARG PLATFORM_EVENTS_ARM64_SHA256
ARG TARGETARCH=amd64

RUN apk add --no-cache curl unzip tar

WORKDIR /fetch

# ── crane ────────────────────────────────────────────────────────────────────
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64) ARCH="x86_64"; EXPECTED="${CRANE_AMD64_SHA256}" ;; \
    arm64) ARCH="arm64";  EXPECTED="${CRANE_ARM64_SHA256}" ;; \
    *)     echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
        "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_${ARCH}.tar.gz" \
        -o /tmp/crane.tar.gz; \
    echo "${EXPECTED}  /tmp/crane.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/crane.tar.gz -C /fetch crane; \
    chmod 0755 /fetch/crane; \
    rm /tmp/crane.tar.gz

# ── oras ─────────────────────────────────────────────────────────────────────
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64) EXPECTED="${ORAS_AMD64_SHA256}" ;; \
    arm64) EXPECTED="${ORAS_ARM64_SHA256}" ;; \
    *)     echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
        "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${TARGETARCH}.tar.gz" \
        -o /tmp/oras.tar.gz; \
    echo "${EXPECTED}  /tmp/oras.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/oras.tar.gz -C /fetch oras; \
    chmod 0755 /fetch/oras; \
    rm /tmp/oras.tar.gz

# ── cosign ───────────────────────────────────────────────────────────────────
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64) EXPECTED="${COSIGN_AMD64_SHA256}" ;; \
    arm64) EXPECTED="${COSIGN_ARM64_SHA256}" ;; \
    *)     echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
        "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${TARGETARCH}" \
        -o /fetch/cosign; \
    echo "${EXPECTED}  /fetch/cosign" | sha256sum -c -; \
    chmod 0755 /fetch/cosign

# ── trivy ────────────────────────────────────────────────────────────────────
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64) TARCH="64bit";  EXPECTED="${TRIVY_AMD64_SHA256}" ;; \
    arm64) TARCH="ARM64";  EXPECTED="${TRIVY_ARM64_SHA256}" ;; \
    *)     echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
        "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${TARCH}.tar.gz" \
        -o /tmp/trivy.tar.gz; \
    echo "${EXPECTED}  /tmp/trivy.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/trivy.tar.gz -C /fetch trivy; \
    chmod 0755 /fetch/trivy; \
    rm /tmp/trivy.tar.gz

# ── step CLI ─────────────────────────────────────────────────────────────────
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64) EXPECTED="${STEP_AMD64_SHA256}" ;; \
    arm64) EXPECTED="${STEP_ARM64_SHA256}" ;; \
    *)     echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
        "https://github.com/smallstep/cli/releases/download/v${STEP_VERSION}/step_linux_${STEP_VERSION}_${TARGETARCH}.tar.gz" \
        -o /tmp/step.tar.gz; \
    echo "${EXPECTED}  /tmp/step.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/step.tar.gz -C /tmp "step_${STEP_VERSION}/bin/step"; \
    mv /tmp/step_${STEP_VERSION}/bin/step /fetch/step; \
    chmod 0755 /fetch/step; \
    rm -rf /tmp/step.tar.gz /tmp/step_${STEP_VERSION}

# ── Bitwarden CLI (amd64 only) ────────────────────────────────────────────────
RUN set -eux; \
    if [ "${TARGETARCH}" = "amd64" ]; then \
        curl -fsSL \
            "https://github.com/bitwarden/clients/releases/download/cli-v${BW_VERSION}/bw-linux-${BW_VERSION}.zip" \
            -o /tmp/bw.zip; \
        echo "${BW_AMD64_SHA256}  /tmp/bw.zip" | sha256sum -c -; \
        unzip -j /tmp/bw.zip -d /fetch bw; \
        chmod 0755 /fetch/bw; \
        rm /tmp/bw.zip; \
    else \
        printf '#!/bin/sh\necho "bw: no arm64 binary available" >&2\nexit 1\n' > /fetch/bw; \
        chmod 0755 /fetch/bw; \
    fi

# ── Jenkins remoting JAR ─────────────────────────────────────────────────────
RUN set -eux; \
    curl -fsSL \
        "https://repo.jenkins-ci.org/releases/org/jenkins-ci/main/remoting/${JENKINS_REMOTING_VERSION}/remoting-${JENKINS_REMOTING_VERSION}.jar" \
        -o /fetch/agent.jar; \
    echo "${JENKINS_REMOTING_SHA256}  /fetch/agent.jar" | sha256sum -c -

# ── platform-events (first-party; from internal Nexus, not the internet) ──────
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64) EXPECTED="${PLATFORM_EVENTS_AMD64_SHA256}" ;; \
    arm64) EXPECTED="${PLATFORM_EVENTS_ARM64_SHA256}" ;; \
    *)     echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
        "${ARTIFACT_BASE_URL}/platform-events-linux-${TARGETARCH}" \
        -o /fetch/platform-events; \
    echo "${EXPECTED}  /fetch/platform-events" | sha256sum -c -; \
    chmod 0755 /fetch/platform-events

# =============================================================================
# Stage 2 — final
# =============================================================================
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="jenkins-toolbox-agent" \
      org.opencontainers.image.description="Jenkins inbound agent for artifact transport, vault operations, image signing, and vulnerability scanning" \
      org.opencontainers.image.vendor="sarins-lab" \
      org.opencontainers.image.source="https://github.com/sarins-lab/docker-images" \
      org.opencontainers.image.licenses="MIT"

ARG CRANE_VERSION ORAS_VERSION COSIGN_VERSION TRIVY_VERSION STEP_VERSION BW_VERSION JENKINS_REMOTING_VERSION PLATFORM_EVENTS_VERSION

LABEL io.crane.version="${CRANE_VERSION}" \
      io.oras.version="${ORAS_VERSION}" \
      io.cosign.version="${COSIGN_VERSION}" \
      io.trivy.version="${TRIVY_VERSION}" \
      io.step.version="${STEP_VERSION}" \
      io.jenkins.remoting.version="${JENKINS_REMOTING_VERSION}" \
      io.platform-events.version="${PLATFORM_EVENTS_VERSION}"

USER root

# ── Runtime packages ──────────────────────────────────────────────────────────
RUN apk add --no-cache curl jq ca-certificates \
 && rm -rf \
    /var/cache/apk \
    /lib/apk \
    /usr/share/apk \
    /etc/apk \
    /sbin/apk

# ── Verified binaries from fetcher ───────────────────────────────────────────
COPY --from=fetcher /fetch/crane          /usr/local/bin/crane
COPY --from=fetcher /fetch/oras           /usr/local/bin/oras
COPY --from=fetcher /fetch/cosign         /usr/local/bin/cosign
COPY --from=fetcher /fetch/trivy          /usr/local/bin/trivy
COPY --from=fetcher /fetch/step           /usr/local/bin/step
COPY --from=fetcher /fetch/bw             /usr/local/bin/bw
COPY --from=fetcher /fetch/platform-events /usr/local/bin/platform-events
COPY --from=fetcher /fetch/agent.jar      /usr/share/jenkins/agent.jar

RUN chown root:root \
      /usr/local/bin/crane \
      /usr/local/bin/oras \
      /usr/local/bin/cosign \
      /usr/local/bin/trivy \
      /usr/local/bin/step \
      /usr/local/bin/bw \
      /usr/local/bin/platform-events \
 && mkdir -p /usr/share/jenkins \
 && chown root:root /usr/share/jenkins/agent.jar

# ── CIS DI-4.10: re-strip SUID/SGID after all installs ───────────────────────
RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} +

USER 10001:10001
