#!/bin/bash
# 08b-build-xorg.sh
# Build Xorg display server, libraries, drivers, and GTK+3/GTK4.
# Follows BLFS Chapter 24 build order.
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
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

DESKTOP_TYPE="${LFS_CONFIG_DESKTOP_TYPE:-xfce}"
export DESKTOP_TYPE

log_info "========================================="
log_info "Building Xorg display server and libraries"
log_info "Desktop type: $DESKTOP_TYPE"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – creating minimal Xorg structure in $LFS"
    run_privileged mkdir -pv "$LFS"/etc/X11/xorg.conf.d "$LFS"/usr/share/X11/xkb \
        "$LFS"/usr/lib/xorg/modules
    log_success "Minimal Xorg structure created (Docker)"
    exit 0
fi

[ "$DESKTOP_TYPE" = "none" ] && { log_info "No desktop requested; skipping Xorg"; exit 0; }

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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-xorg.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/xorg /usr/lib/xorg/modules /etc/X11/xorg.conf.d \
    /usr/share/X11/xkb /usr/share/X11/xkb/rules /usr/share/pixmaps

jobs() { nproc 2>/dev/null || echo 1; }
marker_for() { echo "/var/lib/lfs-builder/xorg/$1.done"; }
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
        util-macros)        [ -f /usr/share/aclocal/xorg-macros.m4 ] ;;
        xorgproto)          have_pc xproto ;;
        libXau)             have_pc xau ;;
        libXdmcp)           have_pc xdmcp ;;
        xcb-proto)          [ -d /usr/share/xcb ] || have_pc xcb-proto ;;
        libxcb)             have_pc xcb ;;
        libX11)             have_pc x11 ;;
        libXext)            have_pc xext ;;
        libXrender)         have_pc xrender ;;
        libXrandr)          have_pc xrandr ;;
        libXfixes)          have_pc xfixes ;;
        libXi)              have_pc xi ;;
        libXcursor)         have_pc xcursor ;;
        libXinerama)        have_pc xinerama ;;
        libXcomposite)     have_pc xcomposite ;;
        libXdamage)         have_pc xdamage ;;
        libfontenc)         have_pc fontenc ;;
        libxkbfile)         have_pc xkbfile ;;
        libXtst)            have_pc xtst ;;
        libXScrnSaver)      have_pc xscrnsaver ;;
        libXv)              have_pc xv ;;
        libXvMC)            have_pc xvmc ;;
        libXxf86vm)         have_pc xxf86vm ;;
        libXres)            have_pc xres ;;
        libXpm)             have_pc xpm ;;
        libpciaccess)       have_pc pciaccess ;;
        libdrm)             have_pc libdrm ;;
        mesa)               have_pc gl ;;
        xcb-util)           have_pc xcb-aux ;;
        xcb-util-image)    have_pc xcb-image ;;
        xcb-util-keysyms)  have_pc xcb-keysyms ;;
        xcb-util-renderutil) have_pc xcb-renderutil ;;
        xcb-util-wm)        have_pc xcb-ewmh ;;
        xcb-util-cursor)   have_pc xcb-cursor ;;
        xkeyboard-config)   [ -d /usr/share/X11/xkb/rules/evdev ] || [ -f /usr/share/X11/xkb/rules/evdev.lst ] ;;
        xorg-server)        [ -x /usr/bin/Xorg ] || [ -x /usr/lib/Xorg ] ;;
        xf86-input-libinput) [ -f /usr/lib/xorg/modules/input/libinput_drv.so ] ;;
        xf86-video-amdgpu)  [ -f /usr/lib/xorg/modules/drivers/amdgpu_drv.so ] ;;
        xf86-video-ati)     [ -f /usr/lib/xorg/modules/drivers/radeon_drv.so ] ;;
        xf86-video-fbdev)   [ -f /usr/lib/xorg/modules/drivers/fbdev_drv.so ] ;;
        xf86-video-vesa)    [ -f /usr/lib/xorg/modules/drivers/vesa_drv.so ] ;;
        xf86-video-vmware)  [ -f /usr/lib/xorg/modules/drivers/vmware_drv.so ] ;;
        xinit)              [ -x /usr/bin/startx ] ;;
        twm)                [ -x /usr/bin/twm ] ;;
        xterm)              [ -x /usr/bin/xterm ] ;;
        xclock)             [ -x /usr/bin/xclock ] ;;
        xeyes)              [ -x /usr/bin/xeyes ] ;;
        libepoxy)           have_pc epoxy ;;
        gtk3)               have_pc gtk+-3.0 ;;
        gtk4)               have_pc gtk4 ;;
        *) return 1 ;;
    esac
}

# Generic package builder: meson, autotools, or cmake
build_pkg() {
    local pkg="$1" archive dir extra_opts=""
    shift
    extra_opts="$*"
    if is_installed "$pkg"; then log_info "$pkg already installed; skipping"; return 0; fi
    archive="$(find_archive "$pkg")"
    if [ -z "$archive" ]; then
        case "$pkg" in
            # gtk tarballs are named gtk-<version>, not gtk3-<version>.
            # Pin the major version so gtk3 and gtk4 cannot resolve to
            # each other's tarball.
            gtk3) archive="$(compgen -G 'gtk-3.*.tar.*' 2>/dev/null | sort -V | tail -n 1)" ;;
            gtk4) archive="$(compgen -G 'gtk-4.*.tar.*' 2>/dev/null | sort -V | tail -n 1)" ;;
            mesa) archive="$(find_archive Mesa)" ;;
        esac
    fi
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
        meson setup builddir --prefix=/usr --buildtype=release --sysconfdir=/etc $extra_opts
        ninja -C builddir
        ninja -C builddir install
    elif [ -x ./configure ] || [ -f configure ]; then
        # shellcheck disable=SC2086
        ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static $extra_opts
        make -j"$(jobs)"
        make install
    elif [ -f CMakeLists.txt ]; then
        # shellcheck disable=SC2086
        cmake -B builddir -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release $extra_opts
        cmake --build builddir -j"$(jobs)"
        cmake --install builddir
    else
        # Some packages are just installed with make install and no configure
        if [ -f Makefile ] || [ -x ./autogen.sh ]; then
            if [ -x ./autogen.sh ]; then
                # shellcheck disable=SC2086
                ./autogen.sh --prefix=/usr --sysconfdir=/etc $extra_opts
            fi
            make -j"$(jobs)"
            make install
        else
            log_error "$pkg has no recognised build system"; popd >/dev/null; return 1
        fi
    fi
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for "$pkg")"
    log_success "$pkg installed"
}

# Policy wrapper (audit finding F-07).  required: any failure aborts the
# stage.  optional: failures are logged and the build continues; used for
# packages not present in packages/stable/12.4/sources.list and for
# hardware-specific drivers.
run_build() {
    local mode="$1" pkg="$2"
    shift 2
    if build_pkg "$pkg" "$@"; then
        return 0
    fi
    if [ "$mode" = "required" ]; then
        log_error "Required package $pkg failed – aborting stage"
        exit 1
    fi
    log_warning "[OPTIONAL] $pkg failed or is missing – continuing"
}

# Verify BLFS libs prerequisites
verify_prerequisites() {
    local missing=() pc
    for pc in glib-2.0 cairo pango freetype2 fontconfig gdk-pixbuf-2.0; do
        if ! have_pc "$pc" 2>/dev/null; then
            missing+=("$pc")
        fi
    done
    if [ "${#missing[@]}" -ne 0 ]; then
        log_error "Missing BLFS library prerequisites: ${missing[*]}"
        log_error "Build blfs-libs stage (08a) before this stage."
        exit 1
    fi
}
verify_prerequisites

# ======================================================================
# Phase 1: Xorg protocol headers and build macros
# ======================================================================
log_info "Phase 1: Protocol headers and macros"
run_build required util-macros
run_build required xorgproto

# ======================================================================
# Phase 2: Core Xorg libraries (strict dependency order)
# ======================================================================
log_info "Phase 2: Core X libraries"
run_build required libXau
run_build required libXdmcp
run_build required xcb-proto
run_build required libxcb
run_build required libX11

# ======================================================================
# Phase 3: Extension libraries
# ======================================================================
log_info "Phase 3: Extension libraries"
run_build required libXext
run_build required libXrender
run_build required libXfixes
run_build required libXi
run_build required libXrandr
run_build required libXcursor
run_build required libXinerama
run_build required libXcomposite
run_build required libXdamage
run_build required libfontenc
run_build required libxkbfile
run_build required libXtst
run_build required libXScrnSaver
run_build required libXv
# libXvMC is not in the BLFS wget-list; legacy, optional
run_build optional libXvMC
run_build required libXxf86vm
run_build required libXres
run_build required libXpm

# ======================================================================
# Phase 4: DRM, Mesa (GL), and XCB utilities
# ======================================================================
log_info "Phase 4: DRM and Mesa"

run_build required libpciaccess
run_build required libdrm

# Mesa: build with software rendering (swrast) as a safe default.
# Hardware drivers requiring LLVM are optional and can be added later.
run_build required mesa \
    -Dgallium-drivers=swrast,zink \
    -Dvulkan-drivers=auto \
    -Ddri3=enabled \
    -Degl=enabled \
    -Dgles2=enabled \
    -Dglx=dri \
    -Dllvm=disabled \
    -Dosmesa=true

# XCB utility libraries
log_info "Phase 5: XCB utilities"
run_build required xcb-util
run_build required xcb-util-image
run_build required xcb-util-keysyms
run_build required xcb-util-renderutil
run_build required xcb-util-wm
run_build required xcb-util-cursor

# ======================================================================
# Phase 6: Xorg server and drivers
# ======================================================================
log_info "Phase 6: Xorg server and drivers"

run_build required xkeyboard-config

# Xorg server: build with DRI3, systemd optional
XORG_OPTS=""
if [ -d /usr/lib/systemd/system ]; then
    XORG_OPTS="-Dsystemd_logind=true"
fi
# shellcheck disable=SC2086  # XORG_OPTS is empty or one meson flag
run_build required xorg-server \
    -Dxorg=true \
    -Dxwayland=true \
    -Dglamor=true \
    -Dxvfb=true \
    -Dunitdir=/usr/lib/systemd/system \
    $XORG_OPTS

# Input driver
run_build required xf86-input-libinput

# Video drivers: hardware specific, not in the BLFS wget-list; optional
run_build optional xf86-video-amdgpu
run_build optional xf86-video-ati
run_build optional xf86-video-fbdev
run_build optional xf86-video-vesa
run_build optional xf86-video-vmware

# ======================================================================
# Phase 7: Xorg applications
# ======================================================================
log_info "Phase 7: Xorg applications"
run_build required xinit
# twm/xterm/xclock/xeyes are book test clients, not desktop requirements
run_build optional twm
run_build optional xterm
run_build optional xclock
run_build optional xeyes

# ======================================================================
# Phase 8: GL-dependent libraries (libepoxy, GTK+3, GTK4)
# These need Mesa/GL headers from the Xorg build above.
# ======================================================================
log_info "Phase 8: GL-dependent libraries (libepoxy, GTK)"

run_build required libepoxy

# GTK+3: requires glib2, cairo, pango, at-spi2-core, gdk-pixbuf, libepoxy,
# and X11 libraries (all built above).
run_build required gtk3 \
    -Dbroadway_backend=false \
    -Dx11_backend=true \
    -Dwayland_backend=false

# GTK4: requires glib2, cairo, pango, graphene, gdk-pixbuf, libepoxy.
# Required by the GNOME stack (09b); gtk-4.18 is in the source list.
run_build required gtk4 \
    -Dbroadway_backend=false \
    -Dx11_backend=true \
    -Dwayland_backend=false

log_success "Xorg display server and libraries build complete"
INNEREOF

run_privileged chmod +x "$LFS/build-xorg.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    LFS_CONFIG_DESKTOP_TYPE="$DESKTOP_TYPE" \
    /bin/bash /build-xorg.sh

log_success "Xorg display server built successfully"
