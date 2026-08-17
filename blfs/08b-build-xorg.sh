#!/bin/bash
# 08b-build-xorg.sh
# Build Xorg display server, libraries, drivers, and GTK+3/GTK4.
# Follows BLFS Chapter 24 build order.
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
            util-macros)     archive="$(find_archive util-macros)" ;;
            xorgproto)       archive="$(find_archive xorgproto) || archive=$(find_archive xproto-xorgproto)" ;;
            libXau)          archive="$(find_archive libXau)" ;;
            libXScrnSaver)   archive="$(find_archive libXScrnSaver)" ;;
            xcb-proto)       archive="$(find_archive xcb-proto)" ;;
            xkeyboard-config) archive="$(find_archive xkeyboard-config)" ;;
            xf86-input-libinput) archive="$(find_archive xf86-input-libinput)" ;;
            xf86-video-amdgpu) archive="$(find_archive xf86-video-amdgpu)" ;;
            xf86-video-ati)    archive="$(find_archive xf86-video-ati)" ;;
            xf86-video-fbdev)  archive="$(find_archive xf86-video-fbdev)" ;;
            xf86-video-vesa)   archive="$(find_archive xf86-video-vesa)" ;;
            xf86-video-vmware) archive="$(find_archive xf86-video-vmware)" ;;
            xorg-server)     archive="$(find_archive xorg-server)" ;;
            xinit)           archive="$(find_archive xinit)" ;;
            twm)             archive="$(find_archive twm)" ;;
            xterm)           archive="$(find_archive xterm)" ;;
            xclock)          archive="$(find_archive xclock)" ;;
            xeyes)           archive="$(find_archive xeyes)" ;;
            libepoxy)        archive="$(find_archive libepoxy)" ;;
            gtk3)            archive="$(find_archive gtk+-3) || archive=$(find_archive gtk+)" ;;
            gtk4)            archive="$(find_archive gtk-4) || archive=$(find_archive gtk4)" ;;
            mesa)            archive="$(find_archive mesa) || archive=$(find_archive Mesa)" ;;
        esac
    fi
    if [ -z "$archive" ]; then log_warning "Source archive missing for $pkg; skipping"; return 0; fi
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
build_pkg util-macros || log_warning "util-macros build failed"
build_pkg xorgproto || log_warning "xorgproto build failed"

# ======================================================================
# Phase 2: Core Xorg libraries (strict dependency order)
# ======================================================================
log_info "Phase 2: Core X libraries"
build_pkg libXau || log_warning "libXau build failed"
build_pkg libXdmcp || log_warning "libXdmcp build failed"
build_pkg xcb-proto || log_warning "xcb-proto build failed"
build_pkg libxcb || log_warning "libxcb build failed"
build_pkg libX11 || log_warning "libX11 build failed"

# ======================================================================
# Phase 3: Extension libraries
# ======================================================================
log_info "Phase 3: Extension libraries"
build_pkg libXext || log_warning "libXext build failed"
build_pkg libXrender || log_warning "libXrender build failed"
build_pkg libXfixes || log_warning "libXfixes build failed"
build_pkg libXi || log_warning "libXi build failed"
build_pkg libXrandr || log_warning "libXrandr build failed"
build_pkg libXcursor || log_warning "libXcursor build failed"
build_pkg libXinerama || log_warning "libXinerama build failed"
build_pkg libXcomposite || log_warning "libXcomposite build failed"
build_pkg libXdamage || log_warning "libXdamage build failed"
build_pkg libfontenc || log_warning "libfontenc build failed"
build_pkg libxkbfile || log_warning "libxkbfile build failed"
build_pkg libXtst || log_warning "libXtst build failed"
build_pkg libXScrnSaver || log_warning "libXScrnSaver build failed"
build_pkg libXv || log_warning "libXv build failed"
build_pkg libXvMC || log_warning "libXvMC build failed"
build_pkg libXxf86vm || log_warning "libXxf86vm build failed"
build_pkg libXres || log_warning "libXres build failed"
build_pkg libXpm || log_warning "libXpm build failed"

# ======================================================================
# Phase 4: DRM, Mesa (GL), and XCB utilities
# ======================================================================
log_info "Phase 4: DRM and Mesa"

build_pkg libpciaccess || log_warning "libpciaccess build failed"
build_pkg libdrm || log_warning "libdrm build failed"

# Mesa: build with software rendering (swrast) as a safe default.
# Hardware drivers requiring LLVM are optional and can be added later.
build_pkg mesa \
    -Dgallium-drivers=swrast,zink \
    -Dvulkan-drivers=auto \
    -Ddri3=enabled \
    -Degl=enabled \
    -Dgles2=enabled \
    -Dglx=dri \
    -Dllvm=disabled \
    -Dosmesa=true \
    || log_warning "mesa build failed (system will use software rendering)"

# XCB utility libraries
log_info "Phase 5: XCB utilities"
build_pkg xcb-util || log_warning "xcb-util build failed"
build_pkg xcb-util-image || log_warning "xcb-util-image build failed"
build_pkg xcb-util-keysyms || log_warning "xcb-util-keysyms build failed"
build_pkg xcb-util-renderutil || log_warning "xcb-util-renderutil build failed"
build_pkg xcb-util-wm || log_warning "xcb-util-wm build failed"
build_pkg xcb-util-cursor || log_warning "xcb-util-cursor build failed"

# ======================================================================
# Phase 6: Xorg server and drivers
# ======================================================================
log_info "Phase 6: Xorg server and drivers"

build_pkg xkeyboard-config || log_warning "xkeyboard-config build failed"

# Xorg server: build with DRI3, systemd optional
XORG_OPTS=""
if [ -d /usr/lib/systemd/system ]; then
    XORG_OPTS="-Dsystemd_logind=true"
fi
build_pkg xorg-server \
    -Dxorg=true \
    -Dxwayland=true \
    -Dglamor=true \
    -Dxvfb=true \
    -Dunitdir=/usr/lib/systemd/system \
    $XORG_OPTS \
    || log_warning "xorg-server build failed"

# Input driver
build_pkg xf86-input-libinput || log_warning "xf86-input-libinput build failed"

# Video drivers (all optional, build what's available)
build_pkg xf86-video-amdgpu || log_warning "xf86-video-amdgpu not built (optional)"
build_pkg xf86-video-ati || log_warning "xf86-video-ati not built (optional)"
build_pkg xf86-video-fbdev || log_warning "xf86-video-fbdev not built (optional)"
build_pkg xf86-video-vesa || log_warning "xf86-video-vesa not built (optional)"
build_pkg xf86-video-vmware || log_warning "xf86-video-vmware not built (optional)"

# ======================================================================
# Phase 7: Xorg applications
# ======================================================================
log_info "Phase 7: Xorg applications"
build_pkg xinit || log_warning "xinit build failed"
build_pkg twm || log_warning "twm build failed"
build_pkg xterm || log_warning "xterm build failed"
build_pkg xclock || log_warning "xclock build failed"
build_pkg xeyes || log_warning "xeyes build failed"

# ======================================================================
# Phase 8: GL-dependent libraries (libepoxy, GTK+3, GTK4)
# These need Mesa/GL headers from the Xorg build above.
# ======================================================================
log_info "Phase 8: GL-dependent libraries (libepoxy, GTK)"

build_pkg libepoxy || log_warning "libepoxy build failed"

# GTK+3: requires glib2, cairo, pango, at-spi2-core, gdk-pixbuf, libepoxy,
# and X11 libraries (all built above).
build_pkg gtk3 \
    -Dbroadway_backend=false \
    -Dx11_backend=true \
    -Dwayland_backend=false \
    || log_warning "gtk3 build failed"

# GTK4: requires glib2, cairo, pango, graphene, gdk-pixbuf, libepoxy.
build_pkg gtk4 \
    -Dbroadway_backend=false \
    -Dx11_backend=true \
    -Dwayland_backend=false \
    || log_warning "gtk4 build failed"

log_success "Xorg display server and libraries build complete"
INNEREOF

run_privileged chmod +x "$LFS/build-xorg.sh"
run_privileged chroot "$LFS" /bin/bash -c \
    "export LFS_CONFIG_DESKTOP_TYPE=$DESKTOP_TYPE; /build-xorg.sh"

log_success "Xorg display server built successfully"
