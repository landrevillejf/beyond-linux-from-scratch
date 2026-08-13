#!/bin/bash
# Build LFS system – official LFS compilation with cross-toolchain
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
# 05-build-lfs-system.sh – Build the LFS system using the cross-compiled toolchain.
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

LFS_TGT="${LFS_TGT:-$(uname -m)-lfs-linux-gnu}"

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

if [ -d "$LFS/image/tools" ] && [ -d "$LFS/image/usr" ] && [ ! -d "$LFS/tools" ]; then
    log_warning "Detected image-root layout at $LFS/image, switching LFS root"
    LFS="$LFS/image"
fi

run_privileged() {
    if [ "$(whoami)" = "root" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

copy_tool_with_libs() {
    local source_path="$1"
    local dest_path="$2"

    if [ ! -x "$source_path" ]; then
        return 1
    fi

    run_privileged mkdir -p "$(dirname "$dest_path")"
    run_privileged cp -Lv "$source_path" "$dest_path"
    run_privileged chmod +x "$dest_path"

    ldd "$source_path" 2>/dev/null | awk '/=> \// {print $3} $1 ~ /^\/lib/ {print $1}' | while read -r lib; do
        [ -z "$lib" ] && continue
        run_privileged mkdir -p "$LFS$(dirname "$lib")"
        if [ ! -e "$LFS$lib" ]; then
            run_privileged cp -Lv "$lib" "$LFS$lib"
        fi
    done
}

ensure_bootstrap_chroot_shell() {
    if [ ! -x "$LFS/bin/bash" ]; then
        log_info "Bootstrapping /bin/bash into chroot"
        if [ -x "$LFS/usr/bin/bash" ]; then
            run_privileged mkdir -p "$LFS/bin"
            run_privileged ln -sfn /usr/bin/bash "$LFS/bin/bash"
        else
            local host_bash
            host_bash="$(command -v bash 2>/dev/null || true)"
            if [ -z "$host_bash" ] || [ ! -x "$host_bash" ]; then
                log_error "Unable to locate a host bash binary for chroot bootstrap"
                exit 1
            fi
            copy_tool_with_libs "$host_bash" "$LFS/bin/bash"
        fi
    fi

    if [ ! -e "$LFS/bin/sh" ]; then
        run_privileged ln -sfn bash "$LFS/bin/sh"
    fi

    for tool in env xz bzip2 expr grep sed awk find xargs cut head tail wc tr sort uniq dirname basename tar uname make rm mkdir cp mv ln rmdir chmod ld bison m4 wget; do
        if [ ! -x "$LFS/usr/bin/$tool" ]; then
            log_info "Bootstrapping /usr/bin/$tool into chroot"
            local host_tool
            host_tool="$(command -v "$tool" 2>/dev/null || true)"
            if [ -n "$host_tool" ] && [ -x "$host_tool" ]; then
                copy_tool_with_libs "$host_tool" "$LFS/usr/bin/$tool"
            else
                log_warning "Host tool '$tool' not found, chroot may fail"
            fi
        fi
    done

    # glibc's gettext build invokes bison, which needs its m4 templates from
    # bison's datadir (typically /usr/share/bison). Ensure they are available
    # when bison is bootstrapped from the host.
    if [ -x "$LFS/usr/bin/bison" ] && [ ! -f "$LFS/usr/share/bison/m4sugar/m4sugar.m4" ]; then
        local host_bison_datadir
        host_bison_datadir="$(bison --print-datadir 2>/dev/null || true)"
        if [ -n "$host_bison_datadir" ] && [ -d "$host_bison_datadir" ]; then
            log_info "Copying bison data directory into chroot at $host_bison_datadir"
            run_privileged mkdir -p "$LFS$host_bison_datadir"
            run_privileged cp -r "$host_bison_datadir"/. "$LFS$host_bison_datadir"/
        else
            log_warning "Unable to locate host bison data directory, glibc build may fail"
        fi
    fi

    # Bootstrap python3 and create python symlink for glibc configure
    if command -v python3 &>/dev/null && [ ! -x "$LFS/usr/bin/python3" ]; then
        log_info "Bootstrapping /usr/bin/python3 into chroot"
        copy_tool_with_libs "$(command -v python3)" "$LFS/usr/bin/python3"
        # Copy Python standard library so glibc build scripts work inside the chroot.
        # glibc 2.39+ uses Python scripts (e.g. gen-as-const.py) during compilation;
        # without the stdlib the build fails with "No module named 'encodings'".
        PYTHON_STDLIB=$(python3 -c "import sysconfig; print(sysconfig.get_path('stdlib'))" 2>/dev/null || true)
        if [ -n "$PYTHON_STDLIB" ] && [ -d "$PYTHON_STDLIB" ]; then
            log_info "Copying Python stdlib into chroot at $PYTHON_STDLIB"
            run_privileged mkdir -p "$LFS$PYTHON_STDLIB"
            run_privileged cp -r "$PYTHON_STDLIB"/. "$LFS$PYTHON_STDLIB"/
        fi
    fi
    if [ ! -e "$LFS/usr/bin/python" ] && [ -x "$LFS/usr/bin/python3" ]; then
        run_privileged ln -sfn python3 "$LFS/usr/bin/python"
    fi

    # Ensure /bin/awk exists
    if [ ! -x "$LFS/bin/awk" ]; then
        if [ -x "$LFS/usr/bin/awk" ]; then
            run_privileged cp -v "$LFS/usr/bin/awk" "$LFS/bin/awk"
            run_privileged chmod +x "$LFS/bin/awk"
        else
            log_warning "/usr/bin/awk not found in chroot, awk may be missing"
        fi
    fi

    # Copy libtinfo.so.6 to /lib so the LFS glibc ld.so can find it after glibc
    # install replaces the dynamic linker.  On Ubuntu 24.04 (UsrMerge) ldd may
    # report the canonical path under /usr/lib rather than /lib, so search both
    # locations inside the chroot and fall back to the host if neither is present.
    if [ ! -e "$LFS/lib/libtinfo.so.6" ]; then
        _libtinfo_src=""
        for _dir in \
            "$LFS/lib/x86_64-linux-gnu" \
            "$LFS/usr/lib/x86_64-linux-gnu" \
            "$LFS/lib" \
            "$LFS/usr/lib"; do
            if [ -f "$_dir/libtinfo.so.6" ]; then
                _libtinfo_src="$_dir/libtinfo.so.6"
                break
            fi
        done
        if [ -z "$_libtinfo_src" ]; then
            _libtinfo_host=$(find /lib /usr/lib -name "libtinfo.so.6" 2>/dev/null | head -1)
            if [ -n "$_libtinfo_host" ]; then
                run_privileged mkdir -p "$LFS/lib"
                run_privileged cp -Lv "$_libtinfo_host" "$LFS/lib/libtinfo.so.6"
                log_info "Copied libtinfo.so.6 from host to chroot /lib"
            else
                log_warning "libtinfo.so.6 not found – chroot bash may fail after glibc install"
            fi
        else
            run_privileged cp -Lv "$_libtinfo_src" "$LFS/lib/libtinfo.so.6"
        fi
    fi
    # Also mirror libtinfo.so.6 to /usr/lib, which is one of the new glibc
    # ld.so's compiled-in default search directories.  This acts as a
    # belt-and-suspenders safeguard: the inner script runs ldconfig after glibc
    # installs to rebuild the cache, but having the file in /usr/lib ensures
    # /bin/bash keeps working even if ldconfig is unavailable or misconfigured.
    if [ -e "$LFS/lib/libtinfo.so.6" ]; then
        run_privileged mkdir -p "$LFS/usr/lib"
        if [ ! -e "$LFS/usr/lib/libtinfo.so.6" ]; then
            run_privileged cp -Lv "$LFS/lib/libtinfo.so.6" "$LFS/usr/lib/libtinfo.so.6"
            log_info "Mirrored libtinfo.so.6 to chroot /usr/lib for new glibc ld.so"
        fi
    fi

    # If the toolchain built a newer liblzma (e.g. xz-5.6+), prefer it over the
    # host version.  The host liblzma may be an older rollback package that does
    # not export the XZ_5.6.0 version symbol required by the cross-compiled xz
    # binary placed in /tools/bin by the toolchain stage.
    if [ -f "$LFS/tools/lib/liblzma.so.5" ] && [ -f "$LFS/lib/x86_64-linux-gnu/liblzma.so.5" ]; then
        run_privileged cp -Lv "$LFS/tools/lib/liblzma.so.5" "$LFS/lib/x86_64-linux-gnu/liblzma.so.5"
        log_info "Updated /lib/x86_64-linux-gnu/liblzma.so.5 from toolchain"
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

ensure_bootstrap_chroot_shell

if [ ! -f "$LFS/bin/bash" ]; then
    log_error "/bin/bash not found in $LFS/bin – run lfs-basic first"
    exit 1
fi
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
    log_error "chroot not working – run lfs-basic first"
    exit 1
fi

# Check for temporary toolchain
if [ ! -x "$LFS/tools/bin/${LFS_TGT}-gcc" ] || [ ! -x "$LFS/tools/bin/${LFS_TGT}-ld" ] || [ ! -x "$LFS/tools/bin/${LFS_TGT}-as" ]; then
    log_error "Missing temporary toolchain in $LFS/tools/bin (${LFS_TGT}-gcc/${LFS_TGT}-ld/${LFS_TGT}-as)"
    log_error "Cannot proceed – run lfs-basic first"
    exit 1
fi

if [ ! -x "$LFS/bin/sh" ]; then
    log_info "Creating /bin/sh symlink"
    run_privileged ln -sf bash "$LFS/bin/sh"
fi

# -----------------------------------------------------------------
# Mount filesystems
# -----------------------------------------------------------------
cleanup_mounts() {
    run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
    run_privileged umount "$LFS"/dev 2>/dev/null || true
    run_privileged umount "$LFS"/proc 2>/dev/null || true
    run_privileged umount "$LFS"/sys 2>/dev/null || true
    run_privileged umount "$LFS"/run 2>/dev/null || true
}
trap cleanup_mounts EXIT

run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t devpts devpts "$LFS"/dev/pts 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true
run_privileged mount -t tmpfs tmpfs "$LFS"/run 2>/dev/null || true

# -----------------------------------------------------------------
# COPY SOURCES INTO CHROOT (with fallbacks)
# -----------------------------------------------------------------
SOURCES_DIR="$LFS/sources"
HOST_SOURCES=""

# Locate host sources - try multiple locations
for candidate in \
    "$(dirname "$LFS")/sources" \
    "$PWD/sources" \
    "/tmp/lfs-sources" \
    "$(pwd)/../sources" \
    "$(dirname "$LFS")/../sources"
do
    if [ -d "$candidate" ] && [ -n "$(ls -A "$candidate" 2>/dev/null | grep -v placeholder.txt)" ]; then
        HOST_SOURCES="$candidate"
        break
    fi
done

if [ -z "$HOST_SOURCES" ]; then
    # If no sources found, create a symlink from $LFS/sources to the actual builder sources
    # The builder puts sources in $LFS/../sources or $PWD/sources
    log_warning "No sources found in standard locations. Trying to link to builder sources..."
    # In the real build, the builder places sources in $LFS/../sources
    if [ -d "$(dirname "$LFS")/../sources" ] && [ -n "$(ls -A "$(dirname "$LFS")/../sources" 2>/dev/null | grep -v placeholder.txt)" ]; then
        HOST_SOURCES="$(dirname "$LFS")/../sources"
    elif [ -d "$(dirname "$LFS")/sources" ] && [ -n "$(ls -A "$(dirname "$LFS")/sources" 2>/dev/null | grep -v placeholder.txt)" ]; then
        HOST_SOURCES="$(dirname "$LFS")/sources"
    else
        log_error "No sources found. Current directory: $PWD, LFS: $LFS"
        ls -la "$(dirname "$LFS")" 2>/dev/null || true
        exit 1
    fi
fi

log_info "Found sources at: $HOST_SOURCES"
run_privileged rm -rf "$SOURCES_DIR"
run_privileged mkdir -p "$SOURCES_DIR"
run_privileged cp -r "$HOST_SOURCES"/. "$SOURCES_DIR"/
run_privileged chown -R lfs:lfs "$SOURCES_DIR"

# Verify gmp is present
if ! run_privileged test -f "$SOURCES_DIR"/gmp-*.tar.*; then
    log_error "❌ gmp not found in $SOURCES_DIR after copy"
    run_privileged ls -la "$SOURCES_DIR" | head -30
    exit 1
fi
log_success "✅ gmp found in $SOURCES_DIR"

# -----------------------------------------------------------------
# Internal compilation script
# -----------------------------------------------------------------
log_info "Creating internal compilation script"
cat >"$LFS/build-lfs-system.sh" <<'INNEREOF'
#!/bin/bash
set -e

export PATH=/tools/bin:/bin:/usr/bin:/sbin
export LD_LIBRARY_PATH=/tools/lib
export SHELL=/tools/bin/bash
export CONFIG_SHELL=/tools/bin/bash

cd /sources || { echo "ERROR: /sources not found"; exit 1; }

if ! ls gmp-*.tar.* 1>/dev/null 2>&1; then
    echo "ERROR: gmp source not found in /sources"
    echo "Contenu de /sources :"
    ls -la
    exit 1
fi

# ----- Helper: extract and cd -----
extract() {
    local archive=$1
    local dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
    echo "Extracting $archive -> $dir"
    tar -xf "$archive"
    cd "$dir"
}

# ----- Helper: find archive -----
find_archive() {
    local base=$1
    local archive=""
    for f in "${base}"*.tar.* "${base}"*.tgz; do
        if [ -f "$f" ]; then
            archive="$f"
            break
        fi
    done
    echo "$archive"
}

# ---- Install Linux API headers ----
if [ -d /usr/include/linux ] && [ -f /usr/include/linux/types.h ]; then
    echo "Linux API headers already present"
else
    echo "Installing Linux API headers"
    LINUX_ARCHIVE=$(find_archive linux)
    if [ -z "$LINUX_ARCHIVE" ]; then
        echo "ERROR: linux source not found"
        ls -la
        exit 1
    fi
    tar -xf "$LINUX_ARCHIVE"
    LINUX_DIR=$(echo "$LINUX_ARCHIVE" | sed -E 's/\.tar\.[a-z0-9]+$//' | sed -E 's/\.tgz$//')
    cd "$LINUX_DIR"
    make mrproper
    make HOSTCC="${LFS_TGT}-gcc" HOSTCFLAGS="--sysroot=/" headers
    find usr/include -name '.*' -delete
    rm -f usr/include/Makefile
    cp -rv usr/include/. /usr/include
    cd /sources
    rm -rf "$LINUX_DIR"
    echo "Linux headers installed"
fi

# ---- Cross-compiler vars ----
CC="${LFS_TGT}-gcc --sysroot=/"
CXX="${LFS_TGT}-g++ --sysroot=/"
LD="${LFS_TGT}-ld"
AS="${LFS_TGT}-as"
export CC CXX LD AS

# ============================================================
# 1. GLIBC
# ============================================================
echo "=== Building glibc ==="
GLIBC_ARCHIVE=$(find_archive glibc)
if [ -z "$GLIBC_ARCHIVE" ]; then
    echo "ERROR: glibc source not found"
    exit 1
fi
extract "$GLIBC_ARCHIVE"
mkdir -v build
cd build
../configure --prefix=/usr \
             --host=$LFS_TGT \
             --build=$(uname -m)-linux-gnu \
             --disable-werror \
             --enable-kernel=4.14 \
             --enable-stack-protector=strong \
             --with-headers=/usr/include \
             --libdir=/usr/lib \
             --enable-cet \
             --enable-multi-arch
make -j$(nproc)
make RM=/tools/bin/rm SHELL=/tools/bin/bash install
cd /sources
rm -rf "$(basename "$GLIBC_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
echo "glibc done"

mkdir -p /etc
printf '/usr/lib\n/usr/lib/x86_64-linux-gnu\n/lib\n/lib/x86_64-linux-gnu\n/lib64\n' > /etc/ld.so.conf
/sbin/ldconfig || true
export LD_LIBRARY_PATH=/usr/lib:/tools/lib

# ============================================================
# 2. BINUTILS
# ============================================================
echo "=== Building binutils ==="
BINUTILS_ARCHIVE=$(find_archive binutils)
if [ -z "$BINUTILS_ARCHIVE" ]; then
    echo "ERROR: binutils source not found"
    exit 1
fi
extract "$BINUTILS_ARCHIVE"
mkdir -v build
cd build
../configure --prefix=/usr \
             --host=$LFS_TGT \
             --build=$(uname -m)-linux-gnu \
             --sysconfdir=/etc \
             --enable-gold \
             --enable-ld=default \
             --enable-plugins \
             --enable-shared \
             --disable-werror \
             --enable-64-bit-bfd \
             --without-zstd \
             --disable-gprofng \
             --disable-doc
make -j$(nproc) tooldir=/usr MAKEINFO=missing INFO_DEPS= CC_FOR_BUILD="${LFS_TGT}-gcc --sysroot=/" HOSTCC="${LFS_TGT}-gcc"
make tooldir=/usr install MAKEINFO=missing INFO_DEPS=
cd /sources
rm -rf "$(basename "$BINUTILS_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
echo "binutils done"

# ============================================================
# 3. GCC
# ============================================================
echo "=== Building gcc ==="
GCC_ARCHIVE=$(find_archive gcc)
if [ -z "$GCC_ARCHIVE" ]; then
    echo "ERROR: gcc source not found"
    exit 1
fi
extract "$GCC_ARCHIVE"

for pkg in gmp mpfr mpc; do
    if [ -z "$(find_archive "$pkg")" ]; then
        echo "ERROR: $pkg source not found in /sources"
        exit 1
    fi
done

echo "Integrating GMP, MPFR, MPC into GCC source tree"
GMP_ARCHIVE=$(find_archive gmp)
tar -xf "$GMP_ARCHIVE"
GMP_DIR=$(echo "$GMP_ARCHIVE" | sed -E 's/\.tar\.[a-z0-9]+$//' | sed -E 's/\.tgz$//')
mv -v "$GMP_DIR" gmp

MPFR_ARCHIVE=$(find_archive mpfr)
tar -xf "$MPFR_ARCHIVE"
MPFR_DIR=$(echo "$MPFR_ARCHIVE" | sed -E 's/\.tar\.[a-z0-9]+$//' | sed -E 's/\.tgz$//')
mv -v "$MPFR_DIR" mpfr

MPC_ARCHIVE=$(find_archive mpc)
tar -xf "$MPC_ARCHIVE"
MPC_DIR=$(echo "$MPC_ARCHIVE" | sed -E 's/\.tar\.[a-z0-9]+$//' | sed -E 's/\.tgz$//')
mv -v "$MPC_DIR" mpc

mkdir -v build
cd build
../configure --prefix=/usr \
             --enable-languages=c,c++ \
             --disable-multilib \
             --disable-bootstrap \
             --with-system-zlib \
             --enable-default-pie \
             --enable-default-ssp \
             --enable-cet=auto \
             --enable-linker-build-id \
             CXXFLAGS="-std=gnu++14"
make -j$(nproc)
make install
ln -sf gcc /usr/bin/cc
ln -sf g++ /usr/bin/c++
cd /sources
rm -rf "$(basename "$GCC_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
echo "gcc done"
unset CC CXX

# ============================================================
# 4. BASE PACKAGES
# ============================================================
unset CC CXX LD AS

build_simple() {
    local pkg=$1
    local cflags=""
    local archive=$(find_archive "$pkg")
    if [ -z "$archive" ]; then
        echo "WARNING: $pkg source not found, skipping"
        return 0
    fi
    local dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
    echo "=== Building $dir ==="
    tar -xf "$archive"
    cd "$dir"
    if [ "$pkg" = "diffutils" ]; then
        if grep -q "PATH_MAX" lib/stackvma.c 2>/dev/null &&
           ! grep -q "#include <limits.h>" lib/stackvma.c 2>/dev/null; then
            sed -i '1s/^/#include <limits.h>\n/' lib/stackvma.c
        fi
        cflags="-D_GNU_SOURCE -DPATH_MAX=4096"
    fi
    if [ -f "configure" ]; then
        CFLAGS="$cflags" ./configure --prefix=/usr --sysconfdir=/etc
    fi
    CFLAGS="$cflags" make -j$(nproc)
    CFLAGS="$cflags" make install
    cd /sources
    rm -rf "$dir"
    echo "=== $dir done ==="
}

for pkg in coreutils bash make grep sed gawk findutils tar gzip bzip2 diffutils patch; do
    build_simple "$pkg"
done

echo "=== Base system compilation complete ==="
INNEREOF

run_privileged chmod +x "$LFS/build-lfs-system.sh"

log_info "Entering chroot and compiling..."
run_privileged chroot "$LFS" /bin/bash -c "export INIT_SYSTEM=$INIT_SYSTEM; export KERNEL_TYPE=$KERNEL_TYPE; export LFS_TGT=$LFS_TGT; /build-lfs-system.sh"

if [ -x "$LFS/usr/bin/bash" ]; then
    run_privileged ln -sfn /usr/bin/bash "$LFS/bin/bash"
    run_privileged ln -sfn bash "$LFS/bin/sh"
fi

run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true
run_privileged umount "$LFS"/run 2>/dev/null || true

log_success "LFS system build complete"