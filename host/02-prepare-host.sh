#!/bin/bash
# 02-prepare-host.sh
# Prepare host system for LFS build - Compatible with Docker and native
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

if [ -f "$SCRIPT_DIR/../common/error-handler.sh" ]; then
    source "$SCRIPT_DIR/../common/error-handler.sh"
    setup_error_handling 2>/dev/null || true
fi

# Detect distribution
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

# Install packages using the appropriate package manager
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
            log_error "Gentoo detected. Please install the following packages manually using emerge: ${packages[*]}"
            exit 1
            ;;
        *)
            log_error "Unknown distribution. Please install the following packages manually: ${packages[*]}"
            exit 1
            ;;
    esac
}

# Detect if running in Docker
IN_DOCKER=false
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
    IN_DOCKER=true
    log_info "Running in Docker container"
fi

# Detect if running in Lima VM
IN_LIMA=false
if [ -f /etc/lima-version ]; then
    IN_LIMA=true
    log_info "Running in Lima VM"
fi

log_info "Preparing host system for LFS build"

# Set LFS directory (use /output in Docker, /mnt/lfs otherwise)
if [ "$IN_DOCKER" = true ]; then
    LFS=${LFS:-/output}
    log_info "Using Docker output directory: $LFS"
else
    LFS=${LFS:-/mnt/lfs}
    log_info "Using LFS directory: $LFS"
fi

# Function to create user (only on native systems)
create_lfs_user() {
    if [ "$IN_DOCKER" = true ] || [ "$IN_LIMA" = true ]; then
        log_info "Skipping user creation in container/VM environment"
        return 0
    fi

    if ! id "lfs" &>/dev/null; then
        log_info "Creating lfs user"
        # Create group if it doesn't exist
        if ! getent group lfs >/dev/null; then
            groupadd lfs 2>/dev/null || addgroup lfs 2>/dev/null || true
        fi
        # Portable useradd: -m (create home), -s (shell), -g (group)
        useradd -s /bin/bash -g lfs -m -k /dev/null lfs 2>/dev/null || {
            log_warning "useradd failed, trying with -d /home/lfs explicitly"
            useradd -s /bin/bash -g lfs -m -d /home/lfs -k /dev/null lfs
        }
        echo "lfs:lfs123" | chpasswd 2>/dev/null || true
        echo "lfs ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers 2>/dev/null || true
    else
        log_info "User lfs already exists"
    fi
}

# Create LFS directory structure
create_directories() {
    log_info "Creating LFS directory structure: $LFS"

    mkdir -pv "$LFS" 2>/dev/null || sudo mkdir -pv "$LFS" 2>/dev/null || {
        log_warning "Cannot create $LFS, using current directory"
        LFS="$(pwd)/lfs-root"
        mkdir -pv "$LFS"
    }

    # Create base directories
    for dir in bin boot dev etc home lib lib64 media mnt opt proc root run sbin srv sys tmp usr var; do
        mkdir -pv "$LFS/$dir" 2>/dev/null || true
    done

    # Create usr subdirectories
    for dir in bin include lib lib64 sbin share src; do
        mkdir -pv "$LFS/usr/$dir" 2>/dev/null || true
    done

    # Create usr/share subdirectories
    for dir in man doc info; do
        mkdir -pv "$LFS/usr/share/$dir" 2>/dev/null || true
    done

    # Create var subdirectories
    for dir in cache lib local lock log opt run spool tmp; do
        mkdir -pv "$LFS/var/$dir" 2>/dev/null || true
    done

    # Create etc subdirectories
    for dir in profile.d sysconfig skel; do
        mkdir -pv "$LFS/etc/$dir" 2>/dev/null || true
    done

    # Set permissions (skip in Docker)
    if [ "$IN_DOCKER" = false ]; then
        chmod -v 1777 "$LFS/tmp" 2>/dev/null || true
        chmod -v 1777 "$LFS/var/tmp" 2>/dev/null || true
    fi

    # Create sources directory
    mkdir -pv "$LFS/sources" 2>/dev/null || true
    if [ "$IN_DOCKER" = false ]; then
        chmod -v a+wt "$LFS/sources" 2>/dev/null || true
        chown -v lfs:lfs "$LFS/sources" 2>/dev/null || true
    fi

    # Create tools directory
    mkdir -pv "$LFS/tools" 2>/dev/null || true
    if [ "$IN_DOCKER" = false ]; then
        chown -v lfs:lfs "$LFS/tools" 2>/dev/null || true
    fi
}

# Set up user environment (native only)
setup_user_env() {
    if [ "$IN_DOCKER" = true ] || [ "$IN_LIMA" = true ]; then
        log_info "Skipping user environment setup in container/VM"
        return 0
    fi

    if [ ! -f /home/lfs/.bashrc ]; then
        cat > /home/lfs/.bashrc << "EOF"
set +h
umask 022
LFS=/mnt/lfs
LC_ALL=POSIX
LFS_TGT=$(uname -m)-lfs-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
PATH=$LFS/tools/bin:$PATH
CONFIG_SITE=$LFS/usr/share/config.site
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
MAKEFLAGS="-j$(nproc)"
export MAKEFLAGS
EOF
        chown lfs:lfs /home/lfs/.bashrc 2>/dev/null || true
    fi

    if [ ! -f /home/lfs/.bash_profile ]; then
        cat > /home/lfs/.bash_profile << "EOF"
if [ -f "$HOME/.bashrc" ] ; then
    source "$HOME/.bashrc"
fi
EOF
        chown lfs:lfs /home/lfs/.bash_profile 2>/dev/null || true
    fi
}

# Install build dependencies (uses the generic install_packages)
install_dependencies() {
    if [ "$IN_DOCKER" = true ]; then
        log_info "Skipping dependency installation in Docker (already installed)"
        return 0
    fi

    local distro
    distro=$(detect_distro)

    # Common packages for all LFS builds
    local common_packages=(
        build-essential bison flex gawk texinfo
        wget curl git python3 python3-pip
        xorriso isolinux mtools dosfstools
        parted rsync sudo
        bc cpio unzip xz-utils
        libssl-dev libelf-dev
        kmod cpio
    )

    # Adjust package names per distribution
    case "$distro" in
        debian|ubuntu)
            install_packages "$distro" "${common_packages[@]}"
            ;;
        fedora|rhel|centos|rocky)
            # Map Debian names to Red Hat equivalents
            local rh_packages=(
                gcc gcc-c++ make bison flex gawk texinfo
                wget curl git python3 python3-pip
                xorriso syslinux mtools dosfstools
                parted rsync sudo
                bc cpio unzip xz
                openssl-devel elfutils-libelf-devel kmod cpio
            )
            install_packages "$distro" "${rh_packages[@]}"
            ;;
        arch|manjaro)
            local arch_packages=(
                base-devel bison flex gawk texinfo
                wget curl git python python-pip
                xorriso libisoburn mtools
                dosfstools parted rsync sudo
                bc cpio unzip xz
                openssl elfutils kmod cpio
            )
            install_packages "$distro" "${arch_packages[@]}"
            ;;
        opensuse*|sles)
            local suse_packages=(
                gcc gcc-c++ make bison flex gawk texinfo
                wget curl git python3 python3-pip
                xorriso syslinux mtools dosfstools
                parted rsync sudo
                bc cpio unzip xz
                libopenssl-devel libelf-devel kmod cpio
            )
            install_packages "$distro" "${suse_packages[@]}"
            ;;
        *)
            log_warning "Unknown distribution, attempt to install common packages anyway"
            install_packages "$distro" "${common_packages[@]}" || true
            ;;
    esac
}

# Create build script
create_build_script() {
    log_info "Creating LFS build script..."

    cat > "$LFS/build-lfs.sh" << "EOF"
#!/usr/bin/env bash
# Main LFS build script to be run as lfs user

set -e

cd "$LFS/sources"

# Download packages if wget-list exists
if [ -f wget-list ]; then
    echo "Downloading packages..."
    wget --input-file=wget-list --continue --directory-prefix="$LFS/sources" 2>/dev/null || true
fi

# Verify packages if md5sums exists
if [ -f md5sums ]; then
    echo "Verifying packages..."
    md5sum -c md5sums 2>/dev/null || true
fi

# Build toolchain (simplified for Docker)
echo "Building cross-toolchain..."

# Binutils
if [ -f binutils-*.tar.xz ]; then
    echo "Building binutils..."
    tar -xf binutils-*.tar.xz
    cd binutils-*
    mkdir -v build
    cd build
    ../configure --prefix="$LFS/tools" \
                 --with-sysroot="$LFS" \
                 --target="$LFS_TGT" \
                 --disable-nls \
                 --enable-gprofng=no \
                 --disable-werror 2>/dev/null || true
    make 2>/dev/null || true
    make install 2>/dev/null || true
    cd ../..
fi

# GCC
if [ -f gcc-*.tar.xz ]; then
    echo "Building GCC..."
    tar -xf gcc-*.tar.xz
    cd gcc-*
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
                 --enable-languages=c,c++ 2>/dev/null || true
    make 2>/dev/null || true
    make install 2>/dev/null || true
    cd ../..
fi

echo "Cross-toolchain build complete!"
EOF

    chmod +x "$LFS/build-lfs.sh" 2>/dev/null || true
    if [ "$IN_DOCKER" = false ]; then
        chown lfs:lfs "$LFS/build-lfs.sh" 2>/dev/null || true
    fi
}

# Main execution
main() {
    if [ "$IN_DOCKER" = true ]; then
        log_info "Docker environment detected - setting up in container mode"
        create_directories
        create_build_script
        log_success "Docker environment prepared successfully!"
        log_info "Output directory: $LFS"
        log_info "Build script: $LFS/build-lfs.sh"
        exit 0
    fi

    # Native system setup
    create_lfs_user
    create_directories
    setup_user_env
    install_dependencies
    create_build_script

    log_success "Host preparation complete!"

    if [ "$IN_LIMA" = true ]; then
        log_info "Running in Lima VM - you can now build LFS"
    else
        log_info "Now run: su - lfs"
        log_info "Then: /mnt/lfs/build-lfs.sh"
    fi
}

main "$@"