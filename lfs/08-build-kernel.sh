#!/bin/bash
# Build and install the Linux kernel in the LFS system.
# Author : Jean-Francois Landreville, landrevvillejf@protonmail.com, 2026.
# 08-build-kernel.sh – LFS 12.4 section 10.3: the kernel is compiled inside
#                       the chroot with the system toolchain using the curated
#                       repository configuration (config/kernel-config*).
#                       Cross-compile profiles (CROSS_COMPILE set) still build
#                       on the host, but with the same repository config.
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[INFO] Relaunching with sudo..."
    exec sudo -E "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LFS=${LFS:-/mnt/lfs}
KERNEL_TYPE=${KERNEL_TYPE:-linux}
ARCH=${ARCH:-$(uname -m)}
PROFILE=${PROFILE:-minimal}
CROSS_COMPILE=${CROSS_COMPILE:-}

# Normalise ARCH for make
case "$ARCH" in
x86_64 | amd64) MAKE_ARCH="x86_64" ;;
aarch64 | arm64) MAKE_ARCH="arm64" ;;
armv7l | armhf) MAKE_ARCH="arm" ;;
riscv64) MAKE_ARCH="riscv" ;;
*) MAKE_ARCH="$ARCH" ;;
esac

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_success() { echo "[SUCCESS] $*"; }

if [ -d "$LFS/image/tools" ] && [ -d "$LFS/image/usr" ] && [ ! -d "$LFS/tools" ]; then
    LFS="$LFS/image"
fi

# ---------------------------------------------------------------------------
# Select the curated kernel configuration from the repository.  Explicit
# KERNEL_CONFIG_FILE wins, then per-profile variants, then the default.
# ---------------------------------------------------------------------------
CONFIG_DIR="$SCRIPT_DIR/../config"
if [ -n "${KERNEL_CONFIG_FILE:-}" ] && [ -f "$KERNEL_CONFIG_FILE" ]; then
    KERNEL_CONFIG_SRC="$KERNEL_CONFIG_FILE"
elif [ -f "$CONFIG_DIR/kernel-config-$PROFILE" ]; then
    KERNEL_CONFIG_SRC="$CONFIG_DIR/kernel-config-$PROFILE"
elif [ "$MAKE_ARCH" = "arm64" ] && [ -f "$CONFIG_DIR/kernel-config-arm64" ]; then
    KERNEL_CONFIG_SRC="$CONFIG_DIR/kernel-config-arm64"
else
    KERNEL_CONFIG_SRC="$CONFIG_DIR/kernel-config"
fi
if [ ! -f "$KERNEL_CONFIG_SRC" ]; then
    log_error "Kernel configuration not found: $KERNEL_CONFIG_SRC"
    exit 1
fi
log_info "Using kernel configuration: $KERNEL_CONFIG_SRC"

# ---------------------------------------------------------------------------
# Locate the kernel sources.  The chroot mirror ($LFS/sources) is the
# canonical copy: lfs-basic populates it for every profile, whatever
# the builder's host output layout (nightly #185 died on the old
# "$(dirname $LFS)/sources" guess because CI keeps its sources in
# build-release/sources, not next to $LFS).
# ---------------------------------------------------------------------------
SOURCES_HOST="$LFS/sources"
if [ ! -d "$SOURCES_HOST" ]; then
    log_error "Sources directory not found: $SOURCES_HOST"
    exit 1
fi

cd "$SOURCES_HOST"
KERNEL_TARBALL=$(find . -maxdepth 1 -name "${KERNEL_TYPE}-*.tar.*" -print -quit 2>/dev/null | head -n1)
if [ -z "$KERNEL_TARBALL" ]; then
    log_error "No kernel source found for type '$KERNEL_TYPE'"
    exit 1
fi
KERNEL_TARBALL=${KERNEL_TARBALL#./}

KERNEL_VERSION=$(echo "$KERNEL_TARBALL" | sed -E 's/^[^-]+(-libre)?-([0-9]+\.[0-9]+\.[0-9]+)\.tar\..*$/\2/')
KERNEL_DIR=$(tar -tf "$KERNEL_TARBALL" | head -1 | cut -d/ -f1)
log_info "Using kernel source: $KERNEL_TARBALL (version $KERNEL_VERSION)"

# Skip if already installed
if [ -f "$LFS/boot/vmlinuz" ]; then
    log_info "Kernel already installed – skipping"
    exit 0
fi

# ---------------------------------------------------------------------------
# Cross-compile path: the chroot cannot execute host-foreign binaries, so
# ARM-style profiles compile on the host with the cross toolchain but still
# use the curated repository configuration instead of defconfig.
# ---------------------------------------------------------------------------
if [ -n "$CROSS_COMPILE" ]; then
    WORKDIR=$(mktemp -d)
    trap 'rm -rf "$WORKDIR"' EXIT
    cd "$WORKDIR"
    log_info "Extracting kernel source (cross-compile on host)"
    tar -xf "$SOURCES_HOST/$KERNEL_TARBALL"
    cd "$KERNEL_DIR"

    MAKE_CMD="make ARCH=$MAKE_ARCH CROSS_COMPILE=$CROSS_COMPILE"

    log_info "Cleaning source tree (make mrproper)"
    $MAKE_CMD mrproper
    log_info "Configuring kernel from $KERNEL_CONFIG_SRC"
    cp "$KERNEL_CONFIG_SRC" .config
    $MAKE_CMD olddefconfig
    log_info "Compiling kernel (using -j$(nproc))"
    $MAKE_CMD -j"$(nproc)"
    log_info "Installing modules to $LFS"
    $MAKE_CMD modules_install INSTALL_MOD_PATH="$LFS"

    KERNEL_IMAGE=""
    for candidate in "arch/$MAKE_ARCH/boot/bzImage" "arch/$MAKE_ARCH/boot/Image" \
                     "arch/$MAKE_ARCH/boot/zImage" "vmlinuz"; do
        if [ -f "$candidate" ]; then
            KERNEL_IMAGE="$candidate"
            break
        fi
    done
    if [ -z "$KERNEL_IMAGE" ]; then
        log_error "No kernel image found"
        exit 1
    fi

    mkdir -p "$LFS/boot"
    cp -v "$KERNEL_IMAGE" "$LFS/boot/vmlinuz-${KERNEL_VERSION}"
    ln -sf "vmlinuz-${KERNEL_VERSION}" "$LFS/boot/vmlinuz"
    cp System.map "$LFS/boot/System.map"
    cp .config "$LFS/boot/config-${KERNEL_VERSION}"
    log_success "Kernel $KERNEL_TYPE cross-compiled and installed to $LFS/boot/vmlinuz"
    exit 0
fi

# ---------------------------------------------------------------------------
# Native path: build inside the chroot with the chapter 8 toolchain
# (LFS 12.4 section 10.3).  The source tarball is already present in the
# chroot's /sources directory; only the configuration file is injected.
# ---------------------------------------------------------------------------
if [ ! -f "$LFS/sources/$KERNEL_TARBALL" ]; then
    log_error "Kernel tarball missing from chroot: $LFS/sources/$KERNEL_TARBALL"
    exit 1
fi
cp "$KERNEL_CONFIG_SRC" "$LFS/sources/.kernel-config"

cleanup_mounts() {
    umount "$LFS"/dev/pts 2>/dev/null || true
    umount "$LFS"/dev 2>/dev/null || true
    umount "$LFS"/proc 2>/dev/null || true
    umount "$LFS"/sys 2>/dev/null || true
    umount "$LFS"/run 2>/dev/null || true
}
trap cleanup_mounts EXIT

mount --bind /dev "$LFS"/dev 2>/dev/null || true
mount -t devpts devpts "$LFS"/dev/pts 2>/dev/null || true
mount -t proc proc "$LFS"/proc 2>/dev/null || true
mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true
mount -t tmpfs tmpfs "$LFS"/run 2>/dev/null || true

cat >"$LFS/build-kernel.sh" <<EOF
#!/bin/bash
set -e
cd /sources
rm -rf "$KERNEL_DIR"
echo "=== Extracting $KERNEL_TARBALL ==="
tar -xf "$KERNEL_TARBALL"
cd "$KERNEL_DIR"

echo "=== make mrproper ==="
make mrproper

echo "=== Installing curated .config ==="
cp /sources/.kernel-config .config
make olddefconfig

echo "=== Compiling kernel ==="
make -j"\$(nproc)"

echo "=== Installing modules ==="
make modules_install

KERNEL_IMAGE=""
for candidate in "arch/$MAKE_ARCH/boot/bzImage" "arch/$MAKE_ARCH/boot/Image" \\
                 "arch/$MAKE_ARCH/boot/zImage" "vmlinuz"; do
    if [ -f "\$candidate" ]; then
        KERNEL_IMAGE="\$candidate"
        break
    fi
done
if [ -z "\$KERNEL_IMAGE" ]; then
    echo "ERROR: no kernel image found"
    exit 1
fi

echo "=== Installing kernel image to /boot ==="
cp -v "\$KERNEL_IMAGE" "/boot/vmlinuz-$KERNEL_VERSION"
ln -sf "vmlinuz-$KERNEL_VERSION" /boot/vmlinuz
cp -v System.map /boot/System.map
cp -v .config "/boot/config-$KERNEL_VERSION"
echo "=== Kernel build complete ==="
EOF
chmod +x "$LFS/build-kernel.sh"

log_info "Building kernel inside the chroot"
chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-kernel.sh

rm -f "$LFS/sources/.kernel-config"

umount "$LFS"/dev/pts 2>/dev/null || true
umount "$LFS"/dev 2>/dev/null || true
umount "$LFS"/proc 2>/dev/null || true
umount "$LFS"/sys 2>/dev/null || true
umount "$LFS"/run 2>/dev/null || true

log_success "Kernel $KERNEL_TYPE compiled and installed to $LFS/boot/vmlinuz"
