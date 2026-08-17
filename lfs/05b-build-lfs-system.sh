#!/bin/bash
# Build LFS system – official LFS compilation with cross-toolchain
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
# 05b-build-lfs-system.sh – Compile glibc, binutils, gcc, and Chapter 8
#                            packages inside the chroot prepared by 05a.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/../common/utils.sh" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/../common/utils.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warning() { echo "[WARNING] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
fi

KERNEL_TYPE="${KERNEL_TYPE:-linux}"
export KERNEL_TYPE

LFS_TGT="${LFS_TGT:-$(uname -m)-lfs-linux-gnu}"

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
    log_error "LFS variable not set"
    exit 1
fi

if [ -d "$LFS/image/tools" ] && [ -d "$LFS/image/usr" ] && [ ! -d "$LFS/tools" ]; then
    LFS="$LFS/image"
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

# -----------------------------------------------------------------
# Verify chroot is functional (05a should have set this up)
# -----------------------------------------------------------------
if [ ! -L "$LFS/bin/bash" ] && [ ! -x "$LFS/bin/bash" ]; then
    log_error "/bin/bash not found in chroot – run lfs-basic (05a) first"
    exit 1
fi
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>&1; then
    log_error "chroot test failed – run lfs-basic (05a) first"
    exit 1
fi

# -----------------------------------------------------------------
# Mount filesystems (idempotent – safe if 05a already mounted them)
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
# Internal compilation script (official LFS steps with cross-toolchain)
# -----------------------------------------------------------------
log_info "Creating internal compilation script"
cat >"$LFS/build-lfs-system.sh" <<'INNEREOF'
#!/bin/bash
set -e

export PATH=/tools/bin:/bin:/usr/bin:/sbin
export LD_LIBRARY_PATH=/tools/lib
export LIBRARY_PATH=/tools/lib
# Use the cross-compiled toolchain bash so that make recipes survive the
# moment glibc installs its new ld.so.  The bootstrapped /bin/bash is linked
# against the HOST libc (/lib/x86_64-linux-gnu/libc.so.6) which lacks the
# GLIBC_PRIVATE __nptl_change_stack_perm symbol required by glibc 2.34+
# ld.so, causing an immediate symbol-lookup error.  /tools/bin/bash was
# cross-compiled against the LFS toolchain glibc at /usr/lib/libc.so.6 and
# is therefore compatible with both the pre-install toolchain glibc and the
# newly installed system glibc.
export SHELL=/tools/bin/bash
export CONFIG_SHELL=/tools/bin/bash

cd /sources

# ----- Helper: extract and cd -----
extract() {
    local archive=$1
    local dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
    echo "Extracting $archive -> $dir"
    tar -xf "$archive"
    cd "$dir"
}

# ----- Helper: find archive (supports .tar.xz, .tar.gz, .tgz, etc.) -----
find_archive() {
    local base=$1
    local archive=""
    for f in "/sources/${base}"*.tar.* "/sources/${base}"*.tgz; do
        if [ -f "$f" ]; then
            archive="$f"
            break
        fi
    done
    echo "$archive"
}

# ---- Install Linux API headers into /usr/include ----
# The toolchain stage (04-build-toolchain.sh) installs Linux API headers to
# $LFS/usr/include before entering the chroot.  Re-use them when already
# present to avoid invoking make inside a chroot where the host gcc is not
# accessible.  When the headers are absent (e.g. partial resume), fall back
# to a full installation using the cross-compiler with --sysroot=/ so that
# it can locate the C headers already present in the chroot under /usr/include.
if [ -d /usr/include/linux ] && [ -f /usr/include/linux/types.h ]; then
    echo "Linux API headers already present from toolchain stage, skipping reinstallation"
else
    echo "Installing Linux API headers"
    LINUX_ARCHIVE=$(find_archive linux)
    if [ -z "$LINUX_ARCHIVE" ]; then
        echo "ERROR: linux source not found"
        echo "Available source archives:"
        ls -la
        exit 1
    fi
    echo "Extracting $LINUX_ARCHIVE"
    tar -xf "$LINUX_ARCHIVE"
    LINUX_DIR=$(echo "$LINUX_ARCHIVE" | sed -E 's/\.tar\.[a-z0-9]+$//' | sed -E 's/\.tgz$//')
    if [ ! -d "$LINUX_DIR" ]; then
        echo "ERROR: extracted directory $LINUX_DIR not found"
        exit 1
    fi
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

# ---- Set cross-compiler variables ----
# The cross-compiler was built with --with-sysroot=$LFS pointing at the
# host-side LFS directory.  Inside the chroot that absolute path does not
# exist (the chroot root IS that directory), so the linker cannot find
# target libraries and configure reports "C compiler cannot create
# executables".  Override the built-in sysroot with --sysroot=/ so that
# headers and libraries are resolved relative to the chroot root.
# Add -L and -rpath-link to both CC and CXX so the linker can find
# the cross-compiler's runtime libraries (libgcc_s, libstdc++, etc.)
# installed in /tools/lib and /tools/lib64.
CC="${LFS_TGT}-gcc --sysroot=/ -L/tools/lib -L/tools/lib64 -Wl,-rpath-link,/tools/lib -Wl,-rpath-link,/tools/lib64"
CXX="${LFS_TGT}-g++ --sysroot=/ -L/tools/lib -L/tools/lib64 -Wl,-rpath-link,/tools/lib -Wl,-rpath-link,/tools/lib64"
LD="${LFS_TGT}-ld"
AS="${LFS_TGT}-as"
export CC CXX LD AS

# ---- S'assurer que libgcc_s est disponible pour glibc ----
# glibc's configure must be able to link a test program.  The cross-compiler
# always needs libgcc_s for linking; without it even "int main(){}" fails
# and configure reports "cannot compute suffix of object files".
# The toolchain GCC (pass 1) is built with --disable-shared which may skip
# producing libgcc_s.so.  Detect what's available and build it if missing.
echo "Ensuring libgcc_s is available for glibc..."
echo "Contents of /tools/lib before libgcc_s check:"
ls -la /tools/lib/ 2>/dev/null || echo "  /tools/lib does not exist"
echo "Contents of /tools/lib64 before libgcc_s check:"
ls -la /tools/lib64/ 2>/dev/null || echo "  /tools/lib64 does not exist"

# Search for any libgcc_s variant (soname, real file, or unversioned symlink)
LIBGCC_S=""
for candidate in $(find /tools -name "libgcc_s.so*" 2>/dev/null); do
    if [ -z "$LIBGCC_S" ]; then
        LIBGCC_S="$candidate"
    fi
done

if [ -n "$LIBGCC_S" ]; then
    echo "Found libgcc_s at: $LIBGCC_S"
    # Ensure both the soname and unversioned symlink exist in /tools/lib
    if [ "$LIBGCC_S" != "/tools/lib/libgcc_s.so.1" ] && [ -f "$LIBGCC_S" ]; then
        cp -v "$LIBGCC_S" /tools/lib/libgcc_s.so.1
    fi
    ln -sf libgcc_s.so.1 /tools/lib/libgcc_s.so
    echo "libgcc_s ready in /tools/lib"
else
    echo "libgcc_s.so not found in /tools – building from GCC source"
    # The cross-compiler was built with --disable-shared so libgcc_s.so was
    # never produced.  Build just the target shared libgcc inside the chroot
    # using the cross-compiler and install it to /tools/lib.
    GCC_SRC=$(find_archive gcc)
    if [ -z "$GCC_SRC" ]; then
        echo "ERROR: GCC source not found – cannot build libgcc_s"
        exit 1
    fi
    echo "Extracting $GCC_SRC for libgcc build"
    tar -xf "/sources/$GCC_SRC"
    GCC_SRC_DIR=$(tar -tf "/sources/$GCC_SRC" | head -1 | cut -d/ -f1)
    cd "/sources/$GCC_SRC_DIR"
    mkdir -v build-libgcc
    cd build-libgcc
    # Build only the target shared library (libgcc_s.so)
    "${LFS_TGT}-gcc" -v || true   # diagnostic: confirm compiler works
    make -j"$(nproc)" \
        CC="${LFS_TGT}-gcc" \
        CFLAGS="-O2 -g" \
        libgcc_s.so || {
        # Fallback: use the gcc-internal Makefile target
        echo "Direct make failed, trying via libgcc Makefile..."
        ../libgcc/configure --host="$LFS_TGT" --prefix=/tools
        make -j"$(nproc)"
        make install
    }
    # Install libgcc_s.so into /tools/lib if the build placed it elsewhere
    find . -name "libgcc_s.so*" -exec cp -v {} /tools/lib/ \;
    ln -sf libgcc_s.so.1 /tools/lib/libgcc_s.so 2>/dev/null || true
    cd /sources
    rm -rf "/sources/$GCC_SRC_DIR"
    echo "libgcc_s built and installed"
    if [ ! -f /tools/lib/libgcc_s.so ] && [ ! -f /tools/lib/libgcc_s.so.1 ]; then
        echo "ERROR: libgcc_s build failed – no .so produced"
        exit 1
    fi
fi
echo "libgcc_s available: $(ls -la /tools/lib/libgcc_s.so* 2>/dev/null)"

# ============================================================
# 1. BUILD GLIBC
# ============================================================
echo "=== Building glibc ==="

# Sanity check: verify the cross-compiler can compile and link a test program
# with the same flags used by glibc's configure.  If this fails we get a clear
# error instead of the cryptic "cannot compute suffix of object files".
echo "Verifying cross-compiler can link with libgcc_s..."
echo 'int main(void){return 0;}' > /tmp/conftest.c
if $CC -v /tmp/conftest.c -o /tmp/conftest 2>&1; then
    echo "Cross-compiler sanity check: PASSED"
else
    echo "ERROR: Cross-compiler cannot create executables"
    echo "CC=$CC"
    echo "LDFLAGS=$LDFLAGS"
    echo "libgcc_s status:"
    ls -la /tools/lib/libgcc_s* 2>/dev/null || echo "  no libgcc_s in /tools/lib"
    rm -f /tmp/conftest.c /tmp/conftest
    exit 1
fi
rm -f /tmp/conftest.c /tmp/conftest

GLIBC_ARCHIVE=$(find_archive glibc)
if [ -z "$GLIBC_ARCHIVE" ]; then
    echo "ERROR: glibc source not found"
    exit 1
fi
extract "$GLIBC_ARCHIVE"
mkdir -v build
cd build
# Add LDFLAGS to help linker find libgcc_s during glibc tests
LDFLAGS="-L/tools/lib -L/tools/lib64 -Wl,-rpath-link,/tools/lib -Wl,-rpath-link,/tools/lib64" \
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
# Use /tools/bin/bash (cross-compiled toolchain bash) as SHELL so that make
# recipes keep working after glibc installs its new ld.so.  The new ld.so
# (glibc 2.34+) requires __nptl_change_stack_perm@GLIBC_PRIVATE from
# libc.so.6; the toolchain bash links against /usr/lib/libc.so.6 which is
# updated to glibc 2.42 early in the install sequence, while the bootstrapped
# /bin/bash links against the HOST /lib/x86_64-linux-gnu/libc.so.6 which
# does not carry that private symbol.
make RM=/tools/bin/rm SHELL=/tools/bin/bash install
cd /sources
rm -rf "$(basename "$GLIBC_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
echo "glibc done"

# After glibc installs its new runtime linker (/lib64/ld-linux-x86-64.so.2),
# the new ld.so only searches /lib64 and /usr/lib by default.  The
# bootstrapped /bin/bash (copied from the Ubuntu host) depends on libraries
# such as libtinfo.so.6 and libreadline.so.8 that live under /lib, which is
# NOT in the new ld.so's compiled-in search path.  Create /etc/ld.so.conf
# and rebuild the dynamic linker cache so every subsequent shell invocation
# (/bin/sh, ../configure, etc.) can find those bootstrap host libraries.
# /usr/lib is listed first so that the newly-installed glibc 2.42 libc.so.6
# takes precedence over the Ubuntu host libc copied to /lib/x86_64-linux-gnu.
mkdir -p /etc
printf '/usr/lib\n/usr/lib/x86_64-linux-gnu\n/lib\n/lib/x86_64-linux-gnu\n/lib64\n' > /etc/ld.so.conf
/sbin/ldconfig || true
echo "ldconfig cache rebuilt after glibc install"
# The new glibc 2.42 ld.so (/lib64/ld-linux-x86-64.so.2) requires the
# __nptl_change_stack_perm@GLIBC_PRIVATE symbol from a matching libc.so.6.
# The old cross-toolchain libc at /tools/lib/libc.so.6 uses a different
# GLIBC_PRIVATE ABI, causing a symbol-lookup failure when bootstrapped host
# tools (tar, head, cut ...) are executed after glibc installs its new ld.so.
# Prefer the newly-installed /usr/lib/libc.so.6 (glibc 2.42) so both the
# Ubuntu-bootstrapped binaries and the toolchain binaries use a compatible libc.
export LD_LIBRARY_PATH=/usr/lib:/tools/lib

# ============================================================
# 2. BUILD BINUTILS (official LFS)
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
# 3. BUILD GCC (official LFS) – compilation native avec GCC hôte
# ============================================================
echo "=== Building gcc ==="
GCC_ARCHIVE=$(find_archive gcc)
if [ -z "$GCC_ARCHIVE" ]; then
    echo "ERROR: gcc source not found"
    exit 1
fi
extract "$GCC_ARCHIVE"

# ---- Vérification que GMP, MPFR, MPC sont présents ----
for pkg in gmp mpfr mpc; do
    if [ -z "$(find_archive "$pkg")" ]; then
        echo "ERROR: $pkg source not found in /sources – please check sources.list"
        exit 1
    fi
done

# Integrate GMP, MPFR, MPC into GCC source tree
echo "Integrating GMP, MPFR, MPC into GCC source tree"
GMP_ARCHIVE=$(find_archive gmp)
if [ -n "$GMP_ARCHIVE" ]; then
    tar -xf "$GMP_ARCHIVE"
    GMP_DIR=$(basename "$GMP_ARCHIVE" | sed -E 's/\.tar\.[a-z0-9]+$//' | sed -E 's/\.tgz$//')
    mv -v "$GMP_DIR" gmp
else
    echo "WARNING: GMP source not found – GCC may fail"
fi

MPFR_ARCHIVE=$(find_archive mpfr)
if [ -n "$MPFR_ARCHIVE" ]; then
    tar -xf "$MPFR_ARCHIVE"
    MPFR_DIR=$(basename "$MPFR_ARCHIVE" | sed -E 's/\.tar\.[a-z0-9]+$//' | sed -E 's/\.tgz$//')
    mv -v "$MPFR_DIR" mpfr
else
    echo "WARNING: MPFR source not found – GCC may fail"
fi

MPC_ARCHIVE=$(find_archive mpc)
if [ -n "$MPC_ARCHIVE" ]; then
    tar -xf "$MPC_ARCHIVE"
    MPC_DIR=$(basename "$MPC_ARCHIVE" | sed -E 's/\.tar\.[a-z0-9]+$//' | sed -E 's/\.tgz$//')
    mv -v "$MPC_DIR" mpc
else
    echo "WARNING: MPC source not found – GCC may fail"
fi

# ---- Copie des bibliothèques C++ dans le sysroot (recherche dans /tools/lib et /tools/lib64) ----
echo "Copying C++ runtime libraries to /usr/lib for GCC build..."
mkdir -p /usr/lib

# Recherche les bibliothèques dans les deux répertoires possibles
for libdir in /tools/lib /tools/lib64; do
    if [ -d "$libdir" ]; then
        echo "Looking for libraries in $libdir"
        cp -a $libdir/libstdc++.so* /usr/lib/ 2>/dev/null || true
        cp -a $libdir/libgcc_s.so* /usr/lib/ 2>/dev/null || true
        cp -a $libdir/libgomp.so* /usr/lib/ 2>/dev/null || true
        cp -a $libdir/libatomic.so* /usr/lib/ 2>/dev/null || true
    fi
done

# Reconstruire le cache du linker avec les bons chemins
echo "/usr/lib" > /etc/ld.so.conf
echo "/tools/lib" >> /etc/ld.so.conf
echo "/tools/lib64" >> /etc/ld.so.conf
/sbin/ldconfig

# Forcer le linker dynamique à utiliser ces chemins pour les tests
export LD_LIBRARY_PATH=/tools/lib:/tools/lib64:/usr/lib

# ---- Ajout des flags pour libcody (CXX et LDFLAGS) ----
export CXX="${LFS_TGT}-g++ --sysroot=/ -L/tools/lib -L/tools/lib64 -Wl,-rpath-link,/tools/lib -Wl,-rpath-link,/tools/lib64 -Wl,-rpath,/tools/lib -Wl,-rpath,/tools/lib64"
export LDFLAGS="-L/tools/lib -L/tools/lib64 -Wl,-rpath-link,/tools/lib -Wl,-rpath-link,/tools/lib64 -Wl,-rpath,/tools/lib -Wl,-rpath,/tools/lib64"
export LD_RUN_PATH=/tools/lib:/tools/lib64

mkdir -v build
cd build
../configure --prefix=/usr \
             --enable-languages=c,c++ \
             --disable-multilib \
             --disable-bootstrap \
             --disable-lto \
             --disable-libcc1 \
             --with-system-zlib \
             --enable-default-pie \
             --enable-default-ssp \
             --enable-cet=auto \
             --enable-linker-build-id \
             CXXFLAGS="-std=gnu++14" \
             LDFLAGS="$LDFLAGS"
make -j$(nproc)
make install
ln -sf gcc /usr/bin/cc
ln -sf g++ /usr/bin/c++
cd /sources
rm -rf "$(basename "$GCC_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
echo "gcc done"
unset CC CXX

# ============================================================
# 4. BUILD COMPLETE LFS SYSTEM (Chapter 8 packages)
# ============================================================
# Following LFS 13.0 Chapter 8 order for complete system
build_simple() {
    local pkg=$1
    local cflags=""
    local configure_args=""
    local archive=$(find_archive "$pkg")
    if [ -z "$archive" ]; then
        echo "WARNING: $pkg source not found, skipping"
        return 0
    fi
    local dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
    echo "=== Building $dir ==="
    tar -xf "$archive"
    cd "$dir"
    
    # Package-specific patches and flags
    case "$pkg" in
        diffutils)
            if grep -q "PATH_MAX" lib/stackvma.c 2>/dev/null &&
               ! grep -q "#include <limits.h>" lib/stackvma.c 2>/dev/null; then
                sed -i '1s/^/#include <limits.h>\n/' lib/stackvma.c
            fi
            cflags="-D_GNU_SOURCE -DPATH_MAX=4096"
            ;;
        coreutils|grep|sed|findutils|m4)
            cflags="-D_GNU_SOURCE -DPATH_MAX=4096"
            ;;
        file)
            cflags="-D_GNU_SOURCE"
            ;;
    esac
    
    if [ -f "configure" ]; then
        CFLAGS="$cflags" ./configure --prefix=/usr --sysconfdir=/etc $configure_args
    elif [ -f "Makefile" ]; then
        true
    fi
    CFLAGS="$cflags" make -j$(nproc)
    CFLAGS="$cflags" make install
    cd /sources
    rm -rf "$dir"
    echo "=== $dir done ==="
}

# LFS 13.0 Chapter 8 package order (excluding already built: glibc, binutils, gcc)
for pkg in man-pages iana-etc zlib bzip2 xz lz4 zstd file readline pcre2 bc \
           flex tcl expect dejagnu pkgconf gmp mpfr mpc attr acl libcap libxcrypt \
           shadow ncurses psmisc gettext bison libtool gdbm gperf expat inetutils \
           less perl intltool autoconf automake openssl libelf libffi sqlite python \
           ninja meson kmod groff iproute2 kbd libpipeline texinfo vim man-db procps-ng util-linux e2fsprogs; do
    build_simple "$pkg"
done

# Special packages with custom build steps
# Perl XML::Parser
PERL_ARCHIVE=$(find_archive perl)
if [ -n "$PERL_ARCHIVE" ]; then
    echo "=== Building XML::Parser ==="
    XML_PARSER_ARCHIVE=$(find_archive "XML-Parser")
    if [ -n "$XML_PARSER_ARCHIVE" ]; then
        dir=$(tar -tf "$XML_PARSER_ARCHIVE" | head -1 | cut -d/ -f1)
        tar -xf "$XML_PARSER_ARCHIVE"
        cd "$dir"
        perl Makefile.PL
        make -j$(nproc)
        make install
        cd /sources
        rm -rf "$dir"
    fi
fi

# Python packages (Flit-Core, Packaging, Wheel, Setuptools)
for pkg in flit-core packaging wheel setuptools; do
    archive=$(find_archive "$pkg")
    if [ -n "$archive" ]; then
        dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
        echo "=== Building $dir ==="
        tar -xf "$archive"
        cd "$dir"
        pip3 install .
        cd /sources
        rm -rf "$dir"
    fi
done

# MarkupSafe and Jinja2 (Python dependencies)
for pkg in markupsafe jinja2; do
    archive=$(find_archive "$pkg")
    if [ -n "$archive" ]; then
        dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
        echo "=== Building $dir ==="
        tar -xf "$archive"
        cd "$dir"
        pip3 install .
        cd /sources
        rm -rf "$dir"
    fi
done

echo "=== Complete LFS system compilation complete ==="
INNEREOF

run_privileged chmod +x "$LFS/build-lfs-system.sh"

log_info "Entering chroot and compiling..."
run_privileged chroot "$LFS" /bin/bash -c "export INIT_SYSTEM=$INIT_SYSTEM; export KERNEL_TYPE=$KERNEL_TYPE; export LFS_TGT=$LFS_TGT; /build-lfs-system.sh"

# -----------------------------------------------------------------
# Post-build: re-link /bin/bash to the newly built system bash
# -----------------------------------------------------------------
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
