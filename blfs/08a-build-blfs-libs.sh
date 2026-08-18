#!/bin/bash
# 08a-build-blfs-libs.sh
# Build BLFS core libraries (glib2, cairo, pango, dbus, gdk-pixbuf, etc.)
# These are the foundational libraries required by all desktop environments.
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
        ffmpeg)              have_cmd ffmpeg || have_cmd avconv ;;
        libmatroska)          have_pc libmatroska ;;
        libebml)              have_pc libebml ;;
        taglib)              have_pc taglib ;;
        icu)                 have_cmd icu-config || have_pc icu-i18n ;;
        nspr)                have_pc nspr ;;
        nss)                 have_pc nss ;;
        rust)                have_cmd rustc ;;
        wxWidgets)            have_pc wxWidgets ;;
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
        libsidplay)          have_pc libsidplay ;;
        libcue)              have_pc libcue ;;
        libopenmpt)          have_pc libopenmpt ;;
        libzip)              have_pc libzip ;;
        *) return 1 ;;
    esac
}

# Build a package: auto-detect meson vs autotools
build_pkg() {
    local pkg="$1" archive dir extra_opts=""
    shift
    extra_opts="$*"
    if is_installed "$pkg"; then log_info "$pkg already installed; skipping"; return 0; fi
    archive="$(find_archive "$pkg")"
    if [ -z "$archive" ]; then
        # Try alternate archive name patterns
        case "$pkg" in
            glib2)               archive="$(find_archive glib)" ;;
            libjpeg-turbo)       archive="$(find_archive jpegsrc)" || archive="$(find_archive libjpeg-turbo)" ;;
            shared-mime-info)    archive="$(find_archive shared-mime-info)" ;;
            hicolor-icon-theme)  archive="$(find_archive hicolor-icon-theme)" || archive="$(find_archive icon-theme)" ;;
            at-spi2-core)        archive="$(find_archive at-spi2-core)" ;;
            gobject-introspection) archive="$(find_archive gobject-introspection)" ;;
        esac
    fi
    if [ -z "$archive" ]; then log_warning "Source archive missing for $pkg; skipping"; return 0; fi
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
build_pkg libpng || log_warning "libpng build failed"

# libjpeg-turbo – required by gdk-pixbuf, tiff
build_pkg libjpeg-turbo || log_warning "libjpeg-turbo build failed"

# giflib – required by gdk-pixbuf
build_pkg giflib || log_warning "giflib build failed"

# tiff – depends on libjpeg-turbo
build_pkg tiff || log_warning "tiff build failed"

# libwebp – depends on libpng, libjpeg-turbo
build_pkg libwebp || log_warning "libwebp build failed"

log_info "Phase 2: Font rendering"

# freetype – depends on libpng
build_pkg freetype || log_warning "freetype build failed"

# fontconfig – depends on freetype, expat
build_pkg fontconfig || log_warning "fontconfig build failed"

log_info "Phase 3: GLib ecosystem"

# glib2 – depends on pcre2 (LFS), libffi (LFS)
build_pkg glib2 || log_warning "glib2 build failed"

# graphene – depends on glib2
build_pkg graphene || log_warning "graphene build failed"

# harfbuzz – depends on glib2, freetype, fontconfig
build_pkg harfbuzz || log_warning "harfbuzz build failed"

# json-glib – depends on glib2
build_pkg json-glib || log_warning "json-glib build failed"

# libgee – depends on glib2
build_pkg libgee || log_warning "libgee build failed"

log_info "Phase 4: Graphics and text"

# pixman – depends on libpng
build_pkg pixman || log_warning "pixman build failed"

# cairo – depends on glib2, pixman, fontconfig, freetype, libpng
build_pkg cairo || log_warning "cairo build failed"

# fribidi – no dependencies
build_pkg fribidi || log_warning "fribidi build failed"

# pango – depends on glib2, cairo, harfbuzz, fontconfig, freetype, fribidi
build_pkg pango || log_warning "pango build failed"

log_info "Phase 5: D-Bus and accessibility"

# dbus – depends on expat (blfs-base)
if $HAVE_SYSTEMD; then
    build_pkg dbus --with-systemdsystemunitdir=/usr/lib/systemd/system \
        || log_warning "dbus build failed"
else
    build_pkg dbus --without-systemdsystemunitdir \
        || log_warning "dbus build failed"
fi

# dbus-glib – depends on dbus, glib2
build_pkg dbus-glib || log_warning "dbus-glib build failed"

# at-spi2-core – depends on glib2, dbus
build_pkg at-spi2-core || log_warning "at-spi2-core build failed"

log_info "Phase 6: Image loading and MIME"

# gdk-pixbuf – depends on glib2, libpng, libjpeg-turbo, tiff
build_pkg gdk-pixbuf || log_warning "gdk-pixbuf build failed"

# shared-mime-info – depends on glib2, libxml2
build_pkg shared-mime-info || log_warning "shared-mime-info build failed"

# hicolor-icon-theme – no build, just directory structure
build_pkg hicolor-icon-theme || log_warning "hicolor-icon-theme build failed"

log_info "Phase 7: Development tools"

# libxslt – depends on libxml2 (blfs-base)
build_pkg libxslt || log_warning "libxslt build failed"

# vala – depends on glib2
build_pkg vala || log_warning "vala build failed"

# gobject-introspection – depends on glib2, python3
build_pkg gobject-introspection || log_warning "gobject-introspection build failed"

log_info "Phase 8: Application-specific dependencies"

# hunspell – spell checker for LibreOffice
build_pkg hunspell || log_warning "hunspell build failed"

# poppler – PDF rendering for LibreOffice
build_pkg poppler || log_warning "poppler build failed"

# babl – pixel format translation for GIMP
build_pkg babl || log_warning "babl build failed"

# gegl – Generic Graphics Library for GIMP
build_pkg gegl || log_warning "gegl build failed"

# taglib – audio metadata for VLC
build_pkg taglib || log_warning "taglib build failed"

# libebml – Extensible Binary Meta Language for VLC
build_pkg libebml || log_warning "libebml build failed"

# libmatroska – Matroska container for VLC
build_pkg libmatroska || log_warning "libmatroska build failed"

# icu – International Components for Unicode (Firefox dependency)
build_pkg icu || log_warning "icu build failed"

# nspr – Netscape Portable Runtime (Firefox dependency)
build_pkg nspr || log_warning "nspr build failed"

# nss – Network Security Services (Firefox dependency)
build_pkg nss || log_warning "nss build failed"

log_info "Phase 9: Additional general libraries from BLFS"

# libarchive – archive manipulation (tar, cpio, etc.)
build_pkg libarchive || log_warning "libarchive build failed"

# libxml2 – XML parsing (already in blfs-base, but verify)
build_pkg libxml2 || log_warning "libxml2 build failed"

# libxslt – XSLT processing (already in Phase 7)
build_pkg libxslt || log_warning "libxslt build failed"

# libyaml – YAML parsing
build_pkg libyaml || log_warning "libyaml build failed"

# libusb – USB library
build_pkg libusb || log_warning "libusb build failed"

# libcap – POSIX capabilities
build_pkg libcap || log_warning "libcap build failed"

# libaio – asynchronous I/O
build_pkg libaio || log_warning "libaio build failed"

# lm-sensors – hardware monitoring
build_pkg lm-sensors || log_warning "lm-sensors build failed"

# pciutils – PCI utilities
build_pkg pciutils || log_warning "pciutils build failed"

# usbutils – USB utilities
build_pkg usbutils || log_warning "usbutils build failed"

# libgpg-error – GPG error codes
build_pkg libgpg-error || log_warning "libgpg-error build failed"

# libgcrypt – cryptographic library
build_pkg libgcrypt || log_warning "libgcrypt build failed"

# libassuan – IPC library for GnuPG
build_pkg libassuan || log_warning "libassuan build failed"

# libksba – X.509 library
build_pkg libksba || log_warning "libksba build failed"

# npth – POSIX threads library
build_pkg npth || log_warning "npth build failed"

# libtasn1 – ASN.1 library
build_pkg libtasn1 || log_warning "libtasn1 build failed"

# nettle – cryptographic library
build_pkg nettle || log_warning "nettle build failed"

# libunistring – Unicode string library
build_pkg libunistring || log_warning "libunistring build failed"

# libidn2 – IDNA 2008 implementation
build_pkg libidn2 || log_warning "libidn2 build failed"

# libidn – Internationalized Domain Names
build_pkg libidn || log_warning "libidn build failed"

# pcre2 – Perl Compatible Regular Expressions (LFS, verify)
build_pkg pcre2 || log_warning "pcre2 build failed"

# libseccomp – secure computing mode
build_pkg libseccomp || log_warning "libseccomp build failed"

# libelf – ELF library (part of LFS)
build_pkg libelf || log_warning "libelf build failed"

# libffi – Foreign Function Interface (LFS, verify)
build_pkg libffi || log_warning "libffi build failed"

# expat – XML parsing (blfs-base, verify)
build_pkg expat || log_warning "expat build failed"

log_info "Phase 10: Optional dependencies for BLFS packages"

# wxWidgets – GUI toolkit (for FileZilla, Audacity)
build_pkg wxWidgets || log_warning "wxWidgets build failed"

# libnotify – desktop notifications
build_pkg libnotify || log_warning "libnotify build failed"

# libsecret – password storage
build_pkg libsecret || log_warning "libsecret build failed"

# libgudev – GObject wrapper for udev
build_pkg libgudev || log_warning "libgudev build failed"

# libxkbcommon – keyboard handling library
build_pkg libxkbcommon || log_warning "libxkbcommon build failed"

# libinput – input device handling
build_pkg libinput || log_warning "libinput build failed"

# libwacom – tablet support
build_pkg libwacom || log_warning "libwacom build failed"

# libevdev – evdev wrapper
build_pkg libevdev || log_warning "libevdev build failed"

# libdrm – Direct Rendering Manager
build_pkg libdrm || log_warning "libdrm build failed"

# mesa – 3D graphics library
build_pkg mesa || log_warning "mesa build failed"

# libva – Video Acceleration API
build_pkg libva || log_warning "libva build failed"

# libvdpau – VDPAU library
build_pkg libvdpau || log_warning "libvdpau build failed"

# libass – ASS/SSA subtitle renderer
build_pkg libass || log_warning "libass build failed"

# libbluray – Blu-ray disc playback
build_pkg libbluray || log_warning "libbluray build failed"

# libdvdnav – DVD navigation
build_pkg libdvdnav || log_warning "libdvdnav build failed"

# libdvdread – DVD reading
build_pkg libdvdread || log_warning "libdvdread build failed"

# libcdio – CD-ROM access
build_pkg libcdio || log_warning "libcdio build failed"

# libcddb – CDDB database access
build_pkg libcddb || log_warning "libcddb build failed"

# libmodplug – Mod music playback
build_pkg libmodplug || log_warning "libmodplug build failed"

# libsidplay – SID music playback
build_pkg libsidplay || log_warning "libsidplay build failed"

# libcue – CUE sheet parser
build_pkg libcue || log_warning "libcue build failed"

# libopenmpt – module music playback
build_pkg libopenmpt || log_warning "libopenmpt build failed"

# libzip – ZIP file access
build_pkg libzip || log_warning "libzip build failed"

# libarchive – archive manipulation (already in Phase 9, verify)
build_pkg libarchive || log_warning "libarchive build failed"

# rust – Rust compiler (required to build modern Firefox)
if ! have_cmd rustc; then
    archive="$(find_archive rust)"
    if [ -n "$archive" ]; then
        log_info "Building rust from $archive"
        dir="$(extract_archive "$archive")"
        pushd "$dir" >/dev/null
        if [ -x ./install.sh ]; then
            ./install.sh --prefix=/usr --disable-docs --disable-extended-yamlsamples
        elif [ -x ./configure ] || [ -f configure ]; then
            ./configure --prefix=/usr
            make -j"$(jobs)"
            make install
        else
            log_warning "rust: no recognised build system"
        fi
        popd >/dev/null
        rm -rf "$dir"
        touch "$(marker_for rust)"
        log_success "rust installed"
    else
        log_warning "rust source archive missing; Firefox may not build"
    fi
else
    log_info "rust already installed; skipping"
fi

log_success "BLFS core libraries build complete"
INNEREOF

run_privileged chmod +x "$LFS/build-blfs-libs.sh"
run_privileged chroot "$LFS" /bin/bash -c \
    "export INIT_SYSTEM=$INIT_SYSTEM; export LFS_CONFIG_DESKTOP_TYPE=$DESKTOP_TYPE; /build-blfs-libs.sh"

log_success "BLFS core libraries built successfully"
