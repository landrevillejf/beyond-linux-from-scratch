#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[INFO] Relaunching with sudo..."
    exec sudo -E "$0" "$@"
fi

LFS=${LFS:-/mnt/lfs}
KERNEL_TYPE=${KERNEL_TYPE:-linux}
ARCH=${ARCH:-$(uname -m)}
LFS_TGT=${LFS_TGT:-${ARCH}-lfs-linux-gnu}
CROSS_COMPILE=${CROSS_COMPILE:-}

# Normalise ARCH for make
case "$ARCH" in
    x86_64|amd64)  MAKE_ARCH="x86_64" ;;
    aarch64|arm64) MAKE_ARCH="arm64"  ;;
    armv7l|armhf)  MAKE_ARCH="arm"    ;;
    riscv64)       MAKE_ARCH="riscv"  ;;
    *)             MAKE_ARCH="$ARCH"  ;;
esac

KERNEL_VERSION=""

log_info()    { echo "[INFO] $*"; }
log_error()   { echo "[ERROR] $*" >&2; }
log_success() { echo "[SUCCESS] $*"; }

# ---------------------------------------------------------------------------
# Use the host's sources directory (where the builder downloads tarballs)
# ---------------------------------------------------------------------------
SOURCES_HOST="$(dirname "$LFS")/sources"
if [ ! -d "$SOURCES_HOST" ]; then
    log_error "Sources directory not found: $SOURCES_HOST"
    exit 1
fi

cd "$SOURCES_HOST"
KERNEL_TARBALL=$(find . -maxdepth 1 -name "${KERNEL_TYPE}-*.tar.xz" -print -quit 2>/dev/null | head -n1)
if [ -z "$KERNEL_TARBALL" ]; then
    log_error "No kernel source found for type '$KERNEL_TYPE'"
    exit 1
fi

KERNEL_VERSION=$(echo "$KERNEL_TARBALL" | sed -E 's/^[^-]+-([0-9]+\.[0-9]+\.[0-9]+)\.tar\..*$/\1/')
log_info "Using kernel source: $KERNEL_TARBALL (version $KERNEL_VERSION)"

# Skip if already installed
if [ -f "$LFS/boot/vmlinuz" ]; then
    log_info "Kernel already installed – skipping"
    exit 0
fi

# ---------------------------------------------------------------------------
# Extract and compile on the host (temporary directory)
# ---------------------------------------------------------------------------
WORKDIR=$(mktemp -d)
cd "$WORKDIR"
log_info "Extracting kernel source"
tar -xf "$SOURCES_HOST/$KERNEL_TARBALL"
KERNEL_DIR=$(tar -tf "$SOURCES_HOST/$KERNEL_TARBALL" | head -1 | cut -d/ -f1)
cd "$KERNEL_DIR"

# Force ALL tools – override any inherited false* variables
MAKE_CMD="make ARCH=$MAKE_ARCH"
MAKE_CMD="$MAKE_CMD CC=gcc HOSTCC=gcc CXX=g++ HOSTCXX=g++"
MAKE_CMD="$MAKE_CMD LD=ld HOSTLD=ld"
MAKE_CMD="$MAKE_CMD AR=ar HOSTAR=ar"
MAKE_CMD="$MAKE_CMD NM=nm HOSTNM=nm"
MAKE_CMD="$MAKE_CMD READELF=readelf HOSTREADELF=readelf"
MAKE_CMD="$MAKE_CMD OBJCOPY=objcopy HOSTOBJCOPY=objcopy"
MAKE_CMD="$MAKE_CMD OBJDUMP=objdump HOSTOBJDUMP=objdump"
MAKE_CMD="$MAKE_CMD STRIP=strip HOSTSTRIP=strip"
MAKE_CMD="$MAKE_CMD RANLIB=ranlib HOSTRANLIB=ranlib"

log_info "Cleaning source tree (make mrproper)"
$MAKE_CMD mrproper

log_info "Configuring kernel (defconfig)"
$MAKE_CMD defconfig

log_info "Resolving new config symbols with olddefconfig"
$MAKE_CMD olddefconfig

log_info "Compiling kernel (using -j$(nproc))"
$MAKE_CMD ${CROSS_COMPILE:+CROSS_COMPILE="$CROSS_COMPILE"} -j"$(nproc)"

log_info "Installing modules to $LFS"
$MAKE_CMD ${CROSS_COMPILE:+CROSS_COMPILE="$CROSS_COMPILE"} modules_install INSTALL_MOD_PATH="$LFS"

log_info "Copying kernel image and System.map to $LFS/boot"
mkdir -p "$LFS/boot"

# Determine the correct kernel image path
KERNEL_IMAGE=""
if [ -f "arch/x86/boot/bzImage" ]; then
    KERNEL_IMAGE="arch/x86/boot/bzImage"
elif [ -f "arch/$MAKE_ARCH/boot/bzImage" ]; then
    KERNEL_IMAGE="arch/$MAKE_ARCH/boot/bzImage"
elif [ -f "arch/$MAKE_ARCH/boot/Image" ]; then
    KERNEL_IMAGE="arch/$MAKE_ARCH/boot/Image"
elif [ -f "vmlinuz" ]; then
    KERNEL_IMAGE="vmlinuz"
elif [ -f "arch/$MAKE_ARCH/boot/zImage" ]; then
    KERNEL_IMAGE="arch/$MAKE_ARCH/boot/zImage"
else
    log_error "No kernel image found"
    exit 1
fi

cp -v "$KERNEL_IMAGE" "$LFS/boot/vmlinuz-${KERNEL_VERSION}"
# Create symlink for convenience
ln -sf "vmlinuz-${KERNEL_VERSION}" "$LFS/boot/vmlinuz"
cp System.map "$LFS/boot/System.map"
cp .config "$LFS/boot/config-${KERNEL_VERSION}"

cd /
rm -rf "$WORKDIR"

log_success "Kernel $KERNEL_TYPE compiled and installed to $LFS/boot/vmlinuz"