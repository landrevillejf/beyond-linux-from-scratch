#!/bin/bash
# Build LFS system – compilation of Glibc, Binutils, GCC, etc.
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

# -----------------------------------------------------------------
# 🔧 ASSURER LA PRÉSENCE DES OUTILS DE BASE DANS /tools/bin
# -----------------------------------------------------------------
log_info "Copying essential host tools to $LFS/tools/bin"
run_privileged mkdir -pv "$LFS/tools/bin"

copy_tool_with_libs() {
    local tool_path="$1"
    local tool_name
    tool_name="$(basename "$tool_path")"

    run_privileged cp -Lv "$tool_path" "$LFS/tools/bin/$tool_name"
    run_privileged chmod +x "$LFS/tools/bin/$tool_name"

    # Copy dynamic libraries required by the tool into the chroot.
    ldd "$tool_path" 2>/dev/null | awk '/=> \// {print $3} /^\/lib/ {print $1}' | while read -r lib; do
        [ -z "$lib" ] && continue
        local rel_dir
        rel_dir="$(dirname "$lib")"
        run_privileged mkdir -pv "$LFS$rel_dir"
        run_privileged cp -Lv "$lib" "$LFS$lib"
    done
}

for tool in bash cat cp echo grep ls make mkdir mv rm sed tar touch uname find xargs chmod chown gcc g++ ld nproc; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$tool_path" ] && [ -x "$tool_path" ] && [[ "$tool_path" = /* ]]; then
        copy_tool_with_libs "$tool_path"
    elif [ -n "$tool_path" ]; then
        log_info "Skipping shell builtin '$tool' (no standalone binary to copy)"
    else
        log_warning "Host tool '$tool' not found, chroot may fail"
    fi
done
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

log_info "Creating internal compilation script"
cat > "$LFS/build-lfs-system.sh" << 'INNEREOF'
#!/bin/bash
set -e

# LFS temporary tools path
export PATH=/tools/bin:/bin:/usr/bin

cd /sources

compile_package() {
    local archive=$1
    local pkg_name=$(echo "$archive" | sed -E 's/\.tar\.[a-z0-9]+$//')
    echo "=== Building $pkg_name ==="
    tar -xf "$archive"
    cd "$pkg_name"
    if [ -d "build" ]; then
        cd build
    elif [ -d "build-aux" ]; then
        cd build-aux
    fi
    if [ -f "configure" ]; then
        ./configure --prefix=/usr --disable-werror
    elif [ -f "CMakeLists.txt" ]; then
        cmake -DCMAKE_INSTALL_PREFIX=/usr .
    else
        true
    fi
    make -j$(nproc)
    make install
    cd /sources
    rm -rf "$pkg_name"
    echo "=== $pkg_name done ==="
}

found_glibc=0
for archive in glibc-*.tar.xz; do
    if [ -f "$archive" ]; then
        compile_package "$archive"
        found_glibc=1
        break
    fi
done
[ $found_glibc -eq 0 ] && echo "WARNING: glibc source not found"

found_binutils=0
for archive in binutils-*.tar.xz; do
    if [ -f "$archive" ]; then
        compile_package "$archive"
        found_binutils=1
        break
    fi
done
[ $found_binutils -eq 0 ] && echo "WARNING: binutils source not found"

found_gcc=0
for archive in gcc-*.tar.xz; do
    if [ -f "$archive" ]; then
        compile_package "$archive"
        found_gcc=1
        break
    fi
done
[ $found_gcc -eq 0 ] && echo "WARNING: gcc source not found"

for pkg in coreutils bash make grep sed gawk findutils tar gzip; do
    for archive in "$pkg"-*.tar.*; do
        if [ -f "$archive" ]; then
            compile_package "$archive"
            break
        fi
    done
done

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