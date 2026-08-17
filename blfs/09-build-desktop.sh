#!/bin/bash
# 09-build-desktop.sh
# Desktop environment dispatcher – routes to per-desktop build scripts.
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/../common/utils.sh" ]; then
    source "$SCRIPT_DIR/../common/utils.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warning() { echo "[WARNING] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
fi

DESKTOP_TYPE="${LFS_CONFIG_DESKTOP_TYPE:-xfce}"

log_info "========================================="
log_info "Desktop Environment Build"
log_info "Desktop type: $DESKTOP_TYPE"
log_info "========================================="

case "$DESKTOP_TYPE" in
    xfce)
        log_info "Dispatching to XFCE build script"
        source "$SCRIPT_DIR/09a-build-xfce.sh"
        ;;
    gnome)
        log_info "Dispatching to GNOME build script"
        source "$SCRIPT_DIR/09b-build-gnome.sh"
        ;;
    kde)
        log_info "Dispatching to KDE Plasma build script"
        source "$SCRIPT_DIR/09c-build-kde.sh"
        ;;
    lxqt)
        log_info "Dispatching to LXQt build script"
        source "$SCRIPT_DIR/09d-build-lxqt.sh"
        ;;
    none)
        log_info "No desktop requested; skipping desktop build"
        ;;
    phosh)
        log_info "Phosh mobile desktop requested; skipping full desktop build"
        log_warning "Phosh desktop not yet fully implemented; creating minimal session"
        mkdir -p "$LFS/usr/share/wayland-sessions" 2>/dev/null || true
        ;;
    *)
        log_error "Unknown desktop type: $DESKTOP_TYPE"
        log_error "Supported types: xfce, gnome, kde, lxqt, none"
        exit 1
        ;;
esac
