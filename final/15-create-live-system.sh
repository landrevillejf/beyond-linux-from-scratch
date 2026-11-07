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
# This is deliberately the same path final/14 wrote its installer ISO to.  On a
# live profile (lg3d) the live image IS the deliverable -- the user boots it and
# runs Calamares in-session -- so final/15 supersedes final/14 rather than
# shipping two ISOs.  Both stages are now hybrid BIOS+UEFI, so the overwrite no
# longer downgrades the image to BIOS-only (the reason no lg3d ISO booted on
# UEFI for 8 months).  Do NOT rename this path: the publish steps in
# lg3d.yml/nightly.yml/release.yml all resolve build-release/${ISO_NAME}, and a
# rename would silently drop the release asset.
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

# Vérifier les outils nécessaires.  UEFI is mandatory, not optional: the live
# ISO is the lg3d deliverable and a BIOS-only image cannot boot on the UEFI
# firmware every modern machine has.  mkfs.vfat (dosfstools) + mmd/mcopy
# (mtools) build the FAT16 ESP without a sudo loop mount, so the stage stays
# runnable as the unprivileged builder user.
# unsquashfs is not only the packing tool's counterpart, it is how the stage
# proves below that the boot-critical paths actually landed in the image.
for tool in mksquashfs unsquashfs xorriso mkfs.vfat mmd mcopy; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[ERROR] $tool not found. Please install it."
        echo "        Debian/Ubuntu: apt install squashfs-tools xorriso dosfstools mtools"
        echo "        Fedora:        dnf install squashfs-tools xorriso dosfstools mtools"
        exit 1
    fi
done

# grub-mkstandalone embeds grub.cfg + all modules into one self-contained
# BOOTX64.EFI (no prefix/module dir to go missing at boot); Fedora names it
# grub2-mkstandalone.  Resolve either, then require the x86_64-efi modules it
# packs from.  final/15 used to *consume* a pre-existing
# $LFS/boot/efi/EFI/BOOT/BOOTX64.EFI that nothing ever created in CI, warn, and
# silently ship a BIOS-only ISO -- the reason no lg3d image booted on UEFI.
GRUB_MKSTANDALONE=""
for cand in grub-mkstandalone grub2-mkstandalone; do
    if command -v "$cand" >/dev/null 2>&1; then
        GRUB_MKSTANDALONE="$cand"
        break
    fi
done
if [ -z "$GRUB_MKSTANDALONE" ]; then
    echo "[ERROR] grub-mkstandalone not found: cannot build the UEFI boot image."
    echo "        Debian/Ubuntu: apt install grub-efi-amd64-bin"
    echo "        Fedora:        dnf install grub2-tools-extra grub2-efi-x64-modules"
    exit 1
fi
if [ ! -f /usr/lib/grub/x86_64-efi/modinfo.sh ]; then
    echo "[ERROR] GRUB x86_64-efi modules are not installed."
    echo "        Debian/Ubuntu: apt install grub-efi-amd64-bin"
    echo "        Fedora:        dnf install grub2-efi-x64-modules"
    exit 1
fi

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

# ---------------------------------------------------------------------------
# Static device nodes in the packed rootfs
#
# The live root switches straight from the initramfs into this tree before
# any boot script runs: sysvinit opens /dev/console for its own logging and
# the S-stage scripts redirect to /dev/null, so those nodes must exist in
# the squashfs itself - devtmpfs only comes back once rcS runs mountvirtfs.
# The 0.57.4 images excluded dev/* from mksquashfs and no stage ever created
# the nodes, which left every sysvinit live boot silent and dead right after
# switch_root (nightly 20261105, VirtualBox and QEMU reproductions).
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then SUDO=sudo; else SUDO=""; fi
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
# The cgroup v2 mountpoint in the packed rootfs
#
# rcS.d/S00mountvirtfs (the book script) does `mkdir -p /sys/fs/cgroup` and
# then mounts cgroup2 there, and systemd mounts it itself as PID 1.  Both need
# the directory to exist in the rootfs: once sysfs is mounted, mkdir inside it
# returns EPERM, so the mountpoint cannot be created at boot time.  The
# 0.57.4 live images packed no /sys/fs/cgroup at all -- "sys/*" was in the
# mksquashfs exclude list, and a wildcard that matches a directory prunes its
# whole subtree -- so sysvinit aborted with "cannot create directory
# '/sys/fs/cgroup': Operation not permitted" plus "unknown filesystem type
# 'cgroup2'" and systemd logged "Freezing execution" (lg3d nightly 20261106,
# reproduced in QEMU against the published ISO, both firmware modes).
#
# Dropping "sys/*" from the excludes is only safe because the live-mount guard
# below refuses to pack a mounted sysfs and the two stray checks refuse to
# pack anything under /sys other than the empty cgroup path.
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
# The live media must not obey the installer fstab, nor fsck its own root
#
# rcS.d carries S20swap, S30checkfs and S40mountfs (bootscripts Makefile lines
# 80-82) and all three read /etc/fstab: swap runs `swapon -a`, checkfs runs
# `mount -n -o remount,ro /` then `fsck -A`, mountfs runs `mount --all`.  On
# the live media every one of them is fatal.  lfs/07 deliberately leaves the
# installer placeholders `/dev/<xxx> / <fff>` and `/dev/<yyy> swap` in
# /etc/fstab - only the installer substitutes them, and blfs/22 has Calamares
# regenerate the target's fstab - so swapon, fsck and mount all fail on a
# device node that does not exist.  checkfs cannot even reach fsck: remounting
# a squashfs lower plus tmpfs upper read-only fails, which sends it down its
# "Press Enter to continue..." + halt branch, and rc parks the boot.  That is
# the same wall the cgroup fix moved, one script later.
#
# Two live-media-only changes:
#   * comment the placeholder lines out in the tree being packed;
#   * create /fastboot, the book's own switch that makes checkfs exit 0 before
#     the remount and the fsck.  mountfs deletes it during that same boot (its
#     line 40), so an installed target loses it after first boot and fsck runs
#     normally from then on, while on the live session the removal only touches
#     the tmpfs overlay.
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

# The same trap one runlevel further: /etc/sysconfig/ifconfig.eth0 is written
# by lfs/07 for sysvinit with the book's example ONBOOT=yes, IFACE=eth0 and a
# static 192.168.1.2.  rc exports IN_BOOT=1 (its line 177), so init.d/network
# runs ifup for every ifconfig.* file it finds, and ifup brings $IFACE up by
# name.  On the media the NIC is renamed by udev (enp0s3, not eth0), so `ip
# link set eth0 up` fails, the for loop in init.d/network hands that status
# back, and rc parks runlevel 5 at the same "Press Enter to continue...".
# ONBOOT is the book's own switch for it (ifup line 94 exits 0 when booting
# and ONBOOT is not yes), and a live session has no business claiming a
# hard-coded private address on the host's LAN anyway.
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

# Créer le squashfs
echo "[INFO] Creating squashfs (compression: $COMPRESSION)..."
# $LFS is the rootfs *and* the build's output directory, so the scaffolding
# has to be named or it gets packed.  "dir/*" rather than "dir" leaves the
# empty directory behind, which matters for /proc, /sys and /run: busybox
# switch_root moves those mounts into the new root and fails outright when
# the mount points are absent.  /dev is the exception: it is packed with
# the static nodes created above, because the live root needs them before
# any boot script runs.  /sys is the other exception, for the same reason:
# only the empty sys/fs/cgroup mountpoint is there, guarded above, because
# cgroup2 cannot be mounted without it.  "*.iso" is what keeps the
# installer ISO final/14 wrote into $LFS – and this stage's own output on a
# --resume-from live-system run – out of the image being built.
mksquashfs "$LFS" "$SQUASHFS" \
    -comp "$COMPRESSION" -Xbcj x86 -b 1M \
    -wildcards \
    -e "proc/*" "run/*" "tmp/*" "lost+found/*" \
    "sources/*" "logs/*" "cache/*" "backups/*" "live/*" "image/*" \
    "tools/*" "packages/*" "lpm-repo/*" "sysroot/*" \
    "*.iso" "*.iso.sig"

# Prove the boot-critical paths landed in the image.  mksquashfs exits 0 no
# matter what its wildcards pruned, and the smoke tests boot through paths
# that cannot see this, so a missing node or mountpoint used to reach the
# release silently.  One listing pass, exact-match on every required path.
LIVE_TREE=$(unsquashfs -no-progress -ls "$SQUASHFS" 2>/dev/null)
for need in squashfs-root/dev/console squashfs-root/dev/null \
    squashfs-root/fastboot squashfs-root/sys/fs/cgroup; do
    if ! printf '%s\n' "$LIVE_TREE" | grep -qx "$need"; then
        echo "[ERROR] $SQUASHFS carries no /${need#squashfs-root}."
        echo "        The live session cannot boot without it; an -e wildcard"
        echo "        here prunes the whole subtree silently."
        exit 1
    fi
done
# -cat takes paths relative to the image root, unlike the -ls listing above.
if unsquashfs -no-progress -cat "$SQUASHFS" etc/fstab 2>/dev/null |
    grep -q '^/dev/<'; then
    echo "[ERROR] The packed /etc/fstab still carries the installer"
    echo "        placeholders: S20swap, S30checkfs and S40mountfs fail on a"
    echo "        device node that does not exist and park the live boot."
    exit 1
fi
# And no packed interface may auto-start on the media either.
for packed in $(printf '%s\n' "$LIVE_TREE" |
    grep '^squashfs-root/etc/sysconfig/ifconfig\.'); do
    if unsquashfs -no-progress -cat "$SQUASHFS" "${packed#squashfs-root/}" \
        2>/dev/null | grep -q '^ONBOOT=yes'; then
        echo "[ERROR] $packed still auto-starts on the live media."
        echo "        ifup fails on a NIC udev has renamed and rc parks"
        echo "        runlevel 5 at 'Press Enter to continue...'."
        exit 1
    fi
done
echo "[INFO] Live rootfs boot paths verified in the squashfs"

# Préparer l'arborescence ISO
ISO_DIR="${SCRATCH_DIR}/iso-content"
rm -rf "$ISO_DIR"
mkdir -pv "$ISO_DIR"/isolinux

cp -v "$KERNEL" "$ISO_DIR/isolinux/vmlinuz"
cp -v "$INITRAMFS" "$ISO_DIR/isolinux/initrd.img"
cp -v "$SQUASHFS" "$ISO_DIR/live.squashfs"

# --- Isolinux BIOS payload -----------------------------------------------
# syslinux 6.x splits its loader in two: isolinux.bin is a ~38 KiB first
# stage whose only job is to load ldlinux.c32 - the actual core - from the
# same directory on the boot media, and ldlinux.c32 in turn loads
# libcom32.c32.  An ISO that ships isolinux.bin alone prints its banner and
# then dies with "Failed to load ldlinux.c32 / Boot failed: press a key to
# retry...", which is what every nightly live ISO did: the modules were
# treated as optional and looked for in the Debian path only, so a host
# without that directory silently wrote an unbootable image.  Distributions
# install the payload under different prefixes, so probe them all and fail
# loudly when none carries it rather than ship an ISO no firmware can boot.
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

isolinux_payload "$ISO_DIR/isolinux" || exit 1

# The isohybrid MBR that makes the same image writable onto a stick.  Losing
# it is not survivable: xorriso would abort on the missing file anyway, but
# only after the squashfs has been packed into the image.
ISOHDPFX=$(isolinux_file isohdpfx.bin) || ISOHDPFX=""
if [ -z "$ISOHDPFX" ]; then
    echo "[ERROR] isohdpfx.bin not found: no hybrid MBR can be written."
    echo "        It ships with isolinux (Debian/Ubuntu) or syslinux."
    exit 1
fi

# Configuration isolinux
# Console parameters for the live kernel, shared with the grub.cfg below.
# Two console= options on purpose, and the order is the whole point: printk
# goes to EVERY registered console, but /dev/console - where init, the boot
# scripts and the rc.d messages are written - is the LAST one named.  Putting
# ttyS0 last is what makes the serial line carry the userspace stream and not
# only the kernel log.  The CI UEFI smoke test boots through the loader below
# and appends nothing to this cmdline, so without a serial console in it that
# step is blind by construction: it greps a log only GRUB writes to.  Proven
# on the 20261106 image - a QEMU BIOS boot of that ISO produced a 0-byte
# serial log while its VGA console showed the entire boot attempt.  The screen
# still mirrors every kernel message, and on a machine whose UART is absent or
# not connected the ttyS0 registration simply fails and tty0 stays the
# console, so nothing changes for a user booting the media.
LIVE_CONSOLE="console=tty0 console=ttyS0,115200n8"
cat >"$ISO_DIR/isolinux/isolinux.cfg" <<EOF
default ${DEFAULT_BOOT}
label live
  kernel vmlinuz
  append initrd=initrd.img root=/dev/sr0 ro quiet ${LIVE_CONSOLE}
label live-verbose
  kernel vmlinuz
  append initrd=initrd.img root=/dev/sr0 ro ${LIVE_CONSOLE}
EOF

# --- UEFI boot image: GRUB standalone inside a FAT16 ESP -------------------
# Proven end-to-end under OVMF (no -kernel): firmware loads the El Torito
# no-emulation EFI boot image as a block device and runs \EFI\BOOT\BOOTX64.EFI
# from a FAT on it.  Two traps this avoids: (1) a raw PE binary passed via
# `-e EFI/BOOT/BOOTX64.EFI` is not a FAT, so firmware reports "UEFI QEMU
# DVD-ROM ... Not Found"; (2) `mkfs.vfat -F 32` on a small image yields a
# too-few-clusters FAT32 OVMF also rejects.  FAT16 + a tree-file efi.img (the
# combination grub-mkrescue itself emits: `-e '/efi.img'`) is what boots.
#
# The generated grub.cfg MUST `search` for the kernel and set root to the
# ISO9660 volume.  GRUB is loaded out of the FAT16 efi.img, whose only file
# is \EFI\BOOT\BOOTX64.EFI, so its default root is that ESP -- a bare
# `linux /isolinux/vmlinuz` then resolves against the ESP and aborts with
# "file `/isolinux/vmlinuz' not found" / "you need to load the kernel
# first" (the exact failure the shipped 0.57.4 lg3d ISO showed under OVMF).
GRUB_CFG_LIVE="${SCRATCH_DIR}/grub-live.cfg"
cat >"$GRUB_CFG_LIVE" <<EOF
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console
set timeout=${LFS_CONFIG_LIVE_SYSTEM_GRUB_TIMEOUT:-10}
set default=0
search --file --no-floppy --set=root /isolinux/vmlinuz
menuentry "LFS Live" {
    linux /isolinux/vmlinuz root=/dev/sr0 ro quiet ${LIVE_CONSOLE}
    initrd /isolinux/initrd.img
}
menuentry "LFS Live (verbose)" {
    linux /isolinux/vmlinuz root=/dev/sr0 ro ${LIVE_CONSOLE}
    initrd /isolinux/initrd.img
}
EOF

EFI_DIR="${SCRATCH_DIR}/efi-payload"
rm -rf "$EFI_DIR"
mkdir -p "$EFI_DIR"
echo "[INFO] Building self-contained GRUB EFI binary ($GRUB_MKSTANDALONE x86_64-efi)..."
"$GRUB_MKSTANDALONE" -O x86_64-efi \
    -o "$EFI_DIR/BOOTX64.EFI" \
    "boot/grub/grub.cfg=$GRUB_CFG_LIVE"
if [ ! -s "$EFI_DIR/BOOTX64.EFI" ]; then
    echo "[ERROR] $GRUB_MKSTANDALONE produced no BOOTX64.EFI"
    exit 1
fi

# FAT16 ESP sized to hold the standalone binary plus slack.  -F 16 pins the FAT
# type so a future size change can never flip it to the FAT32 OVMF rejects.
# mtools writes it without a sudo loop mount.
EFI_IMG="${SCRATCH_DIR}/efi.img"
rm -f "$EFI_IMG"
EFI_KB=$(($(stat -c %s "$EFI_DIR/BOOTX64.EFI") / 1024 + 4096))
dd if=/dev/zero of="$EFI_IMG" bs=1K count="$EFI_KB" status=none
mkfs.vfat -F 16 -n ESP "$EFI_IMG" >/dev/null
mmd -i "$EFI_IMG" ::EFI ::EFI/BOOT
mcopy -i "$EFI_IMG" "$EFI_DIR/BOOTX64.EFI" ::EFI/BOOT/BOOTX64.EFI
# The El Torito EFI entry references efi.img by its path in the ISO tree.
cp -v "$EFI_IMG" "$ISO_DIR/efi.img"

# Construction de l'ISO hybride (BIOS isolinux + UEFI GRUB), toujours.
echo "[INFO] Building hybrid BIOS+UEFI ISO..."
xorriso -as mkisofs \
    -iso-level 4 \
    -r -V "LFS_LIVE" \
    -J -joliet-long \
    -isohybrid-mbr "$ISOHDPFX" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -boot-load-size 4 -boot-info-table -no-emul-boot \
    -eltorito-alt-boot -e efi.img -no-emul-boot \
    -isohybrid-gpt-basdat \
    -o "$ISO_OUT" "$ISO_DIR"

# Read the BIOS payload back out of the finished image.  xorriso exits 0
# whether or not the modules it was told to pack are complete, and
# tools/qemu-boot-smoke.sh boots with -kernel/-initrd, so it never runs
# isolinux at all: without this gate an ISO missing ldlinux.c32 passes every
# automated check and fails on the first real boot, as nightly #70 did.
VERIFY_BOOT="${SCRATCH_DIR}/verify-boot-payload.bin"
for need in isolinux.bin ldlinux.c32 libcom32.c32; do
    rm -f "$VERIFY_BOOT"
    if ! xorriso -osirrox on -indev "$ISO_OUT" \
        -extract "/isolinux/$need" "$VERIFY_BOOT" >/dev/null 2>&1 ||
        [ ! -s "$VERIFY_BOOT" ]; then
        echo "[ERROR] $ISO_OUT carries no /isolinux/$need; it cannot boot."
        rm -f "$VERIFY_BOOT" "$ISO_OUT"
        exit 1
    fi
done
rm -f "$VERIFY_BOOT"
echo "[INFO] BIOS boot payload verified in image"

# Read the UEFI El Torito boot image back out and prove it carries a real GRUB
# EFI binary.  xorriso exits 0 even when `-e` names a file that never became a
# valid ESP, and the BIOS-payload gate above cannot see the EFI entry, so
# without this the BIOS-only regression that shipped for 8 months would pass
# every stage check again.  The authoritative proof that firmware actually
# boots it is the lg3d.yml UEFI smoke test, which runs OVMF against the
# finished ISO with no -kernel.
VERIFY_ESP="${SCRATCH_DIR}/verify-efi.img"
VERIFY_EFI="${SCRATCH_DIR}/verify-BOOTX64.EFI"
rm -f "$VERIFY_ESP" "$VERIFY_EFI"
if ! xorriso -osirrox on -indev "$ISO_OUT" \
    -extract "/efi.img" "$VERIFY_ESP" >/dev/null 2>&1 ||
    [ ! -s "$VERIFY_ESP" ]; then
    echo "[ERROR] $ISO_OUT carries no /efi.img El Torito EFI boot image."
    rm -f "$VERIFY_ESP" "$VERIFY_EFI" "$ISO_OUT"
    exit 1
fi
if ! mcopy -i "$VERIFY_ESP" ::EFI/BOOT/BOOTX64.EFI "$VERIFY_EFI" >/dev/null 2>&1 ||
    [ "$(head -c 2 "$VERIFY_EFI" 2>/dev/null)" != "MZ" ]; then
    echo "[ERROR] $ISO_OUT /efi.img has no bootable \\EFI\\BOOT\\BOOTX64.EFI (not a PE/MZ image)."
    rm -f "$VERIFY_ESP" "$VERIFY_EFI" "$ISO_OUT"
    exit 1
fi
rm -f "$VERIFY_ESP" "$VERIFY_EFI"
echo '[INFO] UEFI El Torito boot image verified (FAT16 + \EFI\BOOT\BOOTX64.EFI)'

# Report (never judge) the hybrid layout so the stage log carries it:
# xorriso writes reports on stderr.  The gate is the lg3d.yml step, which runs
# after the artifacts are uploaded.  Measured Boot record of a published ISO:
#   Boot record  : El Torito , MBR isohybrid cyl-align-on GPT
xorriso -indev "$ISO_OUT" -report_system_area as_plain 2>&1 | grep -a "Boot record" \
    || echo "[WARNING] could not report the system area of $ISO_OUT"

# Nettoyage
rm -rf "$ISO_DIR" "$SQUASHFS" "$EFI_IMG" "$EFI_DIR" "$GRUB_CFG_LIVE"

echo "[SUCCESS] Live ISO created at $ISO_OUT"
ls -lh "$ISO_OUT"
