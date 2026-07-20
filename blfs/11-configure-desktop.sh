#!/bin/bash
# Configure desktop environment – compatible Docker et native
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
log_info "Configuring desktop environment"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – minimal desktop config inside $LFS"
    run_privileged mkdir -pv "$LFS"/etc/X11/xorg.conf.d
    run_privileged mkdir -pv "$LFS"/usr/share/xsessions
    cat > "$LFS/usr/share/xsessions/xfce.desktop" << 'XFCE'
[Desktop Entry]
Name=XFCE
Exec=startxfce4
Type=Application
XFCE
    log_success "Desktop configuration created (Docker mode)"
    exit 0
fi

log_info "Native mode – configuring desktop inside chroot"

if [ ! -f "$LFS/bin/bash" ]; then
    log_error "/bin/bash not found in $LFS/bin"
    exit 1
fi

run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true

cat > "$LFS/configure-desktop.sh" << 'INNEREOF'
#!/bin/bash
set -e
echo "Configuring desktop..."
mkdir -pv /etc/X11/xorg.conf.d
mkdir -pv /usr/share/xsessions
cat > /usr/share/xsessions/xfce.desktop << 'XFCE'
[Desktop Entry]
Name=XFCE
Exec=startxfce4
Type=Application
XFCE
echo "Desktop configured."
INNEREOF

run_privileged chmod +x "$LFS/configure-desktop.sh"
run_privileged chroot "$LFS" /bin/bash /configure-desktop.sh

run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true

log_success "Desktop configuration complete"