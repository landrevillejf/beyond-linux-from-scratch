#!/bin/bash
# Create a functional initramfs with busybox (auto-download if missing)
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

# Re‑launch with sudo if not root (preserve environment)
if [ "$EUID" -ne 0 ]; then
    echo "[INFO] Relaunching with sudo..."
    # `sudo -E` is not reliable: the Ubuntu 26.04 runner's sudo refuses it
    # ("preserving the entire environment is not supported, '-E' is
    # ignored"), which stripped $LFS and every flattened LFS_CONFIG_* /
    # LFS_PROFILE_* knob the builder exported, dropping the stage back to its
    # compiled-in default (lg3d Nightly #45).  Re-feed the whole current
    # environment through `sudo env`; that never relies on sudo's env_reset
    # whitelist.
    _sudo_env=()
    while IFS= read -r -d '' _kv; do
        _sudo_env+=("$_kv")
    done < <(env -0)
    exec sudo env "${_sudo_env[@]}" "$0" "$@"
fi

LFS="${LFS:-/output/image}"
INITRAMFS_DIR="${LFS}/boot/initramfs-tmp"
INITRAMFS_OUTPUT="${LFS}/boot/initramfs.img"

# Target architecture, same convention as blfs/28-knowledge.sh.  uname -m is
# only the last resort: on a cross-compile the host arch is not the target's,
# and picking busybox by the host is what put an x86_64 shell into the arm64
# initramfs.
TARGET_ARCH="${LFS_CONFIG_ARCHITECTURE:-${ARCH:-$(uname -m)}}"
case "$TARGET_ARCH" in
arm64) TARGET_ARCH="aarch64" ;;
esac

echo "[INFO] Building initramfs for LFS (target: $TARGET_ARCH)..."

rm -rf "$INITRAMFS_DIR"
mkdir -pv "$INITRAMFS_DIR"/{bin,dev,etc,lib,lib64,mnt,proc,root,sbin,sys,tmp,usr,var}

# --------------------------------------------------------------------------
# Find or download busybox
# --------------------------------------------------------------------------
# The initramfs has no libc yet, so busybox must be statically linked: a
# dynamic one is copied happily and then dies at exec with "No such file or
# directory", which reads like a missing file rather than a missing
# interpreter.  readelf is authoritative – a static executable carries no
# PT_INTERP program header – and final/16 already relies on readelf being on
# the host.
is_static_binary() {
    [ -f "$1" ] || return 1
    command -v readelf >/dev/null 2>&1 || return 0
    ! readelf -lW "$1" 2>/dev/null | grep -q 'INTERP'
}

BUSYBOX_SRC=""
for candidate in "$LFS/bin/busybox" "$LFS/usr/bin/busybox" \
    "$LFS/sbin/busybox" "$LFS/usr/sbin/busybox"; do
    if is_static_binary "$candidate"; then
        BUSYBOX_SRC="$candidate"
        break
    fi
done

if [ -z "$BUSYBOX_SRC" ]; then
    HOST_BUSYBOX="$(command -v busybox 2>/dev/null)"
    if is_static_binary "$HOST_BUSYBOX"; then
        BUSYBOX_SRC="$HOST_BUSYBOX"
        echo "[INFO] Using host busybox: $BUSYBOX_SRC"
    fi
fi

# busybox.net publishes prebuilt statics for i686 and x86_64 only – there is
# no aarch64 musl build to fetch – so on any other target the host's
# busybox-static is the only source.  Downloading the x86_64 binary there
# produced an initramfs whose shell could not exec, and nothing caught it:
# final/16 only checks that boot/initramfs* exists and no arm64 artifact was
# ever booted.
case "$TARGET_ARCH" in
x86_64) BUSYBOX_TRIPLET="x86_64-linux-musl" ;;
i686 | i386) BUSYBOX_TRIPLET="i686-linux-musl" ;;
*) BUSYBOX_TRIPLET="" ;;
esac

if [ -z "$BUSYBOX_SRC" ] && [ -n "$BUSYBOX_TRIPLET" ]; then
    echo "[INFO] Busybox not found. Downloading static binary..."
    BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-${BUSYBOX_TRIPLET}/busybox"
    wget -q -O /tmp/busybox "$BUSYBOX_URL"
    chmod +x /tmp/busybox
    BUSYBOX_SRC="/tmp/busybox"
    echo "[INFO] Downloaded busybox to $BUSYBOX_SRC"
fi

if [ -z "$BUSYBOX_SRC" ]; then
    echo "[ERROR] No static busybox is available for target $TARGET_ARCH."
    echo "        busybox.net publishes statics for i686 and x86_64 only, so on"
    echo "        this architecture either install one on the host:"
    echo "          apt-get install busybox-static"
    echo "        or build busybox into the target rootfs."
    exit 1
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
# LUKS/LVM support: bundle cryptsetup + lvm and every shared library they need
# into the initramfs.  The early environment otherwise carries only a static
# busybox, but the LUKS unlock in the init script below needs the dynamic
# cryptsetup/lvm binaries plus each DT_NEEDED library (libdevmapper, libcrypto,
# libjson-c, libpopt, libblkid, libuuid, libc, the dynamic loader, ...).
# readelf resolves them recursively against $LFS.  Missing tools are NOT an
# error: only profiles that ran the luks-encryption stage (blfs/21) have them,
# and a profile that did not simply ships an initramfs with no LUKS path.
# --------------------------------------------------------------------------
INITRAMFS_LIBDIRS=("$LFS/lib" "$LFS/usr/lib" "$LFS/lib64" "$LFS/usr/lib64")

resolve_host_lib() {
    local soname="$1" d
    for d in "${INITRAMFS_LIBDIRS[@]}"; do
        if [ -e "$d/$soname" ]; then
            printf '%s\n' "$d/$soname"
            return 0
        fi
    done
    return 1
}

copy_host_lib() {
    local src="$1" rel dest tgt
    if [ ! -e "$src" ]; then return 0; fi
    rel="${src#"$LFS"}"
    dest="$INITRAMFS_DIR$rel"
    if [ ! -e "$dest" ]; then
        mkdir -p "$(dirname "$dest")"
        if ! cp -a "$src" "$dest" 2>/dev/null; then
            cp -L "$src" "$dest" 2>/dev/null || echo "[WARN] could not copy $src" >&2
        fi
    fi
    if [ -L "$src" ]; then
        tgt="$(readlink -f "$src" 2>/dev/null)"
        if [ -n "$tgt" ] && [ "$tgt" != "$src" ]; then
            copy_host_lib "$tgt"
        fi
    fi
    return 0
}

bundle_tool() {
    # $1 = host path under $LFS, $2 = name under the initramfs /bin
    local bin="$1" name="$2"
    local -a queue=()
    local -A seen=()
    local interp need cur base p
    if [ ! -x "$bin" ]; then return 1; fi
    cp -a "$bin" "$INITRAMFS_DIR/bin/$name"
    chmod 755 "$INITRAMFS_DIR/bin/$name"
    interp="$(readelf -lW "$bin" 2>/dev/null | sed -n 's/.*program interpreter: \(.*\)\]/\1/p' | head -1)"
    if [ -n "$interp" ]; then queue+=("$LFS$interp"); fi
    while read -r need; do
        if [ -n "$need" ]; then
            if p="$(resolve_host_lib "$need")"; then queue+=("$p"); fi
        fi
    done < <(readelf -dW "$bin" 2>/dev/null | awk '/NEEDED/{print $NF}' | tr -d '[]')
    while [ "${#queue[@]}" -gt 0 ]; do
        cur="${queue[0]}"
        queue=("${queue[@]:1}")
        if [ ! -e "$cur" ]; then continue; fi
        base="$(basename "$cur")"
        if [ -n "${seen[$base]:-}" ]; then continue; fi
        seen["$base"]=1
        copy_host_lib "$cur"
        while read -r need; do
            if [ -n "$need" ]; then
                if p="$(resolve_host_lib "$need")"; then queue+=("$p"); fi
            fi
        done < <(readelf -dW "$cur" 2>/dev/null | awk '/NEEDED/{print $NF}' | tr -d '[]')
    done
    echo "[INFO] bundled $name into the initramfs with its shared libraries"
    return 0
}

CRYPT_BIN=""
for p in "$LFS/usr/sbin/cryptsetup" "$LFS/sbin/cryptsetup"; do
    if [ -x "$p" ]; then
        CRYPT_BIN="$p"
        break
    fi
done
LVM_BIN=""
for p in "$LFS/usr/sbin/lvm" "$LFS/sbin/lvm"; do
    if [ -x "$p" ]; then
        LVM_BIN="$p"
        break
    fi
done
if [ -n "$CRYPT_BIN" ]; then
    echo "[INFO] Bundling cryptsetup for the LUKS unlock"
    bundle_tool "$CRYPT_BIN" cryptsetup || echo "[WARN] could not bundle cryptsetup"
fi
if [ -n "$LVM_BIN" ]; then
    echo "[INFO] Bundling lvm for LVM root activation"
    bundle_tool "$LVM_BIN" lvm || echo "[WARN] could not bundle lvm"
fi

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

# ---------------------------------------------------------------------------
# LUKS / dm-crypt + LVM unlock (runs before root resolution)
#
# An encrypted install puts one of these on the kernel command line:
#   cryptdevice=<src>:<name>   mkinitcpio/Calamares convention; <src> is
#                              UUID=..., LABEL=... or a /dev node
#   rd.luks.uuid=<uuid>        dracut convention
# dm-crypt is built into vmlinuz (config/kernel-config*) and cryptsetup/lvm are
# bundled into this initramfs, so nothing has to be modprobe'd here.  The
# container is opened first, then any LVM volume groups stacked on it are
# activated, so the root logic below can mount /dev/mapper/<name>.
# ---------------------------------------------------------------------------
CRYPT_SRC=""
CRYPT_NAME=""
for param in $(cat /proc/cmdline); do
    case "$param" in
        cryptdevice=*)
            _cd="${param#cryptdevice=}"
            CRYPT_SRC="${_cd%%:*}"
            _rest="${_cd#*:}"
            CRYPT_NAME="${_rest%%:*}"
            ;;
        rd.luks.uuid=* | luks.uuid=*)
            CRYPT_SRC="UUID=${param#*=}"
            [ -n "$CRYPT_NAME" ] || CRYPT_NAME="luksroot"
            ;;
    esac
done

if [ -n "$CRYPT_NAME" ] && [ -x /bin/cryptsetup ]; then
    _src="$CRYPT_SRC"
    case "$CRYPT_SRC" in
        UUID=* | LABEL=*) _src="$(findfs "$CRYPT_SRC" 2>/dev/null)" ;;
    esac
    # The physical device probe is asynchronous (see wait_for_dev below), so
    # poll for the source node before handing it to cryptsetup.
    _tries=0
    while [ "$_tries" -lt 10 ]; do
        [ -n "$_src" ] && [ -e "$_src" ] && break
        /bin/busybox sleep 1
        case "$CRYPT_SRC" in
            UUID=* | LABEL=*) _src="$(findfs "$CRYPT_SRC" 2>/dev/null)" ;;
            *) _src="$CRYPT_SRC" ;;
        esac
        _tries=$((_tries + 1))
    done
    /bin/busybox mkdir -p /dev/mapper /run
    echo "Unlocking LUKS device $_src as $CRYPT_NAME (enter passphrase)"
    if /bin/cryptsetup luksOpen "$_src" "$CRYPT_NAME"; then
        echo "LUKS container $CRYPT_NAME opened"
    else
        echo "LUKS unlock failed for $_src. Dropping to shell."
        /bin/busybox sh
    fi
elif [ -n "$CRYPT_NAME" ]; then
    echo "cryptdevice=$CRYPT_SRC:$CRYPT_NAME is on the cmdline but /bin/cryptsetup"
    echo "is absent: this initramfs was built without LUKS support. Dropping to shell."
    /bin/busybox sh
fi

# Activate LVM volume groups; an LVM-backed root is /dev/mapper/<vg>-<lv>.
if [ -x /bin/lvm ]; then
    /bin/busybox mkdir -p /dev/mapper /run
    /bin/lvm vgchange -ay --sysinit 2>/dev/null || true
fi

# If the cmdline named a LUKS container but no explicit root=, default the root
# to the mapper node the unlock just created.
if [ -n "$CRYPT_NAME" ] && [ -z "$ROOT_DEV" ] && [ -z "$ROOT_UUID" ]; then
    ROOT_DEV="/dev/mapper/$CRYPT_NAME"
fi

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

# wait_for_dev <device> [seconds] - poll until the block node shows up.
# Block-device probing (PCI, AHCI, virtio-blk, SCSI scan) is asynchronous:
# devtmpfs is mounted above, but /dev/sdX nodes can appear seconds later,
# especially under TCG-emulated QEMU with no KVM.  Testing the node exactly
# once raced ahead of the probe and dropped to a shell with "Root device not
# found" for a disk and a driver that were both fine (Nightly #227).
# Integer sleeps only: busybox fractional sleep needs
# CONFIG_FEATURE_FANCY_SLEEP, which the downloaded static binary lacks.
wait_for_dev() {
    local dev="$1" timeout="${2:-10}" i=0
    [ -n "$dev" ] || return 1
    while [ "$i" -lt "$timeout" ]; do
        [ -b "$dev" ] && return 0
        /bin/busybox sleep 1
        i=$((i + 1))
    done
    [ -b "$dev" ]
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
    # Give the kernel time to finish enumerating the disk before declaring
    # the root device missing (see wait_for_dev above).
    if [ -n "$ROOT_DEV" ]; then
        wait_for_dev "$ROOT_DEV" 10
    fi

    # Fallback: try common root device names.  /dev/sr0 leads because both
    # ISO images keep live.squashfs on the boot media, and on aarch64
    # CONFIG_CMDLINE_FORCE bakes root=/dev/mmcblk0p2 into the kernel, so the
    # root= the ISO's GRUB passes never reaches the initramfs at all and
    # probing the optical device is the only way that image finds its own
    # squashfs.  Partition 3 leads the disk candidates because
    # host/03-create-disk-image.sh lays the image out as p1=ESP(/boot),
    # p2=swap, p3=root - probing p2 first tried to mount the swap partition
    # (the same mistake already fixed in tools/qemu-boot-smoke.sh).
    if [ -z "$ROOT_DEV" ] || [ ! -b "$ROOT_DEV" ]; then
        for candidate in /dev/sr0 \
                         /dev/sda3 /dev/vda3 /dev/nvme0n1p3 \
                         /dev/sda2 /dev/vda2 /dev/nvme0n1p2 \
                         /dev/xvda2 /dev/sda1 /dev/vda1; do
            if wait_for_dev "$candidate" 2; then
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

# ---------------------------------------------------------------------------
# Live media support: the live ISO (final/15-create-live-system.sh) boots
# with root=/dev/sr0, but the real root filesystem lives inside the
# live.squashfs stored on the media, not on the media itself.
# ---------------------------------------------------------------------------
if [ -f /mnt/live.squashfs ]; then
    echo "Live media detected, mounting live.squashfs"
    mkdir -p /sysroot /sysroot/media/live
    # mount -o loop automatically sets up the loop device, avoiding the
    # need for /dev/loop0 to exist beforehand (devtmpfs may not create it).
    # This is more robust than explicit losetup in a minimal initramfs.
    if /bin/busybox mount -o loop,ro /mnt/live.squashfs /sysroot 2>/dev/null; then
        # Move the boot media mount inside the new root so the file
        # backing the loop device survives switch_root.
        /bin/busybox mount -o move /mnt /sysroot/media/live 2>/dev/null || true
    else
        echo "Failed to mount live.squashfs. Dropping to shell."
        /bin/busybox sh
    fi
    /bin/busybox umount /proc
    /bin/busybox umount /sys
    /bin/busybox umount /dev
    exec /bin/busybox switch_root /sysroot /sbin/init
fi

/bin/busybox umount /proc
/bin/busybox umount /sys
/bin/busybox umount /dev
exec /bin/busybox switch_root /mnt /sbin/init
EOF

chmod 755 "$INITRAMFS_DIR/init"

# --------------------------------------------------------------------------
# FIPS-mode marker (Phase 3, gated on security.fips.enabled)
# --------------------------------------------------------------------------
# The kernel performs its own FIPS power-on self-test at boot because
# CONFIG_CRYPTO_FIPS=y and the crypto API is built in, so the POST runs
# before this initramfs is even unpacked: there is no initramfs crypto
# module to load and no per-module HMAC to carry, and the fips=1 cmdline
# (final/13) is what arms it. All the early environment needs is the
# /etc/system-fips marker blfs/08 wrote into the rootfs, mirrored here so
# anything inspecting FIPS state before switch_root sees a consistent
# answer. No-op unless FIPS resolved on.
if [ "${LFS_CONFIG_SECURITY_FIPS_ENABLED:-false}" = "true" ]; then
    echo "[INFO] FIPS-mode enabled: mirroring /etc/system-fips into initramfs"
    : >"$INITRAMFS_DIR/etc/system-fips"
    [ -e "$LFS/etc/system-fips" ] || : >"$LFS/etc/system-fips"
fi

# --------------------------------------------------------------------------
# Create compressed cpio archive (prefer zstd, fallback to gzip)
# --------------------------------------------------------------------------
cd "$INITRAMFS_DIR"
if command -v zstd >/dev/null 2>&1; then
    echo "[INFO] Compressing initramfs with zstd..."
    find . | cpio -o -H newc 2>/dev/null | zstd -19 -q >"$INITRAMFS_OUTPUT"
else
    echo "[INFO] Compressing initramfs with gzip..."
    find . | cpio -o -H newc 2>/dev/null | gzip -9 >"$INITRAMFS_OUTPUT"
fi
cd - >/dev/null

rm -rf "$INITRAMFS_DIR"
echo "[SUCCESS] Initramfs created at $INITRAMFS_OUTPUT"
ls -lh "$INITRAMFS_OUTPUT"
