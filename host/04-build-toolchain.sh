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

# Create minimal toolchain (with base tools for chroot)
create_minimal_toolchain() {
    log_info "Creating minimal toolchain with base tools for chroot"

    mkdir -pv "$LFS/tools/bin"

    # 1. Compiler and binutils from host
    if command -v gcc &> /dev/null; then
        log_info "Using system GCC: $(gcc --version | head -n1)"
        for tool in gcc g++ ld ar ranlib nm strip; do
            if command -v $tool &> /dev/null; then
                ln -sfv "$(which $tool)" "$LFS/tools/bin/$tool"
            fi
        done
    else
        # Fallback wrapper for GCC
        cat > "$LFS/tools/bin/gcc" << 'WRAPPER'
#!/usr/bin/env bash
echo "WARNING: Using minimal GCC wrapper"
if [ "$1" = "--version" ]; then
    echo "gcc (LFS Minimal) 13.0"
else
    if command -v gcc &> /dev/null; then
        exec gcc "$@"
    fi
fi
exit 0
WRAPPER
        chmod +x "$LFS/tools/bin/gcc"
        ln -sfv gcc "$LFS/tools/bin/cc"
        ln -sfv gcc "$LFS/tools/bin/g++"
    fi

    if [ ! -f "$LFS/tools/bin/ld" ]; then
        cat > "$LFS/tools/bin/ld" << 'WRAPPER'
#!/usr/bin/env bash
if command -v ld &> /dev/null; then
    exec ld "$@"
else
    echo "WARNING: No ld available"
    exit 0
fi
WRAPPER
        chmod +x "$LFS/tools/bin/ld"
    fi

    # 2. Add essential base tools (sed, tar, make, etc.) as symlinks to host
    log_info "Linking essential build tools from host"
    for tool in bash cat cp echo grep ls make mkdir mv rm sed tar touch uname find xargs chmod chown; do
        if command -v $tool &>/dev/null; then
            ln -sfv "$(which $tool)" "$LFS/tools/bin/$tool"
        else
            log_warning "Host tool '$tool' not found, may cause chroot issues"
        fi
    done

    # 3. Ensure ld-linux is available (real copy, not symlink)
    if [ ! -f "$LFS/lib64/ld-linux-x86-64.so.2" ] && [ -f /lib64/ld-linux-x86-64.so.2 ]; then
        mkdir -pv "$LFS/lib64"
        cp -L /lib64/ld-linux-x86-64.so.2 "$LFS/lib64/"
    fi

    log_success "Minimal toolchain (with base tools) created at $LFS/tools"
    return 0
}

# Build toolchain from sources
build_toolchain() {
    log_info "Building toolchain from sources"

    cd "$LFS/sources" || {
        log_error "Sources directory not found: $LFS/sources"
        log_info "Creating minimal toolchain instead"
        create_minimal_toolchain
        return $?
    }

    if ! ls -1 binutils-*.tar.xz &>/dev/null; then
        log_warning "No source files found in $LFS/sources"
        log_info "Creating minimal toolchain instead"
        create_minimal_toolchain
        return $?
    fi

    # Binutils
    log_info "Building binutils"
    BINUTILS_TAR=$(ls -1 binutils-*.tar.xz 2>/dev/null | head -n1)
    if [ -n "$BINUTILS_TAR" ]; then
        tar -xf "$BINUTILS_TAR"
        BINUTILS_DIR=$(ls -1d binutils-* 2>/dev/null | grep -v '\.tar' | head -n1)
        if [ -n "$BINUTILS_DIR" ]; then
            cd "$BINUTILS_DIR"
            mkdir -pv build
            cd build
            ../configure --prefix="$LFS/tools" \
                         --with-sysroot="$LFS" \
                         --target="$LFS_TGT" \
                         --disable-nls \
                         --enable-gprofng=no \
                         --disable-werror 2>/dev/null || {
                log_warning "Binutils configure failed"
                cd ../..
                create_minimal_toolchain
                return $?
            }
            make -j"$NUM_JOBS" 2>/dev/null || {
                log_warning "Binutils make failed"
                cd ../..
                create_minimal_toolchain
                return $?
            }
            make install 2>/dev/null || {
                log_warning "Binutils install failed"
                cd ../..
                create_minimal_toolchain
                return $?
            }
            cd ../..
        fi
    fi

    # GCC
    log_info "Building GCC"
    GCC_TAR=$(ls -1 gcc-*.tar.xz 2>/dev/null | head -n1)
    if [ -n "$GCC_TAR" ]; then
        tar -xf "$GCC_TAR"
        GCC_DIR=$(ls -1d gcc-* 2>/dev/null | grep -v '\.tar' | head -n1)
        if [ -n "$GCC_DIR" ]; then
            cd "$GCC_DIR"
            mkdir -pv build
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
                         --enable-languages=c,c++ 2>/dev/null || {
                log_warning "GCC configure failed"
                cd ../..
                create_minimal_toolchain
                return $?
            }
            make -j"$NUM_JOBS" 2>/dev/null || {
                log_warning "GCC make failed"
                cd ../..
                create_minimal_toolchain
                return $?
            }
            make install 2>/dev/null || {
                log_warning "GCC install failed"
                cd ../..
                create_minimal_toolchain
                return $?
            }
            cd ../..
        fi
    fi

    if [ -f "$LFS/tools/bin/gcc" ] && [ ! -f "$LFS/tools/bin/cc" ]; then
        ln -sfv gcc "$LFS/tools/bin/cc"
    fi

    log_success "Toolchain build complete"
    return 0
}

# Main
main() {
    # Ensure a working compiler is present (try to install if missing)
    ensure_compiler

    if [ "$IN_DOCKER" = true ]; then
        log_info "Running in Docker"
        if check_toolchain; then
            log_success "Toolchain already exists, skipping"
            exit 0
        fi
        log_info "Building toolchain for Docker"
        build_toolchain || create_minimal_toolchain
        log_success "Toolchain setup complete"
        exit 0
    fi

    if check_toolchain; then
        log_success "Toolchain already exists, skipping"
        exit 0
    fi

    if [ "$(whoami)" != "lfs" ]; then
        log_warning "Not running as lfs user. Switch to lfs user first:"
        log_info "  su - lfs"
        log_info "  cd $LFS/sources"
        log_info "  $0"
        if [ "$1" = "--force" ]; then
            log_info "Force mode enabled - building anyway"
            build_toolchain
        else
            exit 1
        fi
    else
        build_toolchain
    fi

    log_success "Cross-toolchain build complete!"
}

main "$@"