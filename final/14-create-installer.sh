#!/bin/bash
# final/14-create-installer.sh – Bootable ISO with xorriso direct + Branding
#   x86_64  : hybrid BIOS (isolinux) + UEFI (BOOTX64.EFI), isohybrid MBR
#   aarch64 : UEFI only (BOOTAA64.EFI) – arm64 has no BIOS and no isolinux
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

# builder.py exports LFS as its --output directory and looks for the ISO
# there: build(), sign_iso(), generate_sbom() and create_writable_media()
# all resolve output_dir/ISO_NAME, and so do nightly.yml, release.yml and
# xfce-live-boot-iso.yml.  The previous "$(dirname "$LFS")" wrote the ISO
# one level above all of them, so every profile built an image and every
# consumer reported none – Nightly #232's minimal job ran this stage for
# 28m22s, exited 0, and still logged "No ISO for this profile, skipping
# pointer".
INSTALLER_ISO="${LFS}/${ISO_NAME:-lfs-installer.iso}"

# The scratch tree has to stay OUTSIDE $LFS: mksquashfs below packs $LFS,
# so an iso-root/ or efi.img growing inside it would be packed into the
# very squashfs it feeds, while changing size under the reader.
SCRATCH_DIR="$(dirname "$LFS")"
ISO_ROOT="${SCRATCH_DIR}/iso-root"
EFI_IMG="${SCRATCH_DIR}/efi.img"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BRANDING_DIR="${LFS_CONFIG_BRANDING_DIR:-$REPO_ROOT/branding/installer}"

# Target architecture.  Same convention as blfs/28-knowledge.sh: builder.py
# flattens config/build.conf into LFS_CONFIG_*, and every workflow leg pins
# the target with --arch.  uname -m keeps the script usable by hand.
ARCH="${LFS_CONFIG_ARCHITECTURE:-${ARCH:-$(uname -m)}}"
case "$ARCH" in
arm64) ARCH="aarch64" ;;
esac
case "$ARCH" in
aarch64)
    GRUB_EFI_TARGET="arm64-efi"
    EFI_BINARY_NAME="BOOTAA64.EFI"
    ;;
x86_64)
    GRUB_EFI_TARGET="x86_64-efi"
    EFI_BINARY_NAME="BOOTX64.EFI"
    ;;
*)
    echo "[ERROR] Unsupported architecture '$ARCH' for the installer ISO."
    echo "        This stage builds x86_64 (BIOS+UEFI) and aarch64 (UEFI) images."
    exit 1
    ;;
esac

echo "[INFO] Creating bootable ISO from $LFS"
echo "[INFO] Architecture: $ARCH"
echo "[INFO] Output: $INSTALLER_ISO"
echo "[INFO] Branding directory: $BRANDING_DIR"

# Vérifier les outils.  Only the x86_64 path needs a loop-mounted FAT image
# to run grub-install against; arm64 uses grub-mkstandalone, which writes
# the EFI image straight out and so needs no mount and no root.
# unsquashfs is how the stage proves below that the boot-critical paths
# actually landed in the packed squashfs.
REQUIRED_TOOLS="xorriso mksquashfs unsquashfs python3"
if [ "$ARCH" = "aarch64" ]; then
    REQUIRED_TOOLS="$REQUIRED_TOOLS grub-mkstandalone"
else
    REQUIRED_TOOLS="$REQUIRED_TOOLS grub-install mkfs.vfat mount"
fi
for tool in $REQUIRED_TOOLS; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[ERROR] $tool not found. Please install."
        exit 1
    fi
done

# Nightly #228 lost the arm64 leg to "grub-install: error:
# /usr/lib/grub/x86_64-efi/modinfo.sh doesn't exist".  Name the package
# instead of leaving the reader to guess which one is missing.
if [ ! -f "/usr/lib/grub/${GRUB_EFI_TARGET}/modinfo.sh" ]; then
    echo "[ERROR] GRUB modules for ${GRUB_EFI_TARGET} are not installed."
    if [ "$ARCH" = "aarch64" ]; then
        echo "        Install them with: apt-get install grub-efi-arm64-bin"
    else
        echo "        Install them with: apt-get install grub-efi-amd64-bin"
    fi
    exit 1
fi

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

# Console parameters handed to the live/installer kernel by both bootloaders.
# Two console= options on purpose, and the order is the whole point: printk
# goes to EVERY registered console but /dev/console - where init and the boot
# scripts write - is the LAST one named, so the serial line has to come last
# for the QEMU smoke tests to see the userspace stream and not only the kernel
# log.  Without a serial console in the shipped cmdline those steps are blind
# by construction: they grep a serial log only the bootloader writes to.  The
# port differs by architecture: x86_64 has the 16550 at ttyS0, arm64 firmware
# exposes the PL011/AMA serial as ttyAMA0.
if [ "$ARCH" = "aarch64" ]; then
    CONSOLE_ARGS="console=tty0 console=ttyAMA0,115200"
else
    CONSOLE_ARGS="console=tty0 console=ttyS0,115200n8"
fi

# --- Isolinux BIOS payload helpers --------------------------------------
# syslinux 6.x splits its loader in two: isolinux.bin is a ~38 KiB first
# stage whose only job is to load ldlinux.c32 - the actual core - from the
# same directory on the boot media, and ldlinux.c32 in turn loads
# libcom32.c32.  An ISO that ships isolinux.bin alone prints its banner and
# then dies with "Failed to load ldlinux.c32 / Boot failed: press a key to
# retry...", which is what the images built by final/14 and final/15 did:
# the modules were never copied at all here, and the loader was looked for
# in the Debian path only.  Distributions install the payload under
# different prefixes, so probe them all and fail loudly when none carries
# it rather than ship an ISO no firmware can boot.
ISOLINUX_DIRS=(
    /usr/lib/ISOLINUX
    /usr/lib/syslinux/modules/bios
    /usr/lib/syslinux/bios
    /usr/lib/syslinux
    /usr/share/syslinux
)

isolinux_file() {
    local name="$1" dir
    for dir in "${ISOLINUX_DIRS[@]}"; do
        if [ -f "$dir/$name" ]; then
            echo "$dir/$name"
            return 0
        fi
    done
    return 1
}

# Every file the BIOS boot path needs, copied into the isolinux directory of
# the image.  libutil.c32 is not loaded by this config but is part of the
# module set ldlinux expects to find beside it, and costs 25 KiB.
isolinux_payload() {
    local dest="$1" src name
    for name in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32; do
        if ! src=$(isolinux_file "$name"); then
            echo "[ERROR] $name not found on this host."
            echo "        Install it: apt install isolinux syslinux-common,"
            echo "        dnf install syslinux, or pacman -S syslinux."
            return 1
        fi
        cp -v "$src" "$dest/"
    done
}

# Préparer la racine de l'ISO
rm -rf "$ISO_ROOT"
mkdir -p "$ISO_ROOT"/{boot/grub,EFI/BOOT}
# isolinux is the x86 BIOS boot loader; arm64 firmware is UEFI only.
if [ "$ARCH" != "aarch64" ]; then
    mkdir -p "$ISO_ROOT/isolinux"
fi

cp -v "$KERNEL" "$ISO_ROOT/boot/vmlinuz"
cp -v "$INITRAMFS" "$ISO_ROOT/boot/initramfs.img"

# Créer le squashfs (taille > 4 Go)
# ---------------------------------------------------------------------------
# Static device nodes in the packed rootfs (see final/15 for the rationale:
# the live root needs /dev/console and /dev/null before any boot script
# runs, and the 0.57.4 images shipped an empty /dev because mksquashfs
# excluded dev/*).
# ---------------------------------------------------------------------------
if mountpoint -q "$LFS/dev"; then
    $SUDO umount "$LFS/dev" || {
        echo "[ERROR] $LFS/dev is a live mount; refusing to pack it" >&2
        exit 1
    }
fi
$SUDO mkdir -p "$LFS/dev"
while read -r node type major minor mode; do
    if [ ! -e "$LFS/dev/$node" ]; then
        $SUDO mknod -m "$mode" "$LFS/dev/$node" "$type" "$major" "$minor"
    fi
done <<'NODES'
console c 5 1 600
tty     c 5 0 666
null    c 1 3 666
zero    c 1 5 666
random  c 1 8 666
urandom c 1 9 666
NODES

# ---------------------------------------------------------------------------
# The cgroup v2 mountpoint in the packed rootfs.  Same hole as final/15: the
# squashfs excluded "sys/*", so /sys/fs/cgroup did not exist in the image,
# mountvirtfs' mkdir returns EPERM once sysfs is mounted, and systemd as PID 1
# aborts with "Failed to mount cgroup v1 hierarchy / Freezing execution".  See
# final/15-create-live-system.sh for the full write-up.
# ---------------------------------------------------------------------------
if mountpoint -q "$LFS/sys"; then
    $SUDO umount "$LFS/sys" || {
        echo "[ERROR] $LFS/sys is a live mount; refusing to pack it" >&2
        exit 1
    }
fi
$SUDO mkdir -p "$LFS/sys/fs/cgroup"
for entry in "$LFS"/sys/* "$LFS"/sys/fs/*; do
    [ -e "$entry" ] || continue
    case "${entry##*/}" in
    fs | cgroup) ;;
    *)
        echo "[ERROR] unexpected content under $LFS/sys: $entry" >&2
        echo "        Only the empty sys/fs/cgroup mountpoint may be packed."
        exit 1
        ;;
    esac
done

# ---------------------------------------------------------------------------
# Live-media fstab and /fastboot.  Same hole as final/15, same rationale over
# there: rcS.d's S20swap, S30checkfs and S40mountfs all read /etc/fstab, which
# still carries the installer placeholders `/dev/<xxx>` and `/dev/<yyy>` on the
# media (only Calamares substitutes them, on the target), and checkfs cannot
# remount a squashfs-plus-overlay root read-only.  Each one parks this boot.
# ---------------------------------------------------------------------------
$SUDO touch "$LFS/fastboot"
if [ -f "$LFS/etc/fstab" ] && grep -q '^/dev/<' "$LFS/etc/fstab"; then
    FSTAB_TMP=$(mktemp)
    if ! sed -E 's|^(/dev/<[^>]+>[[:space:]].*)|# live media: \1|' \
        "$LFS/etc/fstab" >"$FSTAB_TMP"; then
        echo "[ERROR] Could not rewrite $LFS/etc/fstab for the live media." >&2
        rm -f "$FSTAB_TMP"
        exit 1
    fi
    if ! $SUDO cp "$FSTAB_TMP" "$LFS/etc/fstab"; then
        echo "[ERROR] Could not install the rewritten $LFS/etc/fstab." >&2
        rm -f "$FSTAB_TMP"
        exit 1
    fi
    $SUDO chmod 0644 "$LFS/etc/fstab"
    rm -f "$FSTAB_TMP"
    echo "[INFO] Live media: installer fstab placeholders disabled"
fi

# And one runlevel further: lfs/07 writes /etc/sysconfig/ifconfig.eth0 for
# sysvinit with the book's example ONBOOT=yes and IFACE=eth0, init.d/network
# runs ifup for every ifconfig.* by name, and on the media udev has renamed
# the NIC (enp0s3), so `ip link set eth0 up` fails and rc parks runlevel 5 at
# "Press Enter to continue...".  ONBOOT is the book's own switch (ifup line 94
# exits 0 when booting with ONBOOT != yes); a live session must not claim a
# hard-coded private address on the host's LAN either.
for cfg in "$LFS"/etc/sysconfig/ifconfig.*; do
    [ -f "$cfg" ] || continue
    if grep -q '^ONBOOT=yes' "$cfg"; then
        IFCFG_TMP=$(mktemp)
        if ! sed -E 's|^ONBOOT=yes|ONBOOT=no|' "$cfg" >"$IFCFG_TMP"; then
            echo "[ERROR] Could not rewrite $cfg for the live media." >&2
            rm -f "$IFCFG_TMP"
            exit 1
        fi
        if ! $SUDO cp "$IFCFG_TMP" "$cfg"; then
            echo "[ERROR] Could not install the rewritten $cfg." >&2
            rm -f "$IFCFG_TMP"
            exit 1
        fi
        rm -f "$IFCFG_TMP"
        echo "[INFO] Live media: ${cfg##*/} auto-start disabled"
    fi
done

echo "[INFO] Creating squashfs..."
# $LFS is the rootfs *and* the build's output directory, so the scaffolding
# has to be named or it gets packed – sources/ alone is a thousand tarballs,
# and Nightly #232 spent most of this stage's 28m22s compressing them on the
# minimal profile.  Excluding "dir/*" rather than "dir" leaves the empty
# directory behind, which matters for /proc, /sys and /run: busybox
# switch_root moves those mounts into the new root and fails outright
# when the mount points are absent.  /dev is the exception: it is packed
# with the static nodes created above.  "*.iso" keeps this stage's own output –
# and that of a previous --resume-from installer run – out of the image it
# is building.  Same list nightly.yml uses for the rootfs tarball.
# /sys keeps only the empty sys/fs/cgroup mountpoint created above; "sys/*"
# used to be excluded here, and a wildcard matching a directory prunes its
# whole subtree, which is how every 0.57.4 image shipped without the cgroup2
# mountpoint.
mksquashfs "$LFS" "$ISO_ROOT/live.squashfs" -comp xz -noappend \
    -wildcards \
    -e "proc/*" "run/*" "tmp/*" "lost+found/*" \
    "sources/*" "logs/*" "cache/*" "backups/*" "live/*" "image/*" \
    "tools/*" "packages/*" "lpm-repo/*" "sysroot/*" \
    "*.iso" "*.iso.sig"

# Prove the boot-critical paths landed in the image: mksquashfs exits 0 no
# matter what its wildcards pruned.
LIVE_TREE=$(unsquashfs -no-progress -ls "$ISO_ROOT/live.squashfs" 2>/dev/null)
for need in squashfs-root/dev/console squashfs-root/dev/null \
    squashfs-root/fastboot squashfs-root/sys/fs/cgroup; do
    if ! printf '%s\n' "$LIVE_TREE" | grep -qx "$need"; then
        echo "[ERROR] The installer squashfs carries no /${need#squashfs-root}."
        echo "        The live session cannot boot without it; an -e wildcard"
        echo "        here prunes the whole subtree silently."
        exit 1
    fi
done
# -cat takes paths relative to the image root, unlike the -ls listing above.
if unsquashfs -no-progress -cat "$ISO_ROOT/live.squashfs" etc/fstab \
    2>/dev/null | grep -q '^/dev/<'; then
    echo "[ERROR] The packed /etc/fstab still carries the installer"
    echo "        placeholders: S20swap, S30checkfs and S40mountfs fail on a"
    echo "        device node that does not exist and park the live boot."
    exit 1
fi
# And no packed interface may auto-start on the media either.
for packed in $(printf '%s\n' "$LIVE_TREE" |
    grep '^squashfs-root/etc/sysconfig/ifconfig\.'); do
    if unsquashfs -no-progress -cat "$ISO_ROOT/live.squashfs" \
        "${packed#squashfs-root/}" 2>/dev/null | grep -q '^ONBOOT=yes'; then
        echo "[ERROR] $packed still auto-starts on the live media."
        echo "        ifup fails on a NIC udev has renamed and rc parks"
        echo "        runlevel 5 at 'Press Enter to continue...'."
        exit 1
    fi
done
echo "[INFO] Installer rootfs boot paths verified in the squashfs"

# Load branding and ensure images exist
load_branding_config
ensure_branding_images

# Fichier grub.cfg (utilisé par BIOS et UEFI) - WITH BRANDING
GRUB_CFG="$ISO_ROOT/boot/grub/grub.cfg"
cat >"$GRUB_CFG" <<EOF
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
EOF
# vbe drives the x86 BIOS video services.  arm64 firmware is UEFI only, so
# the module does not exist there and insmod'ing it makes GRUB report an
# error and stop reading the file – taking the menu entries below with it.
if [ "$ARCH" != "aarch64" ]; then
    echo "    insmod vbe" >>"$GRUB_CFG"
fi
cat >>"$GRUB_CFG" <<EOF
    set gfxpayload=keep
    background_image (cd)/branding/backgrounds/grub-background.png
fi

# root= names the device the initramfs mounts in order to find live.squashfs
# on it, so it has to be the boot media itself.  /dev/loop0 – what these two
# entries used to say – is the loop node the initramfs only creates *after*
# it has found the squashfs, so neither entry could ever boot: the initramfs
# polled ten seconds for a loop device, probed its disk candidates and
# dropped to a shell with "Root device not found".  final/15 has always said
# /dev/sr0.
menuentry "LFS Linux Live" {
    linux /boot/vmlinuz root=/dev/sr0 ro quiet ${CONSOLE_ARGS}
    initrd /boot/initramfs.img
}
menuentry "Install LFS Linux" {
    linux /boot/vmlinuz root=/dev/sr0 ro quiet install ${CONSOLE_ARGS}
    initrd /boot/initramfs.img
}
EOF
# "chainloader +1" loads the first BIOS boot sector; arm64 has no MBR to
# chain to, and GRUB's chainloader is not built for arm64-efi at all.
if [ "$ARCH" != "aarch64" ]; then
    cat >>"$GRUB_CFG" <<'EOF'
menuentry "Boot from hard disk" {
    chainloader +1
}
EOF
fi

# Install branding assets into ISO
install_branding_assets

if [ "$ARCH" = "aarch64" ]; then
    # --- CHARGEUR UEFI arm64 ---
    # grub-mkstandalone packs grub.cfg into a memdisk inside the EFI image,
    # so booting does not depend on GRUB's iso9660 driver finding
    # /boot/grub/grub.cfg on the media, and no dd/mkfs.vfat/loop mount is
    # needed – which is what lets the stage run as the unprivileged builder
    # user (AGENTS.md: compile and assemble as non-root).
    echo "[INFO] Creating arm64 UEFI boot image with grub-mkstandalone..."
    grub-mkstandalone -O "$GRUB_EFI_TARGET" \
        -o "$ISO_ROOT/EFI/BOOT/$EFI_BINARY_NAME" \
        "boot/grub/grub.cfg=$GRUB_CFG"
else
    # --- CRÉER L'IMAGE EFI (FAT avec GRUB) ---
    echo "[INFO] Creating EFI boot image..."
    EFI_MOUNT="${SCRATCH_DIR}/efi-mount"
    EFI_EXTRACT="${SCRATCH_DIR}/efi-extract"
    mkdir -p "$EFI_MOUNT"

    # Image FAT de 64 Mo
    dd if=/dev/zero of="$EFI_IMG" bs=1M count=64 2>/dev/null
    mkfs.vfat "$EFI_IMG" 2>/dev/null

    # Monter l'image avec sudo si nécessaire
    $SUDO mount -o loop "$EFI_IMG" "$EFI_MOUNT"

    # Installer GRUB pour EFI dans l'image
    $SUDO grub-install --target="$GRUB_EFI_TARGET" \
        --efi-directory="$EFI_MOUNT" \
        --boot-directory="$EFI_MOUNT/boot" \
        --removable \
        --modules="part_gpt fat" \
        --no-floppy

    # Copier notre grub.cfg
    mkdir -p "$EFI_MOUNT/boot/grub"
    $SUDO cp "$GRUB_CFG" "$EFI_MOUNT/boot/grub/"

    # Démonter et nettoyer
    $SUDO umount "$EFI_MOUNT"
    rmdir "$EFI_MOUNT"

    # Copier l'image EFI dans l'ISO (comme fichier)
    # Extract the actual EFI binary from the FAT image
    mkdir -p "$EFI_EXTRACT"
    $SUDO mount -o loop "$EFI_IMG" "$EFI_EXTRACT"
    EFI_BINARY=$(find "$EFI_EXTRACT" -name "grubx64.efi" -o -name "$EFI_BINARY_NAME" 2>/dev/null | head -1)
    if [ -n "$EFI_BINARY" ]; then
        cp "$EFI_BINARY" "$ISO_ROOT/EFI/BOOT/$EFI_BINARY_NAME"
        echo "[INFO] EFI binary extracted from FAT image"
    else
        # Fallback: copy the whole FAT image (not ideal but works for some firmware)
        cp "$EFI_IMG" "$ISO_ROOT/EFI/BOOT/$EFI_BINARY_NAME"
        echo "[WARNING] No EFI binary found in FAT image – using raw image as fallback"
    fi
    $SUDO umount "$EFI_EXTRACT"
    rmdir "$EFI_EXTRACT"

    # --- PRÉPARER ISOLINUX POUR LE BOOT BIOS ---
    # isolinux is an x86 BIOS loader: arm64 firmware is UEFI only, so this
    # whole block stays out of the aarch64 arm.
    isolinux_payload "$ISO_ROOT/isolinux" || exit 1

    # The isohybrid MBR is what makes the same image usable as a stick.
    # xorriso would abort on a missing file anyway, but only after the
    # squashfs has been packed, so resolve it before the build starts.
    ISOHDPFX=$(isolinux_file isohdpfx.bin) || ISOHDPFX=""
    if [ -z "$ISOHDPFX" ]; then
        echo "[ERROR] isohdpfx.bin not found: no hybrid MBR can be written."
        echo "        It ships with isolinux (Debian/Ubuntu) or syslinux."
        exit 1
    fi

    cat >"$ISO_ROOT/isolinux/isolinux.cfg" <<EOF
default live
timeout 10
label live
    kernel /boot/vmlinuz
    append initrd=/boot/initramfs.img root=/dev/sr0 ro quiet ${CONSOLE_ARGS}
label install
    kernel /boot/vmlinuz
    append initrd=/boot/initramfs.img root=/dev/sr0 ro quiet install ${CONSOLE_ARGS}
EOF
fi

# --- CONSTRUIRE L'ISO AVEC XORRISO (ISO LEVEL 4) ---
echo "[INFO] ISO Label: $ISO_LABEL"
if [ "$ARCH" = "aarch64" ]; then
    # UEFI-only El Torito: -e is the *primary* boot entry, so there is no
    # -eltorito-alt-boot, and none of the isohybrid options apply – they
    # write an x86 MBR and GPT that arm64 firmware never reads.
    echo "[INFO] Building UEFI-only ISO with xorriso (arm64, ISO level 4)..."
    xorriso -as mkisofs \
        -iso-level 4 \
        -V "$ISO_LABEL" \
        -p "${ISO_PUBLISHER:-Beyond Linux From Scratch}" \
        -publisher "${ISO_PUBLISHER:-Beyond Linux From Scratch}" \
        -R -J -joliet-long \
        -cache-inodes \
        -e "EFI/BOOT/$EFI_BINARY_NAME" \
        -no-emul-boot \
        -o "$INSTALLER_ISO" "$ISO_ROOT"
else
    echo "[INFO] Building ISO with xorriso (BIOS+UEFI, ISO level 4)..."
    xorriso -as mkisofs \
        -iso-level 4 \
        -V "$ISO_LABEL" \
        -p "${ISO_PUBLISHER:-Beyond Linux From Scratch}" \
        -publisher "${ISO_PUBLISHER:-Beyond Linux From Scratch}" \
        -R -J -joliet-long \
        -cache-inodes \
        -isohybrid-mbr "$ISOHDPFX" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -boot-load-size 4 -boot-info-table -no-emul-boot \
        -eltorito-alt-boot -e "EFI/BOOT/$EFI_BINARY_NAME" -no-emul-boot \
        -isohybrid-gpt-basdat \
        -o "$INSTALLER_ISO" "$ISO_ROOT"
fi

# --- VÉRIFIER L'ENTRÉE DE BOOT ---
# xorriso accepts an -e path that is absent from the tree and then writes an
# ISO with no usable El Torito record at all, so read the loader back out of
# the finished image.  Every GRUB EFI image is a PE/COFF file and starts
# "MZ"; the x86 fallback above copies a whole FAT image instead, which also
# starts "MZ", so this catches a missing entry without rejecting it.
VERIFY_EFI="${SCRATCH_DIR}/verify-efi.bin"
rm -f "$VERIFY_EFI"
if xorriso -osirrox on -indev "$INSTALLER_ISO" \
    -extract "/EFI/BOOT/$EFI_BINARY_NAME" "$VERIFY_EFI" >/dev/null 2>&1 &&
    [ "$(head -c 2 "$VERIFY_EFI" 2>/dev/null)" = "MZ" ]; then
    echo "[SUCCESS] El Torito entry verified: EFI/BOOT/$EFI_BINARY_NAME"
else
    echo "[ERROR] $INSTALLER_ISO carries no bootable EFI/BOOT/$EFI_BINARY_NAME"
    rm -f "$VERIFY_EFI" "$INSTALLER_ISO"
    exit 1
fi

# --- VÉRIFIER LE PAYLOAD BIOS ---
# Same reasoning as the El Torito check above, and the same blind spot:
# xorriso exits 0 on an incomplete payload, and tools/qemu-boot-smoke.sh
# boots with -kernel/-initrd so it never runs isolinux.  An installer ISO
# without ldlinux.c32 is unbootable on every BIOS machine.
if [ "$ARCH" != "aarch64" ]; then
    VERIFY_BOOT="${SCRATCH_DIR}/verify-boot-payload.bin"
    for need in isolinux.bin ldlinux.c32 libcom32.c32; do
        rm -f "$VERIFY_BOOT"
        if ! xorriso -osirrox on -indev "$INSTALLER_ISO" \
            -extract "/isolinux/$need" "$VERIFY_BOOT" >/dev/null 2>&1 ||
            [ ! -s "$VERIFY_BOOT" ]; then
            echo "[ERROR] $INSTALLER_ISO carries no /isolinux/$need; it cannot boot."
            rm -f "$VERIFY_BOOT" "$INSTALLER_ISO"
            exit 1
        fi
    done
    rm -f "$VERIFY_BOOT"
    echo "[INFO] BIOS boot payload verified in image"
fi

# Nettoyer
rm -rf "$ISO_ROOT" "$EFI_IMG" "$VERIFY_EFI"
echo "[SUCCESS] ISO created at $INSTALLER_ISO"
ls -lh "$INSTALLER_ISO"
