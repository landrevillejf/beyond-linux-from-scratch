#!/bin/bash
# Build BLFS base packages
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -euo pipefail

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
KERNEL_TYPE=${KERNEL_TYPE:-linux}
export KERNEL_TYPE

if [ -z "$LFS" ]; then
    log_error "LFS variable not set"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    log_info "Relaunching with sudo..."
    exec sudo -E "$0" "$@"
fi

log_info "========================================="
log_info "Building BLFS base packages"
log_info "========================================="

if [ ! -d "$LFS" ]; then
    log_error "LFS directory $LFS does not exist"
    exit 1
fi

install_docker_metadata() {
    log_info "Docker mode – installing BLFS base metadata and filesystem skeleton in $LFS"
    mkdir -p "$LFS"/{etc/ssl/certs,etc/pki/tls/certs,etc/ssh,etc/sudoers.d,usr/bin,usr/lib,usr/share/doc,usr/share/man,var/lib/lfs-builder/blfs-base,var/log}
    cat >"$LFS/var/lib/lfs-builder/blfs-base/packages.list" <<'EOF'
openssl
make-ca
libtasn1
p11-kit
nettle
xz
lz4
zstd
libarchive
pcre2
libxml2
libxslt
libssh2
curl
wget
rsync
openssh
git
cmake
python3
ninja
meson
sudo
less
nano
vim
dhcpcd
iproute2
tzdata
iana-etc
sqlite
EOF
    cat >"$LFS/etc/ssl/openssl.cnf" <<'EOF'
openssl_conf = openssl_init
[openssl_init]
[system_default_sect]
EOF
    cat >"$LFS/etc/ca-certificates.conf" <<'EOF'
# Managed by Way Beyond Linux From Scratch Docker metadata mode.
# Native builds install make-ca generated anchors here.
EOF
    cat >"$LFS/etc/sudoers.d/README" <<'EOF'
# sudo package metadata installed; native builds install sudo itself.
EOF
    chmod 0755 "$LFS/var/lib/lfs-builder" "$LFS/var/lib/lfs-builder/blfs-base"
    while read -r pkg; do
        [ -n "$pkg" ] && touch "$LFS/var/lib/lfs-builder/blfs-base/${pkg}.docker"
    done <"$LFS/var/lib/lfs-builder/blfs-base/packages.list"
    log_success "BLFS base Docker metadata installed"
}

if [ "$IN_DOCKER" = true ]; then
    install_docker_metadata
    exit 0
fi

mount_chroot_fs() {
    mkdir -p "$LFS"/{dev,dev/pts,proc,sys,run,sources}
    mountpoint -q "$LFS/dev" || mount --bind /dev "$LFS/dev"
    mountpoint -q "$LFS/dev/pts" || mount -t devpts devpts "$LFS/dev/pts"
    mountpoint -q "$LFS/proc" || mount -t proc proc "$LFS/proc"
    mountpoint -q "$LFS/sys" || mount -t sysfs sysfs "$LFS/sys"
    mountpoint -q "$LFS/run" || mount -t tmpfs tmpfs "$LFS/run"
}

cleanup() {
    if mountpoint -q "$LFS/dev/pts" && ! umount "$LFS/dev/pts" 2>/dev/null; then log_warning "Could not unmount $LFS/dev/pts"; fi
    if mountpoint -q "$LFS/dev" && ! umount "$LFS/dev" 2>/dev/null; then log_warning "Could not unmount $LFS/dev"; fi
    if mountpoint -q "$LFS/proc" && ! umount "$LFS/proc" 2>/dev/null; then log_warning "Could not unmount $LFS/proc"; fi
    if mountpoint -q "$LFS/sys" && ! umount "$LFS/sys" 2>/dev/null; then log_warning "Could not unmount $LFS/sys"; fi
    if mountpoint -q "$LFS/run" && ! umount "$LFS/run" 2>/dev/null; then log_warning "Could not unmount $LFS/run"; fi
}
trap cleanup EXIT

if [ ! -x "$LFS/bin/bash" ]; then
    log_error "/bin/bash not found in $LFS/bin – run lfs-basic first"
    exit 1
fi

mount_chroot_fs

SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    mkdir -p "$LFS/sources"
    cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    if ! chown -R lfs:lfs "$LFS/sources" 2>/dev/null; then log_warning "Could not chown $LFS/sources to lfs:lfs"; fi
fi

cat >"$LFS/build-blfs-base.sh" <<'INNEREOF'
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/blfs-base

jobs() { nproc 2>/dev/null || echo 1; }
marker_for() { echo "/var/lib/lfs-builder/blfs-base/$1.done"; }

is_installed() {
    local pkg="$1" marker
    marker="$(marker_for "$pkg")"
    [ -f "$marker" ] && return 0
    case "$pkg" in
        openssl) [ -x /usr/bin/openssl ] ;;
        make-ca) [ -x /usr/sbin/make-ca ] || [ -f /etc/ssl/certs/ca-certificates.crt ] ;;
        libtasn1) [ -f /usr/lib/libtasn1.so ] ;;
        p11-kit) [ -x /usr/bin/p11-kit ] ;;
        nettle) [ -f /usr/lib/libnettle.so ] ;;
        xz) [ -x /usr/bin/xz ] ;;
        lz4) [ -x /usr/bin/lz4 ] ;;
        zstd) [ -x /usr/bin/zstd ] ;;
        libarchive) [ -x /usr/bin/bsdtar ] ;;
        pcre2) [ -x /usr/bin/pcre2-config ] ;;
        libxml2) [ -x /usr/bin/xml2-config ] ;;
        libxslt) [ -x /usr/bin/xslt-config ] ;;
        libssh2) [ -f /usr/lib/libssh2.so ] ;;
        curl) [ -x /usr/bin/curl ] ;;
        wget) [ -x /usr/bin/wget ] ;;
        rsync) [ -x /usr/bin/rsync ] ;;
        openssh) [ -x /usr/bin/ssh ] ;;
        git) [ -x /usr/bin/git ] ;;
        cmake) [ -x /usr/bin/cmake ] ;;
        python3) [ -x /usr/bin/python3 ] ;;
        ninja) [ -x /usr/bin/ninja ] ;;
        meson) [ -x /usr/bin/meson ] ;;
        sudo) [ -x /usr/bin/sudo ] ;;
        less) [ -x /usr/bin/less ] ;;
        nano) [ -x /usr/bin/nano ] ;;
        vim) [ -x /usr/bin/vim ] ;;
        dhcpcd) [ -x /usr/sbin/dhcpcd ] || [ -x /usr/bin/dhcpcd ] ;;
        iproute2) [ -x /usr/sbin/ip ] || [ -x /usr/bin/ip ] ;;
        tzdata) [ -d /usr/share/zoneinfo ] ;;
        iana-etc) [ -f /etc/services ] && [ -f /etc/protocols ] ;;
        sqlite) [ -x /usr/bin/sqlite3 ] ;;
        *) return 1 ;;
    esac
}

find_archive() {
    local pattern="$1"
    compgen -G "$pattern" | sort -V | tail -n 1
}

extract_archive() {
    local archive="$1" dir
    dir="$(tar -tf "$archive" | head -n 1 | cut -d/ -f1)"
    rm -rf "$dir"
    tar -xf "$archive"
    printf '%s\n' "$dir"
}

finish_pkg() {
    local pkg="$1"
    touch "$(marker_for "$pkg")"
    log_success "$pkg installed"
}

configure_and_make() {
    local pkg="$1" pattern="$2" configure_cmd="$3"
    shift 3
    local archive dir
    archive="$(find_archive "$pattern")"
    if [ -z "$archive" ]; then
        log_warning "Source archive missing for $pkg ($pattern); skipping"
        return 0
    fi
    if is_installed "$pkg"; then
        log_info "$pkg already installed; skipping"
        return 0
    fi
    log_info "Building $pkg from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
    "$configure_cmd" "$@"
    make -j"$(jobs)"
    make install
    popd >/dev/null
    rm -rf "$dir"
    finish_pkg "$pkg"
}

build_pkg() {
    local pkg="$1" pattern="$2"
    shift 2
    configure_and_make "$pkg" "$pattern" ./configure "$@"
}

build_openssl() {
    configure_and_make openssl 'openssl-*.tar.*' ./config --prefix=/usr --openssldir=/etc/ssl --libdir=lib shared zlib-dynamic
}

build_make_ca() {
    local pkg=make-ca archive dir
    archive="$(find_archive 'make-ca-*.tar.*')"
    if [ -z "$archive" ]; then log_warning "Source archive missing for make-ca; skipping"; return 0; fi
    if is_installed "$pkg"; then log_info "make-ca already installed; skipping"; return 0; fi
    log_info "Building make-ca from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
    make install
    install -vdm755 /etc/ssl/local
    /usr/sbin/make-ca -g || log_warning "make-ca generation failed; install completed but certificates may need regeneration"
    popd >/dev/null
    rm -rf "$dir"
    finish_pkg "$pkg"
}

build_p11_kit() {
    local archive dir
    archive="$(find_archive 'p11-kit-*.tar.*')"
    if [ -z "$archive" ]; then log_warning "Source archive missing for p11-kit; skipping"; return 0; fi
    if is_installed p11-kit; then log_info "p11-kit already installed; skipping"; return 0; fi
    log_info "Building p11-kit from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
    if [ -f meson.build ]; then
        rm -rf build
        meson setup build --prefix=/usr --buildtype=release -Dtrust_paths=/etc/pki/anchors
        ninja -C build
        ninja -C build install
    else
        ./configure --prefix=/usr --sysconfdir=/etc --with-trust-paths=/etc/pki/anchors --disable-static
        make -j"$(jobs)"
        make install
    fi
    popd >/dev/null
    rm -rf "$dir"
    finish_pkg p11-kit
}

build_cmake() {
    local archive dir
    archive="$(find_archive 'cmake-*.tar.*')"
    if [ -z "$archive" ]; then log_warning "Source archive missing for cmake; skipping"; return 0; fi
    if is_installed cmake; then log_info "cmake already installed; skipping"; return 0; fi
    log_info "Building cmake from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
    ./bootstrap --prefix=/usr --system-libs --mandir=/share/man --no-system-jsoncpp --no-system-cppdylib
    make -j"$(jobs)"
    make install
    popd >/dev/null
    rm -rf "$dir"
    finish_pkg cmake
}

build_python3() { build_pkg python3 'Python-*.tar.*' --prefix=/usr --enable-shared --with-system-expat --with-ensurepip=yes; }

build_ninja() {
    local archive dir
    archive="$(find_archive 'ninja-*.tar.*')"
    if [ -z "$archive" ]; then log_warning "Source archive missing for ninja; skipping"; return 0; fi
    if is_installed ninja; then log_info "ninja already installed; skipping"; return 0; fi
    log_info "Building ninja from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
    python3 configure.py --bootstrap
    install -vm755 ninja /usr/bin/
    popd >/dev/null
    rm -rf "$dir"
    finish_pkg ninja
}

build_meson() {
    local archive dir
    archive="$(find_archive 'meson-*.tar.*')"
    if [ -z "$archive" ]; then log_warning "Source archive missing for meson; skipping"; return 0; fi
    if is_installed meson; then log_info "meson already installed; skipping"; return 0; fi
    log_info "Installing meson from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
    python3 setup.py build
    python3 setup.py install --root=/ --optimize=1
    popd >/dev/null
    rm -rf "$dir"
    finish_pkg meson
}

build_iproute2() {
    local archive dir
    archive="$(find_archive 'iproute2-*.tar.*')"
    if [ -z "$archive" ]; then log_warning "Source archive missing for iproute2; skipping"; return 0; fi
    if is_installed iproute2; then log_info "iproute2 already installed; skipping"; return 0; fi
    log_info "Building iproute2 from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
    sed -i /ARPD/d Makefile
    rm -fv man/man8/arpd.8
    make -j"$(jobs)" NETNS_RUN_DIR=/run/netns
    make SBINDIR=/usr/sbin install
    popd >/dev/null
    rm -rf "$dir"
    finish_pkg iproute2
}

build_tzdata() {
    local archive dir zoneinfo=/usr/share/zoneinfo
    archive="$(find_archive 'tzdata*.tar.*')"
    if [ -z "$archive" ]; then log_warning "Source archive missing for tzdata; skipping"; return 0; fi
    if is_installed tzdata; then log_info "tzdata already installed; skipping"; return 0; fi
    log_info "Installing tzdata from $archive"
    dir="tzdata-build"
    rm -rf "$dir" && mkdir "$dir"
    tar -xf "$archive" -C "$dir"
    pushd "$dir" >/dev/null
    mkdir -p "$zoneinfo"/{posix,right}
    for tz in etcetera southamerica northamerica europe africa antarctica asia australasia backward; do
        zic -L /dev/null -d "$zoneinfo" "${tz}"
        zic -L /dev/null -d "$zoneinfo/posix" "${tz}"
        zic -L leapseconds -d "$zoneinfo/right" "${tz}"
    done
    cp -v zone.tab zone1970.tab iso3166.tab "$zoneinfo"
    zic -d "$zoneinfo" -p America/New_York
    popd >/dev/null
    rm -rf "$dir"
    finish_pkg tzdata
}

build_iana_etc() {
    local archive dir
    archive="$(find_archive 'iana-etc-*.tar.*')"
    if [ -z "$archive" ]; then log_warning "Source archive missing for iana-etc; skipping"; return 0; fi
    if is_installed iana-etc; then log_info "iana-etc already installed; skipping"; return 0; fi
    log_info "Installing iana-etc from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
    make install
    popd >/dev/null
    rm -rf "$dir"
    finish_pkg iana-etc
}

log_info "Phase 1 – Encryption/networking primitives"
build_openssl
build_make_ca
build_pkg libtasn1 'libtasn1-*.tar.*' --prefix=/usr --disable-static
build_p11_kit
build_pkg nettle 'nettle-*.tar.*' --prefix=/usr --disable-static

log_info "Phase 2 – Compression/parsing"
build_pkg xz 'xz-*.tar.*' --prefix=/usr --disable-static
build_pkg lz4 'lz4-*.tar.*' --prefix=/usr --disable-static
build_pkg zstd 'zstd-*.tar.*' --prefix=/usr --disable-static
build_pkg libarchive 'libarchive-*.tar.*' --prefix=/usr --disable-static
build_pkg pcre2 'pcre2-*.tar.*' --prefix=/usr --disable-static --enable-unicode --enable-pcre2-16 --enable-pcre2-32 --enable-pcre2grep-libz --enable-pcre2grep-libbz2
build_pkg libxml2 'libxml2-*.tar.*' --prefix=/usr --sysconfdir=/etc --disable-static --with-history --with-python=/usr/bin/python3
build_pkg libxslt 'libxslt-*.tar.*' --prefix=/usr --disable-static

log_info "Phase 3 – Network clients"
build_pkg libssh2 'libssh2-*.tar.*' --prefix=/usr --disable-static --with-openssl
build_pkg curl 'curl-*.tar.*' --prefix=/usr --disable-static --with-openssl --with-libssh2 --enable-threaded-resolver
build_pkg wget 'wget-*.tar.*' --prefix=/usr --sysconfdir=/etc --with-ssl=openssl
build_pkg rsync 'rsync-*.tar.*' --prefix=/usr --disable-xxhash --without-included-zlib
build_pkg openssh 'openssh-*.tar.*' --prefix=/usr --sysconfdir=/etc/ssh --with-md5-passwords --with-privsep-path=/var/lib/sshd
[ -d /var/lib/sshd ] || install -vdm755 /var/lib/sshd

log_info "Phase 4 – Version control & build tools"
build_pkg git 'git-*.tar.*' --prefix=/usr --with-gitconfig=/etc/gitconfig --with-libpcre2
build_cmake
build_python3
build_ninja
build_meson

log_info "Phase 5 – System utilities"
build_pkg sudo 'sudo-*.tar.*' --prefix=/usr --libexecdir=/usr/lib --with-secure-path --with-env-editor --docdir=/usr/share/doc/sudo
build_pkg less 'less-*.tar.*' --prefix=/usr --sysconfdir=/etc
build_pkg nano 'nano-*.tar.*' --prefix=/usr --sysconfdir=/etc --enable-utf8
build_pkg vim 'vim-*.tar.*' --prefix=/usr --with-features=huge --enable-gui=no --without-x --disable-gpm --enable-cscope --docdir=/usr/share/doc/vim
build_pkg dhcpcd 'dhcpcd-*.tar.*' --prefix=/usr --sysconfdir=/etc --libexecdir=/usr/lib/dhcpcd --dbdir=/var/lib/dhcpcd --runstatedir=/run
build_iproute2
build_tzdata
build_iana_etc
build_pkg sqlite 'sqlite-autoconf-*.tar.*' --prefix=/usr --disable-static --enable-fts5 CFLAGS=-DSQLITE_ENABLE_COLUMN_METADATA=1

log_success "BLFS base package build completed"
INNEREOF

chmod +x "$LFS/build-blfs-base.sh"
chroot "$LFS" /bin/bash -c "export KERNEL_TYPE=$KERNEL_TYPE; /build-blfs-base.sh"
log_success "BLFS base packages built successfully"
