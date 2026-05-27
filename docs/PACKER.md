# Packer OS Images

This directory contains Packer templates for building hardened OS images used across Sarins LAB. These are full OS disk images, not containers — they complement the Docker
base images in the repo root.

All images bake in the **Offline Root CA certificate** from `security-infra`. Every machine booted from a golden image trusts the full lab PKI chain from first boot, before any service is deployed.

---

## Two Image Categories

### 1. Cloud-Init VM Templates

Generic, lab-agnostic Proxmox VM templates. OpenTofu clones these when provisioning any role VM during the devops bootstrap pipeline.

**Contains:** CIS OS hardening + cloud-init agent + Root CA cert  
**Does not contain:** Lab-specific endpoints, mTLS certs, phone-home scripts  
**Published:** GHCR as OCI artifact (safe — no lab config) → mirrored to internal Nexus  
**Consumed by:** OpenTofu `proxmox_vm_qemu` resource (`clone` argument)

| Template                    | OS               | Use case                          |
| --------------------------- | ---------------- | --------------------------------- |
| `ubuntu-cloud-init.pkr.hcl` | Ubuntu 24.04 LTS | All Wave 0–N roles except FreeIPA |
| `rocky-cloud-init.pkr.hcl`  | Rocky Linux 9    | FreeIPA primary and replicas      |

### 2. Discovery Golden Images

Lab-specific images for bare-metal and SBC hardware. These boot, collect hardware facts, and phone home to the Genie Discovery Endpoint via mTLS. Operator never needs to touch the machine after flashing.

**Contains:** CIS OS hardening + Root CA cert + discovery-enrollment mTLS cert + phone-home systemd service  
**Does not contain:** NetBox API tokens, OpenBao tokens, any production secrets  
**Published:** Internal Nexus only (never GHCR — contains lab-specific cert)  
**Consumed by:** Bare-metal x86 (Proxmox template import) and Pi/SBC nodes (SD card flash)

| Template                            | OS               | Platform                         | Format                       |
| ----------------------------------- | ---------------- | -------------------------------- | ---------------------------- |
| `discovery.pkr.hcl` (amd64)         | Ubuntu 24.04     | x86 bare-metal, x86 VM           | `.qcow2` → Proxmox template  |
| `discovery.pkr.hcl` (arm64)         | Ubuntu 24.04     | Pi 4 — DNS/DHCP replicas         | `.img` → SD card flash       |
| `discovery.pkr.hcl` (amd64)         | Rocky Linux 9    | x86 bare-metal requiring RHEL    | `.qcow2` → Proxmox template  |
| `discovery.pkr.hcl` (arm64)         | Rocky Linux 9    | Pi 4 — FreeIPA replicas          | `.img` → SD card flash       |
| `raspbian-discovery.pkr.hcl` (arm64)| Raspbian Bookworm| Pi 4 — Pi-specific workloads     | `.img` → SD card flash       |

`discovery.pkr.hcl` uses an OS variable to select Ubuntu or Rocky at build time — no separate
template file is needed per OS. `raspbian-discovery.pkr.hcl` is a separate template because
Raspbian uses the `arm-image` plugin (customise a pre-built image) rather than an ISO install.

---

## OS Assignment Rationale

The lab uses two OS families. The split is by workload type, not preference.

| OS               | Assigned to                                                       | Reason                                                                  |
| ---------------- | ----------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Rocky Linux 9    | FreeIPA VMs (amd64) and FreeIPA Pi replicas (arm64)               | `ansible-freeipa` is RHEL-native; Dogtag CA subordination tested on RHEL |
| Rocky Linux 9    | Any service explicitly requiring RHEL certification or SCAP/STIG  | CIS RHEL 9 + DISA STIG profiles apply directly; OpenSCAP + SSG ready   |
| Ubuntu 24.04 LTS | All other roles: DNS, DHCP, NetBox, Forgejo, Jenkins, OpenBao, K3s nodes | AppArmor simplifies container workloads; cloud-native tooling is Ubuntu-first |
| Ubuntu 24.04 LTS | Pi 4 nodes running DNS/DHCP replicas (arm64)                      | Consistent with x86 fleet for those roles; no RHEL dependency          |
| Raspbian         | Pi 4 nodes running Pi-specific workloads (GPIO, VideoCore, etc.)  | Required only when Pi hardware features are needed                      |

Going all-Rocky is not recommended for this lab: K3s + Cilium on SELinux requires
per-workload policy tuning that adds cost without compliance benefit for containerised
services where the application matters more than the host OS.

---

## Directory Structure

```
packer/
├── PACKER.md                         this file
├── variables.pkr.hcl                 shared variable definitions for all templates
├── ubuntu-cloud-init.pkr.hcl         cloud-init VM template — Ubuntu 24.04 (amd64 + arm64)
├── rocky-cloud-init.pkr.hcl          cloud-init VM template — Rocky Linux 9 (amd64 + arm64)
├── discovery.pkr.hcl                 discovery golden image — Ubuntu + Rocky (multi-arch)
│                                     OS selected via variable: ubuntu24 | rocky9
├── raspbian-discovery.pkr.hcl        discovery golden image — Raspbian Bookworm (arm64 only)
│                                     uses arm-image plugin; customises pre-built image
└── scripts/
    ├── cis-harden-host.sh            CIS host-mode hardening — Ubuntu 24.04
    │                                 complements scripts/cis-harden.sh --container
    ├── rocky-cis-harden-host.sh      CIS host-mode hardening — Rocky Linux 9
    │                                 uses oscap + scap-security-guide RHEL9 profile
    ├── raspbian-harden.sh            CIS-equivalent hardening subset — Raspbian Bookworm
    │                                 manual controls; no SCAP profile for Raspbian
    ├── cloud-init-setup.sh           cloud-init datasource config (Ubuntu + Rocky)
    ├── install-phone-home.sh         installs discover.sh + systemd service unit
    ├── ufw-discovery.sh              restrictive UFW rules → Genie endpoint only (Ubuntu)
    └── firewalld-discovery.sh        restrictive firewalld rules → Genie endpoint only (Rocky)
└── http/
    ├── ubuntu/
    │   └── user-data                 subiquity autoinstall seed (Ubuntu ISO install)
    └── rocky/
        └── ks.cfg                    kickstart config (Rocky ISO install)
```

`ufw-discovery.sh` and `firewalld-discovery.sh` are separate because Ubuntu uses `ufw` and
Rocky uses `firewalld`. Both enforce the same rule: allow only outbound to the Genie discovery
endpoint; block everything else.

The `scripts/install-phone-home.sh` script is a build-time installer. It receives `discover.sh`
from the controller repo as a Packer file provisioner input — the phone-home logic is owned
by the controller repo, not here.

---

## `versions.yml` — Packer Tracks Section

```yaml
packer-tracks:
  # ── Generic cloud-init VM templates ─────────────────────────────────────────
  # No lab-specific config. Safe to publish to GHCR.
  # Consumed by OpenTofu as Proxmox clone source.

  - suffix: ubuntu24
    template: packer/ubuntu-cloud-init.pkr.hcl
    os-version: "24.04"
    platforms: [amd64, arm64]
    eol: "2029-05-31"
    status: active
    publish: ghcr

  - suffix: rocky9
    template: packer/rocky-cloud-init.pkr.hcl
    os-version: "9"
    platforms: [amd64, arm64]
    eol: "2032-05-31"
    status: active
    publish: ghcr

  # ── Discovery golden images ─────────────────────────────────────────────────
  # Lab-specific. Never published externally. Internal Nexus only.
  # Built by internal Jenkins pipeline, not GitHub Actions.

  - suffix: ubuntu24-discovery-amd64
    template: packer/discovery.pkr.hcl
    os-version: "24.04"
    platforms: [amd64]
    eol: "2029-05-31"
    status: active
    publish: nexus
    outputs: [qcow2]

  - suffix: ubuntu24-discovery-arm64
    template: packer/discovery.pkr.hcl
    os-version: "24.04"
    platforms: [arm64]
    eol: "2029-05-31"
    status: active
    publish: nexus
    outputs: [img] # raw image for SD card flashing
```

---

## Build Inputs from `security-infra`

The following artifacts must be available at Packer build time. They come from the `security-infra` repo and are injected as Packer variables — never hardcoded in templates.

| Packer variable             | Source                                                            | Used in                                                   |
| --------------------------- | ----------------------------------------------------------------- | --------------------------------------------------------- |
| `root_ca_cert`              | `security-infra/pki/root-ca.crt`                                  | All templates (cloud-init + all discovery variants)       |
| `discovery_enrollment_cert` | `security-infra/pki/discovery-enrollment.crt`                     | `discovery.pkr.hcl` + `raspbian-discovery.pkr.hcl`       |
| `discovery_enrollment_key`  | `security-infra/pki/discovery-enrollment.key`                     | `discovery.pkr.hcl` + `raspbian-discovery.pkr.hcl`       |
| `genie_endpoint`            | Pipeline variable (e.g. `https://genie.lab.sarins.info/discover`) | `discovery.pkr.hcl` + `raspbian-discovery.pkr.hcl`       |
| `discover_sh`               | Controller repo `scripts/discover.sh`                             | `discovery.pkr.hcl` + `raspbian-discovery.pkr.hcl`       |
| `os_variant`                | Build matrix variable: `ubuntu24` or `rocky9`                     | `discovery.pkr.hcl` (selects OS branch inside template)  |

The same `discovery-enrollment.crt` / `.key` pair is shared across Ubuntu, Rocky, and
Raspbian discovery images. The cert identifies the lab discovery service, not the machine
OS — the Genie endpoint accepts any valid mTLS cert from this CA regardless of what OS
issued the request. Rotation rebuilds all discovery variants simultaneously.

The discovery image build pipeline must be able to reach the `security-infra` and `controller`
repos to assemble these inputs before the Packer build runs.

---

## CIS Hardening — Host Mode

Container images use `scripts/cis-harden.sh --container`, which skips host-level controls that cannot apply inside a container build.

Packer OS image builds use `packer/scripts/cis-harden-host.sh`, which applies the full host-level CIS benchmark subset:

| Control                           | Container mode | Ubuntu host | Rocky host                    | Raspbian host              |
| --------------------------------- | -------------- | ----------- | ----------------------------- | -------------------------- |
| Non-root service account          | ✅ (hermes)    | ✅          | ✅                            | ✅                         |
| SUID/SGID strip                   | ✅             | ✅          | ✅                            | ✅                         |
| SSH hardening (no root, key-only) | ❌             | ✅          | ✅                            | ✅                         |
| Firewall default-deny             | ❌             | ✅ (ufw)    | ✅ (firewalld)                | ✅ (ufw)                   |
| sysctl hardening                  | ❌             | ✅          | ✅                            | ✅                         |
| auditd rules                      | ❌             | ✅          | ✅                            | ✅                         |
| Disable unnecessary services      | ❌             | ✅          | ✅                            | ✅                         |
| No default passwords              | ❌             | ✅          | ✅                            | ✅ (removes `pi` user)     |
| Filesystem mount hardening        | ❌             | ✅          | ✅                            | ✅                         |
| MAC enforcement                   | ❌             | AppArmor    | SELinux (targeted policy)     | AppArmor                   |
| SCAP / CIS profile                | ❌             | CIS Ubuntu  | CIS RHEL9 via scap-sg         | Manual subset (no profile) |

---

## Build Pipeline and Artifact Storage

### Cloud-init templates (GHCR path)

```
GitHub Actions
  └── packer build ubuntu-cloud-init.pkr.hcl
        │  injects: root_ca_cert (from security-infra)
        ▼
  qcow2 artifact
        │
        └── ORAS push → GHCR as OCI artifact
              tag: ghcr.io/sarins-lab/packer-ubuntu-cloud-init:<version>-ubuntu24
              │
              └── [air-gap] Bootstrap Pipeline 1 mirrors to internal Nexus
                    ORAS pull from GHCR → ORAS push to Nexus
                    │
                    └── OpenTofu reads from Nexus → imports to Proxmox template
```

### Discovery images (internal Nexus only)

```
Internal Jenkins pipeline (permanent environment)
  └── packer build discovery.pkr.hcl
        │  injects: root_ca_cert, discovery_enrollment_cert/key,
        │           genie_endpoint, discover_sh
        ▼
  qcow2 (amd64) + img (arm64)
        │
        └── ORAS push → internal Nexus
              tag: nexus.mgt.sarins.info/packer/discovery-ubuntu24-amd64:<version>
              │
              ├── amd64: qm importdisk → Proxmox template
              └── arm64: dd to SD card for Pi/SBC nodes
```

### ORAS push convention

```bash
# Push qcow2 as OCI artifact
oras push ${REGISTRY}/packer/${SUFFIX}:${VERSION} \
  --artifact-type application/vnd.sarins-lab.packer-image.v1 \
  disk.qcow2:application/vnd.sarins-lab.qcow2

# Pull
oras pull ${REGISTRY}/packer/${SUFFIX}:${VERSION} \
  --output ./output/
```

---

## Makefile Targets (Planned)

```
make packer-cloud-init   Build all cloud-init VM templates locally
make packer-discovery    Build discovery golden image (requires security-infra inputs)
make packer-list         List all Packer tracks from versions.yml
```

These targets are not yet implemented. They will follow the same pattern as the existing `build-all`, `build-base`, and `trivy-images` targets.
