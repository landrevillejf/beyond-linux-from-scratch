#!/bin/bash
# 09d-build-lxqt.sh
# Build LXQt desktop environment (called by 09-build-desktop.sh dispatcher).
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# Error policy (audit finding F-07): a required package failure aborts the
# stage.  Only packages that are explicitly optional (missing from
# packages/stable/12.4/sources.list) may fail with a warning.
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

log_info "========================================="
log_info "Building LXQt desktop environment"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – installing minimal LXQt session config"
    run_privileged mkdir -pv "$LFS"/usr/share/xsessions "$LFS"/var/lib/lfs-builder/desktop
    run_privileged tee "$LFS/usr/share/xsessions/lxqt.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Name=LXQt
Comment=LXQt Desktop
Exec=lxqt-session
Type=Application
DesktopNames=LXQt
EOF
    log_success "LXQt Docker configuration installed"
    exit 0
fi

[ -x "$LFS/bin/bash" ] || { log_error "/bin/bash not found in $LFS/bin – run lfs-basic first"; exit 1; }

mount_chroot_fs() {
    run_privileged mkdir -p "$LFS"/{dev,dev/pts,proc,sys,run,sources}
    run_privileged mountpoint -q "$LFS/dev" || run_privileged mount --bind /dev "$LFS/dev"
    run_privileged mountpoint -q "$LFS/dev/pts" || run_privileged mount -t devpts devpts "$LFS/dev/pts"
    run_privileged mountpoint -q "$LFS/proc" || run_privileged mount -t proc proc "$LFS/proc"
    run_privileged mountpoint -q "$LFS/sys" || run_privileged mount -t sysfs sysfs "$LFS/sys"
    run_privileged mountpoint -q "$LFS/run" || run_privileged mount -t tmpfs tmpfs "$LFS/run"
}
cleanup() {
    for m in dev/pts dev proc sys run; do
        if run_privileged mountpoint -q "$LFS/$m" && ! run_privileged umount "$LFS/$m" 2>/dev/null; then
            log_warning "Could not unmount $LFS/$m"
        fi
    done
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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-lxqt.sh" >/dev/null
#!/bin/bash
set -euo pipefail
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }
cd /sources
mkdir -p /var/lib/lfs-builder/desktop-lxqt /usr/share/xsessions
JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/desktop-lxqt/$1.done"; }
find_archive() { compgen -G "${1}-*.tar.*" 2>/dev/null | sort -V | tail -n 1; }
extract_archive() {
    local archive="$1" dir
    dir="$(tar -tf "$archive" | head -n 1 | cut -d/ -f1)"
    rm -rf "$dir"; tar -xf "$archive"; printf '%s\n' "$dir"
}
have_pc() { pkg-config --exists "$1" 2>/dev/null; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_installed() {
    local pkg="$1"
    [ -f "$(marker_for "$pkg")" ] && return 0
    case "$pkg" in
        lxqt-build-tools)    [ -d /usr/share/cmake/lxqt-build-tools ] ;;
        libqtxdg)            have_pc qtxdg ;;
        liblxqt)             have_pc lxqt ;;
        libsysstat)          have_pc sysstat-qt ;;
        libfm-qt)            have_pc libfm-qt ;;
        menu-cache)          have_pc libmenu-cache ;;
        pcmanfm-qt)          have_cmd pcmanfm-qt ;;
        lxqt-panel)          have_cmd lxqt-panel ;;
        lxqt-session)        have_cmd lxqt-session ;;
        lxqt-config)         have_cmd lxqt-config ;;
        lxqt-policykit)      have_cmd lxqt-policykit-agent ;;
        lxqt-openssh-askpass) have_cmd lxqt-openssh-askpass ;;
        lxqt-powermanagement) have_cmd lxqt-powermanagment ;;
        lxqt-qtplugin)       have_pc lxqt-qtplugin ;;
        lxqt-sudo)           have_cmd lxqt-sudo ;;
        lxqt-themes)         [ -d /usr/share/lxqt/themes ] ;;
        lxqt-admin)          have_cmd lxqt-admin-user ;;
        lxqt-globalkeys)     have_cmd lxqt-globalkeyshortcuts ;;
        lxqt-notificationd)  have_cmd lxqt-notificationd ;;
        lxqt-runner)         have_cmd lxqt-runner ;;
        lxqt-wallet)         have_pc lxqtwallet ;;
        openbox)             have_cmd openbox ;;
        obconf-qt)           have_cmd obconf-qt ;;
        *) return 1 ;;
    esac
}

build_pkg() {
    local pkg="$1" archive dir extra_opts=""
    shift
    extra_opts="$*"
    if is_installed "$pkg"; then log_info "$pkg already installed; skipping"; return 0; fi
    archive="$(find_archive "$pkg")"
    if [ -z "$archive" ]; then
        log_error "Source archive missing for $pkg"
        return 1
    fi
    log_info "Building $pkg from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
    if [ -f CMakeLists.txt ]; then
        mkdir -p build
        cd build
        # shellcheck disable=SC2086
        cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_TESTING=OFF $extra_opts
        make -j"$JOBS"
        make install
        cd ..
    elif [ -x ./configure ] || [ -f configure ]; then
        # shellcheck disable=SC2086
        ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static $extra_opts
        make -j"$JOBS"
        make install
    else
        log_error "$pkg has no recognised build system"; popd >/dev/null; return 1
    fi
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for "$pkg")"
    log_success "$pkg installed"
}

# Policy wrapper (audit finding F-07).  required: any failure aborts the
# stage.  optional: failures are logged and the build continues.
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

verify_prerequisites() {
    local missing=() pc
    for pc in glib-2.0 gtk+-3.0 cairo pango gdk-pixbuf-2.0 dbus-1 Qt6Core Qt6Widgets Qt6WaylandClient; do
        have_pc "$pc" 2>/dev/null || missing+=("$pc")
    done
    if ! have_cmd cmake; then
        missing+=("cmake (required for LXQt builds)")
    fi
    if [ "${#missing[@]}" -ne 0 ]; then
        log_error "Missing LXQt prerequisites: ${missing[*]}"
        log_error "Build blfs-libs, xorg, and wayland before this stage."
        exit 1
    fi
}
verify_prerequisites

log_info "Building LXQt build tools and libraries"
run_build required lxqt-build-tools
run_build required libqtxdg
run_build required liblxqt
run_build required libsysstat
run_build required menu-cache
run_build required libfm-qt

log_info "Building LXQt core components"
run_build required lxqt-themes
run_build required lxqt-qtplugin
run_build required lxqt-globalkeys
run_build required lxqt-notificationd
run_build required lxqt-powermanagement
run_build required lxqt-policykit
run_build required lxqt-openssh-askpass
run_build required lxqt-sudo
run_build required lxqt-admin
# lxqt-wallet is not in packages/stable/12.4/sources.list
run_build optional lxqt-wallet
run_build required lxqt-runner

log_info "Building LXQt applications"
run_build required pcmanfm-qt
run_build required lxqt-panel
run_build required lxqt-session
run_build required lxqt-config

log_info "Building window manager (OpenBox)"
run_build required openbox
run_build required obconf-qt

# Install LXQt session files
cat > /usr/share/xsessions/lxqt.desktop <<'EOF'
[Desktop Entry]
Name=LXQt
Comment=LXQt Desktop
Exec=lxqt-session
Type=Application
DesktopNames=LXQt
EOF

# Configure LXQt default session
mkdir -p /etc/xdg/lxqt
cat > /etc/xdg/lxqt/session.conf <<'LXCONF'
[General]
window_manager=openbox
LXCONF

# Create LXQt autostart for openbox
mkdir -p /etc/xdg/lxqt/autostart
cat > /etc/xdg/lxqt/autostart/openbox.desktop <<'AUTOSTART'
[Desktop Entry]
Name=Openbox
Comment=Start Openbox window manager
Exec=openbox
Type=Application
AUTOSTART

# Configure display manager (LightDM) for LXQt
if [ -f /etc/lightdm/lightdm.conf ]; then
    sed -i 's/^user-session=.*/user-session=lxqt/' /etc/lightdm/lightdm.conf \
        || log_warning "Could not set user-session in lightdm.conf"
    sed -i 's/^autologin-session=.*/autologin-session=lxqt/' /etc/lightdm/lightdm.conf \
        || log_warning "Could not set autologin-session in lightdm.conf"
    sed -i 's|^session-wrapper=.*|session-wrapper=/usr/bin/lxqt-session|' /etc/lightdm/lightdm.conf \
        || log_warning "Could not set session-wrapper in lightdm.conf"
fi

# Set up environment variables
mkdir -p /etc/profile.d
cat > /etc/profile.d/lxqt.sh <<'LXENV'
export XDG_CURRENT_DESKTOP=LXQt
export XDG_SESSION_DESKTOP=lxqt
LXENV

log_success "LXQt desktop installation complete"
INNEREOF

run_privileged chmod +x "$LFS/build-lxqt.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-lxqt.sh
log_success "LXQt desktop environment installed successfully"
