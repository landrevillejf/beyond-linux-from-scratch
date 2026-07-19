#!/usr/bin/env bash
# Build temporary cross-toolchain (LFS pass 1) – sans fallback vers l'hôte
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

LFS_TGT=${LFS_TGT:-$(uname -m)-lfs-linux-gnu}
export LFS LFS_TGT
log_info "LFS=$LFS, TARGET=$LFS_TGT"

# Ensure lfs user exists and has proper environment
if ! id -u lfs &>/dev/null; then
    log_info "Creating lfs user"
    groupadd lfs
    useradd -s /bin/bash -g lfs -m -k /dev/null lfs
fi

LFS_HOME="/home/lfs"
mkdir -p "$LFS_HOME"
cat > "$LFS_HOME/.bashrc" << 'EOF'
set +h
umask 022
LFS=/mnt/lfs
LC_ALL=POSIX
LFS_TGT=$(uname -m)-lfs-linux-gnu
PATH=/tools/bin:/bin:/usr/bin
export LFS LC_ALL LFS_TGT PATH
EOF
cat > "$LFS_HOME/.bash_profile" << 'EOF'
if [ -f ~/.bashrc ]; then . ~/.bashrc; fi
EOF
chown -R lfs:lfs "$LFS_HOME"

# Ensure directories exist
mkdir -pv "$LFS"/tools "$LFS"/sources
chown -v lfs:lfs "$LFS"/tools "$LFS"/sources

# -------------------------------------------------------------------
# Vérification robuste : le toolchain existe-t-il vraiment ?
# -------------------------------------------------------------------
check_toolchain() {
    # Vérifier que gcc est un cross-compilateur pour $LFS_TGT
    if [ -x "$LFS/tools/bin/gcc" ] && [ -x "$LFS/tools/bin/ld" ] && [ -x "$LFS/tools/bin/as" ]; then
        # Tester que gcc peut compiler un programme simple avec --target
        if echo 'int main(){}' | "$LFS/tools/bin/gcc" -x c - -o /dev/null 2>/dev/null; then
            log_success "Toolchain exists and appears functional."
            return 0
        else
            log_warning "Toolchain binaries exist but are broken (cannot compile)."
            return 1
        fi
    fi
    return 1
}

if check_toolchain; then
    log_info "Skipping toolchain build (already functional)."
    exit 0
fi

# -------------------------------------------------------------------
# Construction réelle (officielle LFS pass 1)
# -------------------------------------------------------------------
log_info "Building temporary toolchain from sources (this will take time)."

# On exécute tout en tant que lfs
su - lfs -c "
set -e
cd $LFS/sources

# Vérifier que les sources existent
for pkg in binutils gcc linux glibc; do
    if ! ls -1 \"\$pkg\"-*.tar.* >/dev/null 2>&1; then
        echo \"ERROR: source for \$pkg not found in $LFS/sources\"
        exit 1
    fi
done

# ----- 1. Binutils (pass 1) -----
echo '=== Building binutils (pass 1) ==='
BINUTILS_TAR=\$(ls -1 binutils-*.tar.xz 2>/dev/null | head -n1)
tar -xf \"\$BINUTILS_TAR\"
BINUTILS_DIR=\$(echo \"\$BINUTILS_TAR\" | sed 's/\.tar\.xz$//')
cd \"\$BINUTILS_DIR\"
mkdir -v build
cd build
../configure --prefix=/tools            \
             --with-sysroot=$LFS        \
             --target=$LFS_TGT          \
             --disable-nls              \
             --enable-gprofng=no        \
             --disable-werror
make -j\$(nproc)
make install
cd $LFS/sources
rm -rf \"\$BINUTILS_DIR\"
echo 'binutils (pass 1) done'

# ----- 2. GCC (pass 1) -----
echo '=== Building GCC (pass 1) ==='
GCC_TAR=\$(ls -1 gcc-*.tar.xz 2>/dev/null | head -n1)
tar -xf \"\$GCC_TAR\"
GCC_DIR=\$(echo \"\$GCC_TAR\" | sed 's/\.tar\.xz$//')
cd \"\$GCC_DIR\"
mkdir -v build
cd build
../configure --target=$LFS_TGT          \
             --prefix=/tools            \
             --with-glibc-version=2.38  \
             --with-sysroot=$LFS        \
             --with-newlib              \
             --without-headers          \
             --enable-default-pie       \
             --enable-default-ssp       \
             --disable-nls              \
             --disable-shared           \
             --disable-multilib         \
             --disable-threads          \
             --disable-libatomic        \
             --disable-libgomp          \
             --disable-libquadmath      \
             --disable-libssp           \
             --disable-libvtv           \
             --disable-libstdcxx        \
             --enable-languages=c,c++
make -j\$(nproc)
make install
if [ ! -f /tools/bin/cc ]; then
    ln -sf gcc /tools/bin/cc
fi
cd $LFS/sources
rm -rf \"\$GCC_DIR\"
echo 'GCC (pass 1) done'

# ----- 3. Linux API headers -----
echo '=== Installing Linux API headers ==='
LINUX_TAR=\$(ls -1 linux-*.tar.xz 2>/dev/null | head -n1)
tar -xf \"\$LINUX_TAR\"
LINUX_DIR=\$(echo \"\$LINUX_TAR\" | sed 's/\.tar\.xz$//')
cd \"\$LINUX_DIR\"
make mrproper
make headers
find usr/include -name '.*' -delete
rm -f usr/include/Makefile
cp -rv usr/include /tools/include
cd $LFS/sources
rm -rf \"\$LINUX_DIR\"
echo 'Linux headers installed'

# ----- 4. Glibc -----
echo '=== Building glibc ==='
GLIBC_TAR=\$(ls -1 glibc-*.tar.xz 2>/dev/null | head -n1)
tar -xf \"\$GLIBC_TAR\"
GLIBC_DIR=\$(echo \"\$GLIBC_TAR\" | sed 's/\.tar\.xz$//')
cd \"\$GLIBC_DIR\"
mkdir -v build
cd build
../configure --prefix=/tools            \
             --host=$LFS_TGT            \
             --build=\$(../scripts/config.guess) \
             --enable-kernel=4.14       \
             --with-headers=/tools/include
make -j\$(nproc)
make install
cd $LFS/sources
rm -rf \"\$GLIBC_DIR\"
echo 'glibc done'

# ----- 5. Libstdc++ (from GCC) -----
echo '=== Building libstdc++ ==='
# Re-extract GCC source
tar -xf \"\$GCC_TAR\"
GCC_DIR=\$(echo \"\$GCC_TAR\" | sed 's/\.tar\.xz$//')
cd \"\$GCC_DIR\"
mkdir -v build-libstdc++
cd build-libstdc++
../libstdc++-v3/configure --host=$LFS_TGT       \
                          --build=\$(../config.guess) \
                          --prefix=/tools       \
                          --disable-multilib    \
                          --disable-nls         \
                          --disable-libstdcxx-pch \
                          --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/\$(cat ../gcc/BASE-VER)
make -j\$(nproc)
make install
cd $LFS/sources
rm -rf \"\$GCC_DIR\"
echo 'libstdc++ done'

echo '============================================'
echo 'Temporary toolchain built successfully!'
echo '============================================'
"

# Vérification post-construction
if check_toolchain; then
    log_success "Toolchain built and verified."
    touch "$LFS/var/log/toolchain-ready"
else
    log_error "Toolchain build failed verification."
    exit 1
fi

exit 0