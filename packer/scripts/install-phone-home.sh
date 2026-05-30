#!/usr/bin/env bash
# =============================================================================
# install-phone-home.sh — Install discover.sh and create sarins-discovery service
#
# Expects /tmp/discover.sh to be present (uploaded by a preceding Packer
# file provisioner from the controller repo). Does NOT run discover.sh during
# the build — only enables it so it executes on first boot.
# =============================================================================
set -euo pipefail

log() { printf '[install-phone-home] %s\n' "$*"; }

if [ "$(id -u)" != "0" ]; then
    printf 'ERROR: must run as root\n' >&2
    exit 1
fi

SCRIPT_SRC="/tmp/discover.sh"
SCRIPT_DST="/usr/local/sbin/discover.sh"
SERVICE="/etc/systemd/system/sarins-discovery.service"

if [ ! -f "${SCRIPT_SRC}" ]; then
    printf 'ERROR: %s not found — upload it via a file provisioner before this script\n' "${SCRIPT_SRC}" >&2
    exit 1
fi

# ── Install discover.sh ───────────────────────────────────────────────────────
log "Installing discover.sh to ${SCRIPT_DST}..."
install -o root -g root -m 0755 "${SCRIPT_SRC}" "${SCRIPT_DST}"
rm -f "${SCRIPT_SRC}"

# ── Write systemd unit ────────────────────────────────────────────────────────
log "Writing sarins-discovery.service..."
cat > "${SERVICE}" << 'EOF'
[Unit]
Description=Sarins Lab — hardware discovery phone-home
Documentation=https://github.com/sarins-lab/infra-controller
After=network-online.target
Wants=network-online.target
ConditionPathExists=/usr/local/sbin/discover.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/discover.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sarins-discovery

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "${SERVICE}"

# ── Enable (do NOT start — not running in build context) ─────────────────────
log "Enabling sarins-discovery.service..."
systemctl enable sarins-discovery.service 2>/dev/null || \
    ln -sf "${SERVICE}" /etc/systemd/system/multi-user.target.wants/sarins-discovery.service

log "Phone-home service installed and enabled."
