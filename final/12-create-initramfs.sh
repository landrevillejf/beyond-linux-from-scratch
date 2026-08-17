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

# Auto-detect root device: try common names, then UUID from kernel cmdline
ROOT_DEV=""
ROOT_UUID=""

# Parse kernel command line for root= parameter
for param in $(cat /proc/cmdline); do
    case "$param" in
        root=UUID=*) ROOT_UUID="${param#root=UUID=}" ;;
        root=/dev/*) ROOT_DEV="${param#root=}" ;;
    esac
done

# If UUID specified, find the device
if [ -n "$ROOT_UUID" ]; then
    ROOT_DEV=$(findfs "UUID=$ROOT_UUID" 2>/dev/null || true)
fi

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
    /bin/busybox mount -t ext4 "$ROOT_DEV" /mnt 2>/dev/null || \
    /bin/busybox mount "$ROOT_DEV" /mnt 2>/dev/null || {
        echo "Failed to mount $ROOT_DEV. Dropping to shell."
        /bin/busybox sh
    }
else
    echo "Root device not found. Dropping to shell."
    /bin/busybox sh
fi

/bin/busybox umount /proc
/bin/busybox umount /sys
/bin/busybox umount /dev
exec /bin/busybox switch_root /mnt /sbin/init
EOF

chmod 755 "$INITRAMFS_DIR/init"

# --------------------------------------------------------------------------
# Create compressed cpio archive
# --------------------------------------------------------------------------
cd "$INITRAMFS_DIR"
find . | cpio -o -H newc | gzip -9 >"$INITRAMFS_OUTPUT"
cd - >/dev/null

rm -rf "$INITRAMFS_DIR"
echo "[SUCCESS] Initramfs created at $INITRAMFS_OUTPUT"
ls -lh "$INITRAMFS_OUTPUT"
