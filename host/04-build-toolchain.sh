#!/usr/bin/env bash
# Build cross-toolchain - Compatible with Docker and native
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fallback functions if utils.sh doesn't exist
if [ -f "$SCRIPT_DIR/../common/utils.sh" ]; then
    source "$SCRIPT_DIR/../common/utils.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warning() { echo "[WARNING] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
fi

# -------------------------------------------------------------------
# Distribution and package management helpers
# -------------------------------------------------------------------
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    elif [ -f /etc/alpine-release ]; then
        echo "alpine"
    else
        echo "unknown"
    fi
}

install_packages() {
    local distro="$1"
    shift
    local packages=("$@")
    log_info "Installing packages: ${packages[*]}"

    case "$distro" in
        debian|ubuntu)
            sudo apt-get update -qq
            sudo apt-get install -y -qq "${packages[@]}"
            ;;
        fedora|rhel|centos|rocky)
            if command -v dnf &>/dev/null; then
                sudo dnf install -y "${packages[@]}"
            else
                sudo yum install -y "${packages[@]}"
            fi
            ;;
        opensuse*|sles)
            sudo zypper install -y "${packages[@]}"
            ;;
        arch|manjaro)
            sudo pacman -Syu --noconfirm "${packages[@]}"
            ;;
        alpine)
            sudo apk add "${packages[@]}"
            ;;
        gentoo)
            log_error "Gentoo detected. Please install the following manually using emerge: ${packages[*]}"
            exit 1
            ;;
        *)
            log_error "Unknown distribution. Please install the following manually: ${packages[*]}"
            exit 1
            ;;
    esac
}

ensure_compiler() {
    if command -v gcc &>/dev/null; then
        log_info "GCC is already installed: $(gcc --version | head -1)"
        return 0
    fi
    log_warning "GCC not found, attempting to install via package manager"
    local distro
    distro=$(detect_distro)
    case "$distro" in
        debian|ubuntu) install_packages "$distro" gcc ;;
        fedora|rhel|centos|rocky) install_packages "$distro" gcc ;;
        arch|manjaro) install_packages "$distro" gcc ;;
        opensuse*|sles) install_packages "$distro" gcc ;;
        *) log_error "Cannot install GCC automatically. Please install it manually."; exit 1 ;;
    esac
    if ! command -v gcc &>/dev/null; then
        log_error "GCC installation failed"
        exit 1
    fi
    log_success "GCC installed successfully"
}

# -------------------------------------------------------------------
# Kernel type (env variable or default)
# -------------------------------------------------------------------
KERNEL_TYPE="${KERNEL_TYPE:-linux}"
export KERNEL_TYPE
log_info "Kernel type: $KERNEL_TYPE"

# Detect if running in Docker
IN_DOCKER=false
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
    IN_DOCKER=true
    log_info "Running in Docker container"
fi

# Configuration
if [ "$IN_DOCKER" = true ]; then
    LFS=${LFS:-/output/image}
else
    LFS=${LFS:-/mnt/lfs}
fi

LFS_TGT=${LFS_TGT:-$(uname -m)-lfs-linux-gnu}
NUM_JOBS=${NUM_JOBS:-$(nproc 2>/dev/null || echo 4)}
LC_ALL=POSIX

log_info "Building cross-toolchain as $(whoami)"
log_info "LFS: $LFS"
log_info "Target: $LFS_TGT"
log_info "Jobs: $NUM_JOBS"

# Ensure directories exist
mkdir -pv "$LFS"/{tools,sources}

# Check if toolchain already exists
check_toolchain() {
    if [ -f "$LFS/tools/bin/ld" ] && [ -f "$LFS/tools/bin/gcc" ]; then
        log_success "Toolchain already exists at $LFS/tools"
        return 0
    fi
    return 1
}

# Create minimal toolchain (only used if sources are missing)
create_minimal_toolchain() {
    log_warning "Creating minimal toolchain with symlinks to host tools (NOT for LFS final build!)"
    mkdir -pv "$LFS/tools/bin"

    # Symlink host compiler and binutils
    for tool in gcc g++ ld ar ranlib nm strip; do
        if command -v $tool &>/dev/null; then
            ln -sfv "$(which $tool)" "$LFS/tools/bin/$tool"
        fi
    done
    # Symlink basic tools
    for tool in bash cat cp echo grep ls make mkdir mv rm sed tar touch uname find xargs chmod chown; do
        if command -v $tool &>/dev/null; then
            ln -sfv "$(which $tool)" "$LFS/tools/bin/$tool"
        fi
    done
    # Ensure ld-linux is present
    if [ ! -f "$LFS/lib64/ld-linux-x86-64.so.2" ] && [ -f /lib64/ld-linux-x86-64.so.2 ]; then
        mkdir -pv "$LFS/lib64"
        cp -L /lib64/ld-linux-x86-64.so.2 "$LFS/lib64/"
    fi
    log_success "Minimal toolchain created (host symlinks)."
    return 0
}

# -------------------------------------------------------------------
# CORRECTED build_toolchain() – official LFS pass 1
# -------------------------------------------------------------------
build_toolchain() {
    log_info "Building temporary toolchain from sources (LFS pass 1)"

    cd "$LFS/sources" || {
        log_error "Sources directory not found: $LFS/sources"
        create_minimal_toolchain
        return $?
    }

    # Check required source archives
    for pkg in binutils gcc linux glibc; do
        if ! ls -1 "$pkg"-*.tar.* &>/dev/null; then
            log_error "Source for $pkg not found in $LFS/sources"
            create_minimal_toolchain
            return 1
        fi
    done

    # ---- 1. Binutils (pass 1) ----
    log_info "Building binutils (pass 1)"
    BINUTILS_TAR=$(ls -1 binutils-*.tar.xz 2>/dev/null | head -n1)
    tar -xf "$BINUTILS_TAR"
    BINUTILS_DIR=$(ls -1d binutils-* 2>/dev/null | grep -v '\.tar' | head -n1)
    cd "$BINUTILS_DIR"
    mkdir -v build
    cd build
    ../configure --prefix="$LFS/tools" \
                 --with-sysroot="$LFS" \
                 --target="$LFS_TGT" \
                 --disable-nls \
                 --enable-gprofng=no \
                 --disable-werror
    make -j"$NUM_JOBS"
    make install
    cd "$LFS/sources"
    rm -rf "$BINUTILS_DIR"
    log_success "binutils (pass 1) done"

    # ---- 2. GCC (pass 1) ----
    log_info "Building GCC (pass 1)"
    GCC_TAR=$(ls -1 gcc-*.tar.xz 2>/dev/null | head -n1)
    tar -xf "$GCC_TAR"
    GCC_DIR=$(ls -1d gcc-* 2>/dev/null | grep -v '\.tar' | head -n1)
    cd "$GCC_DIR"
    mkdir -v build
    cd build
    ../configure --target="$LFS_TGT" \
                 --prefix="$LFS/tools" \
                 --with-glibc-version=2.38 \
                 --with-sysroot="$LFS" \
                 --with-newlib \
                 --without-headers \
                 --enable-default-pie \
                 --enable-default-ssp \
                 --disable-nls \
                 --disable-shared \
                 --disable-multilib \
                 --disable-threads \
                 --disable-libatomic \
                 --disable-libgomp \
                 --disable-libquadmath \
                 --disable-libssp \
                 --disable-libvtv \
                 --disable-libstdcxx \
                 --enable-languages=c,c++
    make -j"$NUM_JOBS"
    make install
    # Create cc symlink
    if [ ! -f "$LFS/tools/bin/cc" ]; then
        ln -sfv gcc "$LFS/tools/bin/cc"
    fi
    cd "$LFS/sources"
    rm -rf "$GCC_DIR"
    log_success "GCC (pass 1) done"

    # ---- 3. Linux API headers ----
    log_info "Installing Linux API headers"
    LINUX_TAR=$(ls -1 linux-*.tar.xz 2>/dev/null | head -n1)
    tar -xf "$LINUX_TAR"
    LINUX_DIR=$(ls -1d linux-* 2>/dev/null | grep -v '\.tar' | head -n1)
    cd "$LINUX_DIR"
    make mrproper
    make headers
    find usr/include -name '.*' -delete
    rm -f usr/include/Makefile
    cp -rv usr/include "$LFS/tools/include"
    cd "$LFS/sources"
    rm -rf "$LINUX_DIR"
    log_success "Linux API headers installed"

    # ---- 4. Glibc ----
    log_info "Building glibc"
    GLIBC_TAR=$(ls -1 glibc-*.tar.xz 2>/dev/null | head -n1)
    tar -xf "$GLIBC_TAR"
    GLIBC_DIR=$(ls -1d glibc-* 2>/dev/null | grep -v '\.tar' | head -n1)
    cd "$GLIBC_DIR"
    mkdir -v build
    cd build
    ../configure --prefix="$LFS/tools" \
                 --host="$LFS_TGT" \
                 --build="$(../scripts/config.guess)" \
                 --enable-kernel=4.14 \
                 --with-headers="$LFS/tools/include"
    make -j"$NUM_JOBS"
    make install
    cd "$LFS/sources"
    rm -rf "$GLIBC_DIR"
    log_success "glibc done"

    # ---- 5. Libstdc++ (from GCC sources, re-extract) ----
    log_info "Building libstdc++"
    tar -xf "$GCC_TAR"   # re-extract GCC (we removed it earlier)
    GCC_DIR=$(ls -1d gcc-* 2>/dev/null | grep -v '\.tar' | head -n1)
    cd "$GCC_DIR"
    mkdir -v build-libstdc++
    cd build-libstdc++
    ../libstdc++-v3/configure --host="$LFS_TGT" \
                              --build="$(../config.guess)" \
                              --prefix="$LFS/tools" \
                              --disable-multilib \
                              --disable-nls \
                              --disable-libstdcxx-pch \
                              --with-gxx-include-dir="$LFS/tools/$LFS_TGT/include/c++/$(cat ../gcc/BASE-VER)"
    make -j"$NUM_JOBS"
    make install
    cd "$LFS/sources"
    rm -rf "$GCC_DIR"
    log_success "libstdc++ done"

    log_success "Full temporary toolchain built successfully."
    return 0
}

# Main
main() {
    # Ensure a working compiler is present (try to install if missing)
    ensure_compiler

    # If toolchain already exists, skip
    if check_toolchain; then
        log_success "Toolchain already exists, skipping"
        exit 0
    fi

    # If running as root or in Docker, we can build directly (as lfs user is created)
    if [ "$IN_DOCKER" = true ]; then
        log_info "Running in Docker – building toolchain"
        build_toolchain || create_minimal_toolchain
        log_success "Toolchain setup complete"
        exit 0
    fi

    # Native mode: switch to lfs user if not already
    if [ "$(whoami)" != "lfs" ]; then
        log_warning "Not running as lfs user. Please run as 'lfs' user or use --force."
        log_info "  su - lfs"
        log_info "  cd $LFS/sources"
        log_info "  $0"
        if [ "$1" = "--force" ]; then
            log_info "Force mode enabled – building anyway (may fail if not lfs)"
            build_toolchain || create_minimal_toolchain
        else
            exit 1
        fi
    else
        build_toolchain || create_minimal_toolchain
    fi

    log_success "Cross-toolchain build complete!"
}

main "$@"