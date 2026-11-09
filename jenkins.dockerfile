ARG JENKINS_IMAGE=jenkins/jenkins:2.589-jdk25@sha256:595b46fe0d82d1dedb9a5681adfb6e709c8e51598a76ad9fcfe23e6eca98280e
FROM ${JENKINS_IMAGE} AS hardened

USER root
COPY scripts/cis-harden.sh /tmp/cis-harden.sh
RUN set -eux; \
    . /etc/os-release; \
    case "$ID" in \
        alpine) apk upgrade --no-cache; apk del --no-cache git-lfs ;; \
        debian) apt-get update; \
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends; \
            apt-get clean; rm -rf /var/lib/apt/lists/* ;; \
        *) echo "Unsupported Jenkins base OS: $ID" >&2; exit 1 ;; \
    esac; \
    if [ ! -e /usr/bin/tini ]; then ln -s "$(command -v tini)" /usr/bin/tini; fi; \
    rm -f /opt/jenkins-plugin-manager.jar /usr/bin/jenkins-plugin-cli /usr/local/bin/git-lfs; \
    sh /tmp/cis-harden.sh --container --skip-user; \
    rm -f /tmp/cis-harden.sh

COPY jenkins/00-controller-hardening.groovy /usr/share/jenkins/ref/init.groovy.d/00-controller-hardening.groovy.override
COPY --chmod=0555 jenkins/entrypoint.sh /usr/local/bin/jenkins-hardened.sh
RUN set -eux; \
    chown -R root:root /usr/share/jenkins/ref; \
    chmod -R go-w /usr/share/jenkins/ref; \
    chown root:root /usr/share/jenkins/jenkins.war; \
    chmod 0444 /usr/share/jenkins/jenkins.war

# Copy the merged filesystem, not upstream layers containing removed tools.
FROM scratch
COPY --from=hardened / /
ARG JENKINS_IMAGE

LABEL org.opencontainers.image.title="sg-jenkins" \
    org.opencontainers.image.description="Jenkins LTS controller: non-root, no controller executors, CSRF protection, WebSocket agents" \
    org.opencontainers.image.source="https://github.com/sarins-lab/docker-images" \
    org.opencontainers.image.vendor="sarins-lab" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.base.name="${JENKINS_IMAGE}"

ENV JAVA_HOME=/opt/java/openjdk \
    PATH=/opt/java/openjdk/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 \
    JENKINS_HOME=/var/jenkins_home \
    JENKINS_SLAVE_AGENT_PORT=-1 \
    REF=/usr/share/jenkins/ref \
    JENKINS_UC=https://updates.jenkins.io \
    JENKINS_UC_EXPERIMENTAL=https://updates.jenkins.io/experimental \
    JENKINS_INCREMENTALS_REPO_MIRROR=https://repo.jenkins-ci.org/incrementals \
    COPY_REFERENCE_FILE_LOG=/var/jenkins_home/copy_reference_file.log

VOLUME /var/jenkins_home

HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
    CMD curl --fail --silent --show-error --max-time 4 http://127.0.0.1:8080/login > /dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/jenkins-hardened.sh"]
USER 1000:1000
