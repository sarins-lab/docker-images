# docker-images

[![Release](https://github.com/sarins-lab/docker-images/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/sarins-lab/docker-images/actions/workflows/release.yml)
[![Security](https://github.com/sarins-lab/docker-images/actions/workflows/security.yml/badge.svg?branch=main)](https://github.com/sarins-lab/docker-images/actions/workflows/security.yml)
[![CodeQL](https://github.com/sarins-lab/docker-images/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/sarins-lab/docker-images/actions/workflows/codeql.yml)

Hardened Docker Images

## Deployment

Container releases are published to GitHub Container Registry (GHCR) by the workflow at `.github/workflows/release.yml`.

## Jenkins controller

The [Jenkins image](jenkins.dockerfile) provides Debian and Alpine variants of
digest-pinned Jenkins 2.580.2 LTS with JDK 25. It runs as upstream UID/GID
`1000:1000`, applies available Debian or Alpine
updates, strips SUID/SGID bits, protects image-owned startup files, and creates
runtime files with a restrictive umask. No plugins or credentials are bundled.
The standalone plugin installer and Git LFS binary are removed; install plugins
through the protected UI or a separately maintained, pinned derivative build.
The final stage copies only the merged hardened filesystem into a fresh image.
Removed installers and their Jackson dependencies are therefore absent from
shipped layers, not merely hidden by deletion markers. Runtime Java, Git, SSH,
certificates and Jenkins startup scripts are retained.
Run Git LFS operations on agents. The upstream unlock password retains mode
`0640` inside the owner-only `0700` secrets directory.
These are container and application controls, not full OS CIS certification.

On every startup, the image disables controller executors and the inbound agent
TCP listener, and enables CSRF protection if absent. Use separate agents over
WebSocket or SSH. The upstream protected setup wizard remains enabled.
The startup agent-port default is also `-1`, avoiding a race between setup
wizard initialization and the hardening hook.
Authentication and authorization are not replaced on existing homes.
Do not disable the setup wizard without supplying secure authentication.

Build and test from the repository root with Docker, Bash, curl, Python and PyYAML:

```bash
make test-jenkins PYTHON=python3 VERSION=0.0.0-test
make test-jenkins PYTHON=python3 VERSION=0.0.0-test JENKINS_TRACK=jenkins-lts-jdk25
```

The default local track is `jenkins-lts-alpine-jdk25`. The second command tests
Debian. Both tracks use the same hardened Dockerfile. Routine release validation
smoke-tests and scans both variants.
Alpine uses musl rather than glibc; validate native plugins and tooling before
switching an existing deployment.

Local Jenkins builds default to `--pull --no-cache` so the Debian update step
checks current repositories instead of reusing a stale layer. This does not
advance the pinned Jenkins version or fix vulnerabilities without vendor patches.
For development-only cached builds, set `JENKINS_BUILD_FLAGS=`.

The test creates a fresh isolated home volume and deletes only its own container
and volume afterward. It verifies startup, admin authentication, anonymous access
denial, zero controller executors, CSRF rejection of unprotected POST requests,
file permissions, zero capabilities, read-only root filesystem,
home persistence, and reapplication of hardening after configuration drift.
Pull requests, main-branch development builds, and releases run this test and a
fixed HIGH/CRITICAL Trivy gate. Pull requests do not publish images. Security
workflow runs also smoke-test Jenkins.

For a local evaluation, create persistent storage and bind HTTP only to loopback:

```bash
docker volume create jenkins-home
docker run -d --name jenkins \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges:true \
  --memory=2g --cpus=2 --pids-limit=256 \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=512m,mode=1777 \
  --mount type=volume,source=jenkins-home,destination=/var/jenkins_home \
  -p 127.0.0.1:8080:8080 \
  sg-jenkins:2.589-alpine-jdk25-cis1.0.0
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

Open `http://127.0.0.1:8080` and complete the setup wizard. Treat the unlock
password and startup logs as secrets. Select and validate only required plugins.
Place the controller behind trusted HTTPS before remote access. Keep FreeIPA
LDAP TLS, group authorization, deployment configuration and security exceptions
in `security-infra`, not this public image. Never mount a Docker socket on the
controller or run builds there.

Back up the complete Jenkins home securely, including encryption keys, and test
restoration. Do not put runtime state or backups in Git. Bind-mounted homes must
be writable by UID/GID `1000:1000`. Read-only runtime requires writable Jenkins
home and `/tmp`. The healthcheck expects HTTP on internal port 8080 with no URL
prefix; replace it if deployment changes those settings.

The Jenkins track is an independent upstream application in `base-tracks`,
reusing the existing local build, GHCR publishing and scan matrices. Update its
upstream version and digest in [versions.yml](versions.yml) and the Dockerfile
default together. Rebuild and rescan for upstream security updates.
Deploy tested GHCR digests rather than mutable tags. OCI-to-Proxmox-LXC startup,
user mapping, LDAP, agent connections and backup restoration require separate
platform acceptance tests; a Docker smoke test does not establish LXC support.

Full-inventory testing also found CRITICAL `CVE-2026-60002` in the retained
Debian OpenSSH client (`1:10.0p1-7+deb13u4`), with no Debian fixed version available.
The SSH client is intentionally retained pending a supported upstream patch.
Do not expose or approve this image for production while that finding remains.

Testing found HIGH `CVE-2026-102554` in the Guava dependency bundled with
Jenkins 2.580.2. The fixed library version is 33.7.2; this Jenkins release
bundles 33.7.1-jre. No newer supported Jenkins LTS was available during testing.
Keep the Trivy gate enabled and retest a supported upstream fix.
Do not replace libraries inside the Jenkins WAR without upstream compatibility
validation.

The release gate checks fixed HIGH/CRITICAL findings only. It is not a complete
inventory or approval of unfixed vulnerabilities. Docker Scout and Trivy can
differ in vulnerability data, severity attribution and counting of duplicate
package findings. Compare the exact image digest, not totals alone.
The initial Alpine Trivy scan did not report OS-package CVEs, but Scout reported
additional musl, OpenSSH and Git LFS findings. Alpine's Git LFS package is removed
with `apk del`; removing only `/usr/local/bin/git-lfs` is insufficient because
Alpine installs it in `/usr/bin`. Git and the OS SSH client remain installed.
Alpine backported the two remaining Scout fixes without adopting the upstream
version numbers:

- `CVE-2026-107891`: musl `1.2.6-r3` includes the fix, as recorded in
  [Alpine's musl package recipe](https://github.com/alpinelinux/aports/blob/3.24-stable/main/musl/APKBUILD).
- `CVE-2026-123158`: OpenSSH `10.3_p1-r2` is fixed for Alpine 3.24, according to
  [Alpine's advisory](https://alpinelinux.org/posts/2026-11-05-openssh-password-authentication-bypass/).
  The issue affects `sshd`; this image contains only the SSH client.

The installed revisions meet those fixed versions. Smoke tests verify the
minimum patched revisions and absence of `sshd`. Scout can still report these
packages when matching upstream version thresholds rather than Alpine backports.
No blanket CVE suppression is applied.
Trivy also reports Guava HIGH and MEDIUM `CVE-2025-48924` in Commons Lang 2.6.
Scanner results can differ; retain both inventories when evaluating approval.
For a full local inventory with the existing Trivy tooling:

```bash
trivy image --scanners vuln --ignore-unfixed=false \
  --ignorefile /dev/null sg-jenkins:2.589-alpine-jdk25-cis1.0.0
```

## Local security checks

Run the inventory and scan-argument regression tests with:

```bash
make test-images PYTHON=.venv/bin/python
```

GitHub CodeQL advanced setup scans the repository in GitHub via
`.github/workflows/codeql.yml`. Keep that workflow enabled, or disable it before
replacing it with a different CodeQL setup.

To run the same analysis locally, install the CodeQL CLI and run:

```bash
make codeql-actions
```

The local run writes SARIF output to `.codeql/results/actions.sarif`.

To build every live image from `versions.yml` and generate a human-readable
local Trivy report, run:

```bash
make trivy-images
```

The report is written to `.trivy/results/all-cves.md`, with one Markdown and
raw JSON report per scanned image in the same directory. The local image list is
resolved from `versions.yml` with Python and PyYAML, matching the parser used by
the GitHub workflows. Builds default to `--pull --no-cache` to fetch current
base images and apply available package updates. Set `BUILD_FLAGS=` only for
development builds that can reuse cached layers.
By default, the report includes all severities and unfixed/vendor-deferred
findings, with no CVE suppressions (`TRIVY_IGNOREFILE=/dev/null`).
Scan findings are not automatically repaired or accepted. If PyYAML is missing
locally, install it with:

```bash
python -m pip install pyyaml
```

To generate an actionable-only report with accepted-risk entries applied:

```bash
make trivy-images TRIVY_IGNORE_UNFIXED=true TRIVY_IGNOREFILE=.trivyignore
```

For a CI-style local gate that fails only on fixed HIGH/CRITICAL findings:

```bash
make trivy-images TRIVY_SEVERITY=HIGH,CRITICAL TRIVY_IGNORE_UNFIXED=true TRIVY_IGNOREFILE=.trivyignore TRIVY_EXIT_CODE=1
```

### Historical local inventory (2026-11-08, before track updates)

The previous ten-track configuration built through `make trivy-images` on `linux/arm64`.
This scan included `alpine321` and `alpine322`, not the newly added `alpine324`.
Trivy 0.76.2 reported 857 package findings (235 unique CVEs), including two
CRITICAL and 147 HIGH findings, with no suppressions and unfixed findings included.
Both Alpine base tracks and both Rocky tracks reported zero findings.
Trivy warned that Alpine 3.21 is EOL, so its zero findings do not establish
continued security support. That track is now marked `eol` in `versions.yml`
and excluded from future builds and scans. Move consumers to a supported Alpine
track. Rebuild and rescan the current inventory before relying on these totals.
Debian and Ubuntu findings had no vendor fixed version in this inventory.

Both Jenkins LTS variants still bundle Guava 33.7.1-jre, affected by HIGH
`CVE-2026-102554` (fixed in 33.7.2). Jenkins remains on 2.580.2 LTS by explicit
channel choice; 2.589 is a weekly release, not an LTS patch.
The fixed HIGH/CRITICAL gate must continue to fail for both Jenkins variants
until a supported upstream LTS update supplies the fix. Do not suppress the CVE
or substitute untested libraries inside the WAR to claim a clean result.
The full local reports remain under `.trivy/results/`, outside Git.
These results do not establish vulnerability-free images or verify other architectures.

### Pre-release and release tags

Pull requests build and validate images without publishing them. When a PR is
merged into `main`, the workflow publishes each non-EOL image with a `-dev`
suffix, such as `sg-rockylinux:9.8-cis1.0.0-dev`, then scans the published
images. These `-dev` tags are mutable: each subsequent push to `main` updates
them for the current manifest version.

For a stable release, set the top-level `version` in [`versions.yml`](versions.yml)
to the release version, merge that change, then push the matching `v<version>`
Git tag. For example, with `version: "1.0.0"`:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The release workflow verifies that the pushed tag matches `versions.yml`, then
publishes stable tags without `-dev`, for example
`sg-rockylinux:9.8-cis1.0.0`. It scans the images and creates the GitHub Release
only after the release scan succeeds. You can also manually dispatch the
workflow to create a stable release from the manifest version.

## Track lifecycle

All image tracks are declared in [`versions.yml`](versions.yml). The CI workflow reads that file to generate its build matrix — **edit `versions.yml`, not the workflow, when adding, updating, or sunsetting tracks**.

| Status       | Meaning                                                                                        |
| ------------ | ---------------------------------------------------------------------------------------------- |
| `active`     | Newest release of this OS line; actively developed                                             |
| `maintained` | Older release still receiving security patches; still published                                |
| `deprecated` | EOL approaching; users should migrate; still published but flagged in release notes            |
| `eol`        | Past end-of-life; CI stops building; existing GHCR packages remain but receive no new versions |

### Sunsetting a track

1. Set `status: eol` in `versions.yml`.
2. Commit and push — the next release will automatically skip that track.
3. Optionally delete old package versions via the GitHub Packages UI.

`status: eol` excludes a track from `make build-all`, `make list-images`,
`make trivy-images`, and the CI build, scan and release matrices.
The `eol` date is informational; passing that date does not change status
automatically. `deprecated` tracks are still built and published.

Changing status does not delete Dockerfiles, existing local images, GHCR
versions or deployed containers. Registry and local cleanup are separate,
explicit actions. Preserve any required rollback artifacts before deleting them.

### Public image scope

Only generic reusable base and application images are published here.
The specialized bootstrap tool image has been retired. Deployment-specific
images and configuration belong in private repositories and Harbor.
`tool-tracks: []` preserves the registry schema without publishing tool images.
`make build-all` and `make trivy-images` cover every non-EOL track; local Docker
builds test the host architecture, while release builds use each track's
declared platforms.

## Published images

Image names are derived from each Dockerfile's `org.opencontainers.image.title`
label. Every non-EOL track uses
`ghcr.io/<owner>/<image-title>:<upstream-version>-cis<version>`.
The upstream component comes from `image-version` in `versions.yml`; the CIS
component comes from the top-level `version` in `versions.yml`.

Current non-EOL publishing tracks (see `versions.yml` for lifecycle status and EOL dates):

| Track | Image |
| ----- | ----- |
| `alpine322` | `ghcr.io/<owner>/sg-alpine:3.22.4-cis<version>` |
| `alpine324` | `ghcr.io/<owner>/sg-alpine:3.24.4-cis<version>` |
| `rocky9` | `ghcr.io/<owner>/sg-rockylinux:9.8-cis<version>` |
| `rocky10` | `ghcr.io/<owner>/sg-rockylinux:10.2-cis<version>` |
| `debian12` | `ghcr.io/<owner>/sg-debian:12-cis<version>` |
| `debian13` | `ghcr.io/<owner>/sg-debian:13-cis<version>` |
| `ubuntu24` | `ghcr.io/<owner>/sg-ubuntu:24.04-cis<version>` |
| `ubuntu26` | `ghcr.io/<owner>/sg-ubuntu:26.04-cis<version>` |
| `jenkins-lts-jdk25` | `ghcr.io/<owner>/sg-jenkins:2.589-jdk25-cis<version>` |
| `jenkins-lts-alpine-jdk25` | `ghcr.io/<owner>/sg-jenkins:2.589-alpine-jdk25-cis<version>` |

For example, with `version: "1.0.0"`, Rocky Linux stable and development tags
are `ghcr.io/sarins-lab/sg-rockylinux:9.8-cis1.0.0` and
`ghcr.io/sarins-lab/sg-rockylinux:9.8-cis1.0.0-dev`.
No unqualified `latest` tag is published.

The `sg-*` names replace the previous package names. Update consumer image
references to the new paths; existing packages are not renamed automatically.
Deploy stable tags or, for testing only, the mutable `-dev` tags. Pin production
deployments to the published digest.
