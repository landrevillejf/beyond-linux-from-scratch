#!/bin/bash
# final/14-create-installer.sh – Hybrid BIOS/UEFI ISO with xorriso direct + Branding
# Author: Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

# Détection de sudo si nécessaire
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
    echo "[INFO] Will use sudo for privileged operations."
fi

LFS="${LFS:-/mnt/lfs}"
if [ -z "$LFS" ] || [ ! -d "$LFS" ]; then
    echo "[ERROR] LFS directory '$LFS' not found"
    exit 1
fi

OUTPUT_DIR="$(dirname "$LFS")"
INSTALLER_ISO="${OUTPUT_DIR}/${ISO_NAME:-lfs-installer.iso}"
ISO_ROOT="${OUTPUT_DIR}/iso-root"
EFI_IMG="${OUTPUT_DIR}/efi.img"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BRANDING_DIR="${LFS_CONFIG_BRANDING_DIR:-$REPO_ROOT/branding/installer}"

echo "[INFO] Creating bootable ISO from $LFS"
echo "[INFO] Output: $INSTALLER_ISO"
echo "[INFO] Branding directory: $BRANDING_DIR"

# Vérifier les outils
for tool in xorriso mksquashfs grub-install mkfs.vfat mount python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[ERROR] $tool not found. Please install."
        exit 1
    fi
done

# Fonctions de branding
load_branding_config() {
    if [ -f "$BRANDING_DIR/installer-branding.conf" ]; then
        # shellcheck disable=SC1090
        source "$BRANDING_DIR/installer-branding.conf"
        echo "[INFO] Loaded branding configuration"
    else
        echo "[WARN] Branding configuration not found, using defaults"
        # Get version from VERSION file or environment
        if [ -f "$REPO_ROOT/VERSION" ]; then
            BUILD_VERSION=$(cat "$REPO_ROOT/VERSION")
        else
            BUILD_VERSION="${BUILD_VERSION:-0.52.7}"
        fi
        ISO_LABEL="BLFS-${BUILD_VERSION}-LIVE"
        GRUB_COLOR_NORMAL="lightgray/black"
        GRUB_COLOR_HIGHLIGHT="black/lightgreen"
    fi
}

ensure_branding_images() {
    local generator="$BRANDING_DIR/generate-installer-branding.py"
    local grub_bg="$BRANDING_DIR/backgrounds/grub-background.png"

    if [ ! -f "$grub_bg" ] || [ -f "$grub_bg.placeholder" ]; then
        if [ -f "$generator" ]; then
            echo "[INFO] Generating branding images..."
            if python3 "$generator" 2>&1 | while read -r line; do
                echo "[BRANDING] $line"
            done; then
                echo "[SUCCESS] Branding images generated"
            else
                echo "[WARN] Failed to generate branding images, continuing without custom graphics"
            fi
        fi
    fi
}

install_branding_assets() {
    local bg_dir="$BRANDING_DIR/backgrounds"
    local logo_dir="$BRANDING_DIR/logo"

    # Create branding directories in ISO
    mkdir -p "$ISO_ROOT/branding"/{backgrounds,logo,boot}

    # Copy backgrounds
    if [ -d "$bg_dir" ]; then
        find "$bg_dir" -type f -name "*.png" 2>/dev/null | while read -r bg; do
            cp "$bg" "$ISO_ROOT/branding/backgrounds/" 2>/dev/null || true
        done
    fi

    # Copy logos
    if [ -d "$logo_dir" ]; then
        find "$logo_dir" -type f 2>/dev/null | while read -r logo; do
            cp "$logo" "$ISO_ROOT/branding/logo/" 2>/dev/null || true
        done
    fi

    # Create branding manifest in ISO
    cat >"$ISO_ROOT/branding/manifest.txt" <<EOF
[Installer Branding Manifest]
preset=$(basename "$BRANDING_DIR")
version=${BUILD_VERSION:-0.52.7}
iso_label=$ISO_LABEL

[Colors]
primary=$PRIMARY_COLOR
primary_dark=$PRIMARY_DARK
primary_light=$PRIMARY_LIGHT
secondary=$SECONDARY_COLOR
accent=$ACCENT_COLOR
text_primary=$TEXT_PRIMARY
background=$BACKGROUND

[GRUB Configuration]
color_normal=$GRUB_COLOR_NORMAL
color_highlight=$GRUB_COLOR_HIGHLIGHT
timeout=$GRUB_TIMEOUT

[Branding Files]
EOF

    if [ -d "$ISO_ROOT/branding" ]; then
        find "$ISO_ROOT/branding" -type f | sort >>"$ISO_ROOT/branding/manifest.txt"
    fi

    echo "[SUCCESS] Branding assets installed"
}

# Trouver noyau et initramfs
KERNEL=$(find "$LFS/boot" -name "vmlinuz*" -type f 2>/dev/null | head -n1)
[ -z "$KERNEL" ] && KERNEL=$(find "$LFS/boot" -name "vmlinuz*" -type f | head -n1)
INITRAMFS=$(find "$LFS/boot" -name "initramfs.img" -type f 2>/dev/null | head -n1)
[ -z "$INITRAMFS" ] && INITRAMFS=$(find "$LFS/boot" -name "initramfs*" -type f | head -n1)

if [ -z "$KERNEL" ] || [ -z "$INITRAMFS" ]; then
    echo "[ERROR] Kernel or initramfs not found in $LFS/boot"
    echo "  Kernel: ${KERNEL:-not found}"
    echo "  Initramfs: ${INITRAMFS:-not found}"
    exit 1
fi

echo "[INFO] Kernel: $KERNEL"
echo "[INFO] Initramfs: $INITRAMFS"

# Préparer la racine de l'ISO
rm -rf "$ISO_ROOT"
mkdir -p "$ISO_ROOT"/{boot/grub,isolinux,EFI/BOOT}

cp -v "$KERNEL" "$ISO_ROOT/boot/vmlinuz"
cp -v "$INITRAMFS" "$ISO_ROOT/boot/initramfs.img"

# Créer le squashfs (taille > 4 Go)
echo "[INFO] Creating squashfs..."
mksquashfs "$LFS" "$ISO_ROOT/live.squashfs" -comp xz -noappend

# Load branding and ensure images exist
load_branding_config
ensure_branding_images

# Fichier grub.cfg (utilisé par BIOS et UEFI) - WITH BRANDING
cat >"$ISO_ROOT/boot/grub/grub.cfg" <<EOF
set timeout=${GRUB_TIMEOUT:-10}
set default=${GRUB_DEFAULT:-0}

# Branded GRUB appearance
set color_normal='${GRUB_COLOR_NORMAL}'
set color_highlight='${GRUB_COLOR_HIGHLIGHT}'

# Set background image if available
if [ -f (cd)/branding/backgrounds/grub-background.png ]; then
    insmod gfxterm
    insmod png
    set gfxmode=800x600
    insmod vbe
    set gfxpayload=keep
    background_image (cd)/branding/backgrounds/grub-background.png
fi

menuentry "LFS Linux Live" {
    linux /boot/vmlinuz root=/dev/loop0 ro quiet
    initrd /boot/initramfs.img
}
menuentry "Install LFS Linux" {
    linux /boot/vmlinuz root=/dev/loop0 ro quiet install
    initrd /boot/initramfs.img
}
menuentry "Boot from hard disk" {
    chainloader +1
}
EOF

# Install branding assets into ISO
install_branding_assets

# --- CRÉER L'IMAGE EFI (FAT avec GRUB) ---
echo "[INFO] Creating EFI boot image..."
EFI_MOUNT="${OUTPUT_DIR}/efi-mount"
mkdir -p "$EFI_MOUNT"

# Image FAT de 64 Mo
dd if=/dev/zero of="$EFI_IMG" bs=1M count=64 2>/dev/null
mkfs.vfat "$EFI_IMG" 2>/dev/null

# Monter l'image avec sudo si nécessaire
$SUDO mount -o loop "$EFI_IMG" "$EFI_MOUNT"

# Installer GRUB pour EFI dans l'image
$SUDO grub-install --target=x86_64-efi \
    --efi-directory="$EFI_MOUNT" \
    --boot-directory="$EFI_MOUNT/boot" \
    --removable \
    --modules="part_gpt fat" \
    --no-floppy

# Copier notre grub.cfg
mkdir -p "$EFI_MOUNT/boot/grub"
$SUDO cp "$ISO_ROOT/boot/grub/grub.cfg" "$EFI_MOUNT/boot/grub/"

# Démonter et nettoyer
$SUDO umount "$EFI_MOUNT"
rmdir "$EFI_MOUNT"

# Copier l'image EFI dans l'ISO (comme fichier)
# Extract the actual EFI binary from the FAT image
mkdir -p "${OUTPUT_DIR}/efi-extract"
$SUDO mount -o loop "$EFI_IMG" "${OUTPUT_DIR}/efi-extract"
EFI_BINARY=$(find "${OUTPUT_DIR}/efi-extract" -name "grubx64.efi" -o -name "BOOTX64.EFI" 2>/dev/null | head -1)
if [ -n "$EFI_BINARY" ]; then
    cp "$EFI_BINARY" "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI"
    echo "[INFO] EFI binary extracted from FAT image"
else
    # Fallback: copy the whole FAT image (not ideal but works for some firmware)
    cp "$EFI_IMG" "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI"
    echo "[WARNING] No EFI binary found in FAT image – using raw image as fallback"
fi
$SUDO umount "${OUTPUT_DIR}/efi-extract"
rmdir "${OUTPUT_DIR}/efi-extract"

# --- PRÉPARER ISOLINUX POUR LE BOOT BIOS ---
cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_ROOT/isolinux/"
cp /usr/lib/ISOLINUX/isohdpfx.bin "$ISO_ROOT/isolinux/" 2>/dev/null || true

cat >"$ISO_ROOT/isolinux/isolinux.cfg" <<'EOF'
default live
timeout 10
label live
    kernel /boot/vmlinuz
    append initrd=/boot/initramfs.img root=/dev/loop0 ro quiet
label install
    kernel /boot/vmlinuz
    append initrd=/boot/initramfs.img root=/dev/loop0 ro quiet install
EOF

# --- CONSTRUIRE L'ISO AVEC XORRISO (ISO LEVEL 4) ---
echo "[INFO] Building ISO with xorriso (BIOS+UEFI, ISO level 4)..."
echo "[INFO] ISO Label: $ISO_LABEL"
xorriso -as mkisofs \
    -iso-level 4 \
    -V "$ISO_LABEL" \
    -p "${ISO_PUBLISHER:-Beyond Linux From Scratch}" \
    -publisher "${ISO_PUBLISHER:-Beyond Linux From Scratch}" \
    -R -J -joliet-long \
    -cache-inodes \
    -isohybrid-mbr "$ISO_ROOT/isolinux/isohdpfx.bin" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -boot-load-size 4 -boot-info-table -no-emul-boot \
    -eltorito-alt-boot -e EFI/BOOT/BOOTX64.EFI -no-emul-boot \
    -isohybrid-gpt-basdat \
    -o "$INSTALLER_ISO" "$ISO_ROOT"

# Nettoyer
rm -rf "$ISO_ROOT" "$EFI_IMG"
echo "[SUCCESS] ISO created at $INSTALLER_ISO"
ls -lh "$INSTALLER_ISO"
