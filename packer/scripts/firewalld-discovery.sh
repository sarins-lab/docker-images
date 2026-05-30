#!/usr/bin/env bash
# =============================================================================
# firewalld-discovery.sh — Restrictive firewalld rules for discovery images (Rocky)
#
# Sets the default zone to drop, then adds rich rules that allow ONLY:
#   - Outbound DNS (TCP+UDP port 53)
#   - Outbound HTTPS to the Genie endpoint host on the specified port
#
# Uses firewall-offline-cmd so it is safe to call when firewalld daemon
# is not running (Packer build context).
#
# Usage: firewalld-discovery.sh <genie_endpoint_url>
# =============================================================================
set -euo pipefail

log()  { printf '[firewalld-discovery] %s\n' "$*"; }
die()  { printf '[firewalld-discovery] ERROR: %s\n' "$*" >&2; exit 1; }

[ "${1:-}" = "" ] && die "Usage: $0 <genie_endpoint_url>"
GENIE_URL="$1"

# ── Extract host and port ─────────────────────────────────────────────────────
GENIE_HOST=$(printf '%s' "${GENIE_URL}" | sed 's|^https\?://||' | sed 's|/.*||' | sed 's|:.*||')
GENIE_PORT=$(printf '%s' "${GENIE_URL}" | sed 's|^https\?://[^:/]*:*||' | sed 's|/.*||')

if [ -z "${GENIE_PORT}" ]; then
    GENIE_PORT=443
fi

[ -z "${GENIE_HOST}" ] && die "Could not parse host from: ${GENIE_URL}"
log "Genie host: ${GENIE_HOST}, port: ${GENIE_PORT}"

# ── Install firewalld if missing ──────────────────────────────────────────────
if ! command -v firewall-offline-cmd >/dev/null 2>&1; then
    dnf install -y firewalld 2>/dev/null || die "firewalld not installed and could not be installed"
fi

FW="firewall-offline-cmd"

# ── Set default zone to drop ──────────────────────────────────────────────────
log "Setting default zone to drop..."
${FW} --set-default-zone=drop

# ── Allow outbound DNS ────────────────────────────────────────────────────────
log "Allowing outbound DNS (TCP+UDP 53)..."
${FW} --zone=drop --add-rich-rule="rule family='ipv4' port port='53' protocol='tcp' accept"
${FW} --zone=drop --add-rich-rule="rule family='ipv4' port port='53' protocol='udp' accept"

# ── Allow outbound HTTPS to Genie host ────────────────────────────────────────
log "Allowing outbound TCP ${GENIE_PORT} to ${GENIE_HOST}..."
${FW} --zone=drop --add-rich-rule="rule family='ipv4' destination address='${GENIE_HOST}' port port='${GENIE_PORT}' protocol='tcp' accept"

# ── Enable firewalld at boot ──────────────────────────────────────────────────
systemctl enable firewalld 2>/dev/null || true

log "firewalld discovery rules applied. Verify at first boot with: firewall-cmd --list-all"
