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
# Internal script with official LFS build steps
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

# ----- Helper function to extract and cd -----
extract() {
    local archive=$1
    local dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
    echo "Extracting $archive -> $dir"
    tar -xf "$archive"
    cd "$dir"
}

# ----- Build glibc (official LFS steps) -----
build_glibc() {
    local archive=$(ls glibc-*.tar.xz 2>/dev/null | head -1)
    if [ -z "$archive" ]; then
        echo "WARNING: glibc source not found"
        return 1
    fi
    extract "$archive"
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
    rm -rf "$(basename "$archive" .tar.xz)"
    echo "glibc done"
}

# ----- Build binutils (official LFS steps) -----
build_binutils() {
    local archive=$(ls binutils-*.tar.xz 2>/dev/null | head -1)
    if [ -z "$archive" ]; then
        echo "WARNING: binutils source not found"
        return 1
    fi
    extract "$archive"
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
    rm -rf "$(basename "$archive" .tar.xz)"
    echo "binutils done"
}

# ----- Build gcc (official LFS steps) -----
build_gcc() {
    local archive=$(ls gcc-*.tar.xz 2>/dev/null | head -1)
    if [ -z "$archive" ]; then
        echo "WARNING: gcc source not found"
        return 1
    fi
    extract "$archive"
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
    rm -rf "$(basename "$archive" .tar.xz)"
    echo "gcc done"
}

# ----- Build base packages (simple configure/make) -----
build_simple() {
    local pkg=$1
    local archive=$(ls "$pkg"-*.tar.* 2>/dev/null | head -1)
    if [ -z "$archive" ]; then
        echo "WARNING: $pkg source not found"
        return 1
    fi
    extract "$archive"
    if [ -f "configure" ]; then
        ./configure --prefix=/usr --sysconfdir=/etc
    elif [ -f "Makefile" ]; then
        : # already has Makefile
    fi
    make -j$(nproc)
    make install
    cd /sources
    rm -rf "$(basename "$archive" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
    echo "$pkg done"
}

# ----- Main build order -----
echo "=== Building glibc ==="
build_glibc

echo "=== Building binutils ==="
build_binutils

echo "=== Building gcc ==="
build_gcc

# Now the remaining base packages (coreutils, bash, etc.)
for pkg in coreutils bash make grep sed gawk findutils tar gzip; do
    echo "=== Building $pkg ==="
    build_simple "$pkg"
done

# Additional packages that may be needed but not covered by the loop
# For example, we might add gzip, tar already in loop, but also bzip2, etc.
# But the loop covers the essentials.

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