#!/bin/bash
# 15-security-hardening.sh
# Apply real security hardening to the LFS/BLFS system.
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/../common/utils.sh" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/../common/utils.sh"
else
    log_info()    { echo "[INFO] $*"; }
    log_error()   { echo "[ERROR] $*" >&2; }
    log_warning() { echo "[WARNING] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
fi

IN_DOCKER=false
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
    IN_DOCKER=true
fi

if [ "$IN_DOCKER" = true ]; then
    LFS=${LFS:-/output/image}
else
    LFS=${LFS:-/mnt/lfs}
fi

if [ -z "${LFS:-}" ] || [ ! -d "$LFS" ]; then
    log_error "LFS directory not set or does not exist: ${LFS:-<unset>}"
    exit 1
fi

run_privileged() {
    if [ "$(whoami)" = "root" ]; then "$@"; else sudo "$@"; fi
}

write_file() {
    # write_file <path> <mode>  (content on stdin)
    local path="$1" mode="$2"
    run_privileged mkdir -p "$(dirname "$LFS$path")"
    run_privileged tee "$LFS$path" >/dev/null
    run_privileged chmod "$mode" "$LFS$path"
    log_info "wrote $path (mode $mode)"
}

log_info "========================================="
log_info "Applying security hardening to $LFS"
log_info "========================================="

run_privileged mkdir -p \
    "$LFS/etc/sysctl.d" \
    "$LFS/etc/security/limits.d" \
    "$LFS/etc/pam.d" \
    "$LFS/etc/profile.d" \
    "$LFS/etc/modprobe.d" \
    "$LFS/etc/ssh" \
    "$LFS/etc/audit/rules.d" \
    "$LFS/usr/lib/sysctl.d" \
    "$LFS/var/log"

# ---------------------------------------------------------------------------
# 1. Kernel / network sysctl hardening
# ---------------------------------------------------------------------------
write_file /etc/sysctl.d/99-security.conf 0644 <<'SYSCTL'
# --- Kernel hardening -------------------------------------------------------
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.perf_event_paranoid = 3
kernel.kexec_load_disabled = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
kernel.randomize_va_space = 2
kernel.sysrq = 0
kernel.core_uses_pid = 1
kernel.panic = 60
kernel.panic_on_oops = 1

# --- Filesystem protections -------------------------------------------------
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0

# --- Network hardening (IPv4) ----------------------------------------------
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1

# --- Network hardening (IPv6) ----------------------------------------------
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
SYSCTL

# ---------------------------------------------------------------------------
# 2. PAM: password quality + login faillock (account lockout)
# ---------------------------------------------------------------------------
write_file /etc/security/faillock.conf 0644 <<'FAILLOCK'
# Lock account after repeated failed logins
deny = 5
unlock_time = 900
fail_interval = 900
even_deny_root
root_unlock_time = 1200
FAILLOCK

write_file /etc/security/pwquality.conf 0644 <<'PWQUALITY'
# Password quality requirements (libpwquality)
minlen = 12
minclass = 3
maxrepeat = 3
maxsequence = 3
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
gecoscheck = 1
dictcheck = 1
enforcing = 1
retry = 3
PWQUALITY

write_file /etc/pam.d/system-password 0644 <<'PAMPW'
# Password stack: enforce quality + sha512 with rounds
password  requisite  pam_pwquality.so
password  required   pam_unix.so sha512 shadow use_authtok rounds=65536
PAMPW

# ---------------------------------------------------------------------------
# 3. Login / shell hardening
# ---------------------------------------------------------------------------
write_file /etc/security/limits.d/99-hardening.conf 0644 <<'LIMITS'
# Disable core dumps for all users
*   hard   core        0
*   soft   core        0
# Limit number of processes to mitigate fork bombs
*   soft   nproc       2048
*   hard   nproc       4096
# Cap simultaneous logins
*   hard   maxlogins   10
LIMITS

write_file /etc/profile.d/00-security.sh 0644 <<'PROFILE'
# Restrictive default file-creation mask
umask 027
# Auto-logout idle root/interactive shells after 15 minutes
if [ -n "${PS1:-}" ]; then
    TMOUT=900
    readonly TMOUT
    export TMOUT
fi
# Disable core dumps in the shell
ulimit -c 0 2>/dev/null || true
PROFILE

# ---------------------------------------------------------------------------
# 4. Kernel module blacklist (rare/attack-surface filesystems & protocols)
# ---------------------------------------------------------------------------
write_file /etc/modprobe.d/hardening-blacklist.conf 0644 <<'BLACKLIST'
# Uncommon network protocols
install dccp /bin/false
install sctp /bin/false
install rds  /bin/false
install tipc /bin/false
# Rare/legacy filesystems
install cramfs   /bin/false
install freevxfs /bin/false
install jffs2    /bin/false
install hfs      /bin/false
install hfsplus  /bin/false
install udf      /bin/false
# Legacy / risky
install usb-storage /bin/false
install firewire-core /bin/false
BLACKLIST

# ---------------------------------------------------------------------------
# 5. SSH daemon hardening (drop-in; merged if sshd_config exists)
# ---------------------------------------------------------------------------
write_file /etc/ssh/sshd_config.d/99-hardening.conf 0644 <<'SSHD'
Protocol 2
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes256-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512
SSHD

# ---------------------------------------------------------------------------
# 6. Login banners / issue
# ---------------------------------------------------------------------------
write_file /etc/issue.net 0644 <<'ISSUE'
Authorized access only. All activity may be monitored and reported.
ISSUE
run_privileged cp "$LFS/etc/issue.net" "$LFS/etc/issue"

# ---------------------------------------------------------------------------
# 7. Login.defs hardening (password aging + hashing)
# ---------------------------------------------------------------------------
if [ -f "$LFS/etc/login.defs" ]; then
    log_info "Hardening /etc/login.defs"
    run_privileged sed -i \
        -e 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' \
        -e 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/'  \
        -e 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   14/' \
        -e 's/^UMASK.*/UMASK           027/' \
        "$LFS/etc/login.defs"
    if ! grep -q '^ENCRYPT_METHOD' "$LFS/etc/login.defs"; then
        echo 'ENCRYPT_METHOD SHA512' | run_privileged tee -a "$LFS/etc/login.defs" >/dev/null
    fi
    if ! grep -q '^SHA_CRYPT_MIN_ROUNDS' "$LFS/etc/login.defs"; then
        echo 'SHA_CRYPT_MIN_ROUNDS 65536' | run_privileged tee -a "$LFS/etc/login.defs" >/dev/null
    fi
else
    write_file /etc/login.defs 0644 <<'LOGINDEFS'
PASS_MAX_DAYS   90
PASS_MIN_DAYS   1
PASS_WARN_AGE   14
UMASK           027
ENCRYPT_METHOD  SHA512
SHA_CRYPT_MIN_ROUNDS 65536
LOGINDEFS
fi

# ---------------------------------------------------------------------------
# 8. Restrict cron/at to authorized users
# ---------------------------------------------------------------------------
write_file /etc/cron.allow 0600 <<'CRONALLOW'
root
CRONALLOW
write_file /etc/at.allow 0600 <<'ATALLOW'
root
ATALLOW

# ---------------------------------------------------------------------------
# 9. Secure permissions on sensitive files
# ---------------------------------------------------------------------------
for f in /etc/shadow /etc/gshadow; do
    [ -f "$LFS$f" ] && run_privileged chmod 0000 "$LFS$f" || true
done
[ -f "$LFS/etc/passwd" ] && run_privileged chmod 0644 "$LFS/etc/passwd" || true
[ -f "$LFS/etc/group" ]  && run_privileged chmod 0644 "$LFS/etc/group"  || true

# ---------------------------------------------------------------------------
# 10. auditd base rules (applied if auditd is installed)
# ---------------------------------------------------------------------------
write_file /etc/audit/rules.d/hardening.rules 0640 <<'AUDIT'
# Delete existing rules on load
-D
# Buffer size
-b 8192
# Failure mode: printk
-f 1
# Monitor changes to authentication/authorization files
-w /etc/passwd  -p wa -k identity
-w /etc/group   -p wa -k identity
-w /etc/shadow  -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
# Monitor login records
-w /var/log/wtmp  -p wa -k logins
-w /var/log/btmp  -p wa -k logins
-w /var/log/lastlog -p wa -k logins
# Monitor kernel module loading
-w /sbin/insmod  -p x -k modules
-w /sbin/rmmod   -p x -k modules
-w /sbin/modprobe -p x -k modules
# Make the configuration immutable (must be last)
-e 2
AUDIT

log_success "Security hardening applied:"
log_success "  - sysctl kernel/network hardening      (/etc/sysctl.d/99-security.conf)"
log_success "  - PAM faillock + pwquality + sha512    (/etc/security/*, /etc/pam.d/system-password)"
log_success "  - login limits, umask 027, TMOUT       (/etc/security/limits.d, /etc/profile.d)"
log_success "  - kernel module blacklist              (/etc/modprobe.d/hardening-blacklist.conf)"
log_success "  - SSH daemon hardening                 (/etc/ssh/sshd_config.d/99-hardening.conf)"
log_success "  - login.defs password aging + banners  (/etc/login.defs, /etc/issue*)"
log_success "  - cron/at restriction + file perms     (/etc/cron.allow, /etc/at.allow)"
log_success "  - auditd base ruleset                  (/etc/audit/rules.d/hardening.rules)"
exit 0
