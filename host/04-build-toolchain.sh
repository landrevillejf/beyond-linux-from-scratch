#!/usr/bin/env bash
# Build cross-toolchain - Compatible with Docker and native
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/../common/utils.sh" ]; then
    source "$SCRIPT_DIR/../common/utils.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warning() { echo "[WARNING] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
fi

KERNEL_TYPE=${KERNEL_TYPE:-linux}

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
        *)
            log_error "Unknown distribution. Please install: ${packages[*]}"
            exit 1
            ;;
    esac
}

ensure_compiler() {
    if command -v gcc &>/dev/null; then
        log_info "GCC installed: $(gcc --version | head -1)"
        return 0
    fi
    log_warning "GCC not found, installing..."
    local distro
    distro=$(detect_distro)
    case "$distro" in
        debian|ubuntu) install_packages "$distro" gcc ;;
        fedora|rhel|centos|rocky) install_packages "$distro" gcc ;;
        arch|manjaro) install_packages "$distro" gcc ;;
        opensuse*|sles) install_packages "$distro" gcc ;;
        *) log_error "Install GCC manually."; exit 1 ;;
    esac
    if ! command -v gcc &>/dev/null; then
        log_error "GCC installation failed"
        exit 1
    fi
    log_success "GCC installed"
}

IN_DOCKER=false
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
    IN_DOCKER=true
fi

if [ "$IN_DOCKER" = true ]; then
    LFS=${LFS:-/output/image}
else
    LFS=${LFS:-/mnt/lfs}
fi

if [ -z "$LFS" ]; then
    log_error "LFS not set"
    exit 1
fi

LFS_TGT=${LFS_TGT:-$(uname -m)-lfs-linux-gnu}
NUM_JOBS=${NUM_JOBS:-$(nproc 2>/dev/null || echo 4)}
PATH="$LFS/tools/bin:/usr/bin:/bin"
export LFS LFS_TGT LC_ALL=POSIX PATH

log_info "LFS=$LFS, TARGET=$LFS_TGT, JOBS=$NUM_JOBS"

mkdir -pv "$LFS"/tools "$LFS"/sources

# Ensure lfs user exists
if ! id -u lfs &>/dev/null; then
    groupadd lfs
    useradd -s /bin/bash -g lfs -m -k /dev/null lfs
fi

# Set up environment for lfs user
LFS_HOME="/home/lfs"
mkdir -p "$LFS_HOME"
{
    echo "set +h"
    echo "umask 022"
    printf 'LFS=%q\n' "$LFS"
    echo "LC_ALL=POSIX"
    echo 'LFS_TGT=$(uname -m)-lfs-linux-gnu'
    echo 'PATH=$LFS/tools/bin:/usr/bin:/bin'
    echo "export LFS LC_ALL LFS_TGT PATH"
} > "$LFS_HOME/.bashrc"
cat > "$LFS_HOME/.bash_profile" << 'EOF'
if [ -f ~/.bashrc ]; then . ~/.bashrc; fi
EOF
chown -R lfs:lfs "$LFS_HOME"

chown -v lfs:lfs "$LFS"/tools "$LFS"/sources

check_toolchain() {
    if [ -x "$LFS/tools/bin/$LFS_TGT-gcc" ] && \
       [ -x "$LFS/tools/bin/$LFS_TGT-ld" ] && \
       [ -x "$LFS/tools/bin/$LFS_TGT-as" ]; then
        if echo 'int main(){}' | "$LFS/tools/bin/$LFS_TGT-gcc" -x c - -o /dev/null 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

if check_toolchain; then
    log_success "Toolchain already exists and works. Skipping build."
    exit 0
fi

# -------------------------------------------------------------------
# Build logic (to be run as lfs)
# -------------------------------------------------------------------
build_toolchain() {
    cd "$LFS/sources" || { log_error "Sources directory missing"; exit 1; }

    for pkg in binutils gcc linux glibc; do
        if ! find . -maxdepth 1 -name "${pkg}-*.tar.*" -print -quit | grep -q .; then
            log_error "Source for $pkg not found"
            exit 1
        fi
    done

    log_info "Building binutils (pass 1)"
    BINUTILS_TAR=$(find . -maxdepth 1 -name "binutils-*.tar.xz" -print -quit)
    tar -xf "$BINUTILS_TAR"
    BINUTILS_DIR=$(find . -maxdepth 1 -type d -name "binutils-*" -print -quit | sed 's|^\./||')
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

    log_info "Building GCC (pass 1)"
    GCC_TAR=$(find . -maxdepth 1 -name "gcc-*.tar.xz" -print -quit)
    tar -xf "$GCC_TAR"
    GCC_DIR=$(find . -maxdepth 1 -type d -name "gcc-*" -print -quit | sed 's|^\./||')
    # Embed GMP, MPFR, and MPC inside the GCC source tree (required by GCC configure)
    for lib in gmp mpfr mpc; do
        LIB_TAR=$(find . -maxdepth 1 -name "${lib}-*.tar.*" -print -quit)
        if [ -n "$LIB_TAR" ]; then
            tar -xf "$LIB_TAR"
            LIB_DIR=$(find . -maxdepth 1 -type d -name "${lib}-*" -print -quit | sed 's|^\./||')
            mv -v "$LIB_DIR" "$GCC_DIR/$lib"
        fi
    done
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
    if [ ! -f "$LFS/tools/bin/cc" ]; then
        ln -sfv "$LFS_TGT-gcc" "$LFS/tools/bin/cc"
    fi
    cd "$LFS/sources"
    rm -rf "$GCC_DIR"
    log_success "GCC (pass 1) done"

    log_info "Installing Linux API headers"
    LINUX_TAR=$(find . -maxdepth 1 -type f -printf '%f\n' | grep -E "^${KERNEL_TYPE}-[0-9].*\\.tar\\.xz$" | head -n1)
    if [ -z "$LINUX_TAR" ]; then
        log_error "No kernel source found for type '$KERNEL_TYPE'"
        exit 1
    fi
    tar -xf "$LINUX_TAR"
    LINUX_DIR=$(tar -tf "$LINUX_TAR" | head -1 | cut -d/ -f1)
    cd "$LINUX_DIR"
    make mrproper
    make headers
    find usr/include -name '.*' -delete
    rm -f usr/include/Makefile
    mkdir -p "$LFS/usr"
    cp -rv usr/include "$LFS/usr"
    cd "$LFS/sources"
    rm -rf "$LINUX_DIR"
    log_success "Linux headers installed"

    log_info "Building glibc"
    GLIBC_TAR=$(find . -maxdepth 1 -name "glibc-*.tar.xz" -print -quit)
    tar -xf "$GLIBC_TAR"
    GLIBC_DIR=$(find . -maxdepth 1 -type d -name "glibc-*" -print -quit | sed 's|^\./||')
    cd "$GLIBC_DIR"
    mkdir -v build
    cd build
    # Use --prefix=/usr with DESTDIR=$LFS so glibc is installed into the sysroot
    # (the cross-compiler has --with-sysroot=$LFS, so it looks for libc at $LFS/usr/lib).
    # libc_cv_slibdir and libc_cv_forced_unwind are provided as cache variables to
    # bypass link tests that fail under GCC_NO_EXECUTABLES in a cross-compile environment.
    ../configure --prefix=/usr \
                 --host="$LFS_TGT" \
                 --build="$(../scripts/config.guess)" \
                 --enable-kernel=4.14 \
                 --with-headers="$LFS/usr/include" \
                 --disable-nscd \
                 libc_cv_slibdir=/usr/lib \
                 libc_cv_forced_unwind=yes
    make -j"$NUM_JOBS"
    make DESTDIR="$LFS" install
    # Fix hard-coded path in ldd script
    sed '/RTLDLIST=/s@/usr@@g' -i "$LFS/usr/bin/ldd"
    cd "$LFS/sources"
    rm -rf "$GLIBC_DIR"
    log_success "glibc done"

    log_info "Building libstdc++"
    tar -xf "$GCC_TAR"   # re-extract GCC
    GCC_DIR=$(find . -maxdepth 1 -type d -name "gcc-*" -print -quit | sed 's|^\./||')
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

    mkdir -p "$LFS/var/log"
    touch "$LFS/var/log/toolchain-ready"
    log_success "Temporary toolchain built successfully."
}

# -------------------------------------------------------------------
# Main execution
# -------------------------------------------------------------------
main() {
    ensure_compiler

    # If we are not lfs, re‑execute as lfs using sudo
    if [ "$(whoami)" != "lfs" ]; then
        log_info "Re‑executing as lfs user"
        exec sudo -n -u lfs bash "$0" --force
    fi

    # Now running as lfs
    build_toolchain

    # Verify
    if check_toolchain; then
        log_success "Toolchain verified after build."
    else
        log_error "Toolchain verification failed after build."
        exit 1
    fi
}

# Handle --force flag to skip user checks (used for re‑execution)
if [ "$1" = "--force" ]; then
    shift
    # We are already lfs; skip the re‑execution
    if [ "$(whoami)" != "lfs" ]; then
        log_error "Cannot use --force without sudo; not lfs user"
        exit 1
    fi
    build_toolchain
    if check_toolchain; then
        log_success "Toolchain verified after build."
    else
        log_error "Toolchain verification failed."
        exit 1
    fi
else
    main "$@"
fi