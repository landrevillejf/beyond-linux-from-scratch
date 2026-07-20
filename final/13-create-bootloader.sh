#!/bin/bash
# final/13-create-bootloader.sh – Install the selected bootloader
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

LFS="${LFS:-/mnt/lfs}"
if [ ! -d "$LFS" ]; then
    echo "[ERROR] LFS directory not found"
    exit 1
fi

# --- Récupération du type de bootloader depuis l'environnement ---
BOOTLOADER="${LFS_CONFIG_BOOTLOADER_TYPE:-grub}"
echo "[INFO] Bootloader selected: $BOOTLOADER"

# Monter les systèmes de fichiers virtuels si nécessaire
mount --bind /dev "$LFS/dev" 2>/dev/null || true
mount --bind /proc "$LFS/proc" 2>/dev/null || true
mount --bind /sys "$LFS/sys" 2>/dev/null || true

case "$BOOTLOADER" in
    grub)
        echo "[INFO] Installing GRUB bootloader..."
        if [ -f "$LFS/usr/sbin/grub-install" ]; then
            chroot "$LFS" grub-install --target=i386-pc /dev/sda || echo "GRUB BIOS install skipped"
            chroot "$LFS" grub-mkconfig -o /boot/grub/grub.cfg
        else
            echo "[WARNING] GRUB not installed in LFS"
        fi
        ;;
    lilo)
        echo "[INFO] Installing LILO bootloader..."
        if [ -x "$LFS/sbin/lilo" ] || [ -x "$LFS/usr/sbin/lilo" ]; then
            # Créer un lilo.conf basique si absent
            if [ ! -f "$LFS/etc/lilo.conf" ]; then
                KERNEL_VERSION=$(find "$LFS/lib/modules" -maxdepth 1 -type d 2>/dev/null | head -n1)
                cat > "$LFS/etc/lilo.conf" << EOF
boot=/dev/sda
map=/boot/map
install=menu
timeout=50
vga=normal
default=linux

image=/boot/vmlinuz-${KERNEL_VERSION:-5.10.0}
    label=linux
    initrd=/boot/initrd.img-${KERNEL_VERSION:-5.10.0}
    read-only
    root=/dev/sda
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