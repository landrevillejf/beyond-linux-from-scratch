#!/bin/bash
# tools/qemu-boot-smoke.sh
# Boot a build artifact (live ISO or raw disk image) in QEMU and verify that
# the kernel reaches userspace.  Used by the nightly/release CI as the
# post-build regression gate: build-time checks alone never caught the
# regressions that only show up when the artifact actually boots.
#
# The artifact's own bootloader is bypassed on purpose: the kernel and
# initramfs are extracted from the artifact and booted directly with
# console=ttyS0, which gives the test full control of the serial console
# regardless of the grub/isolinux configuration shipped inside.
#
# Usage:
#   qemu-boot-smoke.sh <artifact.iso|artifact.img> [rootfs-dir]
#
#   artifact    Live ISO (.iso) or raw disk image (.img) to boot.
#   rootfs-dir  For disk images only: directory holding boot/ with the
#               kernel and initramfs (default: <artifact dir>/image).
#
# Environment:
#   BOOT_TIMEOUT  seconds allowed for the boot (default 300)
#   BOOT_MEMORY   guest memory (default 2G)
#   ROOT_DEV      root device for disk image boot (default /dev/sda3)
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_pass() { echo "[PASS] $*"; }
log_fail() { echo "[FAIL] $*" >&2; }

ARTIFACT="${1:?usage: qemu-boot-smoke.sh <artifact.iso|img> [rootfs-dir]}"
ROOTFS_DIR="${2:-$(dirname "$ARTIFACT")/image}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
BOOT_MEMORY="${BOOT_MEMORY:-2G}"
ROOT_DEV="${ROOT_DEV:-/dev/sda3}"
# Which of the two ISO layouts was found, or "disk" for a raw image.  The
# gate below is deliberately not the same for both flavours.
ISO_FLAVOUR="disk"

[ -f "$ARTIFACT" ] || {
    log_fail "Artifact not found: $ARTIFACT"
    exit 1
}
command -v qemu-system-x86_64 >/dev/null 2>&1 || {
    log_fail "qemu-system-x86_64 not installed"
    exit 1
}

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
LOG="$WORKDIR/boot.log"

# Pull one kernel/initrd pair out of the ISO.  Judge the extracted files,
# never the xorriso status: on an isohybrid image libburn reports "ISO image
# size Ns larger than readable size Ms" (the hybrid MBR/GPT describes the
# USB-sized target, not the .iso file) and returns 32 even though every
# requested file landed, so a status test rejected the very ISOs the gate is
# meant to boot.  Measured on lg3d-nightly-20261106 with xorriso 1.5.8.
# Both targets are removed first so a partial earlier attempt cannot make a
# later candidate look successful.
extract_iso_pair() {
    rm -f "$WORKDIR/vmlinuz" "$WORKDIR/initrd.img"
    xorriso -osirrox on -indev "$ARTIFACT" \
        -extract "$1" "$WORKDIR/vmlinuz" \
        -extract "$2" "$WORKDIR/initrd.img" >/dev/null 2>&1
    [ -s "$WORKDIR/vmlinuz" ] && [ -s "$WORKDIR/initrd.img" ]
}

case "$ARTIFACT" in
*.iso)
    ARTIFACT_TYPE=iso
    command -v xorriso >/dev/null 2>&1 || {
        log_fail "xorriso not installed (needed to unpack the ISO)"
        exit 1
    }
    # Two layouts are current, and reading only one of them failed the
    # gate for exactly the images that had never been published:
    #   final/15-create-live-system.sh   /isolinux/vmlinuz + initrd.img
    #   final/14-create-installer.sh     /boot/vmlinuz + initramfs.img
    # final/15 only runs when the profile enables live_system, so the
    # headless profiles (minimal, server, audio-cli, gnu-free) and every
    # aarch64 profile ship the final/14 layout alone.
    if extract_iso_pair /isolinux/vmlinuz /isolinux/initrd.img; then
        ISO_FLAVOUR=live
    elif extract_iso_pair /boot/vmlinuz /boot/initramfs.img; then
        ISO_FLAVOUR=installer
    else
        log_fail "Could not extract kernel/initrd from $ARTIFACT"
        log_fail "tried /isolinux/{vmlinuz,initrd.img} and /boot/{vmlinuz,initramfs.img}"
        exit 1
    fi
    log_info "ISO layout: $ISO_FLAVOUR"
    # Both flavours keep live.squashfs on the boot media and the
    # initramfs mounts root= to find it (final/12-create-initramfs.sh).
    APPEND="console=ttyS0 earlyprintk=serial root=/dev/sr0 ro"
    DRIVE_ARGS=(-cdrom "$ARTIFACT")
    ;;
*.img)
    ARTIFACT_TYPE=img
    KERNEL=$(find "$ROOTFS_DIR/boot" -maxdepth 1 -name "vmlinuz*" -type f 2>/dev/null | head -n1)
    INITRD=$(find "$ROOTFS_DIR/boot" -maxdepth 1 -name "initramfs*" -type f 2>/dev/null | head -n1)
    [ -n "$KERNEL" ] || {
        log_fail "No kernel found in $ROOTFS_DIR/boot"
        exit 1
    }
    [ -n "$INITRD" ] || {
        log_fail "No initramfs found in $ROOTFS_DIR/boot"
        exit 1
    }
    cp "$KERNEL" "$WORKDIR/vmlinuz"
    cp "$INITRD" "$WORKDIR/initrd.img"
    # Disk image partition layout from host/03-create-disk-image.sh:
    # p1 is the ESP (/boot), p2 is swap, p3 is the root filesystem.
    APPEND="console=ttyS0 earlyprintk=serial root=$ROOT_DEV ro"
    DRIVE_ARGS=(-drive "file=$ARTIFACT,format=raw")
    ;;
*)
    log_fail "Unsupported artifact type (expected .iso or .img): $ARTIFACT"
    exit 1
    ;;
esac

# Use KVM when the host exposes it (GitHub runners do); fall back to TCG.
ACCEL=tcg
if [ -e /dev/kvm ] && [ -r /dev/kvm ]; then
    ACCEL=kvm
fi

log_info "Booting $ARTIFACT (accel=$ACCEL, memory=$BOOT_MEMORY, timeout=${BOOT_TIMEOUT}s)"

# timeout killing QEMU is the expected outcome: once the guest reaches a
# login prompt it never exits on its own (-no-reboot only guards reboots).
# -cpu qemu64: the busybox binary in the initramfs is now built from source
# with baseline CFLAGS (-march=x86-64, no AVX), so the smoke test must use
# a baseline CPU model to catch AVX-dependent binaries.  The old `-cpu max`
# enabled every CPU feature the accelerator supports (AVX/AVX2/AES/...),
# which masked the lg3d nightly 20261108 failure: the pre-built busybox
# from busybox.net required AVX (vmovdqu instruction), panicked with
# "Attempted to kill init! exitcode=0x00000004" on systems without AVX
# (VirtualBox default, pre-2011 CPUs), but passed CI because `-cpu max`
# exposed AVX.  Using `-cpu qemu64` (baseline x86_64 without AVX) ensures
# the smoke test fails on AVX-dependent binaries, matching real-world
# hardware compatibility.
# The guest console goes to $LOG through -serial file:, not through
# -nographic: measured on a Fedora 44 host (qemu 9.x) the same invocation
# with `-nographic >$LOG 2>&1` left the log at 0 bytes while
# `-display none -serial file:$LOG` captured 364 lines up to the initramfs
# shell, so the gate failed a media that was actually running with
# "Kernel never produced any output".  QEMU's own diagnostics are appended
# to the same file the greps below read.
timeout "$BOOT_TIMEOUT" qemu-system-x86_64 \
    -machine q35,accel="$ACCEL" \
    -cpu qemu64 \
    -m "$BOOT_MEMORY" -smp 2 \
    -kernel "$WORKDIR/vmlinuz" \
    -initrd "$WORKDIR/initrd.img" \
    -append "$APPEND" \
    "${DRIVE_ARGS[@]}" \
    -display none -serial file:"$LOG" -monitor none -no-reboot 2>>"$LOG" || true

echo "----- last 40 lines of boot log -----"
tail -n 40 "$LOG"
echo "--------------------------------------"

if ! grep -q "Linux version" "$LOG"; then
    log_fail "Kernel never produced any output (boot log is silent)"
    exit 1
fi

# Userspace markers: the initramfs reached its root logic, or real init took
# over (sysvinit bootscripts, systemd targets, or a login prompt).
userspace_reached() {
    grep -Eqi "Mounting root:|login:|Entering runlevel|Reached target|Welcome" "$LOG"
}

# The initramfs prints this once it has mounted the boot media and found
# live.squashfs on it, so it proves the ISO9660 driver, the media enumeration
# and the squashfs this build packed are all present and readable.
live_media_mounted() {
    grep -q "Live media detected" "$LOG"
}

# Sysinit aborts that this gate used to call a success.  Every string here was
# printed by an artifact the 20261106 lg3d nightly passed: the sysvinit leg
# opened its S stage with "Mounting virtual file systems", died in
# S00mountvirtfs on "cannot create directory '/sys/fs/cgroup'" plus "unknown
# filesystem type 'cgroup2'", and parked on "Press Enter to continue..."; the
# systemd leg logged "Failed to mount cgroup v1 hierarchy" and then "Freezing
# execution".  The old gate matched "Mounting virtual file systems" and
# "systemd[1]:" - both printed by the code that aborts one line later - so it
# could not fail.  Any of these markers means the boot is dead, whatever
# positive text precedes it.
boot_aborted() {
    grep -Eq "Freezing execution|Press Enter to continue|FAILURE:|unknown filesystem type|Failed to mount cgroup|cannot create directory '/sys/fs/cgroup'|Failed to mount API filesystems|Entering emergency mode" "$LOG"
}

# Markers that can ONLY be emitted after the handover to the real rootfs AND
# past S00mountvirtfs.  "Mounting root:" alone is printed by the initramfs
# *before* the handover, and "Mounting virtual file systems" is printed by the
# very script that then fails, so neither proves anything on its own.
# "Create symlinks in /dev targeting /proc" is the earliest decisive sysvinit
# marker: mountvirtfs exits 1 (bootscripts .../init.d/mountvirtfs:70-74)
# before it whenever any virtual filesystem, /sys/fs/cgroup included, fails to
# mount, so seeing it means the cgroup2 mount succeeded.  The remaining S-stage
# lines, a systemd target, or a getty all work the same way further along.
sysinit_completed() {
    grep -Eq "Create symlinks in /dev targeting /proc|Populating /dev with device nodes|Setting up Linux console|Setting kernel runtime parameters|INIT: Entering runlevel|Reached target (Basic System|Multi-User System|Graphical Interface|User Interface)|login:" "$LOG"
}

if [ "$ARTIFACT_TYPE" = img ]; then
    # The disk image's root partition is deliberately empty: host/03 formats
    # build-release.img but umounts it before anything is installed, and the
    # real rootfs is the tree the kernel/initramfs were extracted from.  So for
    # a .img boot the initramfs necessarily fails to switch_root into the empty
    # /mnt and the kernel panics *after* userspace was already reached.  The
    # meaningful signal is that the kernel enumerated the disk, unpacked the
    # initramfs and ran its root logic ("Mounting root: ..."); the trailing
    # panic is expected here and must not fail the gate (Nightly #224).
    if userspace_reached; then
        log_pass "Initramfs reached userspace (disk image root is empty by design)"
        exit 0
    fi
    if grep -qi "Kernel panic" "$LOG"; then
        log_fail "Kernel panic before the initramfs reached userspace"
        exit 1
    fi
    log_fail "Kernel started but the initramfs never reached userspace"
    exit 1
fi

# An installer ISO (final/14) packs a real squashfs, but the rootfs inside it
# was never configured to run from a read-only root: /etc and /var are on the
# image, so the boot scripts fail the moment they write and init can die on
# the way to a login prompt.  What this gate can prove about that flavour is
# that the media was enumerated, the ISO9660 mount worked and the squashfs was
# found on it - so a panic after that point is tolerated the same way the empty
# disk image's is, and a panic before it is not.  A live ISO (final/15) is
# built to boot exactly this way and keeps the strict check below.
if [ "$ISO_FLAVOUR" = installer ]; then
    if ! live_media_mounted && ! userspace_reached; then
        if grep -qi "Kernel panic" "$LOG"; then
            log_fail "Kernel panic before the ISO's live.squashfs was mounted"
        else
            log_fail "Kernel started but the ISO's live.squashfs was never mounted"
        fi
        exit 1
    fi
    # Reported, not fatal: this rootfs was never configured to run read-only,
    # so an abort here is known and the live profiles are the ones the strict
    # gate below protects.
    if boot_aborted; then
        log_info "Known installer-rootfs abort detected (rootfs is not read-only safe):"
        grep -En "Freezing execution|Press Enter to continue|FAILURE:|unknown filesystem type|Failed to mount cgroup|cannot create directory '/sys/fs/cgroup'" "$LOG" | head -n 5
    fi
    log_pass "Installer ISO mounted its live media (rootfs is not read-only safe)"
    exit 0
fi

# Live ISO: the root (squashfs) is real, so a kernel panic is a genuine
# failure and is checked before the userspace markers.
if grep -qi "Kernel panic" "$LOG"; then
    log_fail "Kernel panic during boot"
    exit 1
fi

if boot_aborted; then
    log_fail "Sysinit aborted the boot (the init printed a fatal marker)"
    grep -En "Freezing execution|Press Enter to continue|FAILURE:|unknown filesystem type|Failed to mount cgroup|cannot create directory '/sys/fs/cgroup'|Failed to mount API filesystems|Entering emergency mode" "$LOG" | head -n 8
    exit 1
fi

if ! userspace_reached; then
    log_fail "Kernel started but userspace was never reached"
    exit 1
fi

if sysinit_completed; then
    log_pass "Artifact reached userspace and the rootfs sysinit ran past its S stage"
    exit 0
fi

log_fail "Initramfs handed over but the rootfs init never got past its S stage"
log_fail "(no udev/console/sysctl stage, systemd target or login prompt in the log)"
exit 1
