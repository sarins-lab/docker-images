#!/usr/bin/env bash
# =============================================================================
# ufw-discovery.sh — Restrictive UFW rules for discovery images (Ubuntu/Raspbian)
#
# Allows ONLY:
#   - Outbound DNS (TCP+UDP port 53) for hostname resolution
#   - Outbound HTTPS to the Genie endpoint host on the specified port
#
# Usage: ufw-discovery.sh <genie_endpoint_url>
# Example: ufw-discovery.sh https://genie.lab.sarins.info/discover
# =============================================================================
set -euo pipefail

log()  { printf '[ufw-discovery] %s\n' "$*"; }
die()  { printf '[ufw-discovery] ERROR: %s\n' "$*" >&2; exit 1; }

[ "${1:-}" = "" ] && die "Usage: $0 <genie_endpoint_url>"
GENIE_URL="$1"

# ── Extract host and port from URL ────────────────────────────────────────────
# Strip scheme, then split host:port
GENIE_HOST=$(printf '%s' "${GENIE_URL}" | sed 's|^https\?://||' | sed 's|/.*||' | sed 's|:.*||')
GENIE_PORT=$(printf '%s' "${GENIE_URL}" | sed 's|^https\?://[^:/]*:*||' | sed 's|/.*||')

if [ -z "${GENIE_PORT}" ]; then
    GENIE_PORT=443
fi

[ -z "${GENIE_HOST}" ] && die "Could not parse host from: ${GENIE_URL}"
log "Genie host: ${GENIE_HOST}, port: ${GENIE_PORT}"

# ── Apply UFW rules ───────────────────────────────────────────────────────────
if ! command -v ufw >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ufw 2>/dev/null \
        || die "ufw not installed and could not be installed"
fi

log "Resetting UFW to defaults..."
ufw --force reset 2>/dev/null || true

log "Setting default deny-all policies..."
ufw default deny incoming
ufw default deny outgoing

log "Allowing outbound DNS (TCP+UDP 53)..."
ufw allow out 53/tcp
ufw allow out 53/udp

log "Allowing outbound TCP ${GENIE_PORT} to ${GENIE_HOST}..."
ufw allow out to "${GENIE_HOST}" port "${GENIE_PORT}" proto tcp

log "Enabling UFW..."
ufw --force enable

log "UFW discovery rules applied."
ufw status verbose
