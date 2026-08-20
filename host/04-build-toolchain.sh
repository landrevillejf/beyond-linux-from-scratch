#!/usr/bin/env bash
# 04-build-toolchain.sh
# Build toolchain for LFS / BLFS
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.

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

KERNEL_TYPE=${KERNEL_TYPE:-linux}

detect_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
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

install_packages() {
    local distro="$1"
    shift
    local packages=("$@")
    log_info "Installing packages: ${packages[*]}"
    case "$distro" in
    debian | ubuntu)
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${packages[@]}"
        ;;
    fedora | rhel | centos | rocky)
        if command -v dnf &>/dev/null; then
            sudo dnf install -y "${packages[@]}"
        else
            sudo yum install -y "${packages[@]}"
        fi
        ;;
    opensuse* | sles)
        sudo zypper install -y "${packages[@]}"
        ;;
    arch | manjaro)
        sudo pacman -Syu --noconfirm "${packages[@]}"
        ;;
    alpine)
        sudo apk add "${packages[@]}"
        ;;
    *)
        log_error "Unknown distribution. Please install: ${packages[*]}"
        exit 1
        ;;
    esac
}

ensure_compiler() {
    if command -v gcc &>/dev/null; then
        log_info "GCC installed: $(gcc --version | head -1)"
        return 0
    fi
    log_warning "GCC not found, installing..."
    local distro
    distro=$(detect_distro)
    case "$distro" in
    debian | ubuntu) install_packages "$distro" gcc ;;
    fedora | rhel | centos | rocky) install_packages "$distro" gcc ;;
    arch | manjaro) install_packages "$distro" gcc ;;
    opensuse* | sles) install_packages "$distro" gcc ;;
    *)
        log_error "Install GCC manually."
        exit 1
        ;;
    esac
    if ! command -v gcc &>/dev/null; then
        log_error "GCC installation failed"
        exit 1
    fi
    log_success "GCC installed"
}

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
    log_error "LFS not set"
    exit 1
fi

LFS_TGT=${LFS_TGT:-$(uname -m)-lfs-linux-gnu}
NUM_JOBS=${NUM_JOBS:-$(nproc 2>/dev/null || echo 4)}
PATH="$LFS/tools/bin:/usr/bin:/bin"
export LFS LFS_TGT LC_ALL=POSIX PATH

log_info "LFS=$LFS, TARGET=$LFS_TGT, JOBS=$NUM_JOBS"

mkdir -pv "$LFS"/tools "$LFS"/sources

if ! id -u lfs &>/dev/null; then
    groupadd lfs
    useradd -s /bin/bash -g lfs -m -k /dev/null lfs
fi

LFS_HOME="/home/lfs"
mkdir -p "$LFS_HOME"
{
    echo "set +h"
    echo "umask 022"
    printf 'LFS=%q\n' "$LFS"
    echo "LC_ALL=POSIX"
    # shellcheck disable=SC2016
    {
        echo 'LFS_TGT=${LFS_TGT:-$(uname -m)-lfs-linux-gnu}'
        echo 'PATH=$LFS/tools/bin:/usr/bin:/bin'
    }
    echo "export LFS LC_ALL LFS_TGT PATH"
} >"$LFS_HOME/.bashrc"
cat >"$LFS_HOME/.bash_profile" <<'EOF'
if [ -f ~/.bashrc ]; then . ~/.bashrc; fi
EOF
chown -R lfs:lfs "$LFS_HOME"

chown -v lfs:lfs "$LFS"/tools "$LFS"/sources

check_toolchain() {
    if [ -x "$LFS/tools/bin/$LFS_TGT-gcc" ] &&
        [ -x "$LFS/tools/bin/$LFS_TGT-ld" ] &&
        [ -x "$LFS/tools/bin/$LFS_TGT-as" ]; then
        if echo 'int main(){}' | "$LFS/tools/bin/$LFS_TGT-gcc" -x c - -o /dev/null 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

if check_toolchain; then
    log_success "Toolchain already exists and works. Skipping build."
    exit 0
fi

build_toolchain() {
    cd "$LFS/sources" || {
        log_error "Sources directory missing"
        exit 1
    }

    for pkg in binutils gcc linux glibc; do
        if ! find . -maxdepth 1 -name "${pkg}-*.tar.*" -print -quit | grep -q .; then
            log_error "Source for $pkg not found"
            exit 1
        fi
    done

    # --------------------------------------------------------------
    # LFS 12.4 section 4.2: limited directory layout. Packages built
    # with DESTDIR=$LFS land under $LFS/usr, reached through the
    # usr-merge symlinks.
    # --------------------------------------------------------------
    mkdir -pv "$LFS"/{etc,var} "$LFS"/usr/{bin,lib,sbin}
    for dir in bin lib sbin; do
        if [ ! -e "$LFS/$dir" ]; then
            ln -sv "usr/$dir" "$LFS/$dir"
        fi
    done
    # lib64 is part of the x86_64 target layout, so key on the
    # target triple rather than the build host architecture.
    case "$LFS_TGT" in
        x86_64*) mkdir -pv "$LFS/lib64" ;;
    esac

    # ==============================================================
    # 1. BUILD BINUTILS (pass 1) - LFS 12.4 section 5.2
    # ==============================================================
    log_info "Building binutils (pass 1)"
    BINUTILS_TAR=$(find . -maxdepth 1 -name "binutils-*.tar.xz" -print -quit)
    tar -xf "$BINUTILS_TAR"
    BINUTILS_DIR=$(find . -maxdepth 1 -type d -name "binutils-*" -print -quit | sed 's|^\./||')
    cd "$BINUTILS_DIR"
    mkdir -v build
    cd build
    ../configure --prefix="$LFS/tools" \
        --with-sysroot="$LFS" \
        --target="$LFS_TGT" \
        --disable-nls \
        --enable-gprofng=no \
        --disable-werror \
        --enable-new-dtags \
        --enable-default-hash-style=gnu
    make -j"$NUM_JOBS"
    make install
    cd "$LFS/sources"
    rm -rf "$BINUTILS_DIR"
    log_success "binutils (pass 1) done"

    # ==============================================================
    # 2. BUILD GCC (pass 1) - LFS 12.4 section 5.3
    # ==============================================================
    log_info "Building GCC (pass 1)"
    GCC_TAR=$(find . -maxdepth 1 -name "gcc-*.tar.xz" -print -quit)
    tar -xf "$GCC_TAR"
    GCC_DIR=$(find . -maxdepth 1 -type d -name "gcc-*" -print -quit | sed 's|^\./||')
    cd "$GCC_DIR"
    for lib in gmp mpfr mpc; do
        LIB_TAR=$(find "$LFS/sources" -maxdepth 1 -name "${lib}-*.tar.*" -print | head -1)
        if [ -z "$LIB_TAR" ]; then
            log_error "Tarball for $lib not found"
            exit 1
        fi
        tar -xf "$LIB_TAR"
        LIB_DIR=$(tar -tf "$LIB_TAR" | head -1 | cut -d/ -f1)
        if [ -d "$LIB_DIR" ]; then
            mv -v "$LIB_DIR" "$lib"
        else
            log_error "Could not find extracted directory for $lib"
            exit 1
        fi
    done
    # Use lib instead of lib64 as default directory for 64-bit libs.
    # Keyed on the target triple: cross builds run on a host whose
    # uname -m does not match the target (e.g. aarch64 on x86_64).
    # Without this, GCC installs target libraries into /usr/lib64
    # (MULTILIB_OSDIRNAMES default), splitting the sysroot layout.
    case "$LFS_TGT" in
        x86_64*)
            sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
            ;;
        aarch64*)
            sed -e '/mabi.lp64=/s/lib64/lib/' \
                -i.orig gcc/config/aarch64/t-aarch64-linux
            ;;
    esac
    mkdir -v build
    cd build
    ../configure --target="$LFS_TGT" \
        --prefix="$LFS/tools" \
        --with-glibc-version=2.42 \
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
        --enable-languages=c,c++
    make -j"$NUM_JOBS"
    make install
    cd ..
    # Rebuild the full internal limits.h exactly like the GCC build
    # system would (LFS 12.4 section 5.3).
    cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
        "$(dirname "$("${LFS_TGT}-gcc" -print-libgcc-file-name)")/include/limits.h"
    cd "$LFS/sources"
    rm -rf "$GCC_DIR"
    log_success "GCC (pass 1) done"

    # ==============================================================
    # 3. LINUX API HEADERS - LFS 12.4 section 5.4
    # ==============================================================
    log_info "Installing Linux API headers"

    ARCH=$(echo "$LFS_TGT" | cut -d- -f1)
    case "$ARCH" in
        aarch64) ARCH=arm64 ;;
        x86_64)  ARCH=x86 ;;
        armv7l|armhf) ARCH=arm ;;
        riscv64) ARCH=riscv ;;
    esac

    LINUX_TAR=$(find . -maxdepth 1 -type f -printf '%f\n' | grep -E "^${KERNEL_TYPE}-[0-9].*\\.tar\\.xz$" | head -n1)
    if [ -z "$LINUX_TAR" ]; then
        log_error "No kernel source found for type '$KERNEL_TYPE'"
        exit 1
    fi

    download_kernel() {
        local mirrors=(
            "https://cdn.kernel.org/pub/linux/kernel/v6.x/${LINUX_TAR}"
            "https://mirrors.edge.kernel.org/pub/linux/kernel/v6.x/${LINUX_TAR}"
        )
        for url in "${mirrors[@]}"; do
            log_info "Downloading kernel from $url"
            if command -v wget &>/dev/null; then
                wget -O "$LINUX_TAR" "$url" && return 0
            elif command -v curl &>/dev/null; then
                curl -L -o "$LINUX_TAR" "$url" && return 0
            else
                log_error "No download tool (wget/curl) available"
                return 1
            fi
        done
        log_error "All kernel mirrors failed"
        return 1
    }

    validate_tarball() {
        local tarball="$1"
        if [ ! -f "$tarball" ] || [ ! -s "$tarball" ]; then
            log_error "Tarball missing or empty: $tarball"
            return 1
        fi
        local tar_cmd="tar -tf"
        case "$tarball" in
            *.tar.gz|*.tgz) tar_cmd="tar -tzf" ;;
            *.tar.xz|*.txz) tar_cmd="tar -tJf" ;;
            *.tar.bz2|*.tbz) tar_cmd="tar -tjf" ;;
            *) tar_cmd="tar -tf" ;;
        esac
        if ! $tar_cmd "$tarball" >/dev/null 2>&1; then
            log_error "Tarball integrity check failed: $tarball"
            return 1
        fi
        return 0
    }

    extract_linux() {
        if ! validate_tarball "$LINUX_TAR"; then
            return 1
        fi
        tar -xf "$LINUX_TAR"
        LINUX_DIR=$(tar -tf "$LINUX_TAR" | head -1 | cut -d/ -f1)
        if [ -d "$LINUX_DIR" ] && [ -f "$LINUX_DIR/Makefile" ]; then
            return 0
        else
            return 1
        fi
    }

    MAX_RETRIES=3
    for attempt in $(seq 1 $MAX_RETRIES); do
        if extract_linux; then
            break
        else
            log_warning "Extraction failed (attempt $attempt), removing corrupt tarball..."
            rm -f "$LINUX_TAR"
            if [ "$attempt" -lt $MAX_RETRIES ]; then
                log_info "Re-downloading kernel..."
                if download_kernel; then
                    continue
                else
                    log_error "Download failed, cannot proceed"
                    exit 1
                fi
            else
                log_error "All extraction attempts failed"
                exit 1
            fi
        fi
    done

    cd "$LINUX_DIR"
    make mrproper
    make ARCH="$ARCH" headers
    find usr/include -type f ! -name '*.h' -delete
    mkdir -p "$LFS/usr"
    cp -rv usr/include "$LFS/usr"
    cd "$LFS/sources"
    rm -rf "$LINUX_DIR"
    log_success "Linux headers installed"

    # ==============================================================
    # 4. GLIBC - LFS 12.4 section 5.5
    # ==============================================================
    log_info "Building glibc"
    # LSB compliance symlink, plus the x86_64 loader compatibility
    # symlink required by the dynamic library loader (LFS 5.5).
    # These belong to the target system, so key on the target
    # triple instead of the build host architecture.
    case "$LFS_TGT" in
        i?86*) ln -sfv ld-linux.so.2 "$LFS/lib/ld-lsb.so.3" ;;
        x86_64*)
            ln -sfv ../lib/ld-linux-x86-64.so.2 "$LFS/lib64"
            ln -sfv ../lib/ld-linux-x86-64.so.2 "$LFS/lib64/ld-lsb-x86-64.so.3"
            ;;
    esac
    GLIBC_TAR=$(find . -maxdepth 1 -name "glibc-*.tar.xz" -print -quit)
    tar -xf "$GLIBC_TAR"
    GLIBC_DIR=$(find . -maxdepth 1 -type d -name "glibc-*" -print -quit | sed 's|^\./||')
    cd "$GLIBC_DIR"
    # Make glibc programs store runtime data in FHS-compliant places.
    GLIBC_FHS_PATCH=$(find "$LFS/sources" -maxdepth 1 -name "glibc-*-fhs-*.patch" -print -quit)
    if [ -n "$GLIBC_FHS_PATCH" ]; then
        patch -Np1 -i "$GLIBC_FHS_PATCH"
    else
        log_warning "glibc FHS patch not found, continuing without it"
    fi
    mkdir -v build
    cd build
    echo "rootsbindir=/usr/sbin" > configparms
    ../configure --prefix=/usr \
        --host="$LFS_TGT" \
        --build="$(../scripts/config.guess)" \
        --disable-nscd \
        libc_cv_slibdir=/usr/lib \
        --enable-kernel=5.4
    make -j"$NUM_JOBS"
    make DESTDIR="$LFS" install
    sed '/RTLDLIST=/s@/usr@@g' -i "$LFS/usr/bin/ldd"
    cd "$LFS/sources"
    rm -rf "$GLIBC_DIR"
    log_success "glibc done"

    # ==============================================================
    # 5. LIBSTDC++ - LFS 12.4 section 5.6
    # ==============================================================
    log_info "Building libstdc++"
    tar -xf "$GCC_TAR"
    GCC_DIR=$(find . -maxdepth 1 -type d -name "gcc-*" -print -quit | sed 's|^\./||')
    cd "$GCC_DIR"
    # Same lib64 -> lib normalization as GCC pass 1 above, keyed on the
    # target: otherwise libstdc++ lands in /usr/lib64 on aarch64.
    case "$LFS_TGT" in
        x86_64*)
            sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
            ;;
        aarch64*)
            sed -e '/mabi.lp64=/s/lib64/lib/' \
                -i.orig gcc/config/aarch64/t-aarch64-linux
            ;;
    esac
    mkdir -v build-libstdc++
    cd build-libstdc++
    # Install into the final location ($LFS/usr/lib through DESTDIR):
    # that is where the pass 1 cross compiler looks for it through its
    # sysroot.  A /tools prefix puts the library in a directory the
    # cross compiler does not search.
    ../libstdc++-v3/configure --host="$LFS_TGT" \
        --build="$(../config.guess)" \
        --prefix=/usr \
        --disable-multilib \
        --disable-nls \
        --disable-libstdcxx-pch \
        --with-gxx-include-dir=/tools/"$LFS_TGT"/include/c++/"$(cat ../gcc/BASE-VER)"
    make -j"$NUM_JOBS"
    make DESTDIR="$LFS" install
    # Libtool archives are harmful for cross compilation (LFS 5.6).
    rm -fv "$LFS"/usr/lib/lib{stdc++{,exp,fs},supc++}.la
    cd "$LFS/sources"
    rm -rf "$GCC_DIR"
    log_success "libstdc++ done"

    # ==============================================================
    # 6. BINUTILS (pass 2) - LFS 12.4 section 6.17
    #
    # Note on ordering: the book builds the Chapter 6 temporary tools
    # first, then Binutils/GCC pass 2 into their final locations.
    # Here pass 2 must come BEFORE the /tools loop because the tools
    # loop installs target binaries into $LFS/tools/bin, which sits
    # first in PATH and cannot execute on the host.
    # ==============================================================
    log_info "Building Binutils (pass 2)"
    tar -xf "$BINUTILS_TAR"
    BINUTILS_DIR=$(find . -maxdepth 1 -type d -name "binutils-*" -print -quit | sed 's|^\./||')
    cd "$BINUTILS_DIR"
    # Prevent stale -lpthread linkage (LFS 12.4, binutils-2.45).
    # shellcheck disable=SC2016
    sed '6031s/$add_dir//' -i ltmain.sh
    mkdir -v build
    cd build
    ../configure --prefix=/usr \
        --build="$(../config.guess)" \
        --host="$LFS_TGT" \
        --disable-nls \
        --enable-shared \
        --enable-gprofng=no \
        --disable-werror \
        --enable-64-bit-bfd \
        --enable-new-dtags \
        --enable-default-hash-style=gnu
    make -j"$NUM_JOBS"
    make DESTDIR="$LFS" install
    rm -v "$LFS/usr/lib/lib"{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la} 2>/dev/null || true
    cd "$LFS/sources"
    rm -rf "$BINUTILS_DIR"
    log_success "Binutils (pass 2) done"

    # ==============================================================
    # 7. GCC (pass 2) - LFS 12.4 section 6.18
    #
    # Same ordering note as Binutils pass 2 above.
    # ==============================================================
    log_info "Building GCC (pass 2)"
    tar -xf "$GCC_TAR"
    GCC_DIR=$(find . -maxdepth 1 -type d -name "gcc-*" -print -quit | sed 's|^\./||')
    if [ -z "$GCC_DIR" ] || [ ! -d "$GCC_DIR" ]; then
        log_error "GCC directory not found after extraction"
        exit 1
    fi
    cd "$GCC_DIR"
    for lib in gmp mpfr mpc; do
        LIB_TAR=$(find "$LFS/sources" -maxdepth 1 -name "${lib}-*.tar.*" -print | head -1)
        if [ -n "$LIB_TAR" ]; then
            tar -xf "$LIB_TAR"
            LIB_DIR=$(tar -tf "$LIB_TAR" | head -1 | cut -d/ -f1)
            if [ -d "$LIB_DIR" ]; then
                mv -v "$LIB_DIR" "$lib"
            else
                log_error "Could not find extracted directory for $lib"
                exit 1
            fi
        else
            log_error "Tarball for $lib not found"
            exit 1
        fi
    done
    # Same lib64 -> lib normalization as GCC pass 1 (book 5.3): pass 2
    # installs libgcc_s.so.1 relative to this multilib OS dir name, and
    # it must end up in $LFS/usr/lib for the temporary tools below.
    case "$LFS_TGT" in
        x86_64*)
            sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
            ;;
        aarch64*)
            sed -e '/mabi.lp64=/s/lib64/lib/' \
                -i.orig gcc/config/aarch64/t-aarch64-linux
            ;;
    esac
    sed '/thread_header =/s/@.*@/gthr-posix.h/' \
        -i libgcc/Makefile.in libstdc++-v3/include/Makefile.in
    mkdir -v build
    cd build
    ../configure --build="$(../config.guess)" \
        --host="$LFS_TGT" \
        --target="$LFS_TGT" \
        --prefix=/usr \
        --with-build-sysroot="$LFS" \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-nls \
        --disable-multilib \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libsanitizer \
        --disable-libssp \
        --disable-libvtv \
        --enable-languages=c,c++ \
        LDFLAGS_FOR_TARGET=-L"$PWD"/"$LFS_TGT"/libgcc
    make -j"$NUM_JOBS"
    make DESTDIR="$LFS" install
    # Finishing touch from LFS 12.4 section 6.18: generic cc symlink.
    ln -sv gcc "$LFS/usr/bin/cc"
    # Pass 2 installs libgcc_s.so.1 into the sysroot ($LFS/usr/lib).
    # The temporary tools below still link with the pass 1 compiler,
    # whose static-only libgcc keeps unwind symbols hidden since
    # GCC 14. Without a shared libgcc in the sysroot, linking the
    # ncurses C++ shared library fails later with "hidden symbol
    # _Unwind_GetLanguageSpecificData in libgcc.a referenced by DSO".
    if [ ! -e "$LFS/usr/lib/libgcc_s.so.1" ]; then
        log_error "libgcc_s.so.1 missing from $LFS/usr/lib after GCC pass 2"
        exit 1
    fi
    cd "$LFS/sources"
    rm -rf "$GCC_DIR"
    log_success "GCC (pass 2) done"

    # ==============================================================
    # 8. BUILD TEMPORARY TOOLS - LFS 12.4 sections 6.2 to 6.16
    #
    # Same package list and configure flags as Chapter 6 of the book,
    # installed under $LFS/tools instead of the final locations
    # because the later stages (05a/05b) expect a self-contained
    # /tools userspace.  bison and bzip2 are project additions
    # required by those stages.
    # ==============================================================
    log_info "Building temporary tools (LFS Chapter 6)"
    for pkg in m4 ncurses bash coreutils diffutils file findutils gawk grep gzip make patch sed tar xz bison bzip2; do
        if [ "$pkg" = "make" ]; then
            archive=$(find . -maxdepth 1 -name "make-[0-9]*.tar.*" -print -quit)
        elif [ "$pkg" = "file" ]; then
            archive=$(find . -maxdepth 1 -name "file-[0-9]*.tar.*" -print -quit)
        else
            archive=$(find . -maxdepth 1 -name "${pkg}-*.tar.*" -print -quit)
        fi
        if [ -z "$archive" ]; then
            log_warning "Source for $pkg not found, skipping"
            continue
        fi
        dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
        log_info "Building $dir"
        tar -xf "$archive"
        cd "$dir"

        # ----------------------------------------------------------
        # Per-package settings follow the matching LFS 12.4 Chapter 6
        # section.  The cross compiler is picked up from PATH
        # ($LFS_TGT-gcc) by autoconf, so no explicit CC is set.
        # ----------------------------------------------------------
        extra_flags=""
        build_flag=""
        make_flags=""

        case "$pkg" in
        bzip2)
            # Project addition (no configure script, plain Makefile).
            make -j"$NUM_JOBS"
            make PREFIX="$LFS/tools" install
            ;;
        ncurses)
            # LFS 12.4 section 6.3: a native tic is required because
            # the target tic cannot run on the host during install.
            #
            # GCC 15 defaults to C23 where bool is a keyword, which
            # makes configure misdetect bool and emit a curses.h that
            # leaks "#define bool unsigned char" into the C++ binding,
            # breaking it against GCC 15 libstdc++ headers. Force C17
            # for this package (same workaround as Arch Linux).
            mkdir -v build
            pushd build
            ../configure --prefix="$LFS/tools" AWK=gawk \
                CFLAGS="-O2 -std=gnu17"
            make -C include
            make -C progs tic
            popd
            ./configure --prefix="$LFS/tools" \
                --host="$LFS_TGT" \
                --build="$(./config.guess)" \
                --mandir="$LFS/tools/share/man" \
                --with-manpage-format=normal \
                --with-shared \
                --without-normal \
                --with-cxx-shared \
                --without-debug \
                --without-ada \
                --disable-stripping \
                AWK=gawk \
                CFLAGS="-O2 -std=gnu17" \
                LDFLAGS="-lgcc_s"
            make -j"$NUM_JOBS"
            make TIC_PATH="$(pwd)/build/progs/tic" install
            ln -sv libncursesw.so "$LFS/tools/lib/libncurses.so"
            sed -e 's/^#if.*XOPEN.*$/#if 1/' \
                -i "$LFS/tools/include/ncursesw/curses.h"
            ;;
        bash)
            build_flag="--build=$(sh support/config.guess)"
            extra_flags="--without-bash-malloc"
            ;;
        coreutils)
            extra_flags="--enable-install-program=hostname --enable-no-install-program=kill,uptime"
            # When target binaries can execute on the build host (same
            # architecture), autoconf resolves cross_compiling to "no"
            # and coreutils runs the real help2man against them, which
            # fails (e.g. "can't get `--help' info from man/stty.td/stty"
            # under CI).  Force dummy-man, the script coreutils uses for
            # genuine cross builds: it installs the distributed man
            # pages, which is exactly what temporary tools need.
            make_flags="run_help2man=man/dummy-man"
            ;;
        diffutils)
            build_flag="--build=$(./build-aux/config.guess)"
            extra_flags="gl_cv_func_strcasecmp_works=y"
            ;;
        file)
            # LFS 12.4 section 6.7: a native file binary is required
            # while building the target libmagic.
            mkdir -v build
            pushd build
            ../configure --disable-bzlib \
                --disable-libseccomp \
                --disable-xzlib \
                --disable-zlib
            make
            popd
            ./configure --prefix="$LFS/tools" \
                --host="$LFS_TGT" \
                --build="$(./config.guess)"
            make -j"$NUM_JOBS" FILE_COMPILE="$(pwd)/build/src/file"
            make install
            rm -fv "$LFS/tools/lib/libmagic.la"
            ;;
        findutils)
            extra_flags="--localstatedir=$LFS/tools/var/lib/locate"
            ;;
        gawk)
            # LFS 12.4 section 6.9: do not build the extras.
            sed -i 's/extras//' Makefile.in
            ;;
        gzip)
            # The book passes no --build flag for gzip.
            build_flag="none"
            ;;
        xz)
            extra_flags="--disable-static --docdir=$LFS/tools/share/doc/$dir"
            ;;
        *)
            if [ -f build-aux/config.guess ]; then
                build_flag="--build=$(build-aux/config.guess)"
            fi
            ;;
        esac

        # Generic autotools path for every package that was not fully
        # handled in its case arm above (bzip2, ncurses, file).
        if [ "$pkg" != "bzip2" ] && [ "$pkg" != "ncurses" ] && [ "$pkg" != "file" ]; then
            if [ "$build_flag" = "none" ]; then
                build_flag=""
            fi
            # shellcheck disable=SC2086
            ./configure --prefix="$LFS/tools" \
                --host="$LFS_TGT" \
                $build_flag \
                $extra_flags
            # shellcheck disable=SC2086
            make -j"$NUM_JOBS" $make_flags
            make install
            if [ "$pkg" = "bash" ]; then
                # LFS 12.4 section 6.4: /bin/sh compatibility symlink.
                ln -sv bash "$LFS/tools/bin/sh"
            elif [ "$pkg" = "xz" ]; then
                # Libtool archives are harmful for cross compilation.
                rm -fv "$LFS/tools/lib/liblzma.la"
            fi
        fi

        cd "$LFS/sources"
        rm -rf "$dir"
    done

    mkdir -p "$LFS/var/log"
    touch "$LFS/var/log/toolchain-ready"
    log_success "Temporary toolchain built successfully."
}

main() {
    ensure_compiler

    if [ "$(whoami)" != "lfs" ]; then
        log_info "Re-executing as lfs user"
        exec sudo -n -u lfs env LFS="$LFS" LFS_TGT="$LFS_TGT" KERNEL_TYPE="$KERNEL_TYPE" NUM_JOBS="$NUM_JOBS" bash "$0" --force
    fi

    build_toolchain

    if check_toolchain; then
        log_success "Toolchain verified after build."
    else
        log_error "Toolchain verification failed after build."
        exit 1
    fi
}

if [ "$1" = "--force" ]; then
    shift
    if [ "$(whoami)" != "lfs" ]; then
        log_error "Cannot use --force without sudo; not lfs user"
        exit 1
    fi
    build_toolchain
    if check_toolchain; then
        log_success "Toolchain verified after build."
    else
        log_error "Toolchain verification failed."
        exit 1
    fi
else
    main "$@"
fi