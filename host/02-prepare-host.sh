#!/bin/bash
# 02-prepare-host.sh
# Prepare host system for LFS / BLFS build - Compatible with Docker and native
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
# Language: English

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fallback logging functions if utils.sh is missing
if [ -f "$SCRIPT_DIR/../common/utils.sh" ]; then
    source "$SCRIPT_DIR/../common/utils.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warning() { echo "[WARNING] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
fi

# Optional error handler
if [ -f "$SCRIPT_DIR/../common/error-handler.sh" ]; then
    source "$SCRIPT_DIR/../common/error-handler.sh"
    setup_error_handling 2>/dev/null || true
fi

# ---------- Environment detection ----------
IN_DOCKER=false
[ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null && IN_DOCKER=true

IN_LIMA=false
[ -f /etc/lima-version ] && IN_LIMA=true

if [ "$IN_DOCKER" = true ]; then
    log_info "Running inside Docker container"
fi
if [ "$IN_LIMA" = true ]; then
    log_info "Running inside Lima VM"
fi

# ---------- Distribution detection ----------
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

# ---------- Privilege handling ----------
USE_SUDO=false
if [ "$EUID" -ne 0 ] && [ "$IN_DOCKER" = false ] && [ "$IN_LIMA" = false ]; then
    if sudo -n true 2>/dev/null; then
        USE_SUDO=true
        log_warning "Not running as root, but sudo is available. Using sudo for privileged commands."
    else
        log_error "Please run as root or with sudo."
        exit 1
    fi
fi

# ---------- Package installation function ----------
install_packages() {
    local distro="$1"
    shift
    local packages=("$@")
    [ ${#packages[@]} -eq 0 ] && return 0

    log_info "Installing packages: ${packages[*]}"

    case "$distro" in
        debian|ubuntu)
            $USE_SUDO apt-get update -qq
            $USE_SUDO apt-get install -y -qq "${packages[@]}"
            ;;
        fedora|rhel|centos|rocky|almalinux)
            if command -v dnf &>/dev/null; then
                $USE_SUDO dnf install -y "${packages[@]}"
            else
                $USE_SUDO yum install -y "${packages[@]}"
            fi
            ;;
        opensuse*|sles)
            $USE_SUDO zypper install -y "${packages[@]}"
            ;;
        arch|manjaro)
            $USE_SUDO pacman -Syu --noconfirm "${packages[@]}"
            ;;
        alpine)
            $USE_SUDO apk add "${packages[@]}"
            ;;
        gentoo)
            log_error "Gentoo detected – please install manually using emerge: ${packages[*]}"
            exit 1
            ;;
        *)
            log_error "Unknown distribution – please install manually: ${packages[*]}"
            exit 1
            ;;
    esac
}

# ---------- Set LFS directory ----------
if [ "$IN_DOCKER" = true ]; then
    LFS=${LFS:-/output}
    log_info "Using Docker output directory: $LFS"
else
    LFS=${LFS:-/mnt/lfs}
    log_info "Using LFS directory: $LFS"
fi
export LFS

# ---------- Create lfs user (native only) ----------
create_lfs_user() {
    if [ "$IN_DOCKER" = true ] || [ "$IN_LIMA" = true ]; then
        log_info "Skipping user creation in container/VM environment"
        return 0
    fi

    if ! id "lfs" &>/dev/null; then
        log_info "Creating lfs user"
        # Create group if missing
        if ! getent group lfs >/dev/null; then
            $USE_SUDO groupadd lfs 2>/dev/null || $USE_SUDO addgroup lfs 2>/dev/null || true
        fi
        # Create user with home, shell, and group
        if ! $USE_SUDO useradd -s /bin/bash -g lfs -m -k /dev/null lfs 2>/dev/null; then
            log_warning "useradd failed, trying with explicit home directory"
            $USE_SUDO useradd -s /bin/bash -g lfs -m -d /home/lfs -k /dev/null lfs
        fi
        # Set password (optional)
        echo "lfs:lfs123" | $USE_SUDO chpasswd 2>/dev/null || true
        # Grant sudo access without password (for convenience)
        echo "lfs ALL=(ALL) NOPASSWD: ALL" | $USE_SUDO tee -a /etc/sudoers >/dev/null 2>&1 || true
    else
        log_info "User lfs already exists"
    fi
}

# ---------- Create directory structure ----------
create_directories() {
    log_info "Creating LFS directory structure: $LFS"

    # Create the base LFS mount point
    if [ ! -d "$LFS" ]; then
        $USE_SUDO mkdir -pv "$LFS" 2>/dev/null || {
            log_warning "Cannot create $LFS, using fallback directory"
            LFS="$(pwd)/lfs-root"
            mkdir -pv "$LFS"
        }
    fi

    # Create essential directories
    local base_dirs=(
        bin boot dev etc home lib lib64 media mnt opt proc root run sbin srv sys tmp usr var
    )
    for dir in "${base_dirs[@]}"; do
        $USE_SUDO mkdir -pv "$LFS/$dir" 2>/dev/null || true
    done

    # usr subdirectories
    local usr_dirs=(bin include lib lib64 sbin share src)
    for dir in "${usr_dirs[@]}"; do
        $USE_SUDO mkdir -pv "$LFS/usr/$dir" 2>/dev/null || true
    done

    # usr/share subdirectories
    local share_dirs=(man doc info)
    for dir in "${share_dirs[@]}"; do
        $USE_SUDO mkdir -pv "$LFS/usr/share/$dir" 2>/dev/null || true
    done

    # var subdirectories
    local var_dirs=(cache lib local lock log opt run spool tmp)
    for dir in "${var_dirs[@]}"; do
        $USE_SUDO mkdir -pv "$LFS/var/$dir" 2>/dev/null || true
    done

    # etc subdirectories
    local etc_dirs=(profile.d sysconfig skel)
    for dir in "${etc_dirs[@]}"; do
        $USE_SUDO mkdir -pv "$LFS/etc/$dir" 2>/dev/null || true
    done

    # Set sticky bits on temporary directories (skip in Docker)
    if [ "$IN_DOCKER" = false ]; then
        $USE_SUDO chmod -v 1777 "$LFS/tmp" 2>/dev/null || true
        $USE_SUDO chmod -v 1777 "$LFS/var/tmp" 2>/dev/null || true
    fi

    # Sources directory
    $USE_SUDO mkdir -pv "$LFS/sources" 2>/dev/null || true
    if [ "$IN_DOCKER" = false ]; then
        $USE_SUDO chmod -v a+wt "$LFS/sources" 2>/dev/null || true
        $USE_SUDO chown -v lfs:lfs "$LFS/sources" 2>/dev/null || true
    else
        # In Docker, we might not have lfs user, so keep as current user
        chmod a+wt "$LFS/sources" 2>/dev/null || true
    fi

    # Tools directory
    $USE_SUDO mkdir -pv "$LFS/tools" 2>/dev/null || true
    if [ "$IN_DOCKER" = false ]; then
        $USE_SUDO chown -v lfs:lfs "$LFS/tools" 2>/dev/null || true
    fi
}

# ---------- Set up lfs user environment (native only) ----------
setup_user_env() {
    if [ "$IN_DOCKER" = true ] || [ "$IN_LIMA" = true ]; then
        log_info "Skipping user environment setup in container/VM"
        return 0
    fi

    local home_dir="/home/lfs"
    if [ ! -d "$home_dir" ]; then
        log_warning "Home directory for lfs not found, skipping environment setup"
        return 0
    fi

    # .bashrc
    if [ ! -f "$home_dir/.bashrc" ]; then
        cat > "$home_dir/.bashrc" <<"EOF"
set +h
umask 022
LFS=/mnt/lfs
LC_ALL=POSIX
LFS_TGT=${LFS_TGT:-$(uname -m)-lfs-linux-gnu}
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
PATH=$LFS/tools/bin:$PATH
CONFIG_SITE=$LFS/usr/share/config.site
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
MAKEFLAGS="-j$(nproc)"
export MAKEFLAGS
EOF
        $USE_SUDO chown lfs:lfs "$home_dir/.bashrc" 2>/dev/null || true
    fi

    # .bash_profile
    if [ ! -f "$home_dir/.bash_profile" ]; then
        cat > "$home_dir/.bash_profile" <<"EOF"
if [ -f "$HOME/.bashrc" ] ; then
    source "$HOME/.bashrc"
fi
EOF
        $USE_SUDO chown lfs:lfs "$home_dir/.bash_profile" 2>/dev/null || true
    fi
}

# ---------- Install build dependencies ----------
install_dependencies() {
    if [ "$IN_DOCKER" = true ]; then
        log_info "Skipping dependency installation in Docker (assumed pre-installed)"
        return 0
    fi

    local distro
    distro=$(detect_distro)
    log_info "Installing build dependencies for distribution: $distro"

    # Common packages (Debian/Ubuntu names)
    local common_packages=(
        build-essential bison flex gawk texinfo
        wget curl git python3 python3-pip
        xorriso isolinux mtools dosfstools
        parted rsync sudo
        bc cpio unzip xz-utils
        libssl-dev libelf-dev
        kmod cpio
    )

    case "$distro" in
        debian|ubuntu)
            install_packages "$distro" "${common_packages[@]}"
            ;;
        fedora|rhel|centos|rocky|almalinux)
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
        alpine)
            local alpine_packages=(
                build-base bison flex gawk texinfo
                wget curl git python3 py3-pip
                xorriso syslinux mtools dosfstools
                parted rsync sudo
                bc cpio unzip xz
                openssl-dev elfutils-dev kmod cpio
            )
            install_packages "$distro" "${alpine_packages[@]}"
            ;;
        *)
            log_warning "Unknown distribution, attempting to install common packages anyway"
            install_packages "$distro" "${common_packages[@]}" || true
            ;;
    esac
}

# ---------- Create build script ----------
create_build_script() {
    log_info "Creating LFS build script at $LFS/build-lfs.sh"

    cat > "$LFS/build-lfs.sh" <<"EOF"
#!/usr/bin/env bash
# Main LFS build script - to be run as lfs user
# This is a template; actual build steps should follow LFS book chapters.

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

# Build cross-toolchain (simplified example)
echo "Building cross-toolchain..."

# Example: Binutils
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

# Example: GCC
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
        $USE_SUDO chown lfs:lfs "$LFS/build-lfs.sh" 2>/dev/null || true
    fi
}

# ---------- Main execution ----------
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

    # Native system (including Lima)
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