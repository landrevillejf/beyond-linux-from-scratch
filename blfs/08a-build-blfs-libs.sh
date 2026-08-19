#!/bin/bash
# 08a-build-blfs-libs.sh
# Build BLFS core libraries (glib2, cairo, pango, dbus, gdk-pixbuf, etc.)
# These are the foundational libraries required by all desktop environments.
# Author : Jean-Francois Landreville, landrevvillejf@protonmail.com, 2026.
#
# Error policy (audit finding F-07): a required package failure aborts the
# stage.  Only packages that are explicitly optional (application-specific
# dependencies or packages missing from packages/stable/12.4/sources.list)
# are allowed to fail with a warning.
set -euo pipefail

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

IN_DOCKER=false
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
    IN_DOCKER=true
    log_info "Running in Docker container"
fi

if [ "$IN_DOCKER" = true ]; then LFS=${LFS:-/output/image}; else LFS=${LFS:-/mnt/lfs}; fi
[ -n "$LFS" ] || { log_error "LFS variable not set"; exit 1; }

run_privileged() { if [ "$(whoami)" = "root" ]; then "$@"; else sudo "$@"; fi; }

INIT_SYSTEM="${INIT_SYSTEM:-sysvinit}"
DESKTOP_TYPE="${LFS_CONFIG_DESKTOP_TYPE:-xfce}"
export INIT_SYSTEM DESKTOP_TYPE

log_info "========================================="
log_info "Building BLFS core libraries"
log_info "Init system: $INIT_SYSTEM"
log_info "Desktop type: $DESKTOP_TYPE"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – creating minimal BLFS library structure in $LFS"
    run_privileged mkdir -pv "$LFS"/usr/lib/pkgconfig "$LFS"/usr/share/pkgconfig \
        "$LFS"/usr/share/icons/hicolor "$LFS"/usr/share/mime
    log_success "Minimal BLFS library structure created (Docker)"
    exit 0
fi

[ "$DESKTOP_TYPE" = "none" ] && {
    log_info "No desktop requested; skipping BLFS core libraries"
    exit 0
}

[ -x "$LFS/bin/bash" ] || { log_error "/bin/bash not found in $LFS/bin – run lfs-basic first"; exit 1; }
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
    log_error "chroot not working – run lfs-basic first"
    exit 1
fi

mount_chroot_fs() {
    run_privileged mkdir -p "$LFS"/{dev,dev/pts,proc,sys,run,sources}
    run_privileged mountpoint -q "$LFS/dev" || run_privileged mount --bind /dev "$LFS/dev"
    run_privileged mountpoint -q "$LFS/dev/pts" || run_privileged mount -t devpts devpts "$LFS/dev/pts"
    run_privileged mountpoint -q "$LFS/proc" || run_privileged mount -t proc proc "$LFS/proc"
    run_privileged mountpoint -q "$LFS/sys" || run_privileged mount -t sysfs sysfs "$LFS/sys"
    run_privileged mountpoint -q "$LFS/run" || run_privileged mount -t tmpfs tmpfs "$LFS/run"
}
cleanup() {
    if run_privileged mountpoint -q "$LFS/dev/pts" && ! run_privileged umount "$LFS/dev/pts" 2>/dev/null; then log_warning "Could not unmount $LFS/dev/pts"; fi
    if run_privileged mountpoint -q "$LFS/dev" && ! run_privileged umount "$LFS/dev" 2>/dev/null; then log_warning "Could not unmount $LFS/dev"; fi
    if run_privileged mountpoint -q "$LFS/proc" && ! run_privileged umount "$LFS/proc" 2>/dev/null; then log_warning "Could not unmount $LFS/proc"; fi
    if run_privileged mountpoint -q "$LFS/sys" && ! run_privileged umount "$LFS/sys" 2>/dev/null; then log_warning "Could not unmount $LFS/sys"; fi
    if run_privileged mountpoint -q "$LFS/run" && ! run_privileged umount "$LFS/run" 2>/dev/null; then log_warning "Could not unmount $LFS/run"; fi
}
trap cleanup EXIT
mount_chroot_fs

SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    if ! run_privileged chown -R lfs:lfs "$LFS/sources" 2>/dev/null; then log_warning "Could not chown $LFS/sources to lfs:lfs"; fi
fi

cat <<'INNEREOF' | run_privileged tee "$LFS/build-blfs-libs.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/blfs-libs /usr/lib/pkgconfig /usr/share/pkgconfig \
    /usr/share/icons/hicolor /usr/share/mime /usr/share/icons

jobs() { nproc 2>/dev/null || echo 1; }
marker_for() { echo "/var/lib/lfs-builder/blfs-libs/$1.done"; }
find_archive() { compgen -G "${1}-*.tar.*" 2>/dev/null | sort -V | tail -n 1; }
extract_archive() {
    local archive="$1" dir
    dir="$(tar -tf "$archive" | head -n 1 | cut -d/ -f1)"
    rm -rf "$dir"
    tar -xf "$archive"
    printf '%s\n' "$dir"
}
have_pc() { pkg-config --exists "$1" 2>/dev/null; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_installed() {
    local pkg="$1"
    [ -f "$(marker_for "$pkg")" ] && return 0
    case "$pkg" in
        libpng)              have_pc libpng ;;
        libjpeg-turbo)       have_pc libjpeg ;;
        giflib)              [ -f /usr/lib/libgif.so ] || [ -f /usr/lib64/libgif.so ] ;;
        tiff)                have_pc libtiff-4 ;;
        libwebp)             have_pc libwebp ;;
        freetype)            have_pc freetype2 ;;
        fontconfig)          have_pc fontconfig ;;
        glib2)               have_pc glib-2.0 ;;
        graphene)            have_pc graphene-1.0 ;;
        harfbuzz)            have_pc harfbuzz ;;
        pixman)              have_pc pixman-1 ;;
        cairo)               have_pc cairo ;;
        fribidi)             have_pc fribidi ;;
        pango)               have_pc pango ;;
        dbus)                have_pc dbus-1 ;;
        dbus-glib)           have_pc dbus-glib-1 ;;
        at-spi2-core)        have_pc atspi-2 ;;
        gdk-pixbuf)          have_pc gdk-pixbuf-2.0 ;;
        shared-mime-info)    have_cmd update-mime-database ;;
        hicolor-icon-theme)  [ -d /usr/share/icons/hicolor/48x48 ] ;;
        json-glib)           have_pc json-glib-1.0 ;;
        libgee)              have_pc gee-0.8 ;;
        libxslt)             have_pc libxslt ;;
        vala)                have_cmd valac ;;
        gobject-introspection) have_pc gobject-introspection-1.0 ;;
        hunspell)            have_pc hunspell ;;
        poppler)             have_pc poppler ;;
        babl)                have_pc babl ;;
        gegl)                have_pc gegl-0.4 ;;
        libmatroska)         have_pc libmatroska ;;
        libebml)             have_pc libebml ;;
        taglib)              have_pc taglib ;;
        icu)                 have_cmd icu-config || have_pc icu-i18n ;;
        nspr)                have_pc nspr ;;
        nss)                 have_pc nss ;;
        rust)                have_cmd rustc ;;
        wxWidgets)           have_pc wxWidgets ;;
        libnotify)           have_pc libnotify ;;
        libsecret)           have_pc libsecret-1 ;;
        libgudev)            have_pc libgudev-1.0 ;;
        libxkbcommon)        have_pc xkbcommon ;;
        libinput)            have_pc libinput ;;
        libwacom)            have_pc libwacom ;;
        libevdev)            have_pc libevdev ;;
        libdrm)              have_pc libdrm ;;
        mesa)                have_pc egl ;;
        libva)               have_pc libva ;;
        libvdpau)            have_pc vdpau ;;
        libass)              have_pc libass ;;
        libbluray)           have_pc libbluray ;;
        libdvdnav)           have_pc dvdnav ;;
        libdvdread)          have_pc dvdread ;;
        libcdio)             have_pc libcdio ;;
        libcddb)             have_pc libcddb ;;
        libmodplug)          have_pc libmodplug ;;
        libcue)              have_pc libcue ;;
        libzip)              have_pc libzip ;;
        libarchive)          have_cmd bsdtar || have_pc libarchive ;;
        libyaml)             have_pc yaml-0.1 ;;
        libusb)              have_pc libusb-1.0 ;;
        libcap)              have_cmd setcap ;;
        libaio)              [ -f /usr/lib/libaio.so ] ;;
        lm-sensors)          have_cmd sensors ;;
        pciutils)            have_cmd lspci ;;
        usbutils)            have_cmd lsusb ;;
        libgpg-error)        have_pc gpg-error ;;
        libgcrypt)           have_pc libgcrypt ;;
        libassuan)           have_pc libassuan ;;
        libksba)             have_pc ksba ;;
        npth)                have_pc npth ;;
        libtasn1)            have_pc libtasn1 ;;
        nettle)              have_pc nettle ;;
        libunistring)        have_pc libunistring ;;
        libidn2)             have_pc libidn2 ;;
        libidn)              have_pc libidn ;;
        pcre2)               have_pc libpcre2-8 ;;
        libseccomp)          have_pc libseccomp ;;
        libelf)              have_pc libelf ;;
        libffi)              have_pc libffi ;;
        expat)               have_pc expat ;;
        libxml2)             have_pc libxml-2.0 ;;
        *) return 1 ;;
    esac
}

# Archive name mapping when the tarball base name differs from the
# package name used in this script.
archive_names() {
    case "$1" in
        glib2)       echo "glib2 glib" ;;
        icu)         echo "icu4c icu" ;;
        libelf)      echo "libelf elfutils" ;;
        libyaml)     echo "libyaml yaml" ;;
        lm-sensors)  echo "lm-sensors lm_sensors" ;;
        wxWidgets)   echo "wxWidgets wxwidgets" ;;
        rust)        echo "rustc rust" ;;
        *)           echo "$1" ;;
    esac
}

# Build a package: auto-detect meson vs autotools vs cmake.
# Returns non-zero on any failure, including a missing source archive.
build_pkg() {
    local pkg="$1" archive="" dir extra_opts="" base
    shift
    extra_opts="$*"
    if is_installed "$pkg"; then log_info "$pkg already installed; skipping"; return 0; fi
    for base in $(archive_names "$pkg"); do
        archive="$(find_archive "$base")"
        [ -n "$archive" ] && break
    done
    if [ -z "$archive" ]; then
        log_error "Source archive missing for $pkg"
        return 1
    fi
    log_info "Building $pkg from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
    if [ -f meson.build ]; then
        rm -rf builddir
        # shellcheck disable=SC2086
        meson setup builddir --prefix=/usr --buildtype=release --sysconfdir=/etc --localstatedir=/var $extra_opts
        ninja -C builddir
        ninja -C builddir install
    elif [ -x ./configure ] || [ -f configure ]; then
        # shellcheck disable=SC2086
        ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static $extra_opts
        make -j"$(jobs)"
        make install
    elif [ -x ./autogen.sh ]; then
        # shellcheck disable=SC2086
        ./autogen.sh --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static $extra_opts
        make -j"$(jobs)"
        make install
    elif [ -f CMakeLists.txt ]; then
        # shellcheck disable=SC2086
        cmake -B builddir -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release $extra_opts
        cmake --build builddir -j"$(jobs)"
        cmake --install builddir
    else
        log_error "$pkg has no recognised build system"; popd >/dev/null; return 1
    fi
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for "$pkg")"
    log_success "$pkg installed"
}

# giflib – plain make build, no configure (BLFS general/giflib)
build_giflib() {
    local archive dir
    is_installed giflib && { log_info "giflib already installed; skipping"; return 0; }
    archive="$(find_archive giflib)" || { log_error "Source archive missing for giflib"; return 1; }
    log_info "Building giflib from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
    # Book patches are applied only when they were downloaded
    for p in giflib-5.2.2-upstream_fixes-1.patch giflib-5.2.2-security_fixes-1.patch; do
        if [ -f "../$p" ]; then patch -Np1 -i "../$p"; fi
    done
    if [ -f pic/gifgrid.gif ]; then cp pic/gifgrid.gif doc/giflib-logo.gif; fi
    make
    make PREFIX=/usr install
    rm -fv /usr/lib/libgif.a
    find doc \( -name 'Makefile*' -o -name '*.1' -o -name '*.xml' \) -exec rm -v {} \;
    install -v -dm755 "/usr/share/doc/${dir}"
    cp -v -R doc/* "/usr/share/doc/${dir}"
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for giflib)"
    log_success "giflib installed"
}

# icu – configure lives in the source/ subdirectory (BLFS general/icu)
build_icu() {
    local archive="" base
    is_installed icu && { log_info "icu already installed; skipping"; return 0; }
    for base in $(archive_names icu); do
        archive="$(find_archive "$base")"
        [ -n "$archive" ] && break
    done
    if [ -z "$archive" ]; then log_error "Source archive missing for icu"; return 1; fi
    log_info "Building icu from $archive"
    rm -rf icu
    tar -xf "$archive"
    pushd icu/source >/dev/null
    ./configure --prefix=/usr
    make -j"$(jobs)"
    make install
    popd >/dev/null
    rm -rf icu
    touch "$(marker_for icu)"
    log_success "icu installed"
}

# nspr – book seds + mozilla/pthreads flags (BLFS general/nspr)
build_nspr() {
    local archive dir
    is_installed nspr && { log_info "nspr already installed; skipping"; return 0; }
    archive="$(find_archive nspr)" || { log_error "Source archive missing for nspr"; return 1; }
    log_info "Building nspr from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
    cd nspr
    sed -i '/^RELEASE/s|^|#|' pr/src/misc/Makefile.in
    # shellcheck disable=SC2016  # literal Makefile variable
    sed -i 's|$(LIBRARY) ||' config/rules.mk
    # shellcheck disable=SC2046  # conditional book flag
    ./configure --prefix=/usr \
        --with-mozilla \
        --with-pthreads \
        $([ "$(uname -m)" = x86_64 ] && echo --enable-64bit)
    make -j"$(jobs)"
    make install
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for nspr)"
    log_success "nspr installed"
}

# nss – plain make install into dist/, manual install (BLFS postlfs/nss)
build_nss() {
    local archive dir
    is_installed nss && { log_info "nss already installed; skipping"; return 0; }
    archive="$(find_archive nss)" || { log_error "Source archive missing for nss"; return 1; }
    log_info "Building nss from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
    if [ -f ../nss-standalone-1.patch ]; then patch -Np1 -i ../nss-standalone-1.patch; fi
    cd nss
    # shellcheck disable=SC2046  # conditional book variables
    make BUILD_OPT=1 \
        NSPR_INCLUDE_DIR=/usr/include/nspr \
        USE_SYSTEM_ZLIB=1 \
        ZLIB_LIBS=-lz \
        NSS_ENABLE_WERROR=0 \
        $([ "$(uname -m)" = x86_64 ] && echo USE_64=1) \
        $([ -f /usr/include/sqlite3.h ] && echo NSS_USE_SYSTEM_SQLITE=1)
    cd ../dist
    install -v -m755 Linux*/lib/*.so /usr/lib
    install -v -m644 Linux*/lib/{*.chk,libcrmf.a} /usr/lib
    install -v -m755 -d /usr/include/nss
    cp -v -RL {public,private}/nss/* /usr/include/nss
    install -v -m755 Linux*/bin/{certutil,nss-config,pk12util} /usr/bin
    install -v -m644 Linux*/lib/pkgconfig/nss.pc /usr/lib/pkgconfig
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for nss)"
    log_success "nss installed"
}

# Policy wrapper.  required: any failure aborts the stage.
# optional: failures are logged and the build continues (application
# specific dependencies and packages not present in the source list).
run_build() {
    local mode="$1" pkg="$2"
    shift 2
    case "$pkg" in
        giflib) build_giflib && return 0 ;;
        icu)    build_icu && return 0 ;;
        nspr)   build_nspr && return 0 ;;
        nss)    build_nss && return 0 ;;
        *)      build_pkg "$pkg" "$@" && return 0 ;;
    esac
    if [ "$mode" = "required" ]; then
        log_error "Required package $pkg failed – aborting stage"
        exit 1
    fi
    log_warning "[OPTIONAL] $pkg failed or is missing – continuing"
}

# hicolor-icon-theme – data only, nothing to compile
build_hicolor() {
    local archive
    is_installed hicolor-icon-theme && { log_info "hicolor-icon-theme already installed; skipping"; return 0; }
    archive="$(find_archive hicolor-icon-theme)" || { log_error "Source archive missing for hicolor-icon-theme"; return 1; }
    log_info "Installing hicolor-icon-theme from $archive"
    tar -xf "$archive"
    cp -a hicolor /usr/share/icons/
    rm -rf hicolor
    touch "$(marker_for hicolor-icon-theme)"
    log_success "hicolor-icon-theme installed"
}

# ======================================================================
# Verify prerequisites from LFS base
# ======================================================================
verify_prerequisites() {
    local missing=() pc
    for pc in zlib expat libffi pcre2 python3; do
        if ! have_pc "$pc" 2>/dev/null && ! have_cmd "$pc" 2>/dev/null; then
            missing+=("$pc")
        fi
    done
    if [ "${#missing[@]}" -ne 0 ]; then
        log_error "Missing LFS prerequisites: ${missing[*]}"
        log_error "Build LFS system stage (05) and BLFS base (08) before this stage."
        exit 1
    fi
}
verify_prerequisites

# Detect if systemd is installed (for dbus configure options)
HAVE_SYSTEMD=false
if [ -x /usr/lib/systemd/systemd ] || [ -d /usr/lib/systemd/system ]; then
    HAVE_SYSTEMD=true
fi
log_info "systemd detected: $HAVE_SYSTEMD"

# ======================================================================
# Build packages in strict dependency order
# ======================================================================

log_info "Phase 1: Image and font libraries"

# libpng – required by freetype, cairo, gdk-pixbuf
run_build required libpng

# libjpeg-turbo – required by gdk-pixbuf, tiff
run_build required libjpeg-turbo

# giflib – required by gdk-pixbuf
run_build required giflib

# tiff – depends on libjpeg-turbo
run_build required tiff

# libwebp – depends on libpng, libjpeg-turbo
run_build required libwebp

log_info "Phase 2: Font rendering"

# freetype – depends on libpng
run_build required freetype

# fontconfig – depends on freetype, expat
run_build required fontconfig

log_info "Phase 3: GLib ecosystem"

# glib2 – depends on pcre2 (LFS), libffi (LFS)
run_build required glib2

# graphene – GTK 4 dependency
run_build required graphene

# harfbuzz – depends on glib2, freetype, fontconfig
run_build required harfbuzz

# json-glib – depends on glib2
run_build required json-glib

# libgee – depends on glib2
run_build required libgee

log_info "Phase 4: Graphics and text"

# pixman – depends on libpng
run_build required pixman

# cairo – depends on glib2, pixman, fontconfig, freetype, libpng
run_build required cairo

# fribidi – no dependencies
run_build required fribidi

# pango – depends on glib2, cairo, harfbuzz, fontconfig, freetype, fribidi
run_build required pango

log_info "Phase 5: D-Bus and accessibility"

# dbus – depends on expat (blfs-base)
if $HAVE_SYSTEMD; then
    run_build required dbus --with-systemdsystemunitdir=/usr/lib/systemd/system
else
    run_build required dbus --without-systemdsystemunitdir
fi

# dbus-glib – depends on dbus, glib2
run_build required dbus-glib

# at-spi2-core – depends on glib2, dbus
run_build required at-spi2-core

log_info "Phase 6: Image loading and MIME"

# gdk-pixbuf – depends on glib2, libpng, libjpeg-turbo, tiff
run_build required gdk-pixbuf

# shared-mime-info – depends on glib2, libxml2
run_build required shared-mime-info

# hicolor-icon-theme – no build, just directory structure
if ! is_installed hicolor-icon-theme; then
    if ! build_hicolor; then
        log_error "Required package hicolor-icon-theme failed – aborting stage"
        exit 1
    fi
fi

log_info "Phase 7: Development tools"

# libxslt – depends on libxml2 (blfs-base)
run_build required libxslt

# vala – depends on glib2
run_build required vala

# gobject-introspection – depends on glib2, python3
run_build required gobject-introspection

log_info "Phase 8: Application-specific dependencies"

# hunspell – spell checker (LibreOffice)
run_build optional hunspell

# poppler – PDF rendering (LibreOffice)
run_build optional poppler

# babl – pixel format translation (GIMP)
run_build optional babl

# gegl – Generic Graphics Library (GIMP)
run_build optional gegl

# taglib – audio metadata (VLC)
run_build optional taglib

# libebml – Extensible Binary Meta Language (VLC)
run_build optional libebml

# libmatroska – Matroska container (VLC)
run_build optional libmatroska

# icu – International Components for Unicode (Firefox dependency)
run_build required icu

# nspr – Netscape Portable Runtime (Firefox dependency)
run_build required nspr

# nss – Network Security Services (Firefox dependency)
run_build required nss

log_info "Phase 9: Additional general libraries from BLFS"

# libarchive – archive manipulation (tar, cpio, etc.)
run_build required libarchive

# libyaml – YAML parsing
run_build required libyaml

# libusb – USB library
run_build required libusb

# libcap – POSIX capabilities (already in LFS, rebuild only if missing)
run_build required libcap

# libaio – asynchronous I/O
run_build optional libaio

# lm-sensors – hardware monitoring
run_build optional lm-sensors

# pciutils – PCI utilities
run_build required pciutils

# usbutils – USB utilities
run_build required usbutils

# GnuPG support libraries
run_build required libgpg-error
run_build required libgcrypt
run_build required libassuan
run_build required libksba
run_build required npth

# Crypto/IDN stack
run_build required libtasn1
run_build required nettle
run_build required libunistring
run_build required libidn2
run_build optional libidn

# pcre2 – already in LFS, rebuild only if missing
run_build required pcre2

# libseccomp – secure computing mode
run_build optional libseccomp

# libelf / libffi / expat / libxml2 – already in LFS/blfs-base,
# rebuild only if missing
run_build required libelf
run_build required libffi
run_build required expat
run_build required libxml2

log_info "Phase 10: Optional dependencies for BLFS packages"

# wxWidgets – GUI toolkit (for FileZilla, Audacity)
run_build optional wxWidgets

# libnotify – desktop notifications
run_build optional libnotify

# libsecret – password storage
run_build optional libsecret

# libgudev – GObject wrapper for udev
run_build optional libgudev

# libxkbcommon – keyboard handling library (Wayland input)
run_build required libxkbcommon

# libinput – input device handling (Wayland)
run_build required libinput

# libwacom – tablet support
run_build optional libwacom

# libevdev – evdev wrapper (libinput dependency)
run_build required libevdev

# libdrm – Direct Rendering Manager (Mesa dependency)
run_build required libdrm

# mesa – 3D graphics library
run_build required mesa

# libva – Video Acceleration API
run_build optional libva

# libvdpau – VDPAU library
run_build optional libvdpau

# libass – ASS/SSA subtitle renderer
run_build optional libass

# libbluray – Blu-ray disc playback
run_build optional libbluray

# libdvdnav – DVD navigation
run_build optional libdvdnav

# libdvdread – DVD reading
run_build optional libdvdread

# libcdio – CD-ROM access
run_build optional libcdio

# libcddb – CDDB database access
run_build optional libcddb

# libmodplug – Mod music playback
run_build optional libmodplug

# libsidplay – not in packages/stable sources; optional
run_build optional libsidplay

# libcue – CUE sheet parser
run_build optional libcue

# libopenmpt – not in packages/stable sources; optional
run_build optional libopenmpt

# libzip – ZIP file access
run_build optional libzip

# rust – Rust compiler (required to build modern Firefox)
if ! have_cmd rustc; then
    archive=""
    for base in $(archive_names rust); do
        archive="$(find_archive "$base")"
        [ -n "$archive" ] && break
    done
    if [ -n "$archive" ]; then
        log_info "Building rust from $archive"
        dir="$(extract_archive "$archive")"
        pushd "$dir" >/dev/null
        if [ -x ./install.sh ]; then
            ./install.sh --prefix=/usr --disable-docs
        elif [ -x ./configure ] || [ -f configure ]; then
            ./configure --prefix=/usr
            make -j"$(jobs)"
            make install
        else
            log_warning "[OPTIONAL] rust: no recognised build system"
        fi
        popd >/dev/null
        rm -rf "$dir"
        touch "$(marker_for rust)"
    else
        log_warning "[OPTIONAL] rust source archive missing; Firefox may not build"
    fi
else
    log_info "rust already installed; skipping"
fi

log_success "BLFS core libraries build complete"
INNEREOF

run_privileged chmod +x "$LFS/build-blfs-libs.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    INIT_SYSTEM="$INIT_SYSTEM" LFS_CONFIG_DESKTOP_TYPE="$DESKTOP_TYPE" \
    /bin/bash /build-blfs-libs.sh

log_success "BLFS core libraries built successfully"
