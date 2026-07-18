#!/bin/bash
# Build LFS system – compilation of Glibc, Binutils, GCC, etc. (official LFS procedure)
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

KERNEL_TYPE="${KERNEL_TYPE:-linux}"
export KERNEL_TYPE
log_info "Kernel type: $KERNEL_TYPE"

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
log_info "Building LFS system"
log_info "========================================="

INIT_SYSTEM=${INIT_SYSTEM:-sysvinit}
log_info "Init system: $INIT_SYSTEM"

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – skipping compilation"
    exit 0
fi

if [ ! -f "$LFS/bin/bash" ]; then
    log_error "/bin/bash not found in $LFS/bin – run lfs-basic first"
    exit 1
fi
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
    log_error "chroot not working – run lfs-basic first"
    exit 1
fi

# If lfs-basic did not provision /tools toolchain, we cannot proceed.
if [ ! -x "$LFS/tools/bin/gcc" ] || [ ! -x "$LFS/tools/bin/ld" ] || [ ! -x "$LFS/tools/bin/as" ]; then
    log_warning "Missing temporary toolchain in $LFS/tools/bin (gcc/ld/as)"
    log_warning "Skipping lfs-system compilation in bootstrap mode"
    exit 0
fi

# Many autotools configure scripts require /bin/sh explicitly.
if [ ! -x "$LFS/bin/sh" ]; then
    log_info "Creating /bin/sh symlink inside chroot"
    run_privileged ln -sf bash "$LFS/bin/sh"
fi

# -----------------------------------------------------------------
# Copy essential host tools to /tools/bin (fallback if missing)
# -----------------------------------------------------------------
log_info "Copying essential host tools to $LFS/tools/bin (if missing)"
run_privileged mkdir -pv "$LFS/tools/bin"

copy_tool_with_libs() {
    local tool_path="$1"
    local tool_name
    tool_name="$(basename "$tool_path")"

    if [ -x "$LFS/tools/bin/$tool_name" ]; then
        log_info "Keeping existing chroot tool: /tools/bin/$tool_name"
        return 0
    fi

    run_privileged cp -Lv "$tool_path" "$LFS/tools/bin/$tool_name"
    run_privileged chmod +x "$LFS/tools/bin/$tool_name"

    ldd "$tool_path" 2>/dev/null | awk '/=> \// {print $3} /^\/lib/ {print $1}' | while read -r lib; do
        [ -z "$lib" ] && continue
        local rel_dir
        rel_dir="$(dirname "$lib")"
        run_privileged mkdir -pv "$LFS$rel_dir"
        if [ ! -e "$LFS$lib" ]; then
            run_privileged cp -Lv "$lib" "$LFS$lib"
        fi
    done
}

for tool in bash sh env cat cp echo grep ls make mkdir mv rm sed tar touch uname find xargs chmod chown nproc xz expr dirname sort tr cut uniq head tail wc; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$tool_path" ] && [ -x "$tool_path" ] && [[ "$tool_path" = /* ]]; then
        copy_tool_with_libs "$tool_path"
    elif [ -n "$tool_path" ]; then
        log_info "Skipping shell builtin '$tool' (no standalone binary to copy)"
    else
        log_warning "Host tool '$tool' not found, chroot may fail"
    fi
done

if [ ! -x "$LFS/usr/bin/env" ] && [ -x "$LFS/tools/bin/env" ]; then
    log_info "Creating /usr/bin/env symlink inside chroot"
    run_privileged mkdir -pv "$LFS/usr/bin"
    run_privileged ln -sf /tools/bin/env "$LFS/usr/bin/env"
fi
# -----------------------------------------------------------------

run_privileged mount --bind /dev $LFS/dev 2>/dev/null || true
run_privileged mount -t devpts devpts $LFS/dev/pts 2>/dev/null || true
run_privileged mount -t proc proc $LFS/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs $LFS/sys 2>/dev/null || true
run_privileged mount -t tmpfs tmpfs $LFS/run 2>/dev/null || true

SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    run_privileged chown -R lfs:lfs "$LFS/sources"
else
    log_error "No sources found in $SOURCES_HOST – cannot compile"
    exit 1
fi

# -----------------------------------------------------------------
# Internal script with official LFS build steps (fully detailed)
# -----------------------------------------------------------------
log_info "Creating internal compilation script"
cat > "$LFS/build-lfs-system.sh" << 'INNEREOF'
#!/bin/bash
set -e

# Prefer native chroot tools first; /tools/bin is fallback.
export PATH=/bin:/usr/bin:/tools/bin
export SHELL=/bin/bash
export CONFIG_SHELL=/bin/bash

cd /sources

# ---------- Helper functions ----------
extract() {
    local archive=$1
    local dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
    echo "Extracting $archive -> $dir"
    tar -xf "$archive"
    cd "$dir"
}

# ---------- Build glibc ----------
echo "=== Building glibc ==="
GLIBC_ARCHIVE=$(ls glibc-*.tar.xz 2>/dev/null | head -1)
if [ -z "$GLIBC_ARCHIVE" ]; then
    echo "ERROR: glibc source not found"
    exit 1
fi
extract "$GLIBC_ARCHIVE"
mkdir -v build
cd build
../configure --prefix=/usr \
             --disable-werror \
             --enable-kernel=4.14 \
             --enable-stack-protector=strong \
             --with-headers=/usr/include \
             --libdir=/usr/lib \
             --enable-cet \
             --enable-multi-arch
make -j$(nproc)
make install
cd /sources
rm -rf "$(basename "$GLIBC_ARCHIVE" .tar.xz)"
echo "glibc done"

# ---------- Build binutils ----------
echo "=== Building binutils ==="
BINUTILS_ARCHIVE=$(ls binutils-*.tar.xz 2>/dev/null | head -1)
if [ -z "$BINUTILS_ARCHIVE" ]; then
    echo "ERROR: binutils source not found"
    exit 1
fi
extract "$BINUTILS_ARCHIVE"
mkdir -v build
cd build
../configure --prefix=/usr \
             --sysconfdir=/etc \
             --enable-gold \
             --enable-ld=default \
             --enable-plugins \
             --enable-shared \
             --disable-werror \
             --enable-64-bit-bfd \
             --with-system-zlib
make -j$(nproc) tooldir=/usr
make tooldir=/usr install
cd /sources
rm -rf "$(basename "$BINUTILS_ARCHIVE" .tar.xz)"
echo "binutils done"

# ---------- Build gcc ----------
echo "=== Building gcc ==="
GCC_ARCHIVE=$(ls gcc-*.tar.xz 2>/dev/null | head -1)
if [ -z "$GCC_ARCHIVE" ]; then
    echo "ERROR: gcc source not found"
    exit 1
fi
extract "$GCC_ARCHIVE"
mkdir -v build
cd build
../configure --prefix=/usr \
             --enable-languages=c,c++ \
             --disable-multilib \
             --disable-bootstrap \
             --with-system-zlib \
             --enable-default-pie \
             --enable-default-ssp \
             --enable-cet=auto
make -j$(nproc)
make install
# Create symlinks for cc and c++
ln -sf gcc /usr/bin/cc
ln -sf g++ /usr/bin/c++
cd /sources
rm -rf "$(basename "$GCC_ARCHIVE" .tar.xz)"
echo "gcc done"

# ---------- Build coreutils ----------
echo "=== Building coreutils ==="
COREUTILS_ARCHIVE=$(ls coreutils-*.tar.* 2>/dev/null | head -1)
if [ -n "$COREUTILS_ARCHIVE" ]; then
    extract "$COREUTILS_ARCHIVE"
    ./configure --prefix=/usr --sysconfdir=/etc
    make -j$(nproc)
    make install
    cd /sources
    rm -rf "$(basename "$COREUTILS_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
    echo "coreutils done"
else
    echo "WARNING: coreutils source not found"
fi

# ---------- Build bash ----------
echo "=== Building bash ==="
BASH_ARCHIVE=$(ls bash-*.tar.* 2>/dev/null | head -1)
if [ -n "$BASH_ARCHIVE" ]; then
    extract "$BASH_ARCHIVE"
    ./configure --prefix=/usr --sysconfdir=/etc
    make -j$(nproc)
    make install
    cd /sources
    rm -rf "$(basename "$BASH_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
    echo "bash done"
else
    echo "WARNING: bash source not found"
fi

# ---------- Build make ----------
echo "=== Building make ==="
MAKE_ARCHIVE=$(ls make-*.tar.* 2>/dev/null | head -1)
if [ -n "$MAKE_ARCHIVE" ]; then
    extract "$MAKE_ARCHIVE"
    ./configure --prefix=/usr --sysconfdir=/etc
    make -j$(nproc)
    make install
    cd /sources
    rm -rf "$(basename "$MAKE_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
    echo "make done"
else
    echo "WARNING: make source not found"
fi

# ---------- Build grep ----------
echo "=== Building grep ==="
GREP_ARCHIVE=$(ls grep-*.tar.* 2>/dev/null | head -1)
if [ -n "$GREP_ARCHIVE" ]; then
    extract "$GREP_ARCHIVE"
    ./configure --prefix=/usr --sysconfdir=/etc
    make -j$(nproc)
    make install
    cd /sources
    rm -rf "$(basename "$GREP_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
    echo "grep done"
else
    echo "WARNING: grep source not found"
fi

# ---------- Build sed ----------
echo "=== Building sed ==="
SED_ARCHIVE=$(ls sed-*.tar.* 2>/dev/null | head -1)
if [ -n "$SED_ARCHIVE" ]; then
    extract "$SED_ARCHIVE"
    ./configure --prefix=/usr --sysconfdir=/etc
    make -j$(nproc)
    make install
    cd /sources
    rm -rf "$(basename "$SED_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
    echo "sed done"
else
    echo "WARNING: sed source not found"
fi

# ---------- Build gawk ----------
echo "=== Building gawk ==="
GAWK_ARCHIVE=$(ls gawk-*.tar.* 2>/dev/null | head -1)
if [ -n "$GAWK_ARCHIVE" ]; then
    extract "$GAWK_ARCHIVE"
    ./configure --prefix=/usr --sysconfdir=/etc
    make -j$(nproc)
    make install
    cd /sources
    rm -rf "$(basename "$GAWK_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
    echo "gawk done"
else
    echo "WARNING: gawk source not found"
fi

# ---------- Build findutils ----------
echo "=== Building findutils ==="
FINDUTILS_ARCHIVE=$(ls findutils-*.tar.* 2>/dev/null | head -1)
if [ -n "$FINDUTILS_ARCHIVE" ]; then
    extract "$FINDUTILS_ARCHIVE"
    ./configure --prefix=/usr --sysconfdir=/etc
    make -j$(nproc)
    make install
    cd /sources
    rm -rf "$(basename "$FINDUTILS_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
    echo "findutils done"
else
    echo "WARNING: findutils source not found"
fi

# ---------- Build tar ----------
echo "=== Building tar ==="
TAR_ARCHIVE=$(ls tar-*.tar.* 2>/dev/null | head -1)
if [ -n "$TAR_ARCHIVE" ]; then
    extract "$TAR_ARCHIVE"
    ./configure --prefix=/usr --sysconfdir=/etc
    make -j$(nproc)
    make install
    cd /sources
    rm -rf "$(basename "$TAR_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
    echo "tar done"
else
    echo "WARNING: tar source not found"
fi

# ---------- Build gzip ----------
echo "=== Building gzip ==="
GZIP_ARCHIVE=$(ls gzip-*.tar.* 2>/dev/null | head -1)
if [ -n "$GZIP_ARCHIVE" ]; then
    extract "$GZIP_ARCHIVE"
    ./configure --prefix=/usr --sysconfdir=/etc
    make -j$(nproc)
    make install
    cd /sources
    rm -rf "$(basename "$GZIP_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
    echo "gzip done"
else
    echo "WARNING: gzip source not found"
fi

echo "=== Base system compilation complete ==="
INNEREOF

run_privileged chmod +x "$LFS/build-lfs-system.sh"

log_info "Entering chroot and compiling..."
run_privileged chroot "$LFS" /bin/bash -c "export INIT_SYSTEM=$INIT_SYSTEM; export KERNEL_TYPE=$KERNEL_TYPE; /build-lfs-system.sh"

run_privileged umount $LFS/dev/pts 2>/dev/null || true
run_privileged umount $LFS/dev 2>/dev/null || true
run_privileged umount $LFS/proc 2>/dev/null || true
run_privileged umount $LFS/sys 2>/dev/null || true
run_privileged umount $LFS/run 2>/dev/null || true

log_success "LFS system build complete"