#!/bin/bash
# Build temporary cross-toolchain (binutils, gcc, glibc) into /tools
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

IN_DOCKER=false
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
    IN_DOCKER=true
    log_info "Running in Docker container"
fi

if [ "$IN_DOCKER" = true ]; then
    LFS=${LFS:-/output/image}
else
    LFS=${LFS:-/mnt/lfs}
fi

if [ -z "$LFS" ]; then
    log_error "LFS variable not set"
    exit 1
fi

run_privileged() {
    if [ "$(whoami)" = "root" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

log_info "========================================="
log_info "Building temporary toolchain in /tools"
log_info "========================================="

# Create required directories
run_privileged mkdir -pv $LFS/{bin,etc,lib,lib64,usr,var,tools}
run_privileged mkdir -pv $LFS/usr/{bin,lib,include,share}
run_privileged mkdir -pv $LFS/tools/{bin,lib,libexec,include,share}

# Create 'lfs' user (if not exists) and set ownership
if ! id -u lfs &>/dev/null; then
    run_privileged groupadd lfs
    run_privileged useradd -s /bin/bash -g lfs -m -k /dev/null lfs
fi
run_privileged chown -v lfs:lfs $LFS/tools
run_privileged chown -v lfs:lfs $LFS/sources
run_privileged chown -v lfs:lfs $LFS

# Set up the LFS environment for the lfs user
cat > $LFS/home/lfs/.bashrc << 'EOF'
set +h
umask 022
LFS=/mnt/lfs
LC_ALL=POSIX
LFS_TGT=$(uname -m)-lfs-linux-gnu
PATH=/tools/bin:/bin:/usr/bin
export LFS LC_ALL LFS_TGT PATH
EOF

cat > $LFS/home/lfs/.bash_profile << 'EOF'
if [ -f ~/.bashrc ]; then . ~/.bashrc; fi
EOF

# Copy sources (if they exist)
SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources to $LFS/sources"
    run_privileged mkdir -p $LFS/sources
    run_privileged cp -rv $SOURCES_HOST/* $LFS/sources/
    run_privileged chown -R lfs:lfs $LFS/sources
else
    log_error "No sources found in $SOURCES_HOST – cannot build toolchain"
    exit 1
fi

# Build the temporary toolchain as user 'lfs'
log_info "Building temporary toolchain (this may take a while)..."
run_privileged chroot --userspec=lfs:lfs $LFS /bin/bash << 'INNEREOF'
set -e
cd /sources

# ----- Binutils (pass 1) -----
echo "Building binutils (pass 1)"
tar -xf binutils-*.tar.xz
cd binutils-*
mkdir -v build
cd build
../configure --prefix=/tools            \
             --with-sysroot=$LFS        \
             --target=$LFS_TGT          \
             --disable-nls              \
             --enable-gprofng=no        \
             --disable-werror
make -j$(nproc)
make install
cd /sources
rm -rf binutils-*

# ----- GCC (pass 1) -----
echo "Building gcc (pass 1)"
tar -xf gcc-*.tar.xz
cd gcc-*
mkdir -v build
cd build
../configure --prefix=/tools            \
             --with-sysroot=$LFS        \
             --target=$LFS_TGT          \
             --disable-nls              \
             --enable-languages=c,c++   \
             --disable-multilib         \
             --disable-bootstrap        \
             --with-system-zlib
make -j$(nproc)
make install
cd /sources
rm -rf gcc-*

# ----- Linux API headers -----
echo "Installing Linux API headers"
tar -xf linux-*.tar.xz
cd linux-*
make mrproper
make headers
find usr/include -name '.*' -delete
rm usr/include/Makefile
cp -rv usr/include /tools/include
cd /sources
rm -rf linux-*

# ----- Glibc -----
echo "Building glibc"
tar -xf glibc-*.tar.xz
cd glibc-*
mkdir -v build
cd build
../configure --prefix=/tools            \
             --host=$LFS_TGT            \
             --build=$(../scripts/config.guess) \
             --enable-kernel=4.14       \
             --with-headers=/tools/include
make -j$(nproc)
make install
cd /sources
rm -rf glibc-*

# ----- Libstdc++ (from GCC) -----
echo "Building libstdc++"
tar -xf gcc-*.tar.xz
cd gcc-*
mkdir -v build-libstdc++
cd build-libstdc++
../libstdc++-v3/configure --host=$LFS_TGT \
                          --build=$(../config.guess) \
                          --prefix=/tools \
                          --disable-multilib \
                          --disable-nls \
                          --disable-libstdcxx-pch \
                          --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/$(cat ../gcc/BASE-VER)
make -j$(nproc)
make install
cd /sources
rm -rf gcc-*

# ----- Essential utilities -----
echo "Installing essential utilities (make, sed, grep, etc.)"
for pkg in make sed grep gawk findutils tar gzip bzip2 diffutils patch; do
    archive=$(ls "$pkg"-*.tar.* 2>/dev/null | head -1)
    if [ -z "$archive" ]; then
        echo "WARNING: $pkg source not found, skipping"
        continue
    fi
    dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
    echo "Building $dir"
    tar -xf "$archive"
    cd "$dir"
    if [ -f "configure" ]; then
        ./configure --prefix=/tools
    fi
    make -j$(nproc)
    make install
    cd /sources
    rm -rf "$dir"
done

echo "Temporary toolchain built successfully."
INNEREOF

# Finalize: ensure /tools/bin is in PATH for future steps
log_success "Temporary toolchain installed in $LFS/tools"

# Create a marker file so later stages know /tools exists
touch $LFS/var/log/toolchain-ready