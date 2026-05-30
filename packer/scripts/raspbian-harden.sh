#!/usr/bin/env bash
# =============================================================================
# raspbian-harden.sh — CIS-equivalent hardening for Raspbian Bookworm (arm64)
#
# No SCAP/CIS profile exists for Raspbian — controls applied manually.
# Runs in arm-image chroot context; systemd not running during build.
# =============================================================================
set -euo pipefail

log()  { printf '[raspbian-harden] %s\n' "$*"; }

if [ "$(id -u)" != "0" ]; then
    printf 'ERROR: must run as root\n' >&2
    exit 1
fi

# ── Remove default pi user ────────────────────────────────────────────────────
log "Removing default pi user..."
userdel -r pi 2>/dev/null || true

# ── SSH hardening ─────────────────────────────────────────────────────────────
log "Hardening SSH server..."
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-harden.conf << 'EOF'
X11Forwarding no
MaxAuthTries 4
IgnoreRhosts yes
HostbasedAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
PermitUserEnvironment no
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
ClientAliveInterval 300
ClientAliveCountMax 0
LoginGraceTime 60
AuthenticationMethods publickey
EOF

cat > /etc/issue.net << 'EOF'
*******************************************************************************
         AUTHORIZED ACCESS ONLY — UNAUTHORIZED USE IS PROHIBITED
*******************************************************************************
EOF

systemctl enable ssh 2>/dev/null || true

# ── sysctl hardening ──────────────────────────────────────────────────────────
log "Writing sysctl drop-in..."
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/60-harden.conf << 'EOF'
fs.suid_dumpable = 0
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
net.ipv4.ip_forward = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 1
EOF

# ── UFW default-deny ──────────────────────────────────────────────────────────
log "Configuring UFW..."
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ufw 2>/dev/null || true
if command -v ufw >/dev/null 2>&1; then
    ufw --force reset 2>/dev/null || true
    ufw default deny incoming
    ufw default deny outgoing
    ufw allow ssh
    systemctl enable ufw 2>/dev/null || true
fi

# ── AppArmor ──────────────────────────────────────────────────────────────────
log "Enabling AppArmor..."
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends apparmor 2>/dev/null || true
systemctl enable apparmor 2>/dev/null || true

# ── Disable unnecessary services ─────────────────────────────────────────────
log "Disabling unnecessary services..."
for svc in avahi-daemon triggerhappy bluetooth; do
    systemctl disable "$svc" 2>/dev/null || true
done

# ── Lock passwordless accounts ────────────────────────────────────────────────
log "Locking passwordless accounts..."
awk -F: '($2 == "" || $2 == "!") { print $1 }' /etc/shadow | while read -r user; do
    case "$user" in root|sync|halt|shutdown) continue ;; esac
    passwd -l "$user" 2>/dev/null || true
done

# ── apt cleanup ───────────────────────────────────────────────────────────────
apt-get clean
rm -rf /var/lib/apt/lists/*

log "Raspbian Bookworm hardening complete."
