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
#   ROOT_DEV      root device for disk image boot (default /dev/sda2)
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_pass() { echo "[PASS] $*"; }
log_fail() { echo "[FAIL] $*" >&2; }

ARTIFACT="${1:?usage: qemu-boot-smoke.sh <artifact.iso|img> [rootfs-dir]}"
ROOTFS_DIR="${2:-$(dirname "$ARTIFACT")/image}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
BOOT_MEMORY="${BOOT_MEMORY:-2G}"
ROOT_DEV="${ROOT_DEV:-/dev/sda2}"

[ -f "$ARTIFACT" ] || { log_fail "Artifact not found: $ARTIFACT"; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || {
    log_fail "qemu-system-x86_64 not installed"
    exit 1
}

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
LOG="$WORKDIR/boot.log"

case "$ARTIFACT" in
    *.iso)
        # Extract kernel + initramfs from the ISO's isolinux directory.
        command -v xorriso >/dev/null 2>&1 || {
            log_fail "xorriso not installed (needed to unpack the ISO)"
            exit 1
        }
        xorriso -osirrox on -indev "$ARTIFACT" \
            -extract /isolinux/vmlinuz "$WORKDIR/vmlinuz" \
            -extract /isolinux/initrd.img "$WORKDIR/initrd.img" >/dev/null 2>&1 || {
            log_fail "Could not extract kernel/initrd from $ARTIFACT"
            exit 1
        }
        # Live ISO contract (final/15-create-live-system.sh): the initramfs
        # mounts the boot media and unpacks live.squashfs from it.
        APPEND="console=ttyS0 earlyprintk=serial root=/dev/sr0 ro"
        DRIVE_ARGS=(-cdrom "$ARTIFACT")
        ;;
    *.img)
        KERNEL=$(find "$ROOTFS_DIR/boot" -maxdepth 1 -name "vmlinuz*" -type f 2>/dev/null | head -n1)
        INITRD=$(find "$ROOTFS_DIR/boot" -maxdepth 1 -name "initramfs*" -type f 2>/dev/null | head -n1)
        [ -n "$KERNEL" ] || { log_fail "No kernel found in $ROOTFS_DIR/boot"; exit 1; }
        [ -n "$INITRD" ] || { log_fail "No initramfs found in $ROOTFS_DIR/boot"; exit 1; }
        cp "$KERNEL" "$WORKDIR/vmlinuz"
        cp "$INITRD" "$WORKDIR/initrd.img"
        # Disk image partition layout from host/03-create-disk-image.sh:
        # partition 1 is /boot, partition 2 is the root filesystem.
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
timeout "$BOOT_TIMEOUT" qemu-system-x86_64 \
    -machine q35,accel="$ACCEL" \
    -m "$BOOT_MEMORY" -smp 2 \
    -kernel "$WORKDIR/vmlinuz" \
    -initrd "$WORKDIR/initrd.img" \
    -append "$APPEND" \
    "${DRIVE_ARGS[@]}" \
    -nographic -no-reboot >"$LOG" 2>&1 || true

echo "----- last 40 lines of boot log -----"
tail -n 40 "$LOG"
echo "--------------------------------------"

if grep -qi "Kernel panic" "$LOG"; then
    log_fail "Kernel panic during boot"
    exit 1
fi

if ! grep -q "Linux version" "$LOG"; then
    log_fail "Kernel never produced any output (boot log is silent)"
    exit 1
fi

# Userspace markers: initramfs reached its root logic, or real init took
# over (sysvinit bootscripts, systemd targets, or a login prompt).
if grep -Eqi "Mounting root:|login:|Entering runlevel|Reached target|Welcome" "$LOG"; then
    log_pass "Artifact reached userspace"
    exit 0
fi

log_fail "Kernel started but userspace was never reached"
exit 1
