# =============================================================================
# runner.dockerfile — Jenkins inbound agent for Ansible + OpenTofu stages
#
# Build stages:
#   fetcher  — Alpine; downloads and SHA-256 verifies all third-party binaries
#   final    — Hardened Ubuntu 24.04 base; installs apt packages; copies binaries
#
# Security posture:
#   - All downloaded binaries verified with hardcoded SHA-256 before use
#   - Extends hardened-ubuntu-base (hermes 10001:10001, SUID/SGID stripped)
#   - SUID/SGID re-stripped after all installs
#   - HOME=/dev/null, HEALTHCHECK NONE inherited from base
#   - No secrets or credential stubs in ENV
# =============================================================================

# ── Version ARGs ─────────────────────────────────────────────────────────────
ARG BASE_IMAGE=hardened-ubuntu-base:sha-required

ARG OPENTOFU_VERSION=1.9.1
ARG OPENTOFU_AMD64_SHA256=19eda43eaa45bef3e21d87c58f31a6df73e8534ea30e78619a463bdfdb889cd2
ARG OPENTOFU_ARM64_SHA256=733f41baef5923178385c1fc441140988aa98ba41e7669def97e3418347b4ed6

ARG JENKINS_REMOTING_VERSION=3256.v88a_f6e922152
ARG JENKINS_REMOTING_SHA256=430cde2fc6352a508efa31d5d0bcb329d40c8fea90f629fa8e2c899764795b1f

# =============================================================================
# Stage 1 — fetcher
# =============================================================================
FROM alpine:3.22.4 AS fetcher

ARG OPENTOFU_VERSION
ARG OPENTOFU_AMD64_SHA256
ARG OPENTOFU_ARM64_SHA256
ARG JENKINS_REMOTING_VERSION
ARG JENKINS_REMOTING_SHA256
ARG TARGETARCH=amd64

RUN apk add --no-cache curl unzip

WORKDIR /fetch

# ── OpenTofu ─────────────────────────────────────────────────────────────────
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64) EXPECTED="${OPENTOFU_AMD64_SHA256}" ;; \
    arm64) EXPECTED="${OPENTOFU_ARM64_SHA256}" ;; \
    *)     echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
        "https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_linux_${TARGETARCH}.zip" \
        -o /tmp/tofu.zip; \
    echo "${EXPECTED}  /tmp/tofu.zip" | sha256sum -c -; \
    unzip -j /tmp/tofu.zip tofu -d /fetch; \
    chmod 0755 /fetch/tofu; \
    /fetch/tofu version; \
    rm /tmp/tofu.zip

# ── Jenkins remoting JAR ──────────────────────────────────────────────────────
RUN set -eux; \
    curl -fsSL \
        "https://repo.jenkins-ci.org/releases/org/jenkins-ci/main/remoting/${JENKINS_REMOTING_VERSION}/remoting-${JENKINS_REMOTING_VERSION}.jar" \
        -o /fetch/agent.jar; \
    echo "${JENKINS_REMOTING_SHA256}  /fetch/agent.jar" | sha256sum -c -

# =============================================================================
# Stage 2 — final
# =============================================================================
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="jenkins-runner-agent" \
      org.opencontainers.image.description="Jenkins inbound agent with Ansible and OpenTofu for infrastructure provisioning stages" \
      org.opencontainers.image.vendor="sarins-lab" \
      org.opencontainers.image.source="https://github.com/sarins-lab/docker-images" \
      org.opencontainers.image.licenses="MIT"

ARG OPENTOFU_VERSION
ARG JENKINS_REMOTING_VERSION

LABEL io.opentofu.version="${OPENTOFU_VERSION}" \
      io.jenkins.remoting.version="${JENKINS_REMOTING_VERSION}"

USER root

# ── System packages and Ansible ───────────────────────────────────────────────
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
        git \
        curl \
        openssh-client \
        make \
        ca-certificates; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/ansible \
 && /opt/ansible/bin/pip install --no-cache-dir ansible

# ── Verified binaries from fetcher ───────────────────────────────────────────
COPY --from=fetcher /fetch/tofu       /usr/local/bin/tofu
COPY --from=fetcher /fetch/agent.jar  /usr/share/jenkins/agent.jar

RUN chown root:root /usr/local/bin/tofu \
 && mkdir -p /usr/share/jenkins \
 && chown root:root /usr/share/jenkins/agent.jar

# ── CIS DI-4.10: re-strip SUID/SGID after all installs ───────────────────────
RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} +

ENV PATH="/opt/ansible/bin:${PATH}"

USER 10001:10001
