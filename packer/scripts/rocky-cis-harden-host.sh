#!/usr/bin/env bash
# =============================================================================
# rocky-cis-harden-host.sh — CIS Benchmark L1 host hardening for Rocky Linux 9
#
# Packer provisioner context: systemd NOT running at build time.
# Controls that need live systemd are written as configs and enabled
# (not started) with systemctl enable.
# =============================================================================
set -euo pipefail

log()  { printf '[rocky-cis-harden-host] %s\n' "$*"; }
warn() { printf '[rocky-cis-harden-host] WARN: %s\n' "$*" >&2; }

if [ "$(id -u)" != "0" ]; then
    printf 'ERROR: must run as root\n' >&2
    exit 1
fi

# ── Kernel module blacklisting (CIS §3.4/3.5) ─────────────────────────────────
log "Blacklisting unused kernel modules..."
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/99-cis-blacklist.conf << 'EOF'
install cramfs   /bin/true
install freevxfs /bin/true
install jffs2    /bin/true
install hfs      /bin/true
install hfsplus  /bin/true
install squashfs /bin/true
install udf      /bin/true
install dccp     /bin/true
install sctp     /bin/true
install rds      /bin/true
install tipc     /bin/true
install usb-storage /bin/true
EOF

# ── sysctl hardening (CIS §1.5 / §3) ─────────────────────────────────────────
log "Writing sysctl drop-in..."
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/60-cis.conf << 'EOF'
fs.suid_dumpable = 0
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
EOF

# ── /tmp hardening (CIS 1.1.2-1.1.4) ─────────────────────────────────────────
log "Configuring /tmp as nodev,nosuid,noexec tmpfs..."
mkdir -p /etc/systemd/system/tmp.mount.d
cat > /etc/systemd/system/tmp.mount.d/99-cis-options.conf << 'EOF'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,noexec
EOF
systemctl enable tmp.mount 2>/dev/null || true

# ── Password policy (CIS 5.4.1) ───────────────────────────────────────────────
log "Hardening password policy..."
if [ -f /etc/login.defs ]; then
    sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS\t365/' /etc/login.defs
    sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS\t1/'   /etc/login.defs
    sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE\t7/'   /etc/login.defs
    grep -q '^UMASK' /etc/login.defs && \
        sed -i 's/^UMASK.*/UMASK\t\t027/' /etc/login.defs || \
        printf 'UMASK\t\t027\n' >> /etc/login.defs
fi

# ── SSH hardening (CIS §5.2) ──────────────────────────────────────────────────
log "Hardening SSH server..."
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-cis.conf << 'EOF'
X11Forwarding no
MaxAuthTries 4
IgnoreRhosts yes
HostbasedAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
PermitUserEnvironment no
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
ClientAliveInterval 300
ClientAliveCountMax 0
LoginGraceTime 60
Banner /etc/issue.net
AuthenticationMethods publickey
MaxStartups 10:30:60
EOF

cat > /etc/issue.net << 'EOF'
*******************************************************************************
         AUTHORIZED ACCESS ONLY — UNAUTHORIZED USE IS PROHIBITED
          All activity may be monitored, recorded, and reported.
*******************************************************************************
EOF

systemctl enable sshd 2>/dev/null || true

# ── auditd (CIS §4.1) ─────────────────────────────────────────────────────────
log "Installing auditd and writing rules..."
dnf install -y audit 2>/dev/null || true

mkdir -p /etc/audit/rules.d
cat > /etc/audit/rules.d/99-cis.rules << 'EOF'
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k time-change
-a always,exit -F arch=b32 -S adjtimex -S settimeofday -S stime -k time-change
-a always,exit -F arch=b64 -S clock_settime -k time-change
-w /etc/localtime -p wa -k time-change
-w /etc/group   -p wa -k identity
-w /etc/passwd  -p wa -k identity
-w /etc/shadow  -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d -p wa -k scope
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k system-locale
-w /etc/hosts -p wa -k system-locale
-w /etc/selinux/ -p wa -k MAC-policy
-a always,exit -F arch=b64 -S chmod -S fchmod -S fchmodat -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b64 -S chown -S fchown -S fchownat -S lchown -F auid>=1000 -F auid!=4294967295 -k perm_mod
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod  -p x -k modules
-e 2
EOF
systemctl enable auditd 2>/dev/null || true

# ── SELinux enforcing (CIS §1.6) ──────────────────────────────────────────────
# setenforce does not work without a running kernel — set config for first boot
log "Setting SELinux to enforcing in config..."
if [ -f /etc/selinux/config ]; then
    sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
fi

# ── dnf gpgcheck (CIS 1.2.2) ─────────────────────────────────────────────────
log "Enforcing gpgcheck in dnf.conf..."
if [ -f /etc/dnf/dnf.conf ]; then
    if grep -q '^gpgcheck=' /etc/dnf/dnf.conf; then
        sed -i 's/^gpgcheck=.*/gpgcheck=1/' /etc/dnf/dnf.conf
    else
        printf 'gpgcheck=1\n' >> /etc/dnf/dnf.conf
    fi
fi

# ── firewalld default-deny (CIS §3.5) ────────────────────────────────────────
log "Configuring firewalld..."
dnf install -y firewalld 2>/dev/null || true
# Use offline commands — firewalld daemon is not running during build
if command -v firewall-offline-cmd >/dev/null 2>&1; then
    firewall-offline-cmd --set-default-zone=drop 2>/dev/null || true
    firewall-offline-cmd --zone=drop --add-service=ssh 2>/dev/null || true
fi
systemctl enable firewalld 2>/dev/null || true

# ── Disable unnecessary services (CIS §2.1/2.2) ───────────────────────────────
log "Disabling unnecessary services..."
for svc in avahi-daemon cups nfs-server rpcbind bind9 vsftpd httpd dovecot samba squid snmpd rsync; do
    systemctl disable "$svc" 2>/dev/null || true
done

# ── SUID/SGID audit (CIS 6.1.1) ───────────────────────────────────────────────
log "Auditing SUID/SGID files..."
find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null \
    | tee /var/log/cis-suid-audit.log || true

# ── dnf cleanup ───────────────────────────────────────────────────────────────
dnf clean all
rm -rf /var/cache/dnf

log "Rocky Linux 9 host CIS hardening complete."
