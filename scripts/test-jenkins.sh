#!/usr/bin/env bash
set -Eeuo pipefail

docker=${DOCKER:-docker}
image=${1:?Usage: bash scripts/test-jenkins.sh IMAGE}
name="jenkins-smoke-$(date +%s)-$$"
container=
trap 'echo "FAIL: smoke-test assertion at line $LINENO" >&2' ERR

cleanup() {
    status=$?
    trap - EXIT
    if [[ -n "$container" ]]; then
        if [[ "$status" -ne 0 ]]; then
            echo "FAIL: Jenkins smoke test; inspect startup diagnostics below." >&2
            # The upstream startup log includes a generated unlock password.
            "$docker" logs "$container" 2>&1 | sed -E 's/[a-f0-9]{32}/[REDACTED]/g' >&2
        fi
        "$docker" rm -f -v "$container" > /dev/null
    fi
    exit "$status"
}
trap cleanup EXIT

[[ "$("$docker" image inspect --format '{{.Config.User}}' "$image")" == "1000:1000" ]]
[[ "$("$docker" image inspect --format '{{len .RootFS.Layers}}' "$image")" == "1" ]]
container=$("$docker" run -d --name "$name" \
    --read-only --cap-drop=ALL --security-opt=no-new-privileges:true \
    --memory=2g --cpus=2 --pids-limit=256 \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=512m,mode=1777 \
    --mount type=volume,destination=/var/jenkins_home \
    -p 127.0.0.1::8080 "$image")
wait_ready() {
    started=$("$docker" inspect --format '{{.State.StartedAt}}' "$container")
    for ((attempt=0; attempt<90; attempt++)); do
        state=$("$docker" inspect --format '{{.State.Status}}' "$container")
        if [[ "$state" != "running" ]]; then
            echo "FAIL: container is $state" >&2
            return 1
        fi
        if [[ "$("$docker" inspect --format '{{.State.Health.Status}}' "$container")" == "healthy" ]] \
            && "$docker" logs --since "$started" "$container" 2>&1 | grep -F "Jenkins is fully up and running" > /dev/null; then
            return 0
        fi
        sleep 2
    done
    echo "FAIL: Jenkins did not become healthy within 180 seconds" >&2
    return 1
}

assert_security() {
    address=$("$docker" port "$container" 8080/tcp)
    url="http://$address"
    [[ "$(curl -LsS -o /dev/null -w '%{http_code}' "$url/login")" == "200" ]]
    [[ "$(curl -sS -o /dev/null -w '%{http_code}' "$url/api/json")" == "403" ]]
    "$docker" exec "$container" sh -ec '
        test "$(id -u)" = 1000
        test -z "$(find /usr /bin /sbin -xdev -type f -perm /6000 -print)"
        test ! -w /usr/share/jenkins/jenkins.war
        test ! -w /usr/share/jenkins/ref/init.groovy.d/00-controller-hardening.groovy.override
        test ! -e /opt/jenkins-plugin-manager.jar
        test ! -e /usr/bin/jenkins-plugin-cli
        test ! -e /usr/local/bin/git-lfs
        test ! -e /usr/bin/git-lfs
        if command -v git-lfs > /dev/null; then
            echo "FAIL: Git LFS must run on agents, not the controller" >&2
            exit 1
        fi
        command -v ssh > /dev/null
        command -v git > /dev/null
        if command -v sshd > /dev/null; then
            echo "FAIL: the controller must not include an SSH server" >&2
            exit 1
        fi
        . /etc/os-release
        if [ "$ID" = alpine ]; then
            musl_version=$(apk info -v | sed -n "s/^musl-//p")
            ssh_version=$(apk info -v | sed -n "s/^openssh-client-default-//p")
            test -n "$musl_version"
            test -n "$ssh_version"
            test "$(apk version -t "$musl_version" 1.2.6-r3)" != "<"
            test "$(apk version -t "$ssh_version" 10.3_p1-r2)" != "<"
        fi
        test "$JENKINS_SLAVE_AGENT_PORT" = -1
        grep -q "<numExecutors>0</numExecutors>" "$JENKINS_HOME/config.xml"
        grep -q "<mode>EXCLUSIVE</mode>" "$JENKINS_HOME/config.xml"
        grep -q "<slaveAgentPort>-1</slaveAgentPort>" "$JENKINS_HOME/config.xml"
        grep -q "<useSecurity>true</useSecurity>" "$JENKINS_HOME/config.xml"
        grep -q "FullControlOnceLoggedInAuthorizationStrategy" "$JENKINS_HOME/config.xml"
        grep -q "<denyAnonymousReadAccess>true</denyAnonymousReadAccess>" "$JENKINS_HOME/config.xml"
        grep -q "DefaultCrumbIssuer" "$JENKINS_HOME/config.xml"
        test "$(stat -c %a "$JENKINS_HOME/secrets/initialAdminPassword")" = 640
        test "$(stat -c %a "$JENKINS_HOME/secrets")" = 700
        test "$(stat -c %a "$JENKINS_HOME/config.xml")" = 600
        test -s "$JENKINS_HOME/secrets/initialAdminPassword"
        grep -q "^CapEff:[[:space:]]*0000000000000000$" /proc/1/status
        grep -q "^NoNewPrivs:[[:space:]]*1$" /proc/1/status
        password=$(cat "$JENKINS_HOME/secrets/initialAdminPassword")
        api=http://127.0.0.1:8080
        test "$(curl -sS --max-time 5 --user "admin:$password" -o /dev/null -w "%{http_code}" "$api/api/json")" = 200
        curl -fsS --max-time 5 --user "admin:$password" --globoff "$api/computer/api/json?tree=computer[numExecutors]" | grep "\"numExecutors\":0" > /dev/null
        curl -fsS --max-time 5 --user "admin:$password" "$api/crumbIssuer/api/json" | grep "\"crumbRequestField\":" > /dev/null
        test "$(curl -sS --max-time 5 --user "admin:$password" -X POST -o /dev/null -w "%{http_code}" "$api/quietDown")" = 403
    '
    "$docker" logs --since "$started" "$container" 2>&1 | grep -F "Controller hardening applied:" > /dev/null
}

wait_ready
assert_security
# Simulate configuration drift and verify enforcement with the same home volume.
"$docker" stop "$container" > /dev/null
"$docker" run --rm --volumes-from "$container" --entrypoint sh "$image" -ec '
    sed -i "s/<numExecutors>0/<numExecutors>2/; s/<slaveAgentPort>-1/<slaveAgentPort>50000/" "$JENKINS_HOME/config.xml"
    printf "throw new RuntimeException(\"stale init script\")\n" > "$JENKINS_HOME/init.groovy.d/00-controller-hardening.groovy"
    printf "persistent\n" > "$JENKINS_HOME/smoke-test-marker"
'
"$docker" start "$container" > /dev/null
wait_ready
assert_security
"$docker" exec "$container" grep -q '^persistent$' /var/jenkins_home/smoke-test-marker
echo "PASS: Jenkins startup, authentication, anonymous denial, CSRF enforcement, hardening, read-only runtime, persistence and restart enforcement"
