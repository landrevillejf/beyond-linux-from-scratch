#!/bin/bash
# Service management abstraction layer - sysvinit/systemd compatibility
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
log_info "Service Management Abstraction Layer"
log_info "========================================="

# Récupérer l'init système depuis la config
INIT_SYSTEM=${INIT_SYSTEM:-sysvinit}
if [ -f "$SCRIPT_DIR/../config/init.conf" ]; then
    source "$SCRIPT_DIR/../config/init.conf"
fi
log_info "Detected init system: $INIT_SYSTEM"

# Docker mode – minimal
if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – creating minimal service scripts inside $LFS"
    run_privileged mkdir -p "$LFS/etc/profile.d"
    run_privileged tee "$LFS/etc/profile.d/svc-aliases.sh" << 'EOF'
# Service aliases for both sysvinit and systemd
alias start='sudo /etc/init.d/'
alias stop='sudo /etc/init.d/'
alias restart='sudo /etc/init.d/'
alias status='sudo /etc/init.d/'
EOF
    run_privileged chmod +x "$LFS/etc/profile.d/svc-aliases.sh"
    log_success "Service aliases created in Docker mode"
    exit 0
fi

# Native mode – installer les scripts de gestion de services
log_info "Native mode - installing full service management"

# Monter les FS si nécessaire
run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true

# Créer le répertoire profile.d dans le chroot
run_privileged mkdir -p "$LFS/etc/profile.d"

# Créer le fichier d'aliases dans le chroot
log_info "Writing service aliases to $LFS/etc/profile.d/svc-aliases.sh"
run_privileged tee "$LFS/etc/profile.d/svc-aliases.sh" << 'EOF'
# Service management aliases
if [ -d /etc/init.d ] && [ -x /etc/init.d/rc ]; then
    # sysvinit style
    alias start='sudo /etc/init.d/'
    alias stop='sudo /etc/init.d/'
    alias restart='sudo /etc/init.d/'
    alias status='sudo /etc/init.d/'
elif command -v systemctl >/dev/null 2>&1; then
    # systemd style
    alias start='sudo systemctl start'
    alias stop='sudo systemctl stop'
    alias restart='sudo systemctl restart'
    alias status='sudo systemctl status'
    alias enable='sudo systemctl enable'
    alias disable='sudo systemctl disable'
fi
EOF
run_privileged chmod +x "$LFS/etc/profile.d/svc-aliases.sh"

# Si systemd, créer les liens symboliques pour les commandes legacy
if [ "$INIT_SYSTEM" = "systemd" ]; then
    log_info "Creating legacy symlinks for systemd"
    run_privileged chroot "$LFS" /bin/bash -c "
        ln -sf /usr/lib/systemd/systemd /sbin/init 2>/dev/null || true
        ln -sf /usr/bin/systemctl /sbin/service 2>/dev/null || true
    "
fi

# Nettoyer les montages
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true

log_success "Service management abstraction layer installed"