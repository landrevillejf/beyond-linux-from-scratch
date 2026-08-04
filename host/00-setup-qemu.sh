#!/bin/bash
# host/00-setup-qemu.sh
# Setup QEMU user emulation for cross-compilation (ARM64, ARM, RISC‑V, etc.)
# Only runs if CROSS_COMPILE is set in environment.
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;34m[SUCCESS]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }
log_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }

# ----------------------------------------------------------------------------
# 0. Skip if cross-compilation is not enabled
# ----------------------------------------------------------------------------
if [ -z "${CROSS_COMPILE}" ]; then
    log_info "Cross-compilation not enabled (CROSS_COMPILE is empty). Skipping QEMU setup."
    exit 0
fi

# ----------------------------------------------------------------------------
# 1. Déterminer l'architecture cible et le binaire QEMU
# ----------------------------------------------------------------------------
# Le builder exporte ARCH (ex: aarch64) et QEMU_USER (ex: qemu-aarch64-static)
TARGET_ARCH="${ARCH:-aarch64}"
QEMU_BIN="${QEMU_USER:-qemu-${TARGET_ARCH}-static}"

log_info "Target architecture: $TARGET_ARCH"
log_info "QEMU binary: $QEMU_BIN"

# ----------------------------------------------------------------------------
# 2. Installer qemu-user-static si nécessaire (dans Docker ou sur l'hôte)
# ----------------------------------------------------------------------------
if [ -f /.dockerenv ]; then
    log_info "Docker container detected – installing qemu-user-static"
    sudo mkdir -p /var/lib/apt/lists/partial 2>/dev/null || true
    sudo apt-get update -qq
    sudo apt-get install -y -qq qemu-user-static binfmt-support
else
    if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
        log_error "$QEMU_BIN not found on host. Please install qemu-user-static."
        log_info "On Debian/Ubuntu: sudo apt install qemu-user-static"
        exit 1
    fi
fi

# ----------------------------------------------------------------------------
# 3. Activer binfmt_misc pour l'architecture cible
# ----------------------------------------------------------------------------
if [ -e /proc/sys/fs/binfmt_misc/register ]; then
    log_info "Configuring binfmt_misc for $TARGET_ARCH..."

    INTERPRETER=$(which "$QEMU_BIN" 2>/dev/null || echo "/usr/bin/$QEMU_BIN")
    if [ ! -f "$INTERPRETER" ]; then
        log_error "Interpreter not found: $INTERPRETER"
        exit 1
    fi

    if command -v update-binfmts >/dev/null 2>&1; then
        log_info "Using update-binfmts for $TARGET_ARCH"
        sudo update-binfmts --enable "$TARGET_ARCH" 2>/dev/null || true
        if [ -e "/proc/sys/fs/binfmt_misc/qemu-${TARGET_ARCH}" ]; then
            log_success "binfmt_misc enabled for $TARGET_ARCH"
        else
            log_warning "binfmt_misc not enabled – manual registration might be needed"
        fi
    else
        log_info "Manual registration via /proc"
        printf ":${TARGET_ARCH}:M::\\x7f\\x45\\x4c\\x46\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\xb7::${INTERPRETER}:OCF\n" |
            sudo tee /proc/sys/fs/binfmt_misc/register >/dev/null 2>&1 || true
    fi
else
    log_warning "binfmt_misc not available (kernel support missing?)"
fi

# ----------------------------------------------------------------------------
# 4. Tester l'émulation
# ----------------------------------------------------------------------------
if command -v "$QEMU_BIN" >/dev/null 2>&1; then
    log_success "$QEMU_BIN is ready:"
    "$QEMU_BIN" --version | head -n1
else
    log_error "$QEMU_BIN not found after setup"
    exit 1
fi

if [ -e "/proc/sys/fs/binfmt_misc/qemu-${TARGET_ARCH}" ]; then
    log_success "binfmt_misc entry active:"
    cat "/proc/sys/fs/binfmt_misc/qemu-${TARGET_ARCH}"
fi

log_success "QEMU setup completed for $TARGET_ARCH"
exit 0
