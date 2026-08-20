#!/bin/bash
set -euo pipefail
# 08a-build-blfs-libs.sh
# Build BLFS core libraries (glib2, cairo, pango, dbus, gdk-pixbuf, etc.)
# These are the foundational libraries required by all desktop environments.
# Author : Jean-Francois Landreville, landrevvillejf@protonmail.com, 2026.
#
# Error policy (audit finding F-07): a required package failure aborts the
# stage.  Only packages that are explicitly optional (application-specific
# dependencies or packages missing from packages/stable/12.4/sources.list)
# are allowed to fail with a warning.
#
# Book compliance (audit finding F-07, wave 3): every package that has a
# page in the BLFS book (docs/books) is built with the exact commands of
# that page through a dedicated build_<name> function.  Packages without a
# book page fall back to the generic build_pkg auto-detection.

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

JOBS="$(nproc 2>/dev/null || echo 1)"
HAVE_SYSTEMD=false
marker_for() { echo "/var/lib/lfs-builder/blfs-libs/$1.done"; }
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

# Find and extract the source archive of a package, printing the
# extracted directory name.
prep_src() {
    local pkg="$1" archive="" base
    for base in $(archive_names "$pkg"); do
        archive="$(find_archive "$base")"
        [ -n "$archive" ] && break
    done
    if [ -z "$archive" ]; then
        log_error "Source archive missing for $pkg"
        return 1
    fi
    log_info "Building $pkg from $archive"
    extract_archive "$archive"
}

# Run the BLFS book commands of one package inside its freshly
# extracted source tree.  The second argument is the name of the
# build_commands_<name> function holding the book commands; JOBS
# (make -j value), dir (source directory name, for versioned
# --docdir paths) and HAVE_SYSTEMD are exported.
book_install() {
    local pkg="$1" dir build_cmds
    build_cmds="$2" 
    if is_installed "$pkg"; then
        log_info "$pkg already installed; skipping"
        return 0
    fi
    dir="$(prep_src "$pkg")" || return 1
    pushd "$dir" >/dev/null || return 1
    if ! JOBS="$JOBS" dir="$dir" HAVE_SYSTEMD="$HAVE_SYSTEMD" "$build_cmds"; then
        popd >/dev/null
        return 1
    fi
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for "$pkg")"
    log_success "$pkg installed"
}

# Generic fallback for packages that have no BLFS book page:
# auto-detect meson vs autotools vs cmake.  Returns non-zero on any
# failure, including a missing source archive.
build_pkg() {
    local pkg="$1" dir extra_opts=""
    shift
    extra_opts="$*"
    if is_installed "$pkg"; then log_info "$pkg already installed; skipping"; return 0; fi
    dir="$(prep_src "$pkg")" || return 1
    pushd "$dir" >/dev/null || return 1
    if [ -f meson.build ]; then
        rm -rf builddir
        # shellcheck disable=SC2086
        meson setup builddir --prefix=/usr --buildtype=release --sysconfdir=/etc --localstatedir=/var $extra_opts
        ninja -C builddir
        ninja -C builddir install
    elif [ -x ./configure ] || [ -f configure ]; then
        # shellcheck disable=SC2086
        ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static $extra_opts
        make -j"$JOBS"
        make install
    elif [ -x ./autogen.sh ]; then
        # shellcheck disable=SC2086
        ./autogen.sh --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static $extra_opts
        make -j"$JOBS"
        make install
    elif [ -f CMakeLists.txt ]; then
        # shellcheck disable=SC2086
        cmake -B builddir -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release $extra_opts
        cmake --build builddir -j"$JOBS"
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
# Per-package BLFS book commands (wave 3).  Each build_<name> function
# reproduces the build commands of its BLFS page; optional patches and
# documentation steps are guarded so a missing extra tarball never
# breaks the build.
# ======================================================================

# BLFS general/libpng
build_libpng() { book_install libpng build_commands_libpng; }

build_commands_libpng() {
    for p in ../libpng-*-apng.patch.gz; do
        [ -f "$p" ] && gzip -cd "$p" | patch -Np1
    done
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS general/libjpeg
build_libjpeg_turbo() { book_install libjpeg-turbo build_commands_libjpeg_turbo; }

build_commands_libjpeg_turbo() {
    mkdir build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D CMAKE_BUILD_TYPE=RELEASE \
          -D ENABLE_STATIC=FALSE \
          -D CMAKE_INSTALL_DEFAULT_LIBDIR=lib \
          -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
          -D CMAKE_SKIP_INSTALL_RPATH=ON \
          -D CMAKE_INSTALL_DOCDIR="/usr/share/doc/$dir" .. &&
    make -j"$JOBS" && make install
}

# BLFS general/giflib – plain make build, no configure
build_giflib() { book_install giflib build_commands_giflib; }

build_commands_giflib() {
    for p in ../giflib-*-upstream_fixes-*.patch ../giflib-*-security_fixes-*.patch; do
        [ -f "$p" ] && patch -Np1 -i "$p"
    done
    [ -f pic/gifgrid.gif ] && cp pic/gifgrid.gif doc/giflib-logo.gif
    make &&
    make PREFIX=/usr install &&
    rm -fv /usr/lib/libgif.a &&
    find doc \( -name "Makefile*" -o -name "*.1" -o -name "*.xml" \) -exec rm -v {} \; &&
    install -v -dm755 "/usr/share/doc/$dir" &&
    cp -v -R doc/* "/usr/share/doc/$dir"
}

# BLFS general/libtiff
build_tiff() { book_install tiff build_commands_tiff; }

build_commands_tiff() {
    mkdir -p libtiff-build && cd libtiff-build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr .. \
          -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
          -G Ninja \
          -D CMAKE_INSTALL_DOCDIR="/usr/share/doc/$dir" &&
    ninja && ninja install
}

# BLFS general/libwebp
build_libwebp() { book_install libwebp build_commands_libwebp; }

build_commands_libwebp() {
    ./configure --prefix=/usr \
                --enable-libwebpmux \
                --enable-libwebpdemux \
                --enable-libwebpdecoder \
                --enable-libwebpextras \
                --enable-swap-16bit-csp \
                --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS general/freetype2
build_freetype() { book_install freetype build_commands_freetype; }

build_commands_freetype() {
    for d in ../freetype-doc-*.tar.xz; do
        [ -f "$d" ] && tar -xf "$d" --strip-components=2 -C docs
    done
    sed -ri "s:.*(AUX_MODULES.*valid):\1:" modules.cfg &&
    sed -r "s:.*(#.*SUBPIXEL_RENDERING) .*:\1:" \
        -i include/freetype/config/ftoption.h &&
    ./configure --prefix=/usr --enable-freetype-config --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS general/fontconfig
build_fontconfig() { book_install fontconfig build_commands_fontconfig; }

build_commands_fontconfig() {
    ./configure --prefix=/usr \
                --sysconfdir=/etc \
                --localstatedir=/var \
                --disable-docs \
                --docdir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install
}

# BLFS general/glib2 – introspection stays disabled; gobject-introspection
# is built standalone later in this stage.
build_glib2() { book_install glib2 build_commands_glib2; }

build_commands_glib2() {
    [ -f ../glib-skip_warnings-1.patch ] &&
        patch -Np1 -i ../glib-skip_warnings-1.patch
    man_pages=disabled
    command -v rst2man >/dev/null 2>&1 && man_pages=enabled
    mkdir build && cd build &&
    meson setup .. \
          --prefix=/usr \
          --buildtype=release \
          -D introspection=disabled \
          -D glib_debug=disabled \
          -D man-pages="$man_pages" \
          -D sysprof=disabled &&
    ninja && ninja install
}

# BLFS x/graphene
build_graphene() { book_install graphene build_commands_graphene; }

build_commands_graphene() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS general/harfbuzz – graphite2 only when present
build_harfbuzz() { book_install harfbuzz build_commands_harfbuzz; }

build_commands_harfbuzz() {
    mkdir build && cd build
    if pkg-config --exists graphite2 2>/dev/null; then
        meson setup .. --prefix=/usr --buildtype=release -D graphite2=enabled
    else
        meson setup .. --prefix=/usr --buildtype=release
    fi
    ninja && ninja install
}

# BLFS general/json-glib
build_json_glib() { book_install json-glib build_commands_json_glib; }

build_commands_json_glib() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS gnome/libgee – vala bindings only when valac is available
build_libgee() { book_install libgee build_commands_libgee; }

build_commands_libgee() {
    if command -v valac >/dev/null 2>&1; then
        ./configure --prefix=/usr --enable-vala
    else
        ./configure --prefix=/usr
    fi
    make -j"$JOBS" && make install
}

# BLFS general/pixman
build_pixman() { book_install pixman build_commands_pixman; }

build_commands_pixman() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS x/cairo
build_cairo() { book_install cairo build_commands_cairo; }

build_commands_cairo() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS general/fribidi
build_fribidi() { book_install fribidi build_commands_fribidi; }

build_commands_fribidi() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS x/pango – introspection only when g-i is already available
build_pango() { book_install pango build_commands_pango; }

build_commands_pango() {
    intro=disabled
    pkg-config --exists gobject-introspection-1.0 2>/dev/null && intro=enabled
    mkdir build && cd build &&
    meson setup .. \
              --prefix=/usr \
              --buildtype=release \
              --wrap-mode=nofallback \
              -D introspection="$intro" &&
    ninja && ninja install
}

# BLFS general/dbus – systemd support depends on the active init system
build_dbus() { book_install dbus build_commands_dbus; }

build_commands_dbus() {
    if [ "$HAVE_SYSTEMD" = true ]; then sd=enabled; else sd=disabled; fi
    mkdir build && cd build &&
    meson setup --prefix=/usr \
                --buildtype=release \
                --wrap-mode=nofallback \
                -D systemd="$sd" \
                .. &&
    ninja && ninja install
}

# BLFS general/dbus-glib
build_dbus_glib() { book_install dbus-glib build_commands_dbus_glib; }

build_commands_dbus_glib() {
    ./configure --prefix=/usr \
                --sysconfdir=/etc \
                --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS x/at-spi2-core – systemd_user_dir=/tmp is the sysvinit workaround
build_at_spi2_core() { book_install at-spi2-core build_commands_at_spi2_core; }

build_commands_at_spi2_core() {
    mkdir build && cd build
    if [ "$HAVE_SYSTEMD" = true ]; then
        meson setup .. --prefix=/usr --buildtype=release -D gtk2_atk_adaptor=false
    else
        meson setup .. --prefix=/usr --buildtype=release \
            -D gtk2_atk_adaptor=false -D systemd_user_dir=/tmp
    fi
    ninja && ninja install
}

# BLFS x/gdk-pixbuf
build_gdk_pixbuf() { book_install gdk-pixbuf build_commands_gdk_pixbuf; }

build_commands_gdk_pixbuf() {
    mkdir build && cd build &&
    meson setup .. \
          --prefix=/usr \
          --buildtype=release \
          -D others=enabled \
          --wrap-mode=nofallback &&
    ninja && ninja install
}

# BLFS general/shared-mime-info – xdgmime helper only when shipped
build_shared_mime_info() { book_install shared-mime-info build_commands_shared_mime_info; }

build_commands_shared_mime_info() {
    if [ -f ../xdgmime.tar.xz ]; then
        tar -xf ../xdgmime.tar.xz && make -C xdgmime
        updatemimedb=true
    else
        updatemimedb=false
    fi
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release \
        -D update-mimedb="$updatemimedb" .. &&
    ninja && ninja install
}

# BLFS x/hicolor-icon-theme
build_hicolor_icon_theme() { book_install hicolor-icon-theme build_commands_hicolor_icon_theme; }

build_commands_hicolor_icon_theme() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS general/libxslt
build_libxslt() { book_install libxslt build_commands_libxslt; }

build_commands_libxslt() {
    ./configure --prefix=/usr \
                --disable-static \
                --docdir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install
}

# BLFS general/vala
build_vala() { book_install vala build_commands_vala; }

build_commands_vala() {
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

# BLFS general/babl
build_babl() { book_install babl build_commands_babl; }

build_commands_babl() {
    mkdir bld && cd bld &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS general/gegl
build_gegl() { book_install gegl build_commands_gegl; }

build_commands_gegl() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS multimedia/taglib
build_taglib() { book_install taglib build_commands_taglib; }

build_commands_taglib() {
    mkdir build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D CMAKE_BUILD_TYPE=Release \
          -D BUILD_SHARED_LIBS=ON \
          .. &&
    make -j"$JOBS" && make install
}

# BLFS general/icu – configure lives in the source/ subdirectory
build_icu() { book_install icu build_commands_icu; }

build_commands_icu() {
    cd source &&
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

# BLFS general/nspr – book seds + mozilla/pthreads flags
build_nspr() { book_install nspr build_commands_nspr; }

build_commands_nspr() {
    cd nspr
    sed -i "/^RELEASE/s|^|#|" pr/src/misc/Makefile.in
    sed -i "s|\$(LIBRARY) ||" config/rules.mk
    if [ "$(uname -m)" = x86_64 ]; then bit=--enable-64bit; else bit=; fi
    ./configure --prefix=/usr \
        --with-mozilla \
        --with-pthreads \
        $bit
    make -j"$JOBS" && make install
}

# BLFS postlfs/nss – plain make into dist/, manual install
build_nss() { book_install nss build_commands_nss; }

build_commands_nss() {
    [ -f ../nss-standalone-1.patch ] && patch -Np1 -i ../nss-standalone-1.patch
    cd nss
    opts="BUILD_OPT=1 NSPR_INCLUDE_DIR=/usr/include/nspr USE_SYSTEM_ZLIB=1
          ZLIB_LIBS=-lz NSS_ENABLE_WERROR=0"
    [ "$(uname -m)" = x86_64 ] && opts="$opts USE_64=1"
    [ -f /usr/include/sqlite3.h ] && opts="$opts NSS_USE_SYSTEM_SQLITE=1"
    # shellcheck disable=SC2086  # word splitting is intended here
    make $opts
    cd ../dist
    install -v -m755 Linux*/lib/*.so /usr/lib
    install -v -m644 Linux*/lib/*.chk /usr/lib
    install -v -m644 Linux*/lib/libcrmf.a /usr/lib
    install -v -m755 -d /usr/include/nss
    cp -v -RL public/nss/* /usr/include/nss
    cp -v -RL private/nss/* /usr/include/nss
    install -v -m755 Linux*/bin/certutil /usr/bin
    install -v -m755 Linux*/bin/nss-config /usr/bin
    install -v -m755 Linux*/bin/pk12util /usr/bin
    install -v -m644 Linux*/lib/pkgconfig/nss.pc /usr/lib/pkgconfig
}

# BLFS general/poppler – poppler-data shipped separately when present
build_poppler() { book_install poppler build_commands_poppler; }

build_commands_poppler() {
    mkdir build && cd build &&
    cmake -D CMAKE_BUILD_TYPE=Release \
          -D CMAKE_INSTALL_PREFIX=/usr \
          -D TESTDATADIR="$PWD/testfiles" \
          -D ENABLE_QT5=OFF \
          -D ENABLE_UNSTABLE_API_ABI_HEADERS=ON \
          -G Ninja .. &&
    ninja && ninja install &&
    cd .. &&
    for t in ../poppler-data-*.tar.gz; do
        [ -f "$t" ] || continue
        tar -xf "$t"
        d="${t##*/}"
        make -C "${d%.tar.gz}" prefix=/usr install
    done
}

# BLFS general/libarchive
build_libarchive() { book_install libarchive build_commands_libarchive; }

build_commands_libarchive() {
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS general/libyaml
build_libyaml() { book_install libyaml build_commands_libyaml; }

build_commands_libyaml() {
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS general/libusb – doxygen documentation skipped
build_libusb() { book_install libusb build_commands_libusb; }

build_commands_libusb() {
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS postlfs/libcap – build commands of the LFS book chapter
build_libcap() { book_install libcap build_commands_libcap; }

build_commands_libcap() {
    make -j"$JOBS" &&
    make RAISE_SETFCAP=no lib=lib prefix=/usr install
}

# BLFS general/libaio
build_libaio() { book_install libaio build_commands_libaio; }

build_commands_libaio() {
    sed -i "/install.*libaio.a/s/^/#/" src/Makefile
    make -j"$JOBS" && make install
}

# BLFS general/lm-sensors
build_lm_sensors() { book_install lm-sensors build_commands_lm_sensors; }

build_commands_lm_sensors() {
    make PREFIX=/usr \
         BUILD_STATIC_LIB=0 \
         MANDIR=/usr/share/man \
         -j"$JOBS" &&
    make PREFIX=/usr BUILD_STATIC_LIB=0 MANDIR=/usr/share/man install
}

# BLFS general/pciutils – update-pciids and pci.ids are not installed
build_pciutils() { book_install pciutils build_commands_pciutils; }

build_commands_pciutils() {
    sed -r "/INSTALL/{/PCI_IDS|update-pciids /d; s/update-pciids.8//}" \
        -i Makefile
    make PREFIX=/usr \
         SHAREDIR=/usr/share/hwdata \
         SHARED=yes \
         -j"$JOBS" &&
    make PREFIX=/usr SHAREDIR=/usr/share/hwdata SHARED=yes install install-lib
}

# BLFS general/usbutils
build_usbutils() { book_install usbutils build_commands_usbutils; }

build_commands_usbutils() {
    mkdir build && cd build &&
    meson setup .. \
          --prefix=/usr \
          --buildtype=release &&
    ninja && ninja install
}

# BLFS general/libgpg-error
build_libgpg_error() { book_install libgpg-error build_commands_libgpg_error; }

build_commands_libgpg_error() {
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

# BLFS general/libgcrypt – html documentation skipped
build_libgcrypt() { book_install libgcrypt build_commands_libgcrypt; }

build_commands_libgcrypt() {
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

# BLFS general/libassuan – html documentation skipped
build_libassuan() { book_install libassuan build_commands_libassuan; }

build_commands_libassuan() {
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

# BLFS general/libksba
build_libksba() { book_install libksba build_commands_libksba; }

build_commands_libksba() {
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

# BLFS general/npth
build_npth() { book_install npth build_commands_npth; }

build_commands_npth() {
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

# BLFS general/libtasn1
build_libtasn1() { book_install libtasn1 build_commands_libtasn1; }

build_commands_libtasn1() {
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS postlfs/nettle
build_nettle() { book_install nettle build_commands_nettle; }

build_commands_nettle() {
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS general/libunistring
build_libunistring() { book_install libunistring build_commands_libunistring; }

build_commands_libunistring() {
    ./configure --prefix=/usr \
                --disable-static \
                --docdir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install
}

# BLFS general/libidn2
build_libidn2() { book_install libidn2 build_commands_libidn2; }

build_commands_libidn2() {
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS general/libidn
build_libidn() { book_install libidn build_commands_libidn; }

build_commands_libidn() {
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS general/pcre2
build_pcre2() { book_install pcre2 build_commands_pcre2; }

build_commands_pcre2() {
    ./configure --prefix=/usr \
                --docdir="/usr/share/doc/$dir" \
                --enable-unicode \
                --enable-jit \
                --enable-pcre2-16 \
                --enable-pcre2-32 \
                --enable-pcre2grep-libz \
                --enable-pcre2grep-libbz2 \
                --enable-pcre2test-libreadline \
                --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS general/libseccomp
build_libseccomp() { book_install libseccomp build_commands_libseccomp; }

build_commands_libseccomp() {
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS x/libnotify
build_libnotify() { book_install libnotify build_commands_libnotify; }

build_commands_libnotify() {
    mkdir build && cd build &&
    meson setup --prefix=/usr \
                --buildtype=release \
                -D gtk_doc=false \
                -D man=false \
                .. &&
    ninja && ninja install
}

# BLFS gnome/libsecret
build_libsecret() { book_install libsecret build_commands_libsecret; }

build_commands_libsecret() {
    mkdir bld && cd bld &&
    meson setup --prefix=/usr \
                --buildtype=release \
                -D gtk_doc=false \
                .. &&
    ninja && ninja install
}

# BLFS general/libgudev
build_libgudev() { book_install libgudev build_commands_libgudev; }

build_commands_libgudev() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS general/libxkbcommon
build_libxkbcommon() { book_install libxkbcommon build_commands_libxkbcommon; }

build_commands_libxkbcommon() {
    mkdir build && cd build &&
    meson setup .. \
          --prefix=/usr \
          --buildtype=release \
          -D enable-docs=false &&
    ninja && ninja install
}

# BLFS general/libwacom
build_libwacom() { book_install libwacom build_commands_libwacom; }

build_commands_libwacom() {
    mkdir build && cd build &&
    meson setup .. \
          --prefix=/usr \
          --buildtype=release \
          -D tests=disabled &&
    ninja && ninja install
}

# BLFS x/libdrm
build_libdrm() { book_install libdrm build_commands_libdrm; }

build_commands_libdrm() {
    mkdir build && cd build &&
    meson setup --prefix=/usr \
                --buildtype=release \
                -D udev=true \
                -D valgrind=disabled \
                .. &&
    ninja && ninja install
}

# BLFS x/mesa – xdemos patch applied only when shipped
build_mesa() { book_install mesa build_commands_mesa; }

build_commands_mesa() {
    for p in ../mesa-add_xdemos-*.patch; do
        [ -f "$p" ] && patch -Np1 -i "$p"
    done
    mkdir build && cd build &&
    meson setup .. \
          --prefix=/usr \
          --buildtype=release \
          -D platforms=x11,wayland \
          -D gallium-drivers=auto \
          -D vulkan-drivers=auto \
          -D valgrind=disabled \
          -D video-codecs=all \
          -D libunwind=disabled &&
    ninja && ninja install
}

# BLFS multimedia/libva – tarball ships an empty build/ directory
build_libva() { book_install libva build_commands_libva; }

build_commands_libva() {
    mkdir -p build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS multimedia/libvdpau
build_libvdpau() { book_install libvdpau build_commands_libvdpau; }

build_commands_libvdpau() {
    mkdir build && cd build &&
    meson setup --prefix=/usr .. &&
    ninja && ninja install
}

# BLFS multimedia/libass
build_libass() { book_install libass build_commands_libass; }

build_commands_libass() {
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS multimedia/libdvdnav
build_libdvdnav() { book_install libdvdnav build_commands_libdvdnav; }

build_commands_libdvdnav() {
    ./configure --prefix=/usr \
                --disable-static \
                --docdir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install
}

# BLFS multimedia/libdvdread
build_libdvdread() { book_install libdvdread build_commands_libdvdread; }

build_commands_libdvdread() {
    ./configure --prefix=/usr \
                --disable-static \
                --docdir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install
}

# BLFS multimedia/libcdio – libcdio-paranoia follows when shipped
build_libcdio() { book_install libcdio build_commands_libcdio; }

build_commands_libcdio() {
    sed "/CDIO_LSEEK/s/lseek64/lseek/" -i lib/driver/_cdio_generic.c
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install &&
    for t in ../libcdio-paranoia-*.tar.bz2; do
        [ -f "$t" ] || continue
        tar -xf "$t"
        d="${t##*/}"
        cd "${d%.tar.bz2}"
        ./configure --prefix=/usr --disable-static
        make -j"$JOBS"
        make install
        cd ..
    done
}

# BLFS multimedia/libcddb – freedb.org is gone, use gnudb
build_libcddb() { book_install libcddb build_commands_libcddb; }

build_commands_libcddb() {
    sed -e "/DEFAULT_SERVER/s/freedb.org/gnudb.gnudb.org/" \
        -e "/DEFAULT_PORT/s/888/&0/" \
        -i include/cddb/cddb_ni.h
    sed -i "s/size_t l;/socklen_t l;/" lib/cddb_net.c
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# Policy wrapper (audit finding F-07): a required package failure
# aborts the stage; optional failures are logged and the build
# continues.  Book commands live in the build_<name> functions above;
# packages without a BLFS book page use the generic build_pkg.
run_build() {
    local mode="$1" pkg="$2" fn
    shift 2
    fn="build_${pkg//-/_}"
    if declare -F "$fn" >/dev/null; then
        if "$fn" "$@"; then return 0; fi
    else
        if build_pkg "$pkg" "$@"; then return 0; fi
    fi
    if [ "$mode" = "required" ]; then
        log_error "Required package $pkg failed – aborting stage"
        exit 1
    fi
    log_warning "[OPTIONAL] $pkg failed or is missing – continuing"
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

# Detect if systemd is installed (for dbus/at-spi2-core meson options)
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
run_build required dbus

# dbus-glib – depends on dbus, glib2
run_build required dbus-glib

# at-spi2-core – depends on glib2, dbus
run_build required at-spi2-core

log_info "Phase 6: Image loading and MIME"

# gdk-pixbuf – depends on glib2, libpng, libjpeg-turbo, tiff
run_build required gdk-pixbuf

# shared-mime-info – depends on glib2, libxml2
run_build required shared-mime-info

# hicolor-icon-theme – icon directory structure
run_build required hicolor-icon-theme

log_info "Phase 7: Development tools"

# libxslt – depends on libxml2 (blfs-base)
run_build required libxslt

# vala – depends on glib2
run_build required vala

# gobject-introspection – depends on glib2, python3; no standalone page
# in the BLFS book (built inside glib there), generic meson build.
run_build required gobject-introspection

log_info "Phase 8: Application-specific dependencies"

# hunspell – spell checker (LibreOffice); no BLFS book page
run_build optional hunspell

# poppler – PDF rendering (LibreOffice)
run_build optional poppler

# babl – pixel format translation (GIMP)
run_build optional babl

# gegl – Generic Graphics Library (GIMP)
run_build optional gegl

# taglib – audio metadata (VLC)
run_build optional taglib

# libebml – Extensible Binary Meta Language (VLC); no BLFS book page
run_build optional libebml

# libmatroska – Matroska container (VLC); no BLFS book page
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

# wxWidgets – GUI toolkit (FileZilla, Audacity); no BLFS book page
run_build optional wxWidgets

# libnotify – desktop notifications
run_build optional libnotify

# libsecret – password storage
run_build optional libsecret

# libgudev – GObject wrapper for udev
run_build optional libgudev

# libxkbcommon – keyboard handling library (Wayland input)
run_build required libxkbcommon

# libinput – input device handling (Wayland); no BLFS book page
run_build required libinput

# libwacom – tablet support
run_build optional libwacom

# libevdev – evdev wrapper (libinput dependency); no BLFS book page
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

# libbluray – Blu-ray disc playback; no BLFS book page
run_build optional libbluray

# libdvdnav – DVD navigation
run_build optional libdvdnav

# libdvdread – DVD reading
run_build optional libdvdread

# libcdio – CD-ROM access
run_build optional libcdio

# libcddb – CDDB database access
run_build optional libcddb

# libmodplug – Mod music playback; no BLFS book page
run_build optional libmodplug

# libsidplay – not in packages/stable sources; optional
run_build optional libsidplay

# libcue – CUE sheet parser; no BLFS book page
run_build optional libcue

# libopenmpt – not in packages/stable sources; optional
run_build optional libopenmpt

# libzip – ZIP file access; no BLFS book page
run_build optional libzip

# rust – Rust compiler (required to build modern Firefox).  Not built
# from source here: the shipped rustc tarball is a prebuilt toolchain.
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
            make -j"$JOBS"
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
