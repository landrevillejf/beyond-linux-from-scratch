#!/bin/bash
# First-boot service
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/../common/utils.sh" ]; then
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
    log_info "Running in Docker container"
fi

if [ "$IN_DOCKER" = true ]; then
    LFS=${LFS:-/output/image}
else
    LFS=${LFS:-/mnt/lfs}
fi

if [ -z "$LFS" ]; then
    log_error "LFS variable not set"
    exit 1
fi

run_privileged() {
    if [ "$(whoami)" = "root" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

log_info "========================================="
log_info "Setting up first-boot service"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – creating first-boot script inside $LFS"
    run_privileged mkdir -pv "$LFS/usr/sbin"
    run_privileged tee "$LFS/usr/sbin/first-boot.sh" <<'EOF' >/dev/null
#!/bin/bash
echo "First-boot script running (Docker mode)"
touch /var/log/first-boot-done
EOF
    run_privileged chmod +x "$LFS/usr/sbin/first-boot.sh"
    log_success "First-boot script created (Docker mode)"
    exit 0
fi

# Native mode
log_info "Native mode – installing first-boot service"

# Mount virtual filesystems
run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true

# Create directory and script inside chroot
run_privileged mkdir -pv "$LFS/usr/sbin"

# Write the script
run_privileged tee "$LFS/usr/sbin/first-boot.sh" <<'EOF' >/dev/null
#!/bin/bash
echo "Running first-boot configuration..."
# Add first-boot tasks here
touch /var/log/first-boot-done
echo "First-boot done."
EOF
run_privileged chmod +x "$LFS/usr/sbin/first-boot.sh"

# Create systemd service if systemd is the init, or an rc script for sysvinit
if [ -d "$LFS/usr/lib/systemd/system" ]; then
    run_privileged tee "$LFS/usr/lib/systemd/system/first-boot.service" <<'SERVICE' >/dev/null
[Unit]
Description=First Boot Configuration
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/first-boot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE
    run_privileged chroot "$LFS" systemctl enable first-boot.service 2>/dev/null || true
elif [ -d "$LFS/etc/init.d" ]; then
    run_privileged tee "$LFS/etc/init.d/first-boot" <<'INIT' >/dev/null
#!/bin/sh
case "$1" in
    start)
        /usr/sbin/first-boot.sh
        ;;
    *)
        exit 1
        ;;
esac
INIT
    run_privileged chmod +x "$LFS/etc/init.d/first-boot"
    run_privileged chroot "$LFS" update-rc.d first-boot defaults 2>/dev/null || true
fi

run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true

log_success "First-boot service installed"
