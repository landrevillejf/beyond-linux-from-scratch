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

# --------------------------------------------------------------------------
# Logging helpers
# --------------------------------------------------------------------------
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warn() { echo "[WARNING] $*"; }

# Sources directory: the chroot mirror is the canonical copy.  builder.py
# exports LFS as its --output directory, and every consumer of the image
# resolves output_dir/sources – the same layout lfs/08-build-kernel.sh uses.
SOURCES_HOST="$LFS/sources"
if [ ! -d "$SOURCES_HOST" ]; then
    log_error "Sources directory not found: $SOURCES_HOST"
    exit 1
fi

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
# Helper function to check if a binary is statically linked
# --------------------------------------------------------------------------
# The initramfs has no libc yet, so busybox must be statically linked: a
# dynamic one is copied happily and then dies at exec with "No such file or
# directory", which reads like a missing file rather than a missing
# interpreter.  readelf is authoritative – a static executable carries no
# PT_INTERP program header.
is_static_binary() {
    [ -f "$1" ] || return 1
    command -v readelf >/dev/null 2>&1 || return 0
    ! readelf -lW "$1" 2>/dev/null | grep -q 'INTERP'
}

# --------------------------------------------------------------------------
# Regression guard (lg3d Nightly #125): a static busybox must not execute AVX
# before main().  glibc's startup (_start -> __libc_start_main, into which
# init_cpu_features is constprop-inlined) runs unconditionally for every
# static binary; when any of it is compiled with AVX (VEX vmovd / vpinsrd /
# vmovq) it raises #UD on a CPU without AVX and the kernel panics with
# "Attempted to kill init! exitcode=0x00000004".  The IFUNC-guarded *_avx*
# memcpy/string variants are legitimate -- they are only dispatched when the
# CPU reports AVX, and __libc_start_main merely stores their address -- so
# this scans ONLY the unconditional startup chain and fails the build if it
# carries a single VEX/AVX instruction.  This is the check the old text-only
# validator never performed: it inspected a binary, not a string, so it gave
# false confidence.
#
# x86_64 only: objdump on the host cannot disassemble a foreign target, and a
# non-x86 glibc has no AVX startup to begin with.
# --------------------------------------------------------------------------
assert_no_startup_avx() {
    local bin="$1" disasm
    if [ "$TARGET_ARCH" != "x86_64" ]; then
        return 0
    fi
    if ! command -v objdump >/dev/null 2>&1; then
        log_warn "objdump not available on the host; skipping the startup AVX guard"
        return 0
    fi
    # Isolate the unconditional startup functions.  A function-header line is
    # "<addr> <name>:"; any other header flips the flag off, so a following
    # non-startup function is never scanned.  POSIX-awk only (the Ubuntu
    # runner's default awk is mawk, which lacks gawk's 3-arg match()).
    disasm="$(objdump -d --no-show-raw-insn "$bin" 2>/dev/null |
        awk '/^[0-9a-f]+ <.*>:/ {
                inf = ($0 ~ /<_start>:/ || $0 ~ /<__libc_start_main/ ||
                       $0 ~ /<init_cpu_features/ || $0 ~ /<__libc_early_init/)
                next
             }
             inf { print }')"
    if [ -z "$disasm" ]; then
        # No startup symbols: the binary handed in was stripped.  The chroot
        # build exposes busybox_unstripped precisely so this cannot happen.
        log_warn "no glibc startup symbols in $(basename "$bin") (stripped?); skipping the AVX guard"
        return 0
    fi
    # Field 2 of each line is the mnemonic; on x86 every v-prefixed mnemonic
    # is VEX/EVEX (AVX).  %ymm/%zmm operands are AVX-only registers.
    if printf '%s\n' "$disasm" | awk '{ print $2 }' | grep -Eq '^v[a-z]' ||
        printf '%s\n' "$disasm" | grep -Eq '%ymm|%zmm'; then
        log_error "Static busybox startup (_start/__libc_start_main) contains AVX/VEX instructions:"
        printf '%s\n' "$disasm" | grep -E '\sv[a-z]|%ymm|%zmm' | head -n 5 >&2
        log_error "This binary #UDs on a CPU without AVX (lg3d Nightly #125 kernel panic)."
        log_error "busybox must link the target glibc by building inside the $LFS chroot."
        return 1
    fi
    log_info "Startup AVX guard passed: glibc startup chain is baseline (no VEX/AVX)"
    return 0
}

# --------------------------------------------------------------------------
# Build busybox from source INSIDE the $LFS chroot, against the target glibc
# --------------------------------------------------------------------------
# The initramfs has no libc yet, so busybox must be statically linked.  It is
# built inside the chroot -- NOT on the host -- because a static link pulls in
# the whole C library startup, and the host's glibc-static is out of our
# control.  On the Ubuntu 26.04 runner the host libc.a ships an unconditional
# init_cpu_features() compiled with AVX (VEX vmovd/vpinsrd/vmovq), so a
# host-built static busybox executes AVX before main() and #UDs on a CPU
# without AVX: "Attempted to kill init! exitcode=0x00000004" -> kernel panic
# (lg3d Nightly #125, caught by tools/qemu-boot-smoke.sh on -cpu qemu64).
# -march=x86-64 in CFLAGS cannot fix this: it only recompiles busybox's own
# objects, never the pre-compiled libc.a startup.  The target glibc that
# lfs/05b built is baseline (its init_cpu_features uses SSE2 movd/movdqa), so
# linking inside the chroot is what actually removes the AVX.
#
# Building from source also eliminates the supply-chain risk of downloading a
# pre-built binary without checksum verification, and avoids the busybox.net
# x86_64-v3 prebuilts that required AVX (lg3d nightly 20261108).
# --------------------------------------------------------------------------
BUSYBOX_VERSION="1.36.1"
BUSYBOX_TARBALL="busybox-${BUSYBOX_VERSION}.tar.bz2"
BUSYBOX_URL="https://busybox.net/downloads/${BUSYBOX_TARBALL}"
# Where the in-chroot build leaves the binaries, as host paths.  busybox's
# make emits busybox (stripped, the one that ships) and busybox_unstripped
# (with the symbol table the AVX guard needs to isolate the startup chain).
BUSYBOX_BUILT_BIN="$LFS/tmp/busybox-built"
BUSYBOX_UNSTRIPPED_BIN="$LFS/tmp/busybox-built-unstripped"

# -march=x86-64/-mtune=generic is x86-specific; handing it to a non-x86
# target gcc aborts the build, so baseline flags are only added for x86_64.
case "$TARGET_ARCH" in
x86_64) BUSYBOX_CFLAGS="-march=x86-64 -mtune=generic -O2 -static" ;;
*) BUSYBOX_CFLAGS="-O2 -static" ;;
esac

# Download the source on the HOST into $LFS/sources: the chroot has no
# network, but $LFS/sources is /sources inside it.
if [ ! -f "$SOURCES_HOST/$BUSYBOX_TARBALL" ]; then
    log_info "Downloading busybox source from $BUSYBOX_URL"
    wget -q -O "$SOURCES_HOST/$BUSYBOX_TARBALL" "$BUSYBOX_URL" || {
        log_error "Failed to download busybox source from $BUSYBOX_URL"
        exit 1
    }
fi

log_info "Building busybox $BUSYBOX_VERSION inside the chroot (CFLAGS='$BUSYBOX_CFLAGS')..."

# The build runs entirely inside $LFS so busybox links the target's baseline
# glibc.  Everything it needs is passed through `env -i` because the heredoc
# is quoted (no host expansion); $(nproc) is meant to run in-chroot.
cat >"$LFS/build-busybox.sh" <<'BUILDEOF'
#!/bin/bash
set -e
cd /tmp
rm -rf busybox-build
mkdir -p busybox-build
cd busybox-build
tar -xf "/sources/${BUSYBOX_TARBALL}"
cd "busybox-${BUSYBOX_VERSION}"
make defconfig >/dev/null 2>&1
# CONFIG_STATIC=y links busybox against the target's static libc.a.
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
# TC/TUNCTL applets need newer kernel headers than the initramfs requires.
for applet in CONFIG_TC CONFIG_FEATURE_TC_INGRESS CONFIG_TUNCTL CONFIG_FEATURE_TUNCTL_QUIET_FAILURE; do
    sed -i "s/^${applet}=y/# ${applet} is not set/" .config 2>/dev/null || true
done
make CFLAGS="${BUSYBOX_CFLAGS}" LDFLAGS="-static" -j"$(nproc)" >/dev/null 2>&1
# busybox's make strips busybox down from busybox_unstripped.  Ship the
# stripped binary but also expose the unstripped one: the host-side AVX guard
# needs its symbol table to isolate _start/__libc_start_main.
cp -f busybox /tmp/busybox-built
if [ -f busybox_unstripped ]; then
    cp -f busybox_unstripped /tmp/busybox-built-unstripped
else
    cp -f busybox /tmp/busybox-built-unstripped
fi
BUILDEOF

chmod 755 "$LFS/build-busybox.sh"
chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin:/bin:/sbin \
    BUSYBOX_VERSION="$BUSYBOX_VERSION" BUSYBOX_TARBALL="$BUSYBOX_TARBALL" \
    BUSYBOX_CFLAGS="$BUSYBOX_CFLAGS" \
    /bin/bash /build-busybox.sh || {
    log_error "Failed to build busybox inside the chroot"
    log_error "Check that gcc, make, tar and bzip2 are installed in $LFS"
    rm -f "$LFS/build-busybox.sh"
    exit 1
}
rm -f "$LFS/build-busybox.sh"

if [ ! -f "$BUSYBOX_BUILT_BIN" ]; then
    log_error "Chroot build finished but $BUSYBOX_BUILT_BIN is missing"
    exit 1
fi

# Verify the built binary is static (no PT_INTERP -> the initramfs can exec it).
if ! is_static_binary "$BUSYBOX_BUILT_BIN"; then
    log_error "Built busybox is not a static binary"
    log_error "This will fail in the initramfs (no libc available)"
    exit 1
fi

# Real, binary-level regression guard for lg3d Nightly #125: prove the
# unconditional glibc startup path carries no AVX before the binary ships.
# Runs against busybox_unstripped, whose symbol table the guard needs.
if ! assert_no_startup_avx "$BUSYBOX_UNSTRIPPED_BIN"; then
    rm -rf "$LFS/tmp/busybox-build" "$BUSYBOX_BUILT_BIN" "$BUSYBOX_UNSTRIPPED_BIN"
    exit 1
fi

log_info "Busybox built successfully (static + baseline-startup verified)"

# Install busybox into the initramfs.
mkdir -p "$INITRAMFS_DIR/bin"
cp -v "$BUSYBOX_BUILT_BIN" "$INITRAMFS_DIR/bin/busybox" || {
    log_error "Failed to copy busybox to initramfs"
    exit 1
}
chmod 755 "$INITRAMFS_DIR/bin/busybox"

# Clean up the in-chroot build tree and the staged binaries.
rm -rf "$LFS/tmp/busybox-build" "$BUSYBOX_BUILT_BIN" "$BUSYBOX_UNSTRIPPED_BIN"

log_info "Busybox installed to $INITRAMFS_DIR/bin/busybox"

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
# iso9660 and udf belong in the list, not just in the auto-detect attempt
# above it: the live and installer ISOs both pass root=/dev/sr0, so this is
# the mount that has to succeed before /mnt/live.squashfs can even be seen.
# The static busybox here has no /etc/filesystems to consult in the
# initramfs, so an optical device with no -t falls through to the disk
# types; without iso9660 the boot media never mounts and the live path
# below is unreachable.
try_mount() {
    local dev="$1"
    [ -b "$dev" ] || return 1
    /bin/busybox mount "$dev" /mnt 2>/dev/null && return 0
    for fstype in ext4 xfs btrfs f2fs iso9660 udf; do
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
# live.squashfs stored on the media, not on the media itself.  The squashfs
# is read-only, so a tmpfs-backed overlayfs is stacked on top of it:
# without an upper layer every write of the live session (X11 sockets in
# /tmp, lightdm state in /var, lg3d temp files) fails and the desktop never
# starts.  upper and work share one tmpfs, and the lower, the rw tmpfs and
# the media mount are all moved under /sysroot so switch_root carries them
# (switch_root refuses an old rootfs that still has mounts).  Moving onto
# the bare read-only squashfs always failed, which is why the media mount
# used to be lost; the overlay makes the target writable.
# ---------------------------------------------------------------------------
if [ -f /mnt/live.squashfs ]; then
    echo "Live media detected, mounting live.squashfs"
    mkdir -p /live/lower /live/rw /sysroot
    # mount -o loop automatically sets up the loop device, avoiding the
    # need for /dev/loop0 to exist beforehand (devtmpfs may not create it).
    # This is more robust than explicit losetup in a minimal initramfs.
    if ! /bin/busybox mount -o loop,ro /mnt/live.squashfs /live/lower 2>/dev/null; then
        echo "Failed to mount live.squashfs. Dropping to shell."
        /bin/busybox sh
    fi
    if ! /bin/busybox mount -t tmpfs tmpfs /live/rw 2>/dev/null; then
        echo "Failed to mount the live overlay tmpfs. Dropping to shell."
        /bin/busybox sh
    fi
    mkdir -p /live/rw/upper /live/rw/work
    if ! /bin/busybox mount -t overlay overlay \
        -o lowerdir=/live/lower,upperdir=/live/rw/upper,workdir=/live/rw/work \
        /sysroot 2>/dev/null; then
        echo "Failed to stack the overlay on live.squashfs. Dropping to shell."
        /bin/busybox sh
    fi
    mkdir -p /sysroot/.live /sysroot/media/live
    /bin/busybox mount -o move /live/lower /sysroot/.live/lower 2>/dev/null || true
    /bin/busybox mount -o move /live/rw /sysroot/.live/rw 2>/dev/null || true
    # Move the boot media mount inside the new root so the file
    # backing the loop device survives switch_root.
    /bin/busybox mount -o move /mnt /sysroot/media/live 2>/dev/null || true
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
