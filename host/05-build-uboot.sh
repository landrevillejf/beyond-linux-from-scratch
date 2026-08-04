#!/usr/bin/env bash
# Build U-Boot bootloader for ARM / ARM64 targets
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fallback functions if utils.sh doesn't exist
if [ -f "$SCRIPT_DIR/../common/utils.sh" ]; then
    source "$SCRIPT_DIR/../common/utils.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_success() { echo "[SUCCESS] $*"; }
fi

# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------
# The builder exports CROSS_COMPILE (e.g. aarch64-linux-gnu-) and ARCH.
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
ARCH="${ARCH:-arm64}"
U_BOOT_VERSION="${U_BOOT_VERSION:-2024.07}"
U_BOOT_URL="https://ftp.denx.de/pub/u-boot/u-boot-${U_BOOT_VERSION}.tar.bz2"
U_BOOT_DIR="u-boot-${U_BOOT_VERSION}"
BOARD="${U_BOOT_BOARD:-rpi_4}" # default to Raspberry Pi 4 (64-bit)
OUTPUT_DIR="${LFS:-/mnt/lfs}/boot"

# Map boards to U-Boot defconfigs
declare -A UBOOT_DEFCONFIG
UBOOT_DEFCONFIG[rpi_4]=rpi_4_defconfig
UBOOT_DEFCONFIG[rpi_3]=rpi_3_defconfig
UBOOT_DEFCONFIG[rpi_3_b_plus]=rpi_3_b_plus_defconfig
UBOOT_DEFCONFIG[rpi_4_32b]=rpi_4_32b_defconfig
UBOOT_DEFCONFIG[pinebook]=pinebook_defconfig
UBOOT_DEFCONFIG[pine64_plus]=pine64_plus_defconfig
UBOOT_DEFCONFIG[orange_pi_pc]=orangepi_pc_defconfig
UBOOT_DEFCONFIG[bananapi]=Bananapi_defconfig

if [ -z "${UBOOT_DEFCONFIG[$BOARD]:-}" ]; then
    log_error "Unknown board: $BOARD. Supported boards: ${!UBOOT_DEFCONFIG[*]}"
    exit 1
fi

log_info "Building U-Boot ${U_BOOT_VERSION} for board: ${BOARD} (ARCH=${ARCH})"

# ----------------------------------------------------------------------
# Check cross-compiler
# ----------------------------------------------------------------------
if ! command -v "${CROSS_COMPILE}gcc" &>/dev/null; then
    log_error "Cross-compiler ${CROSS_COMPILE}gcc not found. Please install it first."
    exit 1
fi

# ----------------------------------------------------------------------
# Download U-Boot
# ----------------------------------------------------------------------
mkdir -p /sources
cd /sources

if [ ! -f "${U_BOOT_DIR}.tar.bz2" ]; then
    log_info "Downloading U-Boot ${U_BOOT_VERSION}..."
    wget -q --show-progress "$U_BOOT_URL" || {
        log_error "Failed to download U-Boot"
        exit 1
    }
fi

# Extract if not already extracted
if [ ! -d "$U_BOOT_DIR" ]; then
    log_info "Extracting U-Boot..."
    tar -xf "${U_BOOT_DIR}.tar.bz2"
fi

# ----------------------------------------------------------------------
# Build U-Boot
# ----------------------------------------------------------------------
cd "$U_BOOT_DIR"

log_info "Configuring U-Boot for ${BOARD} (${UBOOT_DEFCONFIG[$BOARD]})"
make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" "${UBOOT_DEFCONFIG[$BOARD]}" -j"$(nproc)"

log_info "Compiling U-Boot..."
make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" -j"$(nproc)"

# ----------------------------------------------------------------------
# Install artifacts
# ----------------------------------------------------------------------
mkdir -p "$OUTPUT_DIR"

if [ -f "u-boot.bin" ]; then
    cp -v u-boot.bin "$OUTPUT_DIR/"
    log_success "Copied u-boot.bin to $OUTPUT_DIR"
else
    log_error "u-boot.bin not found after compilation"
    exit 1
fi

# Some boards need additional files (like spl, bl31, dtb)
if [ -f "spl/u-boot-spl.bin" ]; then
    cp -v spl/u-boot-spl.bin "$OUTPUT_DIR/"
fi
if [ -f "u-boot-dtb.bin" ]; then
    cp -v u-boot-dtb.bin "$OUTPUT_DIR/"
fi
# Copy device trees if available
if ls arch/arm/dts/*.dtb 1>/dev/null 2>&1; then
    cp -v arch/arm/dts/*.dtb "$OUTPUT_DIR/"
fi

log_success "U-Boot ${U_BOOT_VERSION} build completed for ${BOARD}"
exit 0
