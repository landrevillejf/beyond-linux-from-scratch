#!/bin/bash
# final/13-create-bootloader.sh – Install the selected bootloader
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

LFS="${LFS:-/mnt/lfs}"
if [ ! -d "$LFS" ]; then
    echo "[ERROR] LFS directory not found"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# --- Récupération du type de bootloader depuis l'environnement ---
BOOTLOADER="${LFS_CONFIG_BOOTLOADER_TYPE:-grub}"
echo "[INFO] Bootloader selected: $BOOTLOADER"

# Auto-detect target disk device
GRUB_TARGET="${LFS_CONFIG_BOOTLOADER_TARGET:-}"
if [ -z "$GRUB_TARGET" ]; then
    for candidate in /dev/sda /dev/vda /dev/nvme0n1 /dev/xvda; do
        if [ -b "$candidate" ]; then
            GRUB_TARGET="$candidate"
            break
        fi
    done
fi

# Detect kernel version and root device for config template
KERNEL_VERSION="$(ls "$LFS/boot/vmlinuz-"* 2>/dev/null | head -1 | sed 's/.*vmlinuz-//')"
KERNEL_VERSION="${KERNEL_VERSION:-$(uname -r)}"
ROOT_UUID="${LFS_CONFIG_ROOT_UUID:-}"
ROOT_DEVICE="${LFS_CONFIG_ROOT_DEVICE:-/dev/sda2}"

# Monter les systèmes de fichiers virtuels si nécessaire
mount --bind /dev "$LFS/dev" 2>/dev/null || true
mount --bind /proc "$LFS/proc" 2>/dev/null || true
mount --bind /sys "$LFS/sys" 2>/dev/null || true

case "$BOOTLOADER" in
grub)
    echo "[INFO] Installing GRUB bootloader..."
    if [ -f "$LFS/usr/sbin/grub-install" ]; then
        if [ -n "$GRUB_TARGET" ]; then
            chroot "$LFS" grub-install --target=i386-pc "$GRUB_TARGET" || echo "GRUB BIOS install skipped"
        else
            echo "[WARNING] No target disk found for GRUB BIOS install – skipping"
        fi

        # Use config/grub.cfg template if available, else generate with grub-mkconfig
        GRUB_TEMPLATE="$REPO_ROOT/config/grub.cfg"
        if [ -f "$GRUB_TEMPLATE" ]; then
            echo "[INFO] Using GRUB config template: $GRUB_TEMPLATE"
            # Substitute build-time variables into the template
            sed -e "s|\${LFS_CONFIG_BOOTLOADER_TIMEOUT}|${LFS_CONFIG_BOOTLOADER_TIMEOUT:-5}|g" \
                -e "s|\${LFS_ROOT_DEVICE}|$ROOT_DEVICE|g" \
                -e "s|\${LFS_ROOT_UUID}|$ROOT_UUID|g" \
                -e "s|\${LFS_KERNEL_VERSION}|$KERNEL_VERSION|g" \
                -e "s|\${LFS_KERNEL_CMDLINE}|${LFS_CONFIG_KERNEL_CMDLINE:-quiet splash}|g" \
                "$GRUB_TEMPLATE" > "$LFS/boot/grub/grub.cfg"
            echo "[INFO] GRUB config written to /boot/grub/grub.cfg"
        else
            echo "[INFO] No GRUB template found – generating config with grub-mkconfig"
            chroot "$LFS" grub-mkconfig -o /boot/grub/grub.cfg
        fi
    else
        echo "[WARNING] GRUB not installed in LFS"
    fi
    ;;
lilo)
    echo "[INFO] Installing LILO bootloader..."
    if [ -x "$LFS/sbin/lilo" ] || [ -x "$LFS/usr/sbin/lilo" ]; then
        if [ ! -f "$LFS/etc/lilo.conf" ]; then
            cat >"$LFS/etc/lilo.conf" <<EOF
boot=${GRUB_TARGET:-/dev/sda}
map=/boot/map
install=menu
timeout=50
vga=normal
default=linux

image=/boot/vmlinuz-${KERNEL_VERSION}
    label=linux
    initrd=/boot/initramfs.img
    read-only
    root=${ROOT_DEVICE}
EOF
        fi
        chroot "$LFS" lilo -C /etc/lilo.conf
    else
        echo "[WARNING] LILO not installed in LFS"
    fi
    ;;
uboot)
    echo "[INFO] U-Boot installation is handled by host/05-build-uboot.sh – nothing to do here."
    ;;
aboot)
    echo "[INFO] ABoot installation is handled separately – nothing to do here."
    ;;
*)
    echo "[WARNING] Unknown bootloader: $BOOTLOADER. Skipping."
    ;;
esac

# Nettoyage
umount "$LFS/dev" 2>/dev/null || true
umount "$LFS/proc" 2>/dev/null || true
umount "$LFS/sys" 2>/dev/null || true

echo "[SUCCESS] Bootloader configuration completed"
