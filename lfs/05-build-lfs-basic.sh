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

KERNEL_TYPE=${KERNEL_TYPE:-linux}

run_privileged() {
    if [ "$(whoami)" = "root" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

TOOLS_DIR="$LFS/tools"

log_info "========================================="
log_info "Building temporary toolchain in $TOOLS_DIR"
log_info "========================================="

# Create required directories inside $LFS
run_privileged mkdir -pv "$LFS"/{bin,etc,lib,lib64,usr,var,tools}
run_privileged mkdir -pv "$LFS"/usr/{bin,lib,include,share}
run_privileged mkdir -pv "$TOOLS_DIR"/{bin,lib,libexec,include,share}

# Ensure the lfs user exists on the host (not inside chroot)
if ! id -u lfs &>/dev/null; then
    run_privileged groupadd lfs
    run_privileged useradd -s /bin/bash -g lfs -m -k /dev/null lfs
fi

# Set ownership of tools and sources directories to lfs user
run_privileged chown -v lfs:lfs "$LFS"/tools
run_privileged chown -v lfs:lfs "$LFS"/sources
run_privileged chown -v lfs:lfs "$LFS"

# Create the environment file for the lfs user on the host
LFS_HOME="/home/lfs"
if [ ! -d "$LFS_HOME" ]; then
    run_privileged mkdir -p "$LFS_HOME"
    run_privileged chown lfs:lfs "$LFS_HOME"
fi

{
    echo "set +h"
    echo "umask 022"
    printf 'LFS=%q\n' "$LFS"
    echo "LC_ALL=POSIX"
    echo 'LFS_TGT=$(uname -m)-lfs-linux-gnu'
    echo 'PATH=$LFS/tools/bin:/bin:/usr/bin'
    echo "export LFS LC_ALL LFS_TGT PATH"
} > "$LFS_HOME"/.bashrc

cat > "$LFS_HOME"/.bash_profile << 'EOF'
if [ -f ~/.bashrc ]; then . ~/.bashrc; fi
EOF

run_privileged chown lfs:lfs "$LFS_HOME"/.bashrc "$LFS_HOME"/.bash_profile

# Ensure sources are available
SOURCES_DIR="$LFS/sources"
LEGACY_SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_DIR" ] && [ "$(ls -A "$SOURCES_DIR" 2>/dev/null)" ]; then
    log_info "Using existing sources in $SOURCES_DIR"
elif [ -d "$LEGACY_SOURCES_HOST" ] && [ "$(ls -A "$LEGACY_SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $LEGACY_SOURCES_HOST to $SOURCES_DIR"
    run_privileged mkdir -p "$SOURCES_DIR"
    run_privileged cp -r "$LEGACY_SOURCES_HOST"/. "$SOURCES_DIR"/
    run_privileged chown -R lfs:lfs "$SOURCES_DIR"
else
    log_error "No sources found in $SOURCES_DIR or $LEGACY_SOURCES_HOST – cannot build toolchain"
    exit 1
fi

# Build the temporary toolchain as user 'lfs' (on the host, not inside chroot)
log_info "Building temporary toolchain (this may take a while)..."
run_privileged su - lfs -c "
set -e
# shellcheck disable=SC2027
cd \"$LFS/sources\"

# ----- Binutils (pass 1) -----
echo 'Building binutils (pass 1)'
BINUTILS_DIR=\$(tar -tf binutils-*.tar.xz | head -1 | cut -d/ -f1)
tar -xf binutils-*.tar.xz
cd \"\$BINUTILS_DIR\"
mkdir -v build
cd build
../configure --prefix=\"$TOOLS_DIR\"    \
             --with-sysroot=$LFS        \
             --target=\$(uname -m)-lfs-linux-gnu          \
             --disable-nls              \
             --enable-gprofng=no        \
             --disable-werror
make -j\$(nproc)
make install
cd $LFS/sources
rm -rf \$BINUTILS_DIR

# ----- GCC (pass 1) -----
echo 'Building gcc (pass 1)'
GCC_DIR=\$(tar -tf gcc-*.tar.xz | head -1 | cut -d/ -f1)
tar -xf gcc-*.tar.xz
cd \"\$GCC_DIR\"
mkdir -v build
cd build
../configure --prefix=\"$TOOLS_DIR\"    \
             --with-sysroot=$LFS        \
             --target=\$(uname -m)-lfs-linux-gnu          \
             --disable-nls              \
             --enable-languages=c,c++   \
             --disable-multilib         \
             --disable-bootstrap        \
             --with-system-zlib
make -j\$(nproc)
make install
cd $LFS/sources
# shellcheck disable=SC2027
rm -rf "$GCC_DIR"

# ----- Linux API headers -----
echo 'Installing Linux API headers'
LINUX_TAR=\$(find . -maxdepth 1 -type f -printf '%f\n' | grep -E \"^${KERNEL_TYPE}-[0-9].*\\.tar\\.xz\$\" | head -n1)
if [ -z \"\$LINUX_TAR\" ]; then
    echo \"No kernel source found for type '${KERNEL_TYPE}'\" >&2
    exit 1
fi
LINUX_DIR=\$(tar -tf \"\$LINUX_TAR\" | head -1 | cut -d/ -f1)
tar -xf \"\$LINUX_TAR\"
cd \"\$LINUX_DIR\"
make mrproper
make headers
find usr/include -name '.*' -delete
rm usr/include/Makefile
cp -rv usr/include/. \"$TOOLS_DIR/include/\"
cd $LFS/sources
rm -rf linux-*

# ----- Glibc -----
echo 'Building glibc'
GLIBC_DIR=\$(tar -tf glibc-*.tar.xz | head -1 | cut -d/ -f1)
tar -xf glibc-*.tar.xz
cd \"\$GLIBC_DIR\"
mkdir -v build
cd build
../configure --prefix=\"$TOOLS_DIR\"    \
             --host=\$(uname -m)-lfs-linux-gnu            \
             --build=\$(../scripts/config.guess) \
             --enable-kernel=4.14       \
             --with-headers=\"$TOOLS_DIR/include\"
make -j\$(nproc)
make install
cd $LFS/sources
rm -rf \$GLIBC_DIR

# ----- Libstdc++ (from GCC) -----
echo 'Building libstdc++'
GCC_DIR2=\$(tar -tf gcc-*.tar.xz | head -1 | cut -d/ -f1)
tar -xf gcc-*.tar.xz
cd \"\$GCC_DIR2\"
mkdir -v build-libstdc++
cd build-libstdc++
../libstdc++-v3/configure --host=\$(uname -m)-lfs-linux-gnu \
                          --build=\$(../config.guess) \
                          --prefix=\"$TOOLS_DIR\" \
                          --disable-multilib \
                          --disable-nls \
                          --disable-libstdcxx-pch \
                          --with-gxx-include-dir=\"$TOOLS_DIR\"/\$(uname -m)-lfs-linux-gnu/include/c++/\$(cat ../gcc/BASE-VER)
make -j\$(nproc)
make install
cd $LFS/sources
# shellcheck disable=SC2027
rm -rf "$GCC_DIR2"

# ----- Essential utilities -----
echo 'Installing essential utilities (coreutils, make, sed, grep, etc.)'
for pkg in coreutils make sed grep gawk findutils tar gzip bzip2 diffutils patch; do
    archive=\$(ls \"\$pkg\"-*.tar.* 2>/dev/null | head -1)
    if [ -z \"\$archive\" ]; then
        echo \"WARNING: \$pkg source not found, skipping\"
        continue
    fi
    dir=\$(tar -tf \"\$archive\" | head -1 | cut -d/ -f1)
    echo \"Building \$dir\"
    tar -xf \"\$archive\"
    cd \"\$dir\"
    if [ -f \"configure\" ]; then
        if [ \"\$pkg\" = \"coreutils\" ]; then
            ./configure --prefix=\"$TOOLS_DIR\" --without-gmp
        else
            ./configure --prefix=\"$TOOLS_DIR\"
        fi
    fi
    make -j\$(nproc)
    if [ \"\$pkg\" = \"bzip2\" ]; then
        make PREFIX=\"$TOOLS_DIR\" install
    else
        make install
    fi
    cd $LFS/sources
    rm -rf \"\$dir\"
done

echo 'Temporary toolchain built successfully.'
"

# Finalize: ensure /tools/bin is in PATH for future steps
log_success "Temporary toolchain installed in $LFS/tools"

# Create a marker file so later stages know /tools exists
touch "$LFS"/var/log/toolchain-ready