# Security Policy

## Supported Versions

All released images are scanned for CVE vulnerabilities using Trivy at build time. Image support is determined by track status in [`versions.yml`](versions.yml):

| Track             | Base OS      | Status     | Support Level                                     |
| ----------------- | ------------ | ---------- | ------------------------------------------------- |
| `alpine322`       | Alpine 3.22  | active     | :white_check_mark: Security patches published     |
| `alpine321`       | Alpine 3.21  | maintained | :white_check_mark: Security patches published     |
| `ubuntu26`        | Ubuntu 26.04 | active     | :white_check_mark: Security patches published     |
| `ubuntu24`        | Ubuntu 24.04 | active     | :white_check_mark: Security patches published     |
| `debian13`        | Debian 13    | active     | :white_check_mark: Security patches published     |
| `debian12`        | Debian 12    | maintained | :white_check_mark: Security patches published     |
| `rocky10`         | Rocky 10     | active     | :white_check_mark: Security patches published     |
| `rocky9`          | Rocky 9      | maintained | :white_check_mark: Security patches published     |
| `init-tools`      | Alpine 3.22  | active     | :white_check_mark: Security patches published     |
| deprecated tracks | \*           | deprecated | :warning: No longer published; EOL approaching    |
| eol tracks        | \*           | eol        | :x: Not built; existing GHCR packages unsupported |

**Authoritative source**: See [`versions.yml`](versions.yml) for track status, EOL dates, and exact OS versions.

## Vulnerability Scanning

All container images undergo automated CVE scanning:

- **Build-time scanning**: Trivy scans all images during CI/CD (`.github/workflows/deploy-containers.yml`)
- **Release scanning**: Published GHCR images are scanned for HIGH and CRITICAL vulnerabilities
- **CVE reporting**: Critical findings trigger GitHub Security Advisories and issues
- **Dependency controls**: Downloaded tool binaries are SHA-verified; base images and distro packages come from official upstream sources and are scanned by Trivy
- **Distro patches**: Base OS updates via official upstream packages (Alpine, Rocky, Debian, Ubuntu)

## Reporting a Vulnerability

If you discover a security vulnerability in these container images:

1. **Do not open a public GitHub issue** — this notifies potential attackers
2. **Report privately** via GitHub Security Advisory: [Report a security vulnerability](https://github.com/sarins-lab/docker-images/security/advisories/new)
3. **Include**: Affected image/track, CVE ID (if known), reproduction steps, and impact assessment

**Response timeline**: Security reports will receive an initial response within 48 hours. Critical vulnerabilities will trigger an urgent patch release.

## Security Best Practices

When using these images:

- Always pin to a specific **tag** (`v1.0.0-alpine322`), never use `latest`
- Pull from **versioned releases** published to GHCR, not from development branches
- Scan your derived images regularly with Trivy: `trivy image ghcr.io/<owner>/<image>:<tag>`
- Review [`scripts/cis-harden.sh`](scripts/cis-harden.sh) to understand hardening applied (CIS Docker Benchmark v1.6)
- Subscribe to upstream OS security advisories for your chosen base OS
