#!/bin/bash
# Build LFS system – LFS 12.4 chapters 7-8, native rebuild inside the chroot
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
# 05b-build-lfs-system.sh – Rebuild the complete base system natively inside
#                            the chroot prepared by 05a, following the LFS
#                            12.4 book chapter 7 (temporary tools) and
#                            chapter 8 (basic system software) instructions.
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
# Internal compilation script (LFS 12.4 chapters 7-8)
#
# The chapter 6 toolchain stage installed the pass 2 compiler into
# /usr (unprefixed, target-native binaries).  Following the book we
# therefore build chapter 8 natively: PATH prefers /usr/bin:/usr/sbin
# and /tools/bin stays last only as a fallback for the bootstrap
# tools (bash, make, ...) until their chapter 8 replacements are
# installed.  SHELL/CONFIG_SHELL point at /tools/bin/bash because it
# survives the moment glibc replaces the dynamic linker.
# -----------------------------------------------------------------
log_info "Creating internal compilation script"
cat >"$LFS/build-lfs-system.sh" <<'INNEREOF'
#!/bin/bash
set -e

export PATH=/usr/bin:/usr/sbin:/tools/bin
export SHELL=/tools/bin/bash
export CONFIG_SHELL=/tools/bin/bash
unset CC CXX LD AS AR RANLIB CFLAGS CXXFLAGS LDFLAGS LD_LIBRARY_PATH LIBRARY_PATH
MAKEFLAGS="-j$(nproc)"
export MAKEFLAGS

cd /sources

# ----- Helper: find archive (supports .tar.xz, .tar.gz, .tgz, etc.) -----
# Match package names case-insensitively (Python-3.13.7.tar.xz),
# treat underscores like dashes (flit_core), prefer name-<version>
# tarballs over documentation variants (python-3.13.7-docs-html),
# and fall back to oddball layouts (tcl8.6.16-src, expect5.45.4).
find_archive() {
    local base=$1 f name_lc prefix_lc
    local -a tier1=() tier2=() filtered=()
    prefix_lc=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

    for f in *.tar.* *.tgz; do
        [ -f "$f" ] || continue
        name_lc=$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        case "$name_lc" in
            "$prefix_lc"*) ;;
            *) continue ;;
        esac
        case "$name_lc" in
            "$prefix_lc"-[0-9]*) tier1+=("$f") ;;
            *) tier2+=("$f") ;;
        esac
    done

    # Prefer name-<version> tarballs, skipping documentation variants
    # such as python-3.13.7-docs-html.tar.bz2.
    if [ "${#tier1[@]}" -gt 0 ]; then
        for f in "${tier1[@]}"; do
            case "$f" in
                *-docs* | *-html* | *-apidoc*) ;;
                *) filtered+=("$f") ;;
            esac
        done
        [ "${#filtered[@]}" -gt 0 ] && tier1=("${filtered[@]}")
        printf '%s\n' "${tier1[0]}"
        return 0
    fi

    # Fallback: non-standard layouts such as tcl8.6.16-src.tar.gz or
    # expect5.45.4.tar.gz.  Prefer -src archives, then any archive
    # whose top level carries a configure script.
    if [ "${#tier2[@]}" -eq 0 ]; then
        echo "ERROR: no source archive found for $base" >&2
        return 0
    fi
    for f in "${tier2[@]}"; do
        case "$f" in
            *-src*)
                printf '%s\n' "$f"
                return 0
                ;;
        esac
    done
    filtered=()
    for f in "${tier2[@]}"; do
        case "$f" in
            *-docs* | *-html* | *-apidoc*) ;;
            *) filtered+=("$f") ;;
        esac
    done
    [ "${#filtered[@]}" -gt 0 ] && tier2=("${filtered[@]}")
    for f in "${tier2[@]}"; do
        if tar -tf "$f" 2>/dev/null | grep -Eq '(^|/)configure$'; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    printf '%s\n' "${tier2[0]}"
    return 0
}

# ----- Helper: clean-extract and cd -----
extract() {
    local archive=$1
    local dir
    dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
    echo "=== Building $dir ==="
    rm -rf "$dir"
    tar -xf "$archive"
    cd "$dir"
}

# ---- Linux API headers (installed by the toolchain stage) ----
if [ -d /usr/include/linux ] && [ -f /usr/include/linux/types.h ]; then
    echo "Linux API headers already present from toolchain stage"
else
    echo "Installing Linux API headers"
    LINUX_ARCHIVE=$(find_archive linux)
    tar -xf "$LINUX_ARCHIVE"
    LINUX_DIR=$(tar -tf "$LINUX_ARCHIVE" | head -1 | cut -d/ -f1)
    cd "$LINUX_DIR"
    make mrproper
    make HOSTCC=gcc headers
    find usr/include -name '.*' -delete
    rm -f usr/include/Makefile
    cp -rv usr/include/. /usr/include
    cd /sources
    rm -rf "$LINUX_DIR"
fi

# ============================================================
# LFS 12.4 Section 7.6 – essential files and symlinks
# (idempotent: skipped when a previous run already created them)
# ============================================================
if [ ! -f /etc/passwd ]; then
    ln -sv /proc/self/mounts /etc/mtab
    cat > /etc/hosts << EOF
127.0.0.1 localhost $(hostname)
::1 localhost
EOF
    cat > /etc/passwd << "EOF"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF
    cat > /etc/group << "EOF"
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
input:x:24:
mail:x:34:
kvm:x:61:
uuidd:x:80:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF
    touch /var/log/{btmp,lastlog,faillog,wtmp}
    chgrp -v utmp /var/log/lastlog
    chmod -v 664 /var/log/lastlog
    chmod -v 600 /var/log/btmp
fi

# ============================================================
# LFS 12.4 Chapter 7 – temporary tools (installed into /usr)
# ============================================================

# 7.7 Gettext (only the tools needed later to build other packages)
extract "$(find_archive gettext)"
./configure --disable-shared
make -j"$(nproc)"
cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
cd /sources

# 7.8 Bison
extract "$(find_archive bison)"
./configure --prefix=/usr
make -j"$(nproc)"
make install
cd /sources

# 7.9 Perl
extract "$(find_archive perl)"
sh Configure -des \
    -D prefix=/usr \
    -D vendorprefix=/usr \
    -D useshrplib \
    -D privlib=/usr/lib/perl5/5.42/core_perl \
    -D archlib=/usr/lib/perl5/5.42/core_perl \
    -D sitelib=/usr/lib/perl5/5.42/site_perl \
    -D sitearch=/usr/lib/perl5/5.42/site_perl \
    -D vendorlib=/usr/lib/perl5/5.42/vendor_perl \
    -D vendorarch=/usr/lib/perl5/5.42/vendor_perl
make -j"$(nproc)"
make install
cd /sources

# 7.10 Python
extract "$(find_archive python)"
./configure --prefix=/usr \
    --enable-shared \
    --without-ensurepip \
    --without-static-libpython
make -j"$(nproc)"
make install
cd /sources

# 7.11 Texinfo
extract "$(find_archive texinfo)"
./configure --prefix=/usr
make -j"$(nproc)"
make install
cd /sources

# 7.12 Util-linux
extract "$(find_archive util-linux)"
mkdir -pv /var/lib/hwclock
./configure --libdir=/usr/lib \
    --runstatedir=/run \
    --disable-chfn-chsh \
    --disable-login \
    --disable-nologin \
    --disable-su \
    --disable-setpriv \
    --disable-runuser \
    --disable-pylibmount \
    --disable-static \
    --disable-liblastlog2 \
    --without-python \
    ADJTIME_PATH=/var/lib/hwclock/adjtime \
    --docdir=/usr/share/doc/util-linux-2.41.1
make -j"$(nproc)"
make install
cd /sources

# ============================================================
# LFS 12.4 Chapter 8 – basic system software (native rebuild)
# Package order follows the book.  Test suites are skipped to
# keep CI build times acceptable; the book flags binutils/glibc/
# MPFR tests as critical and they should be run when validating
# a new package version.
# ============================================================

CH8_PACKAGES="man-pages iana-etc glibc zlib bzip2 xz lz4 zstd file readline
m4 bc flex tcl expect dejagnu pkgconf binutils gmp mpfr mpc attr acl libcap
libxcrypt shadow gcc ncurses sed psmisc gettext bison grep bash libtool gdbm
gperf expat inetutils less perl xml-parser intltool autoconf automake openssl
libelf libffi python flit-core packaging wheel setuptools ninja meson kmod
coreutils diffutils gawk findutils groff grub gzip iproute2 kbd libpipeline
make patch tar texinfo vim markupsafe jinja2 udev man-db procps-ng util-linux
e2fsprogs sysklogd sysvinit"

# ============================================================
# LPM binary repository: per-package file-list capture.
# Every package's NEWLY ADDED files are recorded in
# /var/lib/lpm/manifests/<pkg>.list; stage 14 (create-base-packages)
# turns those lists into real {name}-{version}.tar.xz binary
# packages with genuine sha256 checksums, so installed systems can
# reinstall and upgrade base packages over the network.
# ============================================================
LPM_MANIFEST_DIR=/var/lib/lpm/manifests
mkdir -p "$LPM_MANIFEST_DIR"

# Files and symlinks of the system tree, minus volatile/build trees.
snapshot_tree() {
    find / -xdev \
        \( -path /proc -o -path /sys -o -path /dev -o -path /run \
           -o -path /sources -o -path /tools -o -path /tmp \
           -o -path /var/log -o -path "$LPM_MANIFEST_DIR" \) -prune \
        -o \( -type f -o -type l \) -print
}

for pkg in $CH8_PACKAGES; do
    snapshot_tree > /tmp/lpm-before.list
    case "$pkg" in
    man-pages)
        extract "$(find_archive man-pages)"
        rm -v man3/crypt*
        make -R GIT=false prefix=/usr install
        ;;
    iana-etc)
        extract "$(find_archive iana-etc)"
        cp services protocols /etc
        ;;
    glibc)
        extract "$(find_archive glibc)"
        patch -Np1 -i ../glibc-2.42-fhs-1.patch
        # Fix an issue which may break Valgrind in BLFS
        sed -e '/unistd.h/i #include <string.h>' \
            -e '/libc_rwlock_init/c\
  __libc_rwlock_define_initialized (, reset_lock);\
  memcpy (&lock, &reset_lock, sizeof (lock));' \
            -i stdlib/abort.c
        mkdir -v build
        cd build
        echo "rootsbindir=/usr/sbin" > configparms
        ../configure --prefix=/usr \
            --disable-werror \
            --disable-nscd \
            libc_cv_slibdir=/usr/lib \
            --enable-stack-protector=strong \
            --enable-kernel=5.4
        make -j"$(nproc)"
        touch /etc/ld.so.conf
        # shellcheck disable=SC2016
        sed '/test-installation/s@$(PERL)@echo not running@' -i ../Makefile
        make install
        sed '/RTLDLIST=/s@/usr@@g' -i /usr/bin/ldd
        make localedata/install-locales
        cat > /etc/nsswitch.conf << "EOF"
# Begin /etc/nsswitch.conf

passwd: files
group: files
shadow: files

hosts: files dns
networks: files

protocols: files
services: files
ethers: files
rpc: files

# End /etc/nsswitch.conf
EOF
        # Time zone data (book 8.5.2.2)
        tar -xf ../../tzdata2025b.tar.gz
        ZONEINFO=/usr/share/zoneinfo
        mkdir -pv $ZONEINFO/{posix,right}
        for tz in etcetera southamerica northamerica europe africa antarctica \
                  asia australasia backward; do
            zic -L /dev/null -d $ZONEINFO "${tz}"
            zic -L /dev/null -d $ZONEINFO/posix "${tz}"
            zic -L leapseconds -d $ZONEINFO/right "${tz}"
        done
        cp -v zone.tab zone1970.tab iso3166.tab $ZONEINFO
        zic -d $ZONEINFO -p America/New_York
        unset ZONEINFO tz
        ;;
    zlib)
        extract "$(find_archive zlib)"
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        rm -fv /usr/lib/libz.a
        ;;
    bzip2)
        extract "$(find_archive bzip2)"
        patch -Np1 -i ../bzip2-1.0.8-install_docs-1.patch
        # shellcheck disable=SC2016
        sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
        sed -i "s@(PREFIX)/man@(PREFIX)/share/man@g" Makefile
        make -f Makefile-libbz2_so
        make clean
        make -j"$(nproc)"
        make PREFIX=/usr install
        cp -av libbz2.so.* /usr/lib
        ln -sv libbz2.so.1.0.8 /usr/lib/libbz2.so
        cp -v bzip2-shared /usr/bin/bzip2
        for i in /usr/bin/{bzcat,bunzip2}; do
            ln -sfv bzip2 "$i"
        done
        rm -fv /usr/lib/libbz2.a
        ;;
    xz)
        extract "$(find_archive xz)"
        ./configure --prefix=/usr \
            --disable-static \
            --docdir=/usr/share/doc/xz-5.8.1
        make -j"$(nproc)"
        make install
        ;;
    lz4)
        extract "$(find_archive lz4)"
        make BUILD_STATIC=no PREFIX=/usr -j"$(nproc)"
        make BUILD_STATIC=no PREFIX=/usr install
        ;;
    zstd)
        extract "$(find_archive zstd)"
        make prefix=/usr -j"$(nproc)"
        make prefix=/usr install
        rm -v /usr/lib/libzstd.a
        ;;
    file)
        extract "$(find_archive file)"
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    readline)
        extract "$(find_archive readline)"
        sed -i '/MV.*old/d' Makefile.in
        sed -i '/{OLDSUFF}/c:' support/shlib-install
        sed -i 's/-Wl,-rpath,[^ ]*//' support/shobj-conf
        # The chapter 7 ncurses lives in /tools/lib, outside the native
        # compiler's default search paths (Nightly #165 died on
        # "cannot find -lncursesw").  Expose it to configure so the
        # shared libraries link against the real library, and keep the
        # explicit SHLIB_LIBS so make never falls back to nothing.
        ./configure --prefix=/usr \
            --disable-static \
            --with-curses \
            --docdir=/usr/share/doc/readline-8.3 \
            LDFLAGS="-L/tools/lib"
        make SHLIB_LIBS="-lncursesw" -j"$(nproc)"
        make install
        ;;
    m4)
        extract "$(find_archive m4)"
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    bc)
        extract "$(find_archive bc)"
        # The readline built just above carries a DT_NEEDED on chapter
        # 7's libncursesw.so.6 (/tools/lib), and the native ncurses is
        # not built until after gcc. Without the search path below, the
        # final link of bin/bc dies on undefined tputs/tgoto references
        # (Nightly #167). Mirror the readline case's exposure.
        CC='gcc -std=c99' \
            LDFLAGS='-L/tools/lib -Wl,-rpath-link,/tools/lib' \
            ./configure --prefix=/usr -G -O3 -r
        make -j"$(nproc)"
        make install
        ;;
    flex)
        extract "$(find_archive flex)"
        ./configure --prefix=/usr \
            --docdir=/usr/share/doc/flex-2.6.4 \
            --disable-static
        make -j"$(nproc)"
        make install
        ln -sv flex /usr/bin/lex
        ln -sv flex.1 /usr/share/man/man1/lex.1
        ;;
    tcl)
        extract "$(find_archive tcl)"
        SRCDIR=$(pwd)
        cd unix
        ./configure --prefix=/usr \
            --mandir=/usr/share/man \
            --disable-rpath
        make -j"$(nproc)"
        sed -e "s|$SRCDIR/unix|/usr/lib|" \
            -e "s|$SRCDIR|/usr/include|" \
            -i tclConfig.sh
        sed -e "s|$SRCDIR/unix/pkgs/tdbc1.1.10|/usr/lib/tdbc1.1.10|" \
            -e "s|$SRCDIR/pkgs/tdbc1.1.10/generic|/usr/include|" \
            -e "s|$SRCDIR/pkgs/tdbc1.1.10/library|/usr/lib/tcl8.6|" \
            -e "s|$SRCDIR/pkgs/tdbc1.1.10|/usr/include|" \
            -i pkgs/tdbc1.1.10/tdbcConfig.sh
        sed -e "s|$SRCDIR/unix/pkgs/itcl4.3.2|/usr/lib/itcl4.3.2|" \
            -e "s|$SRCDIR/pkgs/itcl4.3.2/generic|/usr/include|" \
            -e "s|$SRCDIR/pkgs/itcl4.3.2|/usr/include|" \
            -i pkgs/itcl4.3.2/itclConfig.sh
        unset SRCDIR
        make install
        chmod 644 /usr/lib/libtclstub8.6.a
        chmod -v u+w /usr/lib/libtcl8.6.so
        make install-private-headers
        ln -sfv tclsh8.6 /usr/bin/tclsh
        mv /usr/share/man/man3/{Thread,Tcl_Thread}.3
        cd ..
        ;;
    expect)
        extract "$(find_archive expect)"
        patch -Np1 -i ../expect-5.45.4-gcc15-1.patch
        ./configure --prefix=/usr \
            --with-tcl=/usr/lib \
            --enable-shared \
            --disable-rpath \
            --mandir=/usr/share/man \
            --with-tclinclude=/usr/include
        make -j"$(nproc)"
        make install
        ln -svf expect5.45.4/libexpect5.45.4.so /usr/lib
        ;;
    dejagnu)
        extract "$(find_archive dejagnu)"
        mkdir -v build
        cd build
        ../configure --prefix=/usr
        make install
        ;;
    pkgconf)
        extract "$(find_archive pkgconf)"
        ./configure --prefix=/usr \
            --disable-static \
            --docdir=/usr/share/doc/pkgconf-2.5.1
        make -j"$(nproc)"
        make install
        ln -sv pkgconf /usr/bin/pkg-config
        ln -sv pkgconf.1 /usr/share/man/man1/pkg-config.1
        ;;
    binutils)
        extract "$(find_archive binutils)"
        mkdir -v build
        cd build
        ../configure --prefix=/usr \
            --sysconfdir=/etc \
            --enable-ld=default \
            --enable-plugins \
            --enable-shared \
            --disable-werror \
            --enable-64-bit-bfd \
            --enable-new-dtags \
            --with-system-zlib \
            --enable-default-hash-style=gnu
        make tooldir=/usr -j"$(nproc)"
        make tooldir=/usr install
        rm -rfv /usr/lib/lib{bfd,ctf,ctf-nobfd,gprofng,opcodes,sframe}.a \
                /usr/share/doc/gprofng/
        ;;
    gmp)
        extract "$(find_archive gmp)"
        sed -i '/long long t1;/,+1s/()/(...)/' configure
        ./configure --prefix=/usr \
            --enable-cxx \
            --disable-static \
            --docdir=/usr/share/doc/gmp-6.3.0
        make -j"$(nproc)"
        make install
        ;;
    mpfr)
        extract "$(find_archive mpfr)"
        ./configure --prefix=/usr \
            --disable-static \
            --enable-thread-safe \
            --docdir=/usr/share/doc/mpfr-4.2.2
        make -j"$(nproc)"
        make install
        ;;
    mpc)
        extract "$(find_archive mpc)"
        ./configure --prefix=/usr \
            --disable-static
        make -j"$(nproc)"
        make install
        ;;
    attr)
        extract "$(find_archive attr)"
        ./configure --prefix=/usr \
            --disable-static
        make -j"$(nproc)"
        make install
        ;;
    acl)
        extract "$(find_archive acl)"
        ./configure --prefix=/usr \
            --disable-static
        make -j"$(nproc)"
        make install
        ;;
    libcap)
        extract "$(find_archive libcap)"
        sed -i '/install -m.*STA/d' libcap/Makefile
        make prefix=/usr lib=lib -j"$(nproc)"
        make prefix=/usr lib=lib install
        ;;
    libxcrypt)
        extract "$(find_archive libxcrypt)"
        ./configure --prefix=/usr \
            --enable-hashes=strong,glibc \
            --enable-obsolete-api=no \
            --disable-static \
            --disable-failure-tokens
        make -j"$(nproc)"
        make install
        # Second build providing the obsolete APIs for glibc compatibility
        make distclean
        ./configure --prefix=/usr \
            --enable-hashes=strong,glibc \
            --enable-obsolete-api=glibc \
            --disable-static \
            --disable-failure-tokens
        make -j"$(nproc)"
        cp -av --remove-destination .libs/libcrypt.so.1* /usr/lib
        ;;
    shadow)
        extract "$(find_archive shadow)"
        # shellcheck disable=SC2016
        sed -i 's/groups$(EXEEXT) //' src/Makefile.in
        find man -name Makefile.in -exec sed -i 's/groups\.1 / /' {} \;
        find man -name Makefile.in -exec sed -i 's/getspnam\.3 / /' {} \;
        find man -name Makefile.in -exec sed -i 's/passwd\.5 / /' {} \;
        sed -e 's:#ENCRYPT_METHOD DES:ENCRYPT_METHOD YESCRYPT:' \
            -e 's:/var/spool/mail:/var/mail:' \
            -e '/PATH=/{s@/sbin:@@;s@/bin:@@}' \
            -i etc/login.defs
        touch /usr/bin/passwd
        ./configure --sysconfdir=/etc \
            --disable-static \
            --with-bcrypt \
            --with-yescrypt \
            --without-libbsd \
            --with-group-name-max-length=32
        make -j"$(nproc)"
        make exec_prefix=/usr install
        make -C man install-man
        ;;
    gcc)
        extract "$(find_archive gcc)"
        case $(uname -m) in
            x86_64) sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64 ;;
        esac
        mkdir -v build
        cd build
        ../configure --prefix=/usr \
            LD=ld \
            --enable-languages=c,c++ \
            --enable-default-pie \
            --enable-default-ssp \
            --enable-host-pie \
            --disable-multilib \
            --disable-bootstrap \
            --disable-fixincludes \
            --with-system-zlib
        make -j"$(nproc)"
        make install
        ln -sv gcc /usr/bin/cc
        ;;
    ncurses)
        extract "$(find_archive ncurses)"
        # GCC 15 defaults to C23 where bool is a keyword, which makes
        # configure misdetect bool and emit a curses.h that leaks
        # "#define bool unsigned char" into the C++ binding, breaking
        # it against GCC 15 libstdc++ headers. Force C17 for this
        # package (same workaround as Arch Linux).
        ./configure --prefix=/usr \
            --mandir=/usr/share/man \
            --with-shared \
            --without-debug \
            --without-normal \
            --with-cxx-shared \
            --enable-pc-files \
            --with-pkg-config-libdir=/usr/lib/pkgconfig \
            CFLAGS="-O2 -std=gnu17"
        make -j"$(nproc)"
        # Install via DESTDIR so the running shell's libncursesw is replaced
        # atomically with the install command instead of being overwritten
        # in place (book 8.30.1).
        make DESTDIR="$PWD"/dest install
        install -vm755 dest/usr/lib/libncursesw.so.6.* /usr/lib
        rm -v dest/usr/lib/libncursesw.so.6.*
        sed -e 's/^#if.*XOPEN.*$/#if 1/' \
            -i dest/usr/include/curses.h
        cp -av dest/* /
        for lib in ncurses form panel menu; do
            ln -sfv "lib${lib}w.so" "/usr/lib/lib${lib}.so"
            ln -sfv "${lib}w.pc" "/usr/lib/pkgconfig/${lib}.pc"
        done
        ln -sfv libncursesw.so /usr/lib/libcurses.so
        ;;
    sed)
        extract "$(find_archive sed)"
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    psmisc)
        extract "$(find_archive psmisc)"
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    gettext)
        extract "$(find_archive gettext)"
        ./configure --prefix=/usr \
            --disable-static \
            --docdir=/usr/share/doc/gettext-0.26
        make -j"$(nproc)"
        make install
        ;;
    bison)
        extract "$(find_archive bison)"
        ./configure --prefix=/usr \
            --docdir=/usr/share/doc/bison-3.8.2
        make -j"$(nproc)"
        make install
        ;;
    grep)
        extract "$(find_archive grep)"
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    bash)
        extract "$(find_archive bash)"
        ./configure --prefix=/usr \
            --without-bash-malloc \
            --with-installed-readline \
            --docdir=/usr/share/doc/bash-5.3
        make -j"$(nproc)"
        make install
        ;;
    libtool)
        extract "$(find_archive libtool)"
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    gdbm)
        extract "$(find_archive gdbm)"
        ./configure --prefix=/usr \
            --disable-static \
            --enable-libgdbm-compat
        make -j"$(nproc)"
        make install
        ;;
    gperf)
        extract "$(find_archive gperf)"
        ./configure --prefix=/usr \
            --docdir=/usr/share/doc/gperf-3.3
        make -j"$(nproc)"
        make install
        ;;
    expat)
        extract "$(find_archive expat)"
        ./configure --prefix=/usr \
            --disable-static \
            --docdir=/usr/share/doc/expat-2.7.1
        make -j"$(nproc)"
        make install
        ;;
    inetutils)
        extract "$(find_archive inetutils)"
        sed -i 's/def HAVE_TERMCAP_TGETENT/ 1/' telnet/telnet.c
        ./configure --prefix=/usr \
            --bindir=/usr/bin \
            --localstatedir=/var \
            --disable-logger \
            --disable-whois \
            --disable-rcp \
            --disable-rexec \
            --disable-rlogin \
            --disable-rsh \
            --disable-servers
        make -j"$(nproc)"
        make install
        ;;
    less)
        extract "$(find_archive less)"
        ./configure --prefix=/usr --sysconfdir=/etc
        make -j"$(nproc)"
        make install
        ;;
    perl)
        extract "$(find_archive perl)"
        sh Configure -des \
            -D prefix=/usr \
            -D vendorprefix=/usr \
            -D useshrplib \
            -D privlib=/usr/lib/perl5/5.42/core_perl \
            -D archlib=/usr/lib/perl5/5.42/core_perl \
            -D sitelib=/usr/lib/perl5/5.42/site_perl \
            -D sitearch=/usr/lib/perl5/5.42/site_perl \
            -D vendorlib=/usr/lib/perl5/5.42/vendor_perl \
            -D vendorarch=/usr/lib/perl5/5.42/vendor_perl
        make -j"$(nproc)"
        make install
        ;;
    xml-parser)
        extract "$(find_archive XML-Parser)"
        perl Makefile.PL
        make -j"$(nproc)"
        make install
        ;;
    intltool)
        extract "$(find_archive intltool)"
        sed -i 's:\\\${:\\\$\\{:' intltool-update.in
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    autoconf)
        extract "$(find_archive autoconf)"
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    automake)
        extract "$(find_archive automake)"
        ./configure --prefix=/usr \
            --docdir=/usr/share/doc/automake-1.18.1
        make -j"$(nproc)"
        make install
        ;;
    openssl)
        extract "$(find_archive openssl)"
        ./config --prefix=/usr \
            --openssldir=/etc/ssl \
            --libdir=lib \
            shared \
            zlib-dynamic
        make -j"$(nproc)"
        make install
        ;;
    libelf)
        extract "$(find_archive elfutils)"
        ./configure --prefix=/usr \
            --disable-debuginfod \
            --enable-libdebuginfod=dummy
        make -j"$(nproc)"
        make -C libelf install
        ;;
    libffi)
        extract "$(find_archive libffi)"
        ./configure --prefix=/usr \
            --disable-static \
            --with-gcc-arch=native
        make -j"$(nproc)"
        make install
        ;;
    python)
        extract "$(find_archive python)"
        ./configure --prefix=/usr \
            --enable-shared \
            --with-system-expat \
            --enable-optimizations \
            --without-static-libpython
        make -j"$(nproc)"
        make install
        cat > /etc/pip.conf << "EOF"
[global]
root-user-action = ignore
disable-pip-version-check = true
EOF
        ;;
    flit-core)
        extract "$(find_archive flit-core)"
        pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
        pip3 install --no-index --find-links dist flit_core
        ;;
    packaging)
        extract "$(find_archive packaging)"
        pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
        pip3 install --no-index --find-links dist packaging
        ;;
    wheel)
        extract "$(find_archive wheel)"
        pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
        pip3 install --no-index --find-links dist wheel
        ;;
    setuptools)
        extract "$(find_archive setuptools)"
        pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
        pip3 install --no-index --find-links dist setuptools
        ;;
    ninja)
        extract "$(find_archive ninja)"
        python3 configure.py --bootstrap --verbose
        install -vm755 ninja /usr/bin/
        install -vDm644 misc/bash-completion /usr/share/bash-completion/completions/ninja
        ;;
    meson)
        extract "$(find_archive meson)"
        pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
        pip3 install --no-index --find-links dist meson
        ln -sfv meson /usr/bin/meson
        ;;
    kmod)
        extract "$(find_archive kmod)"
        mkdir -p build
        cd build
        meson setup --prefix=/usr .. \
            --buildtype=release \
            -D manpages=false
        ninja
        ninja install
        ;;
    coreutils)
        extract "$(find_archive coreutils)"
        patch -Np1 -i ../coreutils-9.7-upstream_fix-1.patch
        patch -Np1 -i ../coreutils-9.7-i18n-1.patch
        autoreconf -fv
        automake -af
        FORCE_UNSAFE_CONFIGURE=1 ./configure \
            --prefix=/usr \
            --enable-no-install-program=kill,uptime
        make -j"$(nproc)"
        make install
        mv -v /usr/bin/chroot /usr/sbin
        mkdir -pv /usr/share/man/man8
        mv -v /usr/share/man/man1/chroot.1 /usr/share/man/man8/chroot.8
        sed -i 's/"1"/"8"/' /usr/share/man/man8/chroot.8
        ;;
    diffutils)
        extract "$(find_archive diffutils)"
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    gawk)
        extract "$(find_archive gawk)"
        sed -i 's/extras//' Makefile.in
        ./configure --prefix=/usr
        make -j"$(nproc)"
        rm -f /usr/bin/gawk-*
        make install
        ln -sv gawk.1 /usr/share/man/man1/awk.1
        ;;
    findutils)
        extract "$(find_archive findutils)"
        ./configure --prefix=/usr --localstatedir=/var/lib/locate
        make -j"$(nproc)"
        make install
        ;;
    groff)
        extract "$(find_archive groff)"
        PAGE=letter ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    grub)
        extract "$(find_archive grub)"
        # The book warns against tuning this package with custom flags.
        unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS
        echo depends bli part_gpt > grub-core/extra_deps.lst
        ./configure --prefix=/usr \
            --sysconfdir=/etc \
            --disable-efiemu \
            --disable-werror
        make -j"$(nproc)"
        make install
        mv -v /etc/bash_completion.d/grub /usr/share/bash-completion/completions
        ;;
    gzip)
        extract "$(find_archive gzip)"
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    iproute2)
        extract "$(find_archive iproute2)"
        sed -i /ARPD/d Makefile
        rm -fv man/man8/arpd.8
        make NETNS_RUN_DIR=/run/netns -j"$(nproc)"
        make SBINDIR=/usr/sbin install
        ;;
    kbd)
        extract "$(find_archive kbd)"
        patch -Np1 -i ../kbd-2.8.0-backspace-1.patch
        sed -i '/RESIZECONS_PROGS=/s/yes/no/' configure
        sed -i 's/resizecons.8 //' docs/man/man8/Makefile.in
        ./configure --prefix=/usr --disable-vlock
        make -j"$(nproc)"
        make install
        ;;
    libpipeline)
        extract "$(find_archive libpipeline)"
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    make)
        extract "$(find_archive make)"
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    patch)
        extract "$(find_archive patch)"
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    tar)
        extract "$(find_archive tar)"
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    texinfo)
        extract "$(find_archive texinfo)"
        # shellcheck disable=SC2016
        sed 's/! $output_file eq/$output_file ne/' -i tp/Texinfo/Convert/*.pm
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ;;
    vim)
        extract "$(find_archive vim)"
        echo '#define SYS_VIMRC_FILE "/etc/vimrc"' >> src/feature.h
        ./configure --prefix=/usr
        make -j"$(nproc)"
        make install
        ln -sv vim /usr/bin/vi
        for L in /usr/share/man/{,*/}man1/vim.1; do
            ln -sv vim.1 "$(dirname "$L")/vi.1"
        done
        ln -sv ../vim/vim91/doc /usr/share/doc/vim-9.1.1629
        cat > /etc/vimrc << "EOF"
" Begin /etc/vimrc

" Ensure defaults are set before creating the user's .vimrc
source $VIM/vimdefaults.vim

set nocompatible
set backspace=indent,eol,start
runtime! archlinux.vim

" End /etc/vimrc
EOF
        ;;
    markupsafe)
        extract "$(find_archive markupsafe)"
        pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
        pip3 install --no-index --find-links dist Markupsafe
        ;;
    jinja2)
        extract "$(find_archive jinja2)"
        pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
        pip3 install --no-index --find-links dist Jinja2
        ;;
    udev)
        # Udev is built standalone from the systemd tarball (book 8.76.1)
        extract "$(find_archive systemd)"
        sed -e 's/GROUP="render"/GROUP="video"/' \
            -e 's/GROUP="sgx", //' \
            -i rules.d/50-udev-default.rules.in
        sed -i '/systemd-sysctl/s/^/#/' rules.d/99-systemd.rules.in
        sed -e '/NETWORK_DIRS/s/systemd/udev/' \
            -i src/libsystemd/sd-network/network-util.h
        mkdir -p build
        cd build
        meson setup .. \
            --prefix=/usr \
            --buildtype=release \
            -D mode=release \
            -D dev-kvm-mode=0660 \
            -D link-udev-shared=false \
            -D logind=false \
            -D vconsole=false
        udev_helpers=$(grep "'name' :" ../src/udev/meson.build | \
            awk '{print $3}' | tr -d ",'" | grep -v 'udevadm')
        # Word splitting is required here: ninja takes a list of targets.
        # shellcheck disable=SC2046,SC2086
        ninja "udevadm" "systemd-hwdb" \
            $(ninja -n | grep -Eo '(src/(lib)?udev|rules.d|hwdb.d)/[^ ]*') \
            "$(realpath libudev.so --relative-to .)" \
            $udev_helpers
        install -vm755 -d {/usr/lib,/etc}/udev/{hwdb.d,rules.d,network}
        install -vm755 -d /usr/{lib,share}/pkgconfig
        install -vm755 udevadm /usr/bin/
        install -vm755 systemd-hwdb /usr/bin/udev-hwdb
        ln -svfn ../bin/udevadm /usr/sbin/udevd
        cp -av libudev.so{,*[0-9]} /usr/lib/
        install -vm644 ../src/libudev/libudev.h /usr/include/
        install -vm644 src/libudev/*.pc /usr/lib/pkgconfig/
        install -vm644 src/udev/*.pc /usr/share/pkgconfig/
        install -vm644 ../src/udev/udev.conf /etc/udev/
        install -vm644 rules.d/* ../rules.d/README /usr/lib/udev/rules.d/
        # shellcheck disable=SC2046
        install -vm644 $(find ../rules.d/*.rules \
            -not -name '*power-switch*') /usr/lib/udev/rules.d/
        install -vm644 hwdb.d/* ../hwdb.d/{*.hwdb,README} /usr/lib/udev/hwdb.d/
        # shellcheck disable=SC2086
        install -vm755 $udev_helpers /usr/lib/udev
        install -vm644 ../network/99-default.link /usr/lib/udev/network
        tar -xvf ../../udev-lfs-20230818.tar.xz
        make -f udev-lfs-20230818/Makefile.lfs install
        tar -xf ../../systemd-man-pages-257.8.tar.xz \
            --no-same-owner --strip-components=1 \
            -C /usr/share/man --wildcards '*/udev*' '*/libudev*' \
            '*/systemd.link.5' \
            '*/systemd-'{hwdb,udevd.service}.8
        sed 's|systemd/network|udev/network|' \
            /usr/share/man/man5/systemd.link.5 \
            > /usr/share/man/man5/udev.link.5
        sed 's/systemd\(\\\?-\)/udev\1/' /usr/share/man/man8/systemd-hwdb.8 \
            > /usr/share/man/man8/udev-hwdb.8
        sed 's|lib.*udevd|sbin/udevd|' \
            /usr/share/man/man8/systemd-udevd.service.8 \
            > /usr/share/man/man8/udevd.8
        rm /usr/share/man/man*/systemd*
        udev-hwdb update
        ;;
    man-db)
        extract "$(find_archive man-db)"
        ./configure --prefix=/usr \
            --docdir=/usr/share/doc/man-db-2.13.1 \
            --sysconfdir=/etc \
            --disable-setuid \
            --enable-cache-owner=bin \
            --with-browser=/usr/bin/lynx \
            --with-vgrind=/usr/bin/vgrind \
            --with-grap=/usr/bin/grap \
            --with-systemdtmpfilesdir= \
            --with-systemdsystemunitdir=
        make -j"$(nproc)"
        make install
        ;;
    procps-ng)
        extract "$(find_archive procps-ng)"
        ./configure --prefix=/usr \
            --docdir=/usr/share/doc/procps-ng-4.0.5 \
            --disable-static \
            --disable-kill \
            --enable-watch8bit
        make -j"$(nproc)"
        make install
        ;;
    util-linux)
        extract "$(find_archive util-linux)"
        ./configure --bindir=/usr/bin \
            --libdir=/usr/lib \
            --runstatedir=/run \
            --sbindir=/usr/sbin \
            --disable-chfn-chsh \
            --disable-login \
            --disable-nologin \
            --disable-su \
            --disable-setpriv \
            --disable-runuser \
            --disable-pylibmount \
            --disable-liblastlog2 \
            --disable-static \
            --without-python \
            --without-systemd \
            --without-systemdsystemunitdir \
            --docdir=/usr/share/doc/util-linux-2.41.1
        make -j"$(nproc)"
        make install
        ;;
    e2fsprogs)
        extract "$(find_archive e2fsprogs)"
        mkdir -v build
        cd build
        ../configure --prefix=/usr \
            --sysconfdir=/etc \
            --enable-elf-shlibs \
            --disable-libblkid \
            --disable-libuuid \
            --disable-uuidd \
            --disable-fsck
        make -j"$(nproc)"
        make install
        rm -fv /usr/lib/{libcom_err,libe2p,libext2fs,libss}.a
        sed 's/metadata_csum_seed,//' -i /etc/mke2fs.conf
        ;;
    sysklogd)
        extract "$(find_archive sysklogd)"
        ./configure --prefix=/usr \
            --sysconfdir=/etc \
            --runstatedir=/run \
            --without-logger \
            --disable-static \
            --docdir=/usr/share/doc/sysklogd-2.7.2
        make -j"$(nproc)"
        make install
        cat > /etc/syslog.conf << "EOF"
# Begin /etc/syslog.conf

auth,authpriv.* -/var/log/auth.log
*.*;auth,authpriv.none -/var/log/sys.log
daemon.* -/var/log/daemon.log
kern.* -/var/log/kern.log
mail.* -/var/log/mail.log
user.* -/var/log/user.log
*.emerg -/var/log/emerg.log

# End /etc/syslog.conf
EOF
        ;;
    sysvinit)
        if [ "$INIT_SYSTEM" = "sysvinit" ]; then
            extract "$(find_archive sysvinit)"
            patch -Np1 -i ../sysvinit-3.14-consolidated-1.patch
            make -j"$(nproc)"
            make install
        else
            echo "Skipping sysvinit (init system: $INIT_SYSTEM)"
        fi
        ;;
    *)
        echo "ERROR: no build recipe for package $pkg"
        exit 1
        ;;
    esac
    cd /sources
    # Record the files this package added (awk set difference; the
    # chapter 7 gawk is on PATH here while diffutils' comm may not be
    # built yet). Modified files keep their original owner.
    snapshot_tree > /tmp/lpm-after.list
    awk 'NR == FNR { seen[$0] = 1; next } !($0 in seen)' \
        /tmp/lpm-before.list /tmp/lpm-after.list \
        > "$LPM_MANIFEST_DIR/$pkg.list"
    echo "Captured manifest for $pkg: $(wc -l < "$LPM_MANIFEST_DIR/$pkg.list") files"
done

# ============================================================
# LFS 12.4 Section 8.84 – Stripping (adapted: guards added so
# the procedure stays fatal-error free under set -e)
# ============================================================
echo "=== Stripping debugging symbols (LFS 8.84) ==="

save_usrlib="$(cd /usr/lib; ls ld-linux*[^g])
 libc.so.6
 libthread_db.so.1
 libquadmath.so.0.0.0
 libstdc++.so.6.0.34
 libitm.so.1.0.0
 libatomic.so.1.2.0"

cd /usr/lib

for LIB in $save_usrlib; do
    [ -e "$LIB" ] || continue
    objcopy --only-keep-debug --compress-debug-sections=zstd "$LIB" "$LIB.dbg"
    cp "$LIB" "/tmp/$LIB"
    strip --strip-debug "/tmp/$LIB"
    objcopy --add-gnu-debuglink="$LIB.dbg" "/tmp/$LIB"
    install -vm755 "/tmp/$LIB" /usr/lib
    rm "/tmp/$LIB"
done

online_usrbin="bash find strip"
online_usrlib="libbfd-2.45.so
 libsframe.so.2.0.0
 libhistory.so.8.3
 libncursesw.so.6.5
 libm.so.6
 libreadline.so.8.3
 libz.so.1.3.1
 libzstd.so.1.5.7
 $(cd /usr/lib; find libnss*.so* -type f)"

for BIN in $online_usrbin; do
    [ -e "/usr/bin/$BIN" ] || continue
    cp "/usr/bin/$BIN" "/tmp/$BIN"
    strip --strip-debug "/tmp/$BIN"
    install -vm755 "/tmp/$BIN" /usr/bin
    rm "/tmp/$BIN"
done

for LIB in $online_usrlib; do
    [ -e "/usr/lib/$LIB" ] || continue
    cp "/usr/lib/$LIB" "/tmp/$LIB"
    strip --strip-debug "/tmp/$LIB"
    install -vm755 "/tmp/$LIB" /usr/lib
    rm "/tmp/$LIB"
done

# The final pass strips everything else; scripts trigger "file format not
# recognized" messages which strip reports as errors, hence the guard.
for i in $(find /usr/lib -type f -name '*.so*' ! -name '*dbg') \
         $(find /usr/lib -type f -name '*.a') \
         $(find /usr/bin /usr/sbin /usr/libexec -type f 2>/dev/null); do
    case "$online_usrbin $online_usrlib $save_usrlib" in
        *$(basename "$i")*) ;;
        *) strip --strip-debug "$i" 2>/dev/null || true ;;
    esac
done

unset BIN LIB save_usrlib online_usrbin online_usrlib

# ============================================================
# LFS 12.4 Section 8.85 – Cleaning up
# ============================================================
echo "=== Cleaning up (LFS 8.85) ==="
find /usr/lib /usr/libexec -name \*.la -delete
find /usr -depth -name "$(uname -m)-lfs-linux-gnu*" -exec rm -rf {} +
userdel -r tester 2>/dev/null || true

# ============================================================
# Make the system standalone: point /bin/bash at the chapter 8
# bash, remove the temporary /tools tree, and verify.
# ============================================================
echo "=== Removing /tools and switching to the final system ==="
ln -sfn /usr/bin/bash /bin/bash
ln -sfn bash /bin/sh
rm -rf /tools

if env -i PATH=/usr/bin:/usr/sbin /bin/bash -c 'echo standalone system OK'; then
    echo "System is standalone"
else
    echo "ERROR: system is not standalone after /tools removal"
    exit 1
fi

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
