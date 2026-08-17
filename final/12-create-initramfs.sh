#!/bin/bash
# Create a functional initramfs with busybox (auto-download if missing)
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

# Re‑launch with sudo if not root (preserve environment)
if [ "$EUID" -ne 0 ]; then
    echo "[INFO] Relaunching with sudo..."
    exec sudo -E "$0" "$@"
fi

LFS="${LFS:-/output/image}"
INITRAMFS_DIR="${LFS}/boot/initramfs-tmp"
INITRAMFS_OUTPUT="${LFS}/boot/initramfs.img"

echo "[INFO] Building initramfs for LFS..."

rm -rf "$INITRAMFS_DIR"
mkdir -pv "$INITRAMFS_DIR"/{bin,dev,etc,lib,lib64,mnt,proc,root,sbin,sys,tmp,usr,var}

# --------------------------------------------------------------------------
# Find or download busybox
# --------------------------------------------------------------------------
BUSYBOX_SRC=""
if [ -f "$LFS/bin/busybox" ]; then
    BUSYBOX_SRC="$LFS/bin/busybox"
elif [ -f "$LFS/usr/bin/busybox" ]; then
    BUSYBOX_SRC="$LFS/usr/bin/busybox"
elif [ -f "$LFS/sbin/busybox" ]; then
    BUSYBOX_SRC="$LFS/sbin/busybox"
fi

if [ -z "$BUSYBOX_SRC" ] && command -v busybox >/dev/null 2>&1; then
    BUSYBOX_SRC="$(command -v busybox)"
    echo "[INFO] Using host busybox: $BUSYBOX_SRC"
fi

if [ -z "$BUSYBOX_SRC" ]; then
    echo "[INFO] Busybox not found. Downloading static binary..."
    BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
    wget -q -O /tmp/busybox "$BUSYBOX_URL"
    chmod +x /tmp/busybox
    BUSYBOX_SRC="/tmp/busybox"
    echo "[INFO] Downloaded busybox to $BUSYBOX_SRC"
fi

cp -a "$BUSYBOX_SRC" "$INITRAMFS_DIR/bin/busybox"
chmod 755 "$INITRAMFS_DIR/bin/busybox"

# Create symlinks, ignoring 'busybox' itself
cd "$INITRAMFS_DIR/bin"
for cmd in $(./busybox --list); do
    if [ "$cmd" != "busybox" ]; then
        ln -sf busybox "$cmd"
    fi
done
cd - >/dev/null

# --------------------------------------------------------------------------
# Init script (mounts devtmpfs, so no static device nodes needed)
# --------------------------------------------------------------------------
cat >"$INITRAMFS_DIR/init" <<'EOF'
#!/bin/busybox sh
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev

# ---------------------------------------------------------------------------
# Root device detection with A/B partition support
#
# Kernel cmdline parameters:
#   root=/dev/sdXn     – single root partition (classic mode)
#   root=UUID=...       – root by UUID
#   root_ab=a           – A/B mode: prefer slot A
#   root_ab=b           – A/B mode: prefer slot B
#   root_a=/dev/sdXn    – A/B slot A device
#   root_b=/dev/sdXn    – A/B slot B device
# ---------------------------------------------------------------------------
ROOT_DEV=""
ROOT_UUID=""
ROOT_AB=""
ROOT_A_DEV=""
ROOT_B_DEV=""

for param in $(cat /proc/cmdline); do
    case "$param" in
        root=UUID=*)  ROOT_UUID="${param#root=UUID=}" ;;
        root=/dev/*)  ROOT_DEV="${param#root=}" ;;
        root_ab=*)    ROOT_AB="${param#root_ab=}" ;;
        root_a=*)     ROOT_A_DEV="${param#root_a=}" ;;
        root_b=*)     ROOT_B_DEV="${param#root_b=}" ;;
    esac
done

# Resolve UUID to device
if [ -n "$ROOT_UUID" ]; then
    ROOT_DEV=$(findfs "UUID=$ROOT_UUID" 2>/dev/null || true)
fi

# try_mount <device> – attempt to mount with auto-detection + known fstypes
try_mount() {
    local dev="$1"
    [ -b "$dev" ] || return 1
    /bin/busybox mount "$dev" /mnt 2>/dev/null && return 0
    for fstype in ext4 xfs btrfs f2fs; do
        /bin/busybox mount -t "$fstype" "$dev" /mnt 2>/dev/null && return 0
    done
    return 1
}

# Check if a mounted root has a working init binary
root_is_valid() {
    [ -x /mnt/sbin/init ] || [ -x /mnt/usr/lib/systemd/systemd ] || [ -x /mnt/usr/sbin/init ]
}

# ---------------------------------------------------------------------------
# A/B root partition logic
# ---------------------------------------------------------------------------
if [ -n "$ROOT_A_DEV" ] && [ -n "$ROOT_B_DEV" ]; then
    echo "A/B root mode detected (prefer slot ${ROOT_AB:-a})"

    # Determine preferred and fallback slots
    if [ "$ROOT_AB" = "b" ]; then
        PRIMARY="$ROOT_B_DEV"
        FALLBACK="$ROOT_A_DEV"
    else
        PRIMARY="$ROOT_A_DEV"
        FALLBACK="$ROOT_B_DEV"
    fi

    # Check last-boot marker to implement round-robin on failure
    MARKER_FILE="/dev/.ab-boot-marker"
    LAST_BOOT=""
    if [ -f "$MARKER_FILE" ]; then
        LAST_BOOT=$(cat "$MARKER_FILE")
    fi

    # Try primary slot
    echo "Trying primary root: $PRIMARY"
    if try_mount "$PRIMARY" && root_is_valid; then
        echo "$PRIMARY" > /mnt/etc/.ab-active-slot
        echo "Mounted root A/B slot: $PRIMARY"
    elif try_mount "$FALLBACK" && root_is_valid; then
        echo "$FALLBACK" > /mnt/etc/.ab-active-slot
        echo "Primary failed, fell back to: $FALLBACK"
    else
        echo "Both A/B root slots failed. Dropping to shell."
        /bin/busybox sh
    fi

# ---------------------------------------------------------------------------
# Classic single-root mode
# ---------------------------------------------------------------------------
else
    # Fallback: try common root device names
    if [ -z "$ROOT_DEV" ] || [ ! -b "$ROOT_DEV" ]; then
        for candidate in /dev/sda2 /dev/vda2 /dev/nvme0n1p2 /dev/xvda2 /dev/sda1 /dev/vda1; do
            if [ -b "$candidate" ]; then
                ROOT_DEV="$candidate"
                break
            fi
        done
    fi

    if [ -n "$ROOT_DEV" ] && [ -b "$ROOT_DEV" ]; then
        echo "Mounting root: $ROOT_DEV"
        if ! try_mount "$ROOT_DEV"; then
            echo "Failed to mount $ROOT_DEV. Dropping to shell."
            /bin/busybox sh
        fi
    else
        echo "Root device not found. Dropping to shell."
        /bin/busybox sh
    fi
fi

/bin/busybox umount /proc
/bin/busybox umount /sys
/bin/busybox umount /dev
exec /bin/busybox switch_root /mnt /sbin/init
EOF

chmod 755 "$INITRAMFS_DIR/init"

# --------------------------------------------------------------------------
# Create compressed cpio archive (prefer zstd, fallback to gzip)
# --------------------------------------------------------------------------
cd "$INITRAMFS_DIR"
if command -v zstd >/dev/null 2>&1; then
    echo "[INFO] Compressing initramfs with zstd..."
    find . | cpio -o -H newc 2>/dev/null | zstd -19 -q > "$INITRAMFS_OUTPUT"
else
    echo "[INFO] Compressing initramfs with gzip..."
    find . | cpio -o -H newc 2>/dev/null | gzip -9 >"$INITRAMFS_OUTPUT"
fi
cd - >/dev/null

rm -rf "$INITRAMFS_DIR"
echo "[SUCCESS] Initramfs created at $INITRAMFS_OUTPUT"
ls -lh "$INITRAMFS_OUTPUT"
