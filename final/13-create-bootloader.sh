#!/bin/bash
# final/13-create-bootloader.sh – Install the selected bootloader
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

# Re-launch with sudo if not root (preserve environment).  This stage
# bind-mounts /dev, /proc and /sys into $LFS and then chroots to run
# grub-install; as the unprivileged builder user the mounts fail silently
# (they are `|| true` guarded) and chroot dies with "Operation not
# permitted" (Nightly #215, server profile).  Same pattern as
# final/12-create-initramfs.sh.
if [ "$EUID" -ne 0 ]; then
    echo "[INFO] Relaunching with sudo..."
    exec sudo -E "$0" "$@"
fi

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

# Assemble the kernel command line. FIPS-mode (security.fips.enabled,
# resolved by builder.py -> LFS_CONFIG_SECURITY_FIPS_ENABLED) appends
# fips=1 so the kernel crypto API enters FIPS mode at boot and
# /proc/sys/crypto/fips_enabled reads 1. Requires CONFIG_CRYPTO_FIPS=y,
# which Phase 3 adds to every kernel-config variant; without fips=1 that
# option is inert, so the default cmdline is unchanged. This is the GRUB
# (native x86_64) path -- U-Boot targets are cross-built, where builder.py
# resolves FIPS off, and LILO does not carry a cmdline here.
KERNEL_CMDLINE="${LFS_CONFIG_KERNEL_CMDLINE:-quiet splash}"
if [ "${LFS_CONFIG_SECURITY_FIPS_ENABLED:-false}" = "true" ]; then
    KERNEL_CMDLINE="$KERNEL_CMDLINE fips=1"
    echo "[INFO] FIPS-mode enabled: appending fips=1 to kernel cmdline"
fi

# Boot-integrity command line (Phase 5).  Opt-in through
# security.boot_integrity.measured_boot, so a build that did not ask for it
# keeps the exact same command line as before and a mis-set option can never
# brick an unattended nightly.  lockdown needs no token here: it is already
# forced at compile time by CONFIG_LOCKDOWN_KERNEL_FORCE_INTEGRITY (Phase 1).
#
# IMA/EVM are armed in FIX mode, not enforce.  ima_appraise=fix / evm=fix
# write the security.ima and security.evm xattrs on first boot instead of
# denying access, so the system stays bootable while the integrity baseline
# is provisioned; switching to enforce is a deliberate operator step once
# every measured path carries a valid label (the same staged rollout the
# SELinux enforcing work uses).  Without a loaded IMA policy these tokens are
# inert, which is why blfs/15 also provisions /etc/ima/ima-policy.
if [ "${LFS_CONFIG_SECURITY_BOOT_INTEGRITY_MEASURED_BOOT:-false}" = "true" ]; then
    KERNEL_CMDLINE="$KERNEL_CMDLINE ima_policy=appraise ima_appraise=fix evm=fix"
    echo "[INFO] measured boot: IMA/EVM armed in fix (provisioning) mode"
fi

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
            # grub-install normally creates /boot/grub, but it is skipped when
            # no target disk can be probed (always the case in CI, where the
            # image is a plain file), so the redirect below used to die with
            # "No such file or directory" (Nightly #215).
            mkdir -p "$LFS/boot/grub"
            # Substitute build-time variables into the template
            sed -e "s|\${LFS_CONFIG_BOOTLOADER_TIMEOUT}|${LFS_CONFIG_BOOTLOADER_TIMEOUT:-5}|g" \
                -e "s|\${LFS_ROOT_DEVICE}|$ROOT_DEVICE|g" \
                -e "s|\${LFS_ROOT_UUID}|$ROOT_UUID|g" \
                -e "s|\${LFS_KERNEL_VERSION}|$KERNEL_VERSION|g" \
                -e "s|\${LFS_KERNEL_CMDLINE}|${KERNEL_CMDLINE}|g" \
                "$GRUB_TEMPLATE" >"$LFS/boot/grub/grub.cfg"
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

# ---------------------------------------------------------------------------
# Optional UEFI Secure Boot signing (Phase 5)
# ---------------------------------------------------------------------------
# Off by default (security.boot_integrity.secure_boot).  When enabled, sign the
# installed kernel with a Machine Owner Key (MOK) so firmware with Secure Boot
# on will accept it through shim.  This is deliberately conservative: it never
# writes the firmware key database itself -- it signs the image and emits the
# `mokutil --import` step for the operator, because enrolling a MOK is an
# interactive physical-presence action an unattended build must not attempt.
# Missing tools are a warning, not a failure, so a non-UEFI or cross build that
# left the knob on still completes.  The default (knob off) path is untouched.
if [ "${LFS_CONFIG_SECURITY_BOOT_INTEGRITY_SECURE_BOOT:-false}" = "true" ]; then
    echo "[INFO] Secure Boot requested: signing kernel with a MOK"
    MOK_DIR="$LFS/etc/secure-boot"
    KERNEL_IMG="$(ls "$LFS/boot/vmlinuz-"* 2>/dev/null | head -1)"
    if [ -z "$KERNEL_IMG" ]; then
        echo "[WARNING] no kernel image under $LFS/boot - skipping Secure Boot signing"
    elif ! chroot "$LFS" test -x /usr/bin/sbsign 2>/dev/null; then
        echo "[WARNING] sbsign absent in target - install sbsigntools to sign for Secure Boot"
    else
        # Kernel path relative to the chroot (sbsign runs inside it).
        KERNEL_REL="${KERNEL_IMG#"$LFS"}"
        mkdir -p "$MOK_DIR"
        chmod 700 "$MOK_DIR"
        if [ ! -f "$MOK_DIR/MOK.key" ]; then
            echo "[INFO] generating a Machine Owner Key (MOK)"
            openssl req -new -x509 -newkey rsa:2048 -keyout "$MOK_DIR/MOK.key" \
                -out "$MOK_DIR/MOK.crt" -days 3650 -nodes \
                -subj "/CN=LFS Secure Boot MOK/" >/dev/null 2>&1
            chmod 600 "$MOK_DIR/MOK.key"
        fi
        echo "[INFO] signing $KERNEL_REL"
        if chroot "$LFS" sbsign --key /etc/secure-boot/MOK.key \
            --cert /etc/secure-boot/MOK.crt \
            --output "$KERNEL_REL.signed" "$KERNEL_REL"; then
            mv "$KERNEL_IMG.signed" "$KERNEL_IMG"
            echo "[INFO] signed kernel installed"
        else
            echo "[WARNING] sbsign failed - leaving kernel unsigned"
        fi
        cat >"$MOK_DIR/ENROLL.txt" <<'MOK'
Secure Boot MOK generated for this image.

Enroll the key on the target at first boot (physical presence required):

    mokutil --import /etc/secure-boot/MOK.crt

Then reboot; the shim MOK manager prompts for the enrollment password (empty
by default).  Until the MOK is enrolled, keep Secure Boot disabled in firmware
or the signed kernel will not be accepted.
MOK
        echo "[INFO] wrote MOK enrollment instructions to $MOK_DIR/ENROLL.txt"
    fi
fi

# Nettoyage
umount "$LFS/dev" 2>/dev/null || true
umount "$LFS/proc" 2>/dev/null || true
umount "$LFS/sys" 2>/dev/null || true

echo "[SUCCESS] Bootloader configuration completed"
