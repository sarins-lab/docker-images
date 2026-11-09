# Security Policy

## Supported Versions

All released images are scanned for CVE vulnerabilities using Trivy at build time. Image support is determined by track status in [`versions.yml`](versions.yml):

| Track             | Base OS      | Status     | Support Level                                     |
| ----------------- | ------------ | ---------- | ------------------------------------------------- |
| `alpine324`       | Alpine 3.24  | active     | :white_check_mark: Security patches published     |
| `alpine322`       | Alpine 3.22  | maintained | :white_check_mark: Security patches published     |
| `alpine321`       | Alpine 3.21  | eol        | :x: Not built; existing GHCR packages unsupported |
| `ubuntu26`        | Ubuntu 26.04 | active     | :white_check_mark: Security patches published     |
| `ubuntu24`        | Ubuntu 24.04 | maintained | :white_check_mark: Security patches published     |
| `debian13`        | Debian 13    | active     | :white_check_mark: Security patches published     |
| `debian12`        | Debian 12    | maintained | :white_check_mark: Security patches published     |
| `rocky10`         | Rocky 10.2   | active     | :white_check_mark: Security patches published     |
| `rocky9`          | Rocky 9      | active     | :white_check_mark: Security patches published     |
| `jenkins-lts-jdk25` | Debian / JDK 25 | active | :white_check_mark: Available upstream patches applied |
| `jenkins-lts-alpine-jdk25` | Alpine / JDK 25 | active | :white_check_mark: Available upstream patches applied |
| deprecated tracks | \*           | deprecated | :warning: Still published; migrate before EOL     |
| eol tracks        | \*           | eol        | :x: Not built; existing GHCR packages unsupported |

**Authoritative source**: See [`versions.yml`](versions.yml) for track status, EOL dates, and exact OS versions.

Only `status: eol` excludes a track from local builds and scan inventories.
Every non-EOL track is published by the standard release workflow with a tag
in the form `<upstream-version>-cis<version>`, using the top-level version in
`versions.yml`. Pushes to `main` publish mutable `-dev` tags for validation;
release tags publish the stable tag without the `-dev` suffix.
The `eol` date is informational; it does not automatically change status.
Existing local images and GHCR versions are not deleted.

## Vulnerability Scanning

All container images undergo automated CVE scanning:

- **Build-time scanning**: Trivy scans every live track in `.github/workflows/security.yml`; fixable HIGH/CRITICAL findings fail the gate.
- **Release scanning**: Published GHCR images are scanned for HIGH and CRITICAL vulnerabilities
- **CVE reporting**: Critical findings trigger GitHub Security Advisories and issues
- **Dependency controls**: Base images and distro packages come from official upstream sources and are scanned by Trivy. Jenkins upstream images are digest-pinned.
- **Distro patches**: Base OS updates via official upstream packages (Alpine, Rocky, Debian, Ubuntu)

Local `make trivy-images` rebuilds all live tracks with `--pull --no-cache`
and inventories all severities, including unfixed findings, without suppressions.
Reports are written under `.trivy/results/` and are not committed.
No available vendor fix is not the same as no vulnerability; keep unresolved
findings visible and evaluate them before deployment. Specialized deployment
tool images are no longer built or published by this repository.

## Reporting a Vulnerability

If you discover a security vulnerability in these container images:

1. **Do not open a public GitHub issue** — this notifies potential attackers
2. **Report privately** via GitHub Security Advisory: [Report a security vulnerability](https://github.com/sarins-lab/docker-images/security/advisories/new)
3. **Include**: Affected image/track, CVE ID (if known), reproduction steps, and impact assessment

**Response timeline**: Security reports will receive an initial response within 48 hours. Critical vulnerabilities will trigger an urgent patch release.

## Security Best Practices

When using these images:

- Always pin to a specific **tag** (`9.8-cis<version>`), never use `latest`
- Pull from **versioned releases** published to GHCR, not from development branches
- Scan your derived images regularly with Trivy: `trivy image ghcr.io/<owner>/<image>:<tag>`
- Review [`scripts/cis-harden.sh`](scripts/cis-harden.sh) to understand hardening applied (CIS Docker Benchmark v1.6)
- Subscribe to upstream OS security advisories for your chosen base OS
