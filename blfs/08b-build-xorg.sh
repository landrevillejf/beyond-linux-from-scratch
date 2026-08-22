#!/bin/bash
set -euo pipefail
# 08b-build-xorg.sh
# Build Xorg display server, libraries, drivers, and GTK+3/GTK4.
# Follows BLFS Chapter 24 build order.
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# Error policy (audit finding F-07): a required package failure aborts the
# stage.  Only packages that are explicitly optional (hardware-specific
# drivers or packages missing from packages/stable/12.4/sources.list) are
# allowed to fail with a warning.
#
# Book compliance (audit finding F-07, wave 3): the Xorg libraries are
# built with the commands of the BLFS x/x7lib chapter loop, and every
# package that has its own page in docs/books gets a dedicated
# build_<name> function reproducing that page.

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

JOBS="$(nproc 2>/dev/null || echo 1)"
HAVE_SYSTEMD=false
marker_for() { echo "/var/lib/lfs-builder/xorg/$1.done"; }
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
        # Newest version wins: stale duplicates restored from the CI
        # packages cache must never shadow the book version (glob
        # order silently picks the oldest name, nightly #174).
        printf '%s\n' "${tier1[@]}" | sort -V | tail -n 1
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
        xwayland)           [ -x /usr/bin/Xwayland ] ;;
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

# Find and extract the source archive of a package, printing the
# extracted directory name.  gtk tarballs are named gtk-<major>.<...>,
# so the major version is pinned to keep gtk3 and gtk4 apart.
prep_src() {
    local pkg="$1" archive=""
    case "$pkg" in
        gtk3) archive="$(compgen -G 'gtk-3.*.tar.*' 2>/dev/null | sort -V | tail -n 1)" ;;
        gtk4) archive="$(compgen -G 'gtk-4.*.tar.*' 2>/dev/null | sort -V | tail -n 1)" ;;
        mesa) archive="$(find_archive mesa)"; [ -n "$archive" ] || archive="$(find_archive Mesa)" ;;
        *)    archive="$(find_archive "$pkg")" ;;
    esac
    if [ -z "$archive" ]; then
        log_error "Source archive missing for $pkg"
        return 1
    fi
    log_info "Building $pkg from $archive"
    extract_archive "$archive"
}

# Run the BLFS book commands of one package inside its freshly
# extracted source tree.  The second argument is the name of the
# build_commands_<name> function holding the book commands; JOBS,
# dir and HAVE_SYSTEMD are exported.
book_install() {
    local pkg="$1" build_cmds dir
    build_cmds="$2"
    if is_installed "$pkg"; then
        log_info "$pkg already installed; skipping"
        return 0
    fi
    dir="$(prep_src "$pkg")" || return 1
    pushd "$dir" >/dev/null || return 1
    if ! JOBS="$JOBS" dir="$dir" HAVE_SYSTEMD="$HAVE_SYSTEMD" pkg="$pkg" "$build_cmds"; then
        popd >/dev/null
        return 1
    fi
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for "$pkg")"
    log_success "$pkg installed"
}

# Generic fallback for packages that have no BLFS book page:
# auto-detect meson vs autotools vs cmake.
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
        meson setup builddir --prefix=/usr --buildtype=release --sysconfdir=/etc $extra_opts
        ninja -C builddir
        ninja -C builddir install
    elif [ -x ./configure ] || [ -f configure ]; then
        # shellcheck disable=SC2086
        ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static $extra_opts
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
# Per-package BLFS book commands (wave 3).
# ======================================================================

# Xorg libraries of the BLFS x/x7lib chapter: all of them are built
# with the loop command "./configure $XORG_CONFIG --docdir=... && make
# && make install" plus the case variants of the book loop.
build_commands_xorg_lib() {
    case "$pkg" in
        libXpm)
            ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
                --disable-static --docdir="/usr/share/doc/$dir" \
                --disable-open-zfile ;;
        libXt)
            ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
                --disable-static --docdir="/usr/share/doc/$dir" \
                --with-appdefaultdir=/etc/X11/app-defaults ;;
        libXfont2)
            ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
                --disable-static --docdir="/usr/share/doc/$dir" \
                --disable-devel-docs ;;
        *)
            ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
                --disable-static --docdir="/usr/share/doc/$dir" ;;
    esac
    make -j"$JOBS"
    make install
}
build_xorg_lib() {
    book_install "$1" build_commands_xorg_lib
}

# BLFS x/util-macros – configure only, no compilation
build_util_macros() { book_install util-macros build_commands_util_macros; }
build_commands_util_macros() {
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static
    make install
}

# BLFS x/xorgproto – meson without --buildtype, as in the book
build_xorgproto() { book_install xorgproto build_commands_xorgproto; }
build_commands_xorgproto() {
    mkdir build && cd build &&
    meson setup --prefix=/usr .. &&
    ninja && ninja install
}

# BLFS x/xcb-proto – needs PYTHON set explicitly
build_xcb_proto() { book_install xcb-proto build_commands_xcb_proto; }
build_commands_xcb_proto() {
    PYTHON=python3 ./configure --prefix=/usr --sysconfdir=/etc \
        --localstatedir=/var --disable-static
    make -j"$JOBS"
    make install
}

# BLFS x/libxcb – doxygen disabled, UTF-8 locale for make
build_libxcb() { book_install libxcb build_commands_libxcb; }
build_commands_libxcb() {
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
        --disable-static \
        --without-doxygen \
        --docdir="/usr/share/doc/$dir"
    LC_ALL=en_US.UTF-8 make -j"$JOBS"
    make install
}

# BLFS x/x7lib loop case for libpciaccess – meson build
build_libpciaccess() { book_install libpciaccess build_commands_libpciaccess; }
build_commands_libpciaccess() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
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

# BLFS x/mesa
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

# BLFS x/xkeyboard-config
build_xkeyboard_config() { book_install xkeyboard-config build_commands_xkeyboard_config; }
build_commands_xkeyboard_config() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS x/xorg-server – tearfree patch applied only when shipped;
# systemd_logind follows the detected init system.
build_xorg_server() { book_install xorg-server build_commands_xorg_server; }
build_commands_xorg_server() {
    for p in ../xorg-server-*-tearfree_backport-*.patch; do
        [ -f "$p" ] && patch -Np1 -i "$p"
    done
    logind=false
    [ "$HAVE_SYSTEMD" = true ] && logind=true
    mkdir build && cd build &&
    meson setup .. \
          --prefix=/usr \
          --localstatedir=/var \
          -D glamor=true \
          -D systemd_logind="$logind" \
          -D xkb_output_dir=/var/lib/xkb &&
    ninja && ninja install
}

# BLFS x/xwayland – standalone since xorg-server 21.1
build_xwayland() { book_install xwayland build_commands_xwayland; }
build_commands_xwayland() {
    sed -i '/install_man/,$d' meson.build
    mkdir build && cd build &&
    meson setup .. \
          --prefix=/usr \
          --buildtype=release \
          -D xkb_output_dir=/var/lib/xkb &&
    ninja && ninja install
}

# BLFS x/x7driver – xf86-input-libinput
build_xf86_input_libinput() { book_install xf86-input-libinput build_commands_xf86_input_libinput; }
build_commands_xf86_input_libinput() {
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static
    make -j"$JOBS"
    make install
}

# BLFS x/xinit – plus the book sed on startx
build_xinit() { book_install xinit build_commands_xinit; }
build_commands_xinit() {
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
        --disable-static --with-xinitdir=/etc/X11/app-defaults
    make -j"$JOBS"
    make install
    # shellcheck disable=SC2016  # $serverargs must stay literal in startx
    sed -i '/\$serverargs \$vtarg/ s/serverargs/: #&/' /usr/bin/startx
}

# BLFS x/twm
build_twm() { book_install twm build_commands_twm; }
build_commands_twm() {
    sed -i -e '/^rcdir =/s,^\(rcdir = \).*,\1/etc/X11/app-defaults,' src/Makefile.in
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static
    make -j"$JOBS"
    make install
}

# BLFS x/xterm
build_xterm() { book_install xterm build_commands_xterm; }
build_commands_xterm() {
    sed -i '/v0/{n;s/new:/new:kb=^?:/}' termcap
    printf '\tkbs=\\177,\n' >> terminfo
    TERMINFO=/usr/share/terminfo \
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
        --disable-static \
        --with-app-defaults=/etc/X11/app-defaults
    make -j"$JOBS"
    make install
}

# BLFS x/xclock
build_xclock() { book_install xclock build_commands_xclock; }
build_commands_xclock() {
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static
    make -j"$JOBS"
    make install
}

# BLFS x/libepoxy
build_libepoxy() { book_install libepoxy build_commands_libepoxy; }
build_commands_libepoxy() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS x/gtk3 – the wayland backend is only enabled when the wayland
# stack already exists (this stage may run before 08c).
build_gtk3() { book_install gtk3 build_commands_gtk3; }
build_commands_gtk3() {
    wayland=false
    pkg-config --exists wayland-client 2>/dev/null && wayland=true
    mkdir build && cd build &&
    meson setup .. \
          --prefix=/usr \
          --buildtype=release \
          -D man=true \
          -D broadway_backend=true \
          -D wayland_backend="$wayland" &&
    ninja && ninja install
}

# BLFS x/gtk4 – the book seds fix a 4.18 build error; vulkan and
# introspection follow the available dependencies.
build_gtk4() { book_install gtk4 build_commands_gtk4; }
build_commands_gtk4() {
    sed -e '939 s/= { 0, }//' \
        -e '940 a memset (&transform, 0, sizeof(GtkCssTransform));' \
        -i gtk/gtkcsstransformvalue.c
    wayland=false
    pkg-config --exists wayland-client 2>/dev/null && wayland=true
    vulkan=disabled
    pkg-config --exists vulkan 2>/dev/null && vulkan=enabled
    intro=disabled
    pkg-config --exists gobject-introspection-1.0 2>/dev/null && intro=enabled
    mkdir build && cd build &&
    meson setup --prefix=/usr \
                --buildtype=release \
                -D broadway-backend=true \
                -D wayland-backend="$wayland" \
                -D introspection="$intro" \
                -D vulkan="$vulkan" \
                .. &&
    ninja && ninja install
}

# Policy wrapper (audit finding F-07): a required package failure
# aborts the stage; optional failures are logged and the build
# continues.  The Xorg libraries of the x7lib chapter all use
# build_xorg_lib; packages with a dedicated page use their build_<name>
# function; everything else falls back to the generic build_pkg.
run_build() {
    local mode="$1" pkg="$2" fn
    shift 2
    fn="build_${pkg//-/_}"
    if declare -F "$fn" >/dev/null; then
        if "$fn" "$@"; then return 0; fi
    else
        case "$pkg" in
            libX*|libfontenc|libxkbfile|xcb-util*|xeyes)
                if build_xorg_lib "$pkg" "$@"; then return 0; fi ;;
            *)
                if build_pkg "$pkg" "$@"; then return 0; fi ;;
        esac
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

# Detect if systemd is installed (for xorg-server meson options)
if [ -x /usr/lib/systemd/systemd ] || [ -d /usr/lib/systemd/system ]; then
    HAVE_SYSTEMD=true
fi
log_info "systemd detected: $HAVE_SYSTEMD"

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

# Mesa follows the book flags (auto drivers); already built by 08a in
# most configurations and skipped through is_installed.
run_build required mesa

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

# Xorg server with the book meson flags
run_build required xorg-server

# Standalone Xwayland (split from xorg-server since 21.1)
run_build required xwayland

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
run_build required gtk3

# GTK4: requires glib2, cairo, pango, graphene, gdk-pixbuf, libepoxy.
# Required by the GNOME stack (09b); gtk-4.18 is in the source list.
run_build required gtk4

log_success "Xorg display server and libraries build complete"
INNEREOF

run_privileged chmod +x "$LFS/build-xorg.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    LFS_CONFIG_DESKTOP_TYPE="$DESKTOP_TYPE" \
    /bin/bash /build-xorg.sh

log_success "Xorg display server built successfully"
