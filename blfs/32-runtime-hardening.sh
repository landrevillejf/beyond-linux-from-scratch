#!/bin/bash
set -euo pipefail
# blfs/32-runtime-hardening.sh - build + wire the runtime-hardening toolset.
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# Phase 4 of the hardening program.  blfs/15-security-hardening.sh only writes
# configuration; this stage builds the intrusion-detection / brute-force tools
# that configuration references so those blocks are not dead.  It follows the
# exact "build-if-source-present" idiom of blfs/16-privacy-tools.sh: a tool is
# compiled only when its pinned tarball landed in /sources, so a profile that
# did not download one simply skips it instead of failing.
#
# Knobs (flattened from config/build.conf `security`, exported by builder.py):
#   LFS_CONFIG_SECURITY_FAIL2BAN_ENABLED  -> fail2ban
#   LFS_CONFIG_SECURITY_HIDS_ENABLED      -> rkhunter, lynis, aide (config)
#   LFS_CONFIG_SECURITY_USBGUARD_ENABLED  -> usbguard policy generation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/../common/utils.sh" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/../common/utils.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
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

log_info "========================================="
log_info "Building runtime-hardening toolset"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode - skipping runtime-hardening toolset"
    exit 0
fi

if [ ! -f "$LFS/bin/bash" ]; then
    log_error "/bin/bash not found in $LFS/bin - run lfs-basic first"
    exit 1
fi
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
    log_error "chroot not working - run lfs-basic first"
    exit 1
fi

run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t devpts devpts "$LFS"/dev/pts 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true
run_privileged mount -t tmpfs tmpfs "$LFS"/run 2>/dev/null || true

# --- DYNAMIC SOURCE PATH (same convention as blfs/16) ---
SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -r "$SOURCES_HOST"/* "$LFS/sources/"
    run_privileged chown -R lfs:lfs "$LFS/sources" 2>/dev/null || true
fi

cat >"$LFS/install-runtime-hardening.sh" <<'INNEREOF'
#!/bin/bash
set -e

cd /sources 2>/dev/null || { echo "no /sources; nothing to build"; exit 0; }

FAIL2BAN_ENABLED="${LFS_CONFIG_SECURITY_FAIL2BAN_ENABLED:-true}"
HIDS_ENABLED="${LFS_CONFIG_SECURITY_HIDS_ENABLED:-true}"
USBGUARD_ENABLED="${LFS_CONFIG_SECURITY_USBGUARD_ENABLED:-false}"

echo "=== Runtime hardening toolset ==="

# --------------------------------------------------------------------------
# fail2ban - brute-force ban daemon (python3, no native deps)
# --------------------------------------------------------------------------
if [ "$FAIL2BAN_ENABLED" = "true" ] && ls fail2ban-*.tar.gz 1>/dev/null 2>&1; then
    echo "Building fail2ban..."
    tar -xf "$(ls fail2ban-*.tar.gz | head -n1)"
    cd fail2ban-*/
    python3 setup.py install --prefix=/usr 2>/dev/null || python3 setup.py install
    cd /sources
    mkdir -p /etc/fail2ban /var/log /var/run/fail2ban
    cat >/etc/fail2ban/jail.local <<'F2B'
# Managed by blfs/32-runtime-hardening.sh (Phase 4).
[DEFAULT]
# Ban for one hour after 5 failures inside a 10-minute window.
bantime  = 1h
findtime = 10m
maxretry = 5
# Prefer the systemd journal; fall back to polling the auth log.
backend  = auto
banaction = nftables[type=multiport]

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
F2B
    echo "fail2ban installed and configured (/etc/fail2ban/jail.local)"
else
    echo "fail2ban: skipped (disabled or source absent)"
fi

# --------------------------------------------------------------------------
# rkhunter - rootkit scanner (shell/perl installer)
# --------------------------------------------------------------------------
if [ "$HIDS_ENABLED" = "true" ] && ls rkhunter-*.tar.gz 1>/dev/null 2>&1; then
    echo "Building rkhunter..."
    tar -xf "$(ls rkhunter-*.tar.gz | head -n1)"
    cd rkhunter-*/
    ./installer.sh --layout /usr --install
    cd /sources
    mkdir -p /etc
    if [ -f /etc/rkhunter.conf ]; then
        sed -i 's|^#\?UPDATE_MIRRORS=.*|UPDATE_MIRRORS=1|' /etc/rkhunter.conf
        sed -i 's|^#\?MIRRORS_MODE=.*|MIRRORS_MODE=0|' /etc/rkhunter.conf
        sed -i 's|^#\?WEB_CMD=.*|WEB_CMD=/usr/bin/wget|' /etc/rkhunter.conf
    fi
    # Baseline the file-property database so the first scan is not all noise.
    rkhunter --propupd 2>/dev/null || echo "rkhunter --propupd deferred to first boot"
    echo "rkhunter installed"
else
    echo "rkhunter: skipped (disabled or source absent)"
fi

# --------------------------------------------------------------------------
# lynis - security audit scanner (pure shell; installed by copying the tree)
# --------------------------------------------------------------------------
if [ "$HIDS_ENABLED" = "true" ] && ls lynis-*.tar.gz 1>/dev/null 2>&1; then
    echo "Installing lynis..."
    tar -xf "$(ls lynis-*.tar.gz | head -n1)"
    mkdir -p /usr/local/share/lynis
    cp -r lynis-*/. /usr/local/share/lynis/
    ln -sf /usr/local/share/lynis/lynis /usr/local/bin/lynis
    echo "lynis installed (/usr/local/bin/lynis)"
else
    echo "lynis: skipped (disabled or source absent)"
fi

# --------------------------------------------------------------------------
# aide - file-integrity monitor (config wiring only; build is dependency-heavy)
# --------------------------------------------------------------------------
if [ "$HIDS_ENABLED" = "true" ] && command -v aide >/dev/null 2>&1; then
    echo "Configuring aide..."
    mkdir -p /etc /var/lib/aide /var/log/aide
    if [ ! -f /etc/aide.conf ]; then
        cat >/etc/aide.conf <<'AIDE'
# Managed by blfs/32-runtime-hardening.sh (Phase 4).
database_in=file:/var/lib/aide/aide.db.gz
database_out=file:/var/lib/aide/aide.db.new.gz
database_new=file:/var/lib/aide/aide.db.new.gz
gzip_dbout=yes
verbose=5
NORMAL=FIPSR+ACLX+ANF+ARF+MD5+SHA1
/boot     NORMAL
/bin      NORMAL
/sbin     NORMAL
/usr/bin  NORMAL
/usr/sbin NORMAL
/etc      NORMAL
/var/log  NORMAL
!/var/log/.*[0-9]$
AIDE
    fi
    aide --init 2>/dev/null && mv -f /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz 2>/dev/null \
        || echo "aide --init deferred to first boot"
    echo "aide configured (/etc/aide.conf)"
else
    echo "aide: skipped (binary absent or hids disabled)"
fi

# --------------------------------------------------------------------------
# usbguard - USB device authorization (policy wiring only; not built here)
# --------------------------------------------------------------------------
if [ "$USBGUARD_ENABLED" = "true" ] && command -v usbguard >/dev/null 2>&1; then
    echo "Generating usbguard policy..."
    mkdir -p /etc/usbguard
    if [ ! -s /etc/usbguard/rules.conf ]; then
        usbguard generate-policy >/etc/usbguard/rules.conf 2>/dev/null \
            || echo "usbguard generate-policy needs real devices; deferred to first boot"
    fi
    echo "usbguard policy written (/etc/usbguard/rules.conf)"
else
    echo "usbguard: skipped (disabled or binary absent)"
fi

echo "Runtime hardening toolset complete."
INNEREOF

run_privileged chmod +x "$LFS/install-runtime-hardening.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LFS_CONFIG_SECURITY_FAIL2BAN_ENABLED="${LFS_CONFIG_SECURITY_FAIL2BAN_ENABLED:-true}" \
    LFS_CONFIG_SECURITY_HIDS_ENABLED="${LFS_CONFIG_SECURITY_HIDS_ENABLED:-true}" \
    LFS_CONFIG_SECURITY_USBGUARD_ENABLED="${LFS_CONFIG_SECURITY_USBGUARD_ENABLED:-false}" \
    /bin/bash /install-runtime-hardening.sh

run_privileged rm -f "$LFS/install-runtime-hardening.sh"

run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true
run_privileged umount "$LFS"/run 2>/dev/null || true

log_success "Runtime-hardening toolset stage complete"
exit 0
