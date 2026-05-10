# docker-images

Hardened Docker Images

## Deployment

Container releases are published to GitHub Container Registry (GHCR) by the workflow at `.github/workflows/deploy-containers.yml`.

## Local security checks

CodeQL scans GitHub Actions workflows in CI via `.github/workflows/codeql.yml`.

To run the same analysis locally, install the CodeQL CLI and run:

```bash
make codeql-actions
```

The local run writes SARIF output to `.codeql/results/actions.sarif`.

### Automatic release

Push a version tag to trigger a full multi-arch publish and GitHub Release creation:

```bash
git tag v1.0.0
git push origin v1.0.0
```

### Manual release

Run the **Deploy Container Releases** workflow from GitHub Actions and provide the `version` input (example: `v1.0.0`).

## Track lifecycle

All image tracks are declared in [`versions.yml`](versions.yml). The CI workflow reads that file to generate its build matrix — **edit `versions.yml`, not the workflow, when adding, updating, or sunsetting tracks**.

| Status | Meaning |
|--------|---------|
| `active` | Newest release of this OS line; actively developed |
| `maintained` | Older release still receiving security patches; still published |
| `deprecated` | EOL approaching; users should migrate; still published but flagged in release notes |
| `eol` | Past end-of-life; CI stops building; existing GHCR packages remain but receive no new versions |

### Sunsetting a track

1. Set `status: eol` in `versions.yml`.
2. Commit and push — the next release will automatically skip that track.
3. Optionally delete old package versions via the GitHub Packages UI.

### Upgrading the init-tools base

`platform-init-tools` builds on top of `hardened-alpine-base`. The target Alpine track is declared in `versions.yml` under `tool-tracks[init-tools].base-suffix`. Update it there when advancing to a newer Alpine version.

## Published images

Image names are derived from each Dockerfile's `org.opencontainers.image.title` label.
Published format: `ghcr.io/<owner>/<image-title>:<version>-<track-suffix>`

Current tracks (see `versions.yml` for lifecycle status and EOL dates):

| Track | Image |
|-------|-------|
| `alpine321` | `ghcr.io/<owner>/hardened-alpine-base:<version>-alpine321` |
| `alpine322` | `ghcr.io/<owner>/hardened-alpine-base:<version>-alpine322` |
| `rocky9` | `ghcr.io/<owner>/hardened-rocky-base:<version>-rocky9` |
| `rocky10` | `ghcr.io/<owner>/hardened-rocky-base:<version>-rocky10` |
| `debian12` | `ghcr.io/<owner>/hardened-debian-base:<version>-debian12` |
| `debian13` | `ghcr.io/<owner>/hardened-debian-base:<version>-debian13` |
| `ubuntu24` | `ghcr.io/<owner>/hardened-ubuntu-base:<version>-ubuntu24` |
| `ubuntu26` | `ghcr.io/<owner>/hardened-ubuntu-base:<version>-ubuntu26` |
| `init-tools` | `ghcr.io/<owner>/platform-init-tools:<version>` |

Both `v<version>` and `<version>` tag forms are published for each track.
