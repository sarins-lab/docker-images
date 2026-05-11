#!/bin/sh
# =============================================================================
# cis-harden.sh — CIS Benchmark hardening for Alpine, Ubuntu, and Rocky Linux
# =============================================================================
#
# WHAT IT DOES
#   Alpine (ID=alpine in /etc/os-release):
#     Applies CIS Docker Benchmark v1.6 container controls.
#     Strips SUID/SGID bits and creates a dedicated non-root user.
#     Intended for use inside a Dockerfile (COPY + RUN).
#     apk removal is intentionally left to the calling Dockerfile so that
#     derived images can still run 'apk add' before their final layer.
#
#   Ubuntu 22.04 / 24.04 (ID=ubuntu):
#   Rocky Linux 8 / 9    (ID=rocky):
#     Applies CIS Benchmark Level 1 host controls.
#     Intended to run once during server provisioning via cloud-init,
#     Ansible, or a kickstart %post section. Requires root.
#     Covers: sysctl, SSH, module blacklisting, /tmp, password policy,
#             auditd, firewall, and unnecessary service removal.
#     Also accepts ID=rhel, ID=centos, ID=almalinux (treated as Rocky).
#
# USAGE
#   ./cis-harden.sh [--container] [--dry-run] [--skip-user] [--skip-ssh]
#                   [--skip-firewall] [--skip-audit] [--help]
#
#   --container  Apply container-only controls (CIS Docker Benchmark v1.6):
#                SUID/SGID strip + dedicated non-root user.  Skips all host-
#                specific controls (sysctl, SSH, auditd, firewall, services).
#                Required when running inside a Dockerfile on Ubuntu, Debian,
#                or Rocky Linux — those OSes default to full host hardening.
#                On Alpine, container controls are already the default; this
#                flag is optional and effectively a no-op.
#
# ENVIRONMENT VARIABLES (override defaults)
#   CIS_USER   Name of the dedicated non-root user to create (default: hermes)
#   CIS_UID    UID and GID to assign to that user             (default: 10001)
#
# NOTES
#   • On Alpine: run as root (Docker build layers run as root by default).
#   • On Ubuntu/Rocky: run as root (sudo ./cis-harden.sh).
#   • Safe to run multiple times — each step is idempotent.
#   • --container applies container-only controls and skips all host controls
#     (sysctl, SSH, auditd, firewall, and service hardening) on Ubuntu/Rocky.
#   • sysctl parameters are written to /etc/sysctl.d/60-cis.conf (number 60).
#     This deliberately leaves room for Kubernetes tooling to override at 99-*:
#       99-cilium.conf sets kernel.unprivileged_bpf_disabled=0 and ip_forward=1
#       k3s sysctl sets net.bridge.* and ip_forward=1
#     Run this script BEFORE k3s/Cilium so their drop-ins win on the parameters
#     they legitimately need to change.
# =============================================================================
set -eu

# ── Defaults ──────────────────────────────────────────────────────────────────
CIS_USER="${CIS_USER:-hermes}"
CIS_UID="${CIS_UID:-10001}"
DRY_RUN=0
CONTAINER_MODE=0
SKIP_USER=0
SKIP_SSH=0
SKIP_FIREWALL=0
SKIP_AUDIT=0

# ── Argument parsing ──────────────────────────────────────────────────────────
for arg in "$@"; do
    case "${arg}" in
        --container)     CONTAINER_MODE=1 ;;
        --dry-run)       DRY_RUN=1 ;;
        --skip-user)     SKIP_USER=1 ;;
        --skip-ssh)      SKIP_SSH=1 ;;
        --skip-firewall) SKIP_FIREWALL=1 ;;
        --skip-audit)    SKIP_AUDIT=1 ;;
        --help)
            sed -n '/^# WHAT/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \{0,2\}//'
            exit 0 ;;
        *)
            echo "ERROR: unknown option: ${arg}" >&2
            exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { printf '[cis-harden] %s\n' "$*"; }
warn() { printf '[cis-harden] WARN: %s\n' "$*" >&2; }

run() {
    if [ "${DRY_RUN}" = "1" ]; then
        printf '[DRY-RUN] %s\n' "$*"
    else
        "$@"
    fi
}

# ── OS detection ──────────────────────────────────────────────────────────────
detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        printf '%s' "${ID:-unknown}"
    else
        printf '%s' "unknown"
    fi
}

# Helper: set or replace a KEY VALUE pair in /etc/login.defs
set_logindefs() {
    local key="$1" val="$2"
    if [ "${DRY_RUN}" = "1" ]; then
        printf '[DRY-RUN] login.defs: %s = %s\n' "${key}" "${val}"
        return
    fi
    if grep -q "^${key}" /etc/login.defs 2>/dev/null; then
        sed -i "s|^${key}.*|${key}\t${val}|" /etc/login.defs
    else
        printf '%s\t%s\n' "${key}" "${val}" >> /etc/login.defs
    fi
}

# Create the dedicated non-root user on Linux systems (useradd/groupadd).
# Used by both container and host hardening on Ubuntu, Debian, and Rocky.
create_user_linux() {
    if [ "${SKIP_USER}" = "1" ]; then
        log "Skipping user creation (--skip-user)"
        return
    fi
    if getent passwd "${CIS_USER}" >/dev/null 2>&1; then
        log "User '${CIS_USER}' already exists — skipping"
        return
    fi
    log "Creating dedicated non-root user '${CIS_USER}' uid/gid=${CIS_UID} (CIS DI-4.1)..."
    getent group "${CIS_USER}" >/dev/null || run groupadd -g "${CIS_UID}" "${CIS_USER}"
    run useradd -u "${CIS_UID}" -g "${CIS_UID}" -M \
        -s /sbin/nologin -c "Platform service account" "${CIS_USER}"
}

# =============================================================================
# Alpine — CIS Docker Benchmark v1.6 (container hardening)
# =============================================================================
harden_alpine() {
    log "=== Alpine / container hardening (CIS Docker Benchmark v1.6) ==="

    # CIS DI-4.10: Strip SUID and SGID bits from the entire filesystem.
    # -xdev: stay on the root filesystem; skip /proc, /sys, /dev.
    # Privilege-escalation bits serve no purpose in a non-root init container.
    log "Stripping SUID/SGID bits from filesystem (CIS DI-4.10)..."
    run find / -xdev -perm /6000 -type f -exec chmod a-s {} +

    # CIS DI-4.1: Create a dedicated non-root user.
    # "nobody" (65534) is a shared system account used by NFS and daemons —
    # it must not be reused as an application identity.
    if [ "${SKIP_USER}" = "1" ]; then
        log "Skipping user creation (--skip-user)"
    else
        if id "${CIS_USER}" >/dev/null 2>&1; then
            log "User '${CIS_USER}' already exists — skipping creation"
        else
            log "Creating dedicated non-root user '${CIS_USER}' uid/gid=${CIS_UID} (CIS DI-4.1)..."
            run addgroup -g "${CIS_UID}" "${CIS_USER}"
            run adduser \
                -u "${CIS_UID}" \
                -G "${CIS_USER}" \
                -H \
                -D \
                -s /sbin/nologin \
                "${CIS_USER}"
        fi
    fi

    # ── apk deliberately NOT removed here ─────────────────────────────────────
    # Derived images that need packages must:
    #   1. Run 'apk add --no-cache <packages>'
    #   2. Remove apk state in the SAME RUN layer:
    #        rm -rf /var/cache/apk /lib/apk /usr/share/apk /etc/apk /sbin/apk
    # This satisfies CIS DI-4.3 (minimal packages) without preventing derived
    # images from installing their required tools.
    log "Alpine hardening complete."
    log "REMINDER (CIS DI-4.3): derived Dockerfiles must remove apk state after"
    log "  all 'apk add' calls: rm -rf /var/cache/apk /lib/apk /usr/share/apk /etc/apk /sbin/apk"
}

# =============================================================================
# Linux container hardening — Ubuntu, Debian, Rocky (CIS Docker Benchmark v1.6)
# =============================================================================
# Applied when --container is passed on a non-Alpine Linux base.
# Mirrors harden_alpine() but uses useradd/groupadd instead of busybox adduser.
# Host-only controls (sysctl, SSH, auditd, firewall, services) are skipped —
# they either don't apply or actively break inside containers.
harden_container_linux() {
    log "=== Linux container hardening (CIS Docker Benchmark v1.6) — OS: ${OS_ID} ==="

    # CIS DI-4.10: strip SUID/SGID bits from the entire container filesystem
    log "Stripping SUID/SGID bits (CIS DI-4.10)..."
    run find / -xdev -perm /6000 -type f -exec chmod a-s {} +

    # CIS DI-4.1: dedicated non-root user
    create_user_linux

    # ── Package manager cleanup note ──────────────────────────────────────────
    # Not done here — derived images need to install packages first.
    # Each derived Dockerfile must clean up in its final privileged layer:
    #   Ubuntu/Debian: apt-get clean && rm -rf /var/lib/apt/lists/*
    #   Rocky/RHEL:    microdnf clean all && rm -rf /var/cache/dnf /var/cache/yum
    log "Container hardening complete."
    log "REMINDER (CIS DI-4.3): derived Dockerfiles must clean package manager state"
    log "  after all installs: apt-get clean && rm -rf /var/lib/apt/lists/*"
    log "                   OR microdnf clean all && rm -rf /var/cache/dnf /var/cache/yum"
}

# =============================================================================
# Common host controls — applied on both Ubuntu and Rocky
# =============================================================================

# ── Kernel module blacklisting ────────────────────────────────────────────────
# CIS 3.4 / 3.5: disable unused, potentially exploitable protocols and
# filesystem types. None of these are needed on a platform server.
harden_modules() {
    log "Blacklisting unused kernel modules (CIS §3.4/3.5)..."
    local conf="/etc/modprobe.d/99-cis-blacklist.conf"
    if [ "${DRY_RUN}" = "1" ]; then
        printf '[DRY-RUN] write %s\n' "${conf}"
        return
    fi
    mkdir -p /etc/modprobe.d
    cat > "${conf}" << 'MODEOF'
# CIS Benchmark — kernel module blacklist
# Generated by cis-harden.sh — do not edit manually.

# Uncommon filesystem types (CIS 1.1.1.x)
install cramfs   /bin/true
install freevxfs /bin/true
install jffs2    /bin/true
install hfs      /bin/true
install hfsplus  /bin/true
install squashfs /bin/true
install udf      /bin/true

# Uncommon network protocols (CIS 3.4.x / 3.5.x)
install dccp  /bin/true
install sctp  /bin/true
install rds   /bin/true
install tipc  /bin/true

# USB storage — disable on servers without physical access control (CIS 1.1.10)
install usb-storage /bin/true
MODEOF
    log "  Written: ${conf}"
}

# ── sysctl — kernel and network hardening ─────────────────────────────────────
# CIS Section 3: Network configuration and kernel parameters.
harden_sysctl() {
    log "Writing sysctl hardening parameters (CIS §1.5 / §3)..."
    # File 60-cis.conf — below 99-cilium.conf and k3s drop-ins so that
    # Kubernetes tooling can override ip_forward=1 and bpf_disabled=0.
    local conf="/etc/sysctl.d/60-cis.conf"
    if [ "${DRY_RUN}" = "1" ]; then
        printf '[DRY-RUN] write %s\n' "${conf}"
        return
    fi
    mkdir -p /etc/sysctl.d
    cat > "${conf}" << 'SYSCTLEOF'
# =============================================================================
# CIS Benchmark — sysctl hardening
# Generated by cis-harden.sh — do not edit manually.
# For Kubernetes nodes, override net.ipv4.ip_forward=1 in a later drop-in.
# =============================================================================

# ── Kernel ────────────────────────────────────────────────────────────────────
# CIS 1.5.3: restrict core dumps (no SUID process dumps)
fs.suid_dumpable = 0

# CIS 1.6.2: enable address space layout randomisation (ASLR)
kernel.randomize_va_space = 2

# Restrict dmesg to root (information disclosure mitigation)
kernel.dmesg_restrict = 1

# Restrict /proc/kallsyms and similar kernel pointer exposure
kernel.kptr_restrict = 2

# Harden BPF — restrict JIT and unprivileged use
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2

# ── Network — routing ─────────────────────────────────────────────────────────
# CIS 3.1.1: disable IP forwarding (override to 1 on Kubernetes nodes)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# CIS 3.1.2: disable sending ICMP redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# ── Network — source routing ──────────────────────────────────────────────────
# CIS 3.2.1: reject source-routed packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# ── Network — ICMP redirects ──────────────────────────────────────────────────
# CIS 3.2.2: reject ICMP redirect messages
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# CIS 3.2.3: reject secure ICMP redirects
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

# ── Network — logging ─────────────────────────────────────────────────────────
# CIS 3.2.4: log suspicious (martian) source packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# ── Network — TCP ─────────────────────────────────────────────────────────────
# CIS 3.2.8: enable TCP SYN cookies (SYN-flood DoS mitigation)
net.ipv4.tcp_syncookies = 1

# ── Network — IPv6 ───────────────────────────────────────────────────────────
# CIS 3.3.1: do not accept IPv6 router advertisements
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
SYSCTLEOF
    sysctl -p "${conf}" >/dev/null 2>&1 || true
    log "  Written and applied: ${conf}"
}

# ── /tmp hardening ────────────────────────────────────────────────────────────
# CIS 1.1.2-1.1.4: /tmp must be on a separate partition (or tmpfs) with
# nodev, nosuid, and noexec mount options.
harden_tmp() {
    log "Hardening /tmp mount options (CIS 1.1.2-1.1.4)..."
    if [ "${DRY_RUN}" = "1" ]; then
        printf '[DRY-RUN] configure /tmp as nodev,nosuid,noexec tmpfs\n'
        return
    fi
    mkdir -p /etc/systemd/system/tmp.mount.d
    cat > /etc/systemd/system/tmp.mount.d/99-cis-options.conf << 'TMPEOF'
# CIS 1.1.2-1.1.4 — enforce nodev, nosuid, noexec on /tmp
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,noexec
TMPEOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable tmp.mount 2>/dev/null || true
    log "  Configured systemd tmp.mount override."
}

# ── Password policy ───────────────────────────────────────────────────────────
# CIS 5.4.1.x: password expiry, aging, and hash strength.
harden_password_policy() {
    log "Hardening password policy in /etc/login.defs (CIS 5.4.1)..."
    if [ ! -f /etc/login.defs ]; then
        warn "/etc/login.defs not found — skipping password policy"
        return
    fi
    set_logindefs PASS_MAX_DAYS          365      # CIS 5.4.1.1
    set_logindefs PASS_MIN_DAYS          1        # CIS 5.4.1.2
    set_logindefs PASS_WARN_AGE          7        # CIS 5.4.1.3
    set_logindefs UMASK                  "027"    # CIS 5.4.4
    set_logindefs SHA_CRYPT_MIN_ROUNDS   640000   # strengthen SHA-256/SHA-512 crypt rounds
    set_logindefs LOGIN_RETRIES          5        # CIS 5.4.1
    set_logindefs LOGIN_TIMEOUT          60
    log "  Password policy updated."
}

# ── SSH hardening ─────────────────────────────────────────────────────────────
# CIS Section 5.2: SSH server configuration.
harden_ssh() {
    if [ "${SKIP_SSH}" = "1" ]; then
        log "Skipping SSH hardening (--skip-ssh)"
        return
    fi
    if [ ! -d /etc/ssh ]; then
        warn "/etc/ssh not found — skipping SSH hardening"
        return
    fi
    log "Hardening SSH server configuration (CIS §5.2)..."
    if [ "${DRY_RUN}" = "1" ]; then
        printf '[DRY-RUN] write /etc/ssh/sshd_config.d/99-cis.conf\n'
        return
    fi
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-cis.conf << 'SSHEOF'
# =============================================================================
# CIS Benchmark SSH hardening — §5.2
# Drop-in; loaded via Include sshd_config.d/*.conf in the main sshd_config.
# Generated by cis-harden.sh — do not edit manually.
# =============================================================================

# CIS 5.2.4: disable X11 forwarding (attack surface reduction)
X11Forwarding no

# CIS 5.2.5: limit authentication attempts before disconnect
MaxAuthTries 4

# CIS 5.2.6: ignore .rhosts files
IgnoreRhosts yes

# CIS 5.2.7: disable host-based authentication
HostbasedAuthentication no

# CIS 5.2.8: deny root login over SSH
PermitRootLogin no

# CIS 5.2.9: reject empty-password accounts
PermitEmptyPasswords no

# CIS 5.2.10: prevent user-set environment variables
PermitUserEnvironment no

# CIS 5.2.12: restrict to strong symmetric ciphers
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr

# CIS 5.2.13: restrict to strong MAC algorithms
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256

# CIS 5.2.14: restrict to strong key-exchange algorithms
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512

# CIS 5.2.15: disconnect idle sessions after 5 minutes
ClientAliveInterval 300
ClientAliveCountMax 0

# CIS 5.2.16: limit authentication window to 60 seconds
LoginGraceTime 60

# CIS 5.2.20: display warning banner before authentication
Banner /etc/issue.net

# Enforce public-key authentication (remove 'password' to disable password auth)
AuthenticationMethods publickey

# Limit concurrent unauthenticated connection attempts
MaxStartups 10:30:60
SSHEOF

    # Warning banner (CIS 5.2.20)
    cat > /etc/issue.net << 'BANNEREOF'
*******************************************************************************
         AUTHORIZED ACCESS ONLY — UNAUTHORIZED USE IS PROHIBITED
          All activity may be monitored, recorded, and reported.
*******************************************************************************
BANNEREOF

    # Reload if running
    if systemctl is-active --quiet sshd 2>/dev/null; then
        systemctl reload sshd 2>/dev/null || true
    fi
    log "  Written: /etc/ssh/sshd_config.d/99-cis.conf"
}

# ── auditd rules ──────────────────────────────────────────────────────────────
# CIS Section 4.1: configure the kernel audit subsystem.
harden_audit() {
    if [ "${SKIP_AUDIT}" = "1" ]; then
        log "Skipping auditd rules (--skip-audit)"
        return
    fi
    if ! command -v auditctl >/dev/null 2>&1; then
        warn "auditd not installed — skipping audit rules (install auditd first)"
        return
    fi
    log "Writing auditd rules (CIS §4.1)..."
    local rules="/etc/audit/rules.d/99-cis.rules"
    if [ "${DRY_RUN}" = "1" ]; then
        printf '[DRY-RUN] write %s\n' "${rules}"
        return
    fi
    mkdir -p /etc/audit/rules.d
    cat > "${rules}" << 'AUDITEOF'
# =============================================================================
# CIS Benchmark auditd rules — §4.1
# Generated by cis-harden.sh — do not edit manually.
# -e 2 at the end makes rules immutable until reboot; place new rules BEFORE it.
# =============================================================================

# CIS 4.1.3: date/time modification events
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k time-change
-a always,exit -F arch=b32 -S adjtimex -S settimeofday -S stime -k time-change
-a always,exit -F arch=b64 -S clock_settime -k time-change
-a always,exit -F arch=b32 -S clock_settime -k time-change
-w /etc/localtime -p wa -k time-change

# CIS 4.1.4: user/group information modification
-w /etc/group   -p wa -k identity
-w /etc/passwd  -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/shadow  -p wa -k identity
-w /etc/security/opasswd -p wa -k identity

# CIS 4.1.5: network environment modification
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k system-locale
-a always,exit -F arch=b32 -S sethostname -S setdomainname -k system-locale
-w /etc/issue     -p wa -k system-locale
-w /etc/issue.net -p wa -k system-locale
-w /etc/hosts     -p wa -k system-locale

# CIS 4.1.6: MAC policy modification (AppArmor/SELinux)
-w /etc/apparmor/   -p wa -k MAC-policy
-w /etc/apparmor.d/ -p wa -k MAC-policy

# CIS 4.1.7: login and logout events
-w /var/log/lastlog  -p wa -k logins
-w /var/run/faillock -p wa -k logins

# CIS 4.1.8: session initiation
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k logins
-w /var/log/btmp -p wa -k logins

# CIS 4.1.9: DAC permission modification
-a always,exit -F arch=b64 -S chmod -S fchmod -S fchmodat -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b32 -S chmod -S fchmod -S fchmodat -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b64 -S chown -S fchown -S fchownat -S lchown -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b32 -S chown -S fchown -S fchownat -S lchown -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b64 -S setxattr -S lsetxattr -S fsetxattr -S removexattr -S lremovexattr -S fremovexattr -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b32 -S setxattr -S lsetxattr -S fsetxattr -S removexattr -S lremovexattr -S fremovexattr -F auid>=1000 -F auid!=4294967295 -k perm_mod

# CIS 4.1.10: unsuccessful file access attempts
-a always,exit -F arch=b64 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=4294967295 -k access
-a always,exit -F arch=b32 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=4294967295 -k access
-a always,exit -F arch=b64 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EPERM  -F auid>=1000 -F auid!=4294967295 -k access
-a always,exit -F arch=b32 -S creat -S open -S openat -S truncate -S ftruncate -F exit=-EPERM  -F auid>=1000 -F auid!=4294967295 -k access

# CIS 4.1.14: sudoers scope changes
-w /etc/sudoers   -p wa -k scope
-w /etc/sudoers.d -p wa -k scope

# CIS 4.1.15: administrator command execution
-w /var/log/sudo.log -p wa -k actions

# CIS 4.1.16: kernel module loading/unloading
-w /sbin/insmod  -p x -k modules
-w /sbin/rmmod   -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module -S delete_module -k modules

# CIS 4.1.17: make rules immutable until next reboot (MUST remain last)
-e 2
AUDITEOF
    if augenrules --load 2>/dev/null || auditctl -R "${rules}" 2>/dev/null; then
        log "  Written and loaded: ${rules}"
    else
        warn "audit rules written to ${rules}, but failed to load them now (augenrules/auditctl unavailable or failed)"
    fi
}

# ── Unnecessary services ──────────────────────────────────────────────────────
# CIS 2.1.x / 2.2.x: disable services not required on a platform server.
harden_services() {
    log "Disabling unnecessary services (CIS §2.1/2.2)..."
    for svc in \
        avahi-daemon cups isc-dhcp-server isc-dhcp-server6 \
        slapd nfs-server rpcbind bind9 vsftpd apache2 \
        dovecot smbd squid snmpd rsync talk chargen-dgram \
        chargen-stream daytime-dgram daytime-stream discard-dgram \
        discard-stream echo-dgram echo-stream time-dgram time-stream; do
        if systemctl is-enabled "${svc}" >/dev/null 2>&1; then
            log "  Disabling ${svc}..."
            run systemctl disable --now "${svc}" 2>/dev/null || true
        fi
    done
}

# =============================================================================
# Ubuntu-specific hardening
# =============================================================================
harden_ubuntu() {
    log "=== Ubuntu/Debian host hardening (CIS Ubuntu Linux Benchmark L1) ==="

    harden_modules
    harden_sysctl
    harden_tmp
    harden_password_policy

    # ── Dedicated service account ─────────────────────────────────────────────
    create_user_linux

    harden_ssh
    harden_services
    harden_audit

    # ── su restriction (CIS 1.4) ──────────────────────────────────────────────
    if [ -f /etc/pam.d/su ]; then
        log "Restricting su to sudo group (CIS 1.4)..."
        if [ "${DRY_RUN}" = "0" ]; then
            sed -i 's/^#\s*auth\s*required\s*pam_wheel.so/auth required pam_wheel.so group=sudo/' \
                /etc/pam.d/su 2>/dev/null || true
        fi
    fi

    # ── UFW firewall (CIS §3.5) ───────────────────────────────────────────────
    if [ "${SKIP_FIREWALL}" = "0" ] && command -v ufw >/dev/null 2>&1; then
        log "Configuring UFW: default-deny incoming, allow SSH (CIS §3.5)..."
        run ufw --force reset       2>/dev/null || true
        run ufw default deny incoming
        run ufw default allow outgoing
        run ufw allow ssh
        run ufw --force enable
    fi

    # ── SUID/SGID audit (CIS 6.1.1) ──────────────────────────────────────────
    # On hosts we AUDIT rather than blindly strip — some SUID binaries are
    # intentional (sudo, ping, newgrp). Review /var/log/cis-suid-audit.log.
    log "Auditing SUID/SGID files on host filesystem (CIS 6.1.1)..."
    find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null \
        | tee /var/log/cis-suid-audit.log || true
    log "  Results written to /var/log/cis-suid-audit.log — review and strip any unexpected entries."

    log "Ubuntu hardening complete."
}

# =============================================================================
# Rocky Linux-specific hardening (also handles RHEL, CentOS, AlmaLinux)
# =============================================================================
harden_rocky() {
    log "=== Rocky Linux host hardening (CIS Rocky Linux Benchmark L1) ==="

    harden_modules
    harden_sysctl
    harden_tmp
    harden_password_policy

    # ── Dedicated service account ─────────────────────────────────────────────
    create_user_linux

    harden_ssh
    harden_services
    harden_audit

    # ── SELinux enforcing (CIS 1.6) ───────────────────────────────────────────
    if command -v getenforce >/dev/null 2>&1; then
        log "Ensuring SELinux is in enforcing mode (CIS 1.6)..."
        if [ "$(getenforce)" != "Enforcing" ]; then
            run setenforce 1 2>/dev/null \
                || warn "Could not set SELinux to enforcing — check selinux-policy packages"
        fi
        if [ -f /etc/selinux/config ] && [ "${DRY_RUN}" = "0" ]; then
            sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
        fi
        log "  SELinux: $(getenforce 2>/dev/null || echo 'unknown')"
    fi

    # ── dnf gpgcheck (CIS 1.2.2) ─────────────────────────────────────────────
    if [ -f /etc/dnf/dnf.conf ]; then
        log "Ensuring gpgcheck=1 in dnf.conf (CIS 1.2.2)..."
        if [ "${DRY_RUN}" = "0" ]; then
            if grep -q '^gpgcheck=' /etc/dnf/dnf.conf; then
                sed -i 's/^gpgcheck=.*/gpgcheck=1/' /etc/dnf/dnf.conf
            else
                printf 'gpgcheck=1\n' >> /etc/dnf/dnf.conf
            fi
        fi
    fi

    # ── firewalld (CIS §3.5) ─────────────────────────────────────────────────
    if [ "${SKIP_FIREWALL}" = "0" ] && command -v firewall-cmd >/dev/null 2>&1; then
        log "Configuring firewalld: zone=drop, allow SSH (CIS §3.5)..."
        run systemctl enable --now firewalld 2>/dev/null || true
        run firewall-cmd --set-default-zone=drop  2>/dev/null || true
        run firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
        run firewall-cmd --reload 2>/dev/null || true
    fi

    # ── SUID/SGID audit (CIS 6.1.1) ──────────────────────────────────────────
    log "Auditing SUID/SGID files on host filesystem (CIS 6.1.1)..."
    find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null \
        | tee /var/log/cis-suid-audit.log || true
    log "  Results written to /var/log/cis-suid-audit.log — review and strip any unexpected entries."

    log "Rocky Linux hardening complete."
}

# =============================================================================
# Main
# =============================================================================
main() {
    OS_ID=$(detect_os)
    if [ "${CONTAINER_MODE}" = "1" ]; then
        log "Detected OS: ${OS_ID} — mode: container (CIS Docker Benchmark v1.6)"
    else
        log "Detected OS: ${OS_ID} — mode: host (CIS Benchmark L1)"
    fi

    case "${OS_ID}" in
        alpine)
            # Alpine always uses container mode; --container flag is a no-op here.
            harden_alpine
            ;;
        ubuntu | debian)
            if [ "${CONTAINER_MODE}" = "1" ]; then
                harden_container_linux
            else
                if [ "$(id -u)" != "0" ]; then
                    printf 'ERROR: Ubuntu/Debian host hardening requires root. Run: sudo %s\n' "$0" >&2
                    exit 1
                fi
                harden_ubuntu
            fi
            ;;
        rocky | rhel | centos | almalinux)
            if [ "${CONTAINER_MODE}" = "1" ]; then
                harden_container_linux
            else
                if [ "$(id -u)" != "0" ]; then
                    printf 'ERROR: Rocky/RHEL host hardening requires root. Run: sudo %s\n' "$0" >&2
                    exit 1
                fi
                harden_rocky
            fi
            ;;
        *)
            printf 'ERROR: Unsupported OS "%s". Supported: alpine, ubuntu, debian, rocky/rhel/centos/almalinux.\n' \
                "${OS_ID}" >&2
            exit 1
            ;;
    esac
}

main "$@"
