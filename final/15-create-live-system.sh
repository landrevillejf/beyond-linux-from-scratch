#!/bin/bash
# final/15-create-live-system.sh
# Create a live system with squashfs and hybrid ISO (BIOS+UEFI)
# Author: Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

LFS="${LFS:-/output/image}"
# builder.py exports LFS as its --output directory, and every consumer of the
# image resolves output_dir/ISO_NAME – build(), sign_iso(), generate_sbom(),
# create_writable_media() and the nightly/release/xfce-live workflows alike.
# The old "$(dirname "$LFS")" wrote it one level above all of them, so the
# live ISO was built and then reported missing (Nightly #232).
ISO_OUT="${LFS}/${ISO_NAME:-lfs-installer.iso}"
# Scratch stays outside $LFS: mksquashfs packs $LFS, so a live.squashfs or
# an iso-content/ growing inside it would be packed into itself.
SCRATCH_DIR="$(dirname "$LFS")"
SQUASHFS="${SCRATCH_DIR}/live.squashfs"

# Paramètres du builder
COMPRESSION="${LFS_CONFIG_LIVE_SYSTEM_SQUASHFS_COMPRESSION:-xz}"
PERSISTENCE_SUPPORT="${LFS_CONFIG_LIVE_SYSTEM_PERSISTENCE_SUPPORT:-true}"
DEFAULT_BOOT="${LFS_CONFIG_LIVE_SYSTEM_DEFAULT_BOOT:-live}"

# This stage builds an x86 hybrid: isolinux for BIOS, an isohybrid MBR and
# GPT, and an x86 BCJ filter for the squashfs.  No aarch64 profile enables
# live_system – arm64/pinebook/brax3 ship the UEFI installer ISO from
# final/14 plus a rootfs tarball – so fail loudly here rather than write an
# image arm64 firmware cannot boot and nobody would notice until it shipped.
ARCH="${LFS_CONFIG_ARCHITECTURE:-${ARCH:-$(uname -m)}}"
case "$ARCH" in
arm64) ARCH="aarch64" ;;
esac
if [ "$ARCH" = "aarch64" ]; then
    echo "[ERROR] The live ISO stage is x86_64-only (isolinux + isohybrid MBR)."
    echo "        aarch64 targets get the UEFI installer ISO from final/14."
    exit 1
fi

echo "[INFO] Creating live system (squashfs + ISO)..."
echo "[INFO] Compression: $COMPRESSION, Persistence: $PERSISTENCE_SUPPORT, Default boot: $DEFAULT_BOOT"

# Vérifier les outils nécessaires
for tool in mksquashfs xorriso; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[ERROR] $tool not found. Please install it."
        exit 1
    fi
done

# Trouver noyau et initramfs
KERNEL=$(find "$LFS/boot" -name "vmlinuz-*" -type f 2>/dev/null | head -1)
if [ -z "$KERNEL" ]; then
    echo "[ERROR] Kernel not found in $LFS/boot"
    exit 1
fi
INITRAMFS="$LFS/boot/initramfs.img"
if [ ! -f "$INITRAMFS" ]; then
    echo "[ERROR] Initramfs not found: $INITRAMFS"
    exit 1
fi

echo "[INFO] Kernel: $KERNEL"
echo "[INFO] Initramfs: $INITRAMFS"

# Créer le squashfs
echo "[INFO] Creating squashfs (compression: $COMPRESSION)..."
# $LFS is the rootfs *and* the build's output directory, so the scaffolding
# has to be named or it gets packed.  "dir/*" rather than "dir" leaves the
# empty directory behind, which matters for /dev, /proc, /sys and /run:
# busybox switch_root moves those four mounts into the new root and fails
# outright when the mount points are absent.  "*.iso" is what keeps the
# installer ISO final/14 wrote into $LFS – and this stage's own output on a
# --resume-from live-system run – out of the image being built.
mksquashfs "$LFS" "$SQUASHFS" \
    -comp "$COMPRESSION" -Xbcj x86 -b 1M \
    -wildcards \
    -e "proc/*" "sys/*" "dev/*" "run/*" "tmp/*" "lost+found/*" \
    "sources/*" "logs/*" "cache/*" "backups/*" "live/*" "image/*" \
    "tools/*" "packages/*" "lpm-repo/*" "sysroot/*" \
    "*.iso" "*.iso.sig"

# Préparer l'arborescence ISO
ISO_DIR="${SCRATCH_DIR}/iso-content"
rm -rf "$ISO_DIR"
mkdir -pv "$ISO_DIR"/{isolinux,boot/grub,EFI/BOOT}

cp -v "$KERNEL" "$ISO_DIR/isolinux/vmlinuz"
cp -v "$INITRAMFS" "$ISO_DIR/isolinux/initrd.img"
cp -v "$SQUASHFS" "$ISO_DIR/live.squashfs"

# Isolinux
ISOLINUX_BIN="/usr/lib/ISOLINUX/isolinux.bin"
[ -f "$ISOLINUX_BIN" ] || ISOLINUX_BIN="/usr/lib/syslinux/isolinux.bin"
if [ ! -f "$ISOLINUX_BIN" ]; then
    echo "[ERROR] isolinux.bin not found"
    exit 1
fi
cp -v "$ISOLINUX_BIN" "$ISO_DIR/isolinux/"

# Modules isolinux (optionnel)
if [ -d "/usr/lib/syslinux/modules/bios" ]; then
    cp -v /usr/lib/syslinux/modules/bios/*.c32 "$ISO_DIR/isolinux/" 2>/dev/null || true
fi

# Configuration isolinux
cat >"$ISO_DIR/isolinux/isolinux.cfg" <<EOF
default ${DEFAULT_BOOT}
label live
  kernel vmlinuz
  append initrd=initrd.img root=/dev/sr0 ro quiet
label live-verbose
  kernel vmlinuz
  append initrd=initrd.img root=/dev/sr0 ro
EOF

# EFI
EFI_FILE="$LFS/boot/efi/EFI/BOOT/BOOTX64.EFI"
if [ -f "$EFI_FILE" ]; then
    echo "[INFO] Found EFI bootloader, including UEFI support"
    cp -v "$EFI_FILE" "$ISO_DIR/EFI/BOOT/"
    EFI_OPTION="-eltorito-alt-boot -e EFI/BOOT/BOOTX64.EFI -no-emul-boot -isohybrid-gpt-basdat"
else
    echo "[WARNING] No EFI bootloader found – building BIOS-only ISO"
    EFI_OPTION=""
fi

# Construction de l'ISO
echo "[INFO] Building ISO..."
if [ -n "$EFI_OPTION" ]; then
    xorriso -as mkisofs \
        -iso-level 4 \
        -r -V "LFS_LIVE" \
        -J -joliet-long \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -boot-load-size 4 -boot-info-table -no-emul-boot \
        $EFI_OPTION \
        -o "$ISO_OUT" "$ISO_DIR"
else
    xorriso -as mkisofs \
        -iso-level 4 \
        -r -V "LFS_LIVE" \
        -J -joliet-long \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -boot-load-size 4 -boot-info-table -no-emul-boot \
        -o "$ISO_OUT" "$ISO_DIR"
fi

# Nettoyage
rm -rf "$ISO_DIR" "$SQUASHFS"

echo "[SUCCESS] Live ISO created at $ISO_OUT"
ls -lh "$ISO_OUT"
