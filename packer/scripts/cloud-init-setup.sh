#!/usr/bin/env bash
# =============================================================================
# cloud-init-setup.sh — Configure cloud-init datasource for Proxmox
#
# Sets datasource_list to [NoCloud, ConfigDrive] so the VM finds its
# cloud-init config from Proxmox's built-in cloud-init drive on first boot.
# Detects Ubuntu vs Rocky from /etc/os-release and installs cloud-init
# via apt-get or dnf if not already present.
# =============================================================================
set -euo pipefail

log() { printf '[cloud-init-setup] %s\n' "$*"; }

if [ "$(id -u)" != "0" ]; then
    printf 'ERROR: must run as root\n' >&2
    exit 1
fi

# ── OS detection ──────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
. /etc/os-release

log "Detected OS: ${ID:-unknown} ${VERSION_ID:-}"

# ── Install cloud-init if missing ─────────────────────────────────────────────
if ! command -v cloud-init >/dev/null 2>&1; then
    log "Installing cloud-init..."
    case "${ID}" in
    ubuntu|debian)
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cloud-init
        apt-get clean
        rm -rf /var/lib/apt/lists/*
        ;;
    rocky|rhel|centos|almalinux)
        dnf install -y cloud-init
        dnf clean all
        rm -rf /var/cache/dnf
        ;;
    *)
        printf 'ERROR: unsupported OS %s\n' "${ID}" >&2
        exit 1
        ;;
    esac
fi

# ── Write Proxmox datasource configuration ────────────────────────────────────
log "Writing cloud-init datasource config for Proxmox..."
CLOUD_CFG_DIR="/etc/cloud/cloud.cfg.d"
mkdir -p "${CLOUD_CFG_DIR}"

cat > "${CLOUD_CFG_DIR}/99-proxmox-datasource.cfg" << 'EOF'
# Proxmox passes cloud-init config via a ConfigDrive or NoCloud ISO.
# List both so the VM finds its config regardless of the Proxmox version.
datasource_list: [NoCloud, ConfigDrive]
datasource:
  NoCloud:
    seedfrom: /
  ConfigDrive:
    max_wait: 30
EOF

# ── Enable cloud-init services ────────────────────────────────────────────────
log "Enabling cloud-init services..."
for svc in cloud-init-local cloud-init cloud-config cloud-final; do
    systemctl enable "${svc}" 2>/dev/null || true
done

log "cloud-init setup complete."
