#!/bin/bash
# blfs/21-luks-encryption.sh – LUKS full-disk encryption setup for installer
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# This script installs cryptsetup and configures the initramfs to support
# LUKS-encrypted root partitions. It is called during the build when the
# profile has encryption.enabled = true.
set -euo pipefail

LFS="${LFS:-/mnt/lfs}"
if [ -z "$LFS" ] || [ ! -d "$LFS" ]; then
    echo "[ERROR] LFS directory '$LFS' not found"
    exit 1
fi

run_privileged() {
    if [ "$(whoami)" = "root" ]; then "$@"; else sudo "$@"; fi
}

write_file() {
    local path="$1" mode="$2"
    run_privileged mkdir -p "$(dirname "$LFS$path")"
    run_privileged tee "$LFS$path" >/dev/null
    run_privileged chmod "$mode" "$LFS$path"
}

echo "[INFO] Configuring LUKS full-disk encryption support..."

# --------------------------------------------------------------------------
# 1. Install cryptsetup if not already present
# --------------------------------------------------------------------------
if [ ! -x "$LFS/sbin/cryptsetup" ] && [ ! -x "$LFS/usr/sbin/cryptsetup" ]; then
    echo "[INFO] cryptsetup not found in target – ensure it is built in BLFS stage"
    echo "[WARN] Skipping cryptsetup installation (should be built as a BLFS package)"
else
    echo "[INFO] cryptsetup found in target system"
fi

# --------------------------------------------------------------------------
# 2. Configure initramfs to load dm-crypt modules
# --------------------------------------------------------------------------
write_file /etc/initramfs-tools/modules 0644 <<'MODULES'
# LUKS/dm-crypt support
dm_crypt
dm_mod
crc32_generic
MODULES

# --------------------------------------------------------------------------
# 3. Configure crypttab template for installer use
# --------------------------------------------------------------------------
write_file /etc/crypttab 0640 <<'CRYPTTAB'
# <target name>  <source device>  <key file>  <options>
# Example (filled by installer):
# sda2_crypt  UUID=xxxx-xxxx-xxxx  none  luks,discard
CRYPTTAB

# --------------------------------------------------------------------------
# 4. Kernel modules for encryption
# --------------------------------------------------------------------------
write_file /etc/modprobe.d/cryptsetup.conf 0644 <<'MODPROBE'
# Ensure dm-crypt is loaded
softdep dm_crypt pre: dm_mod
MODPROBE

# --------------------------------------------------------------------------
# 5. Installer helper script (called during disk setup)
# --------------------------------------------------------------------------
write_file /usr/sbin/lfs-encrypt-disk 0755 <<'HELPER'
#!/bin/bash
# LFS disk encryption helper – called by the installer
# Usage: lfs-encrypt-disk <device> [luks-name]
#
# This creates a LUKS container on the specified partition,
# formats it as ext4, and updates /etc/crypttab accordingly.
set -euo pipefail

DEVICE="${1:?Usage: lfs-encrypt-disk <device> [luks-name]}"
LUKS_NAME="${2:-cryptroot}"

echo "WARNING: This will erase ALL data on $DEVICE"
read -rp "Type 'YES' to confirm: " confirm
if [ "$confirm" != "YES" ]; then
    echo "Cancelled."
    exit 0
fi

# Prompt for passphrase
echo "Enter LUKS passphrase (minimum 8 characters):"
read -rs LUKS_PASS
if [ ${#LUKS_PASS} -lt 8 ]; then
    echo "Passphrase too short (minimum 8 characters)"
    exit 1
fi
echo "Confirm passphrase:"
read -rs LUKS_PASS2
if [ "$LUKS_PASS" != "$LUKS_PASS2" ]; then
    echo "Passphrases do not match"
    exit 1
fi

# Format as LUKS
echo "$LUKS_PASS" | cryptsetup luksFormat --type luks2 "$DEVICE" -

# Open the container
echo "$LUKS_PASS" | cryptsetup luksOpen "$DEVICE" "$LUKS_NAME" -

# Format the mapped device
mkfs.ext4 -L "LFS-Root" "/dev/mapper/$LUKS_NAME"

# Get UUID for crypttab
DEVICE_UUID=$(blkid -s UUID -o value "$DEVICE")

# Update /etc/crypttab
echo "$LUKS_NAME UUID=$DEVICE_UUID none luks,discard" >> /etc/crypttab

# Update /etc/fstab
echo "/dev/mapper/$LUKS_NAME / ext4 defaults 0 1" >> /etc/fstab

echo "Encryption setup complete for $DEVICE"
echo "LUKS name: $LUKS_NAME"
echo "UUID: $DEVICE_UUID"
echo ""
echo "The initramfs will prompt for the LUKS passphrase on each boot."
HELPER

# --------------------------------------------------------------------------
# 6. Ensure kernel config includes dm-crypt support
# --------------------------------------------------------------------------
echo "[INFO] Verifying kernel crypto modules are configured..."
if [ -f "$LFS/boot/config-"* ]; then
    config_file=$(ls "$LFS/boot/config-"* 2>/dev/null | head -1)
    if [ -f "$config_file" ]; then
        for opt in CONFIG_MD_CRYPT CONFIG_MD_DM CONFIG_CRYPTO_XTS CONFIG_CRYPTO_AES; do
            if grep -q "${opt}=y\|${opt}=m" "$config_file" 2>/dev/null; then
                echo "  [OK] $opt is enabled"
            else
                echo "  [WARN] $opt may not be enabled – LUKS might not work"
            fi
        done
    fi
fi

echo "[SUCCESS] LUKS encryption support configured"
echo "  - crypttab template: /etc/crypttab"
echo "  - Installer helper:  /usr/sbin/lfs-encrypt-disk"
echo "  - Initramfs modules: /etc/initramfs-tools/modules"
exit 0
