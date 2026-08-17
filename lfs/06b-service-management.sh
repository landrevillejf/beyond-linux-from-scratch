#!/bin/bash
# Service management abstraction layer - supports sysvinit, systemd, openrc, runit, s6
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
# 06b-service-management.sh
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

INIT_SYSTEM=${INIT_SYSTEM:-sysvinit}
log_info "Detected init system: $INIT_SYSTEM"

# Docker mode – minimal
if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – creating minimal service scripts inside $LFS"
    run_privileged mkdir -p "$LFS/etc/profile.d"
    run_privileged tee "$LFS/etc/profile.d/svc-aliases.sh" <<'EOF'
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
cleanup_mounts() {
    run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
    run_privileged umount "$LFS"/dev 2>/dev/null || true
    run_privileged umount "$LFS"/proc 2>/dev/null || true
    run_privileged umount "$LFS"/sys 2>/dev/null || true
    run_privileged umount "$LFS"/run 2>/dev/null || true
}
trap cleanup_mounts EXIT

run_privileged mkdir -p "$LFS"/dev/pts "$LFS"/run
run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t devpts devpts "$LFS"/dev/pts 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true
run_privileged mount -t tmpfs tmpfs "$LFS"/run 2>/dev/null || true

# Créer le répertoire profile.d dans le chroot
run_privileged mkdir -p "$LFS/etc/profile.d"

# Créer le fichier d'aliases dans le chroot (supporte tous les init)
log_info "Writing service management aliases to $LFS/etc/profile.d/svc-aliases.sh"
run_privileged tee "$LFS/etc/profile.d/svc-aliases.sh" <<'EOF'
# Service management abstraction - works with sysvinit, systemd, openrc, runit, s6
# This file is sourced by all interactive shells.

_has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Detect init system at runtime inside the chroot
_detect_init() {
    if _has_cmd systemctl && [ -d /usr/lib/systemd ]; then
        echo "systemd"
    elif _has_cmd rc-service && [ -d /etc/init.d ]; then
        echo "openrc"
    elif _has_cmd sv && [ -d /etc/sv ]; then
        echo "runit"
    elif _has_cmd s6-svscan && [ -d /etc/s6 ]; then
        echo "s6"
    elif [ -f /sbin/init ] && grep -q "sysvinit" /sbin/init 2>/dev/null; then
        echo "sysvinit"
    else
        echo "sysvinit"   # fallback
    fi
}

_INIT=$(_detect_init)

case "$_INIT" in
    sysvinit)
        start() { sudo /etc/init.d/"$1" start; }
        stop()  { sudo /etc/init.d/"$1" stop; }
        restart() { sudo /etc/init.d/"$1" restart; }
        status() { sudo /etc/init.d/"$1" status; }
        enable() { echo "enable not supported for sysvinit"; }
        disable() { echo "disable not supported for sysvinit"; }
        ;;
    openrc)
        start() { sudo rc-service "$1" start; }
        stop()  { sudo rc-service "$1" stop; }
        restart() { sudo rc-service "$1" restart; }
        status() { sudo rc-service "$1" status; }
        enable() { sudo rc-update add "$1" default; }
        disable() { sudo rc-update del "$1"; }
        ;;
    systemd)
        start() { sudo systemctl start "$1"; }
        stop()  { sudo systemctl stop "$1"; }
        restart() { sudo systemctl restart "$1"; }
        status() { sudo systemctl status "$1"; }
        enable() { sudo systemctl enable "$1"; }
        disable() { sudo systemctl disable "$1"; }
        ;;
    runit)
        start() { sudo sv up "$1"; }
        stop()  { sudo sv down "$1"; }
        restart() { sudo sv restart "$1"; }
        status() { sudo sv status "$1"; }
        enable() { sudo ln -sfn /etc/sv/"$1" /var/service/"$1"; echo "Enabled $1 (runit)"; }
        disable() { sudo rm -f /var/service/"$1"; echo "Disabled $1 (runit)"; }
        ;;
    s6)
        start() { sudo s6-svc -u /etc/s6/sv/"$1"; }
        stop()  { sudo s6-svc -d /etc/s6/sv/"$1"; }
        restart() { sudo s6-svc -r /etc/s6/sv/"$1"; }
        status() { sudo s6-svstat /etc/s6/sv/"$1"; }
        enable() { sudo ln -sfn /etc/s6/sv/"$1" /etc/s6/current/"$1"; echo "Enabled $1 (s6)"; }
        disable() { sudo rm -f /etc/s6/current/"$1"; echo "Disabled $1 (s6)"; }
        ;;
esac

# Create command aliases for convenience (but functions are safer)
alias start='start'
alias stop='stop'
alias restart='restart'
alias status='status'
alias enable='enable'
alias disable='disable'

# Also define a generic service command that works on all inits
service() {
    case "$_INIT" in
        sysvinit|openrc) sudo /etc/init.d/"$1" "$2" ;;
        systemd) sudo systemctl "$2" "$1" ;;
        runit) sudo sv "$2" "$1" ;;
        s6) sudo s6-svc "$2" /etc/s6/sv/"$1" ;;
    esac
}
EOF
run_privileged chmod +x "$LFS/etc/profile.d/svc-aliases.sh"

# Si systemd, créer les liens symboliques pour les commandes legacy
if [ "$INIT_SYSTEM" = "systemd" ]; then
    log_info "Creating legacy symlinks for systemd"
    run_privileged chroot "$LFS" /bin/bash -c 'ln -sf /usr/lib/systemd/systemd /sbin/init 2>/dev/null || true; ln -sf /usr/bin/systemctl /sbin/service 2>/dev/null || true'
fi

# Si openrc, créer un lien symlink pour rc-service -> /sbin/rc-service si besoin
if [ "$INIT_SYSTEM" = "openrc" ]; then
    log_info "Creating openrc compatibility links"
    run_privileged chroot "$LFS" /bin/bash -c 'ln -sf /sbin/rc-service /usr/bin/rc-service 2>/dev/null || true'
fi

# Si runit, créer les liens de compatibilité
if [ "$INIT_SYSTEM" = "runit" ]; then
    log_info "Creating runit compatibility links"
    run_privileged chroot "$LFS" /bin/bash -c 'ln -sf /sbin/runit /sbin/runit-init 2>/dev/null || true; ln -sf /sbin/runit /sbin/runit-init 2>/dev/null || true'
fi

# Si s6, créer les liens de compatibilité
if [ "$INIT_SYSTEM" = "s6" ]; then
    log_info "Creating s6 compatibility links"
    run_privileged chroot "$LFS" /bin/bash -c 'ln -sf /sbin/s6-init /sbin/init 2>/dev/null || true; ln -sf /sbin/s6-shutdown /sbin/shutdown 2>/dev/null || true'
fi

# Nettoyer les montages
run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true
run_privileged umount "$LFS"/run 2>/dev/null || true

log_success "Service management abstraction layer installed"