#!/bin/bash
# 09b-build-gnome.sh
# Build GNOME desktop environment (called by 09-build-desktop.sh dispatcher).
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

log_info "========================================="
log_info "Building GNOME desktop environment"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – installing minimal GNOME session config"
    run_privileged mkdir -pv "$LFS"/usr/share/xsessions "$LFS"/usr/bin "$LFS"/var/lib/lfs-builder/desktop
    run_privileged tee "$LFS/usr/share/xsessions/gnome.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Name=GNOME
Comment=GNOME Desktop
Exec=gnome-session
Type=Application
DesktopNames=GNOME
EOF
    run_privileged tee "$LFS/var/lib/lfs-builder/desktop/gnome-packages.list" >/dev/null <<'EOF'
mutter gnome-shell gnome-session gnome-settings-daemon
gnome-control-center gdm nautilus gnome-terminal gedit
EOF
    log_success "GNOME Docker configuration installed"
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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-gnome.sh" >/dev/null
#!/bin/bash
set -euo pipefail
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }
cd /sources
mkdir -p /var/lib/lfs-builder/desktop-gnome /usr/share/xsessions /usr/share/wayland-sessions
JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/desktop-gnome/$1.done"; }
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
        gsettings-desktop-schemas) have_pc gsettings-desktop-schemas ;;
        libadwaita)                have_pc libadwaita-1 ;;
        libnotify)                 have_pc libnotify ;;
        dconf)                     have_pc dconf ;;
        gcr-4)                     have_pc gcr-4 ;;
        glib-networking)           have_pc gio-2.0 && [ -f /etc/glib-networking/tls/gnutls/gtlsconnection-gnutls.pem ] ;;
        libsoup3)                  have_pc libsoup-3.0 ;;
        libpeas)                   have_pc libpeas-1.0 ;;
        gsound)                    have_pc gsound ;;
        gnome-autoar)              have_pc gnome-autoar-0 ;;
        libgnomekbd)               have_pc libgnomekbd ;;
        gdm)                       have_cmd gdm ;;
        mutter)                    have_pc libmutter-15 ;;
        gnome-shell)               have_cmd gnome-shell ;;
        gnome-session)             have_cmd gnome-session ;;
        gnome-settings-daemon)     have_cmd gnome-settings-daemon ;;
        gnome-control-center)      have_cmd gnome-control-center ;;
        gnome-keyring)             have_cmd gnome-keyring-daemon ;;
        gnome-backgrounds)         [ -d /usr/share/backgrounds/gnome ] ;;
        gnome-menus)               have_pc gnome-menus-3.0 ;;
        adwaita-icon-theme)        [ -d /usr/share/icons/Adwaita ] ;;
        nautilus)                  have_cmd nautilus ;;
        gnome-terminal)            have_cmd gnome-terminal ;;
        gedit)                     have_cmd gedit ;;
        gnome-system-monitor)      have_cmd gnome-system-monitor ;;
        gnome-screenshot)          have_cmd gnome-screenshot ;;
        yelp)                      have_cmd yelp ;;
        gnome-calculator)          have_cmd gnome-calculator ;;
        gnome-logs)                have_cmd gnome-logs ;;
        *) return 1 ;;
    esac
}

build_pkg() {
    local pkg="$1" archive dir extra_opts=""
    shift
    extra_opts="$*"
    if is_installed "$pkg"; then log_info "$pkg already installed; skipping"; return 0; fi
    archive="$(find_archive "$pkg")"
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
        make -j"$JOBS"
        make install
    elif [ -x ./autogen.sh ]; then
        # shellcheck disable=SC2086
        ./autogen.sh --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static $extra_opts
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

verify_prerequisites() {
    local missing=() pc
    for pc in glib-2.0 gtk4 gtk+-3.0 pango cairo gdk-pixbuf-2.0 dbus-1 libsystemd wayland-client wayland-protocols libxkbcommon; do
        have_pc "$pc" 2>/dev/null || missing+=("$pc")
    done
    if [ "${#missing[@]}" -ne 0 ]; then
        log_error "Missing GNOME prerequisites: ${missing[*]}"
        log_error "Build blfs-libs, xorg, and wayland before this stage."
        exit 1
    fi
}
verify_prerequisites

log_info "Building GNOME foundation layer"
build_pkg gsettings-desktop-schemas || log_warning "gsettings-desktop-schemas failed"
build_pkg libnotify               || log_warning "libnotify failed"
build_pkg dconf                    || log_warning "dconf failed"
build_pkg gcr-4                    || log_warning "gcr-4 failed"
build_pkg glib-networking          || log_warning "glib-networking failed"
build_pkg libsoup3                || log_warning "libsoup3 failed"
build_pkg libpeas                  || log_warning "libpeas failed"
build_pkg gsound                   || log_warning "gsound failed"
build_pkg gnome-autoar             || log_warning "gnome-autoar failed"
build_pkg libgnomekbd              || log_warning "libgnomekbd failed"
build_pkg libadwaita               || log_warning "libadwaita failed"

log_info "Building GNOME core"
build_pkg gnome-menus              || log_warning "gnome-menus failed"
build_pkg gnome-backgrounds        || log_warning "gnome-backgrounds failed"
build_pkg adwaita-icon-theme       || log_warning "adwaita-icon-theme failed"
build_pkg gnome-keyring            || log_warning "gnome-keyring failed"
build_pkg gnome-online-accounts    || log_warning "gnome-online-accounts failed"
build_pkg gnome-settings-daemon    || log_warning "gnome-settings-daemon failed"
build_pkg mutter \
    -Dtests=false \
    -Dwayland=true \
    -Dx11=true \
    -Dnative_backend=true \
    || log_warning "mutter failed"
build_pkg gnome-shell              || log_warning "gnome-shell failed"
build_pkg gnome-session            || log_warning "gnome-session failed"
build_pkg gnome-control-center    || log_warning "gnome-control-center failed"
build_pkg gdm \
    -Dplymouth=disabled \
    || log_warning "gdm failed"

log_info "Building GNOME applications"
build_pkg nautilus                 || log_warning "nautilus failed"
build_pkg gnome-terminal           || log_warning "gnome-terminal failed"
build_pkg gedit                    || log_warning "gedit failed"
build_pkg gnome-system-monitor     || log_warning "gnome-system-monitor failed"
build_pkg gnome-screenshot         || log_warning "gnome-screenshot failed"
build_pkg yelp                     || log_warning "yelp failed"
build_pkg gnome-calculator         || log_warning "gnome-calculator failed"
build_pkg gnome-logs               || log_warning "gnome-logs failed"

# Install GNOME session files
cat > /usr/share/xsessions/gnome.desktop <<'EOF'
[Desktop Entry]
Name=GNOME
Comment=GNOME Desktop
Exec=gnome-session
Type=Application
DesktopNames=GNOME
EOF

cat > /usr/share/wayland-sessions/gnome.desktop <<'EOF'
[Desktop Entry]
Name=GNOME on Wayland
Comment=GNOME Desktop (Wayland)
Exec=gnome-session --session=gnome
Type=Application
DesktopNames=GNOME
EOF

# Configure GDM if installed
if have_cmd gdm; then
    mkdir -p /etc/gdm
    cat > /etc/gdm/custom.conf <<'GDMCONF'
[daemon]
WaylandEnable=false
AutomaticLogin=lfsuser
AutomaticLoginEnable=true
GDMCONF
    # Enable gdm service
    if have_cmd systemctl; then
        systemctl enable gdm 2>/dev/null || true
    fi
fi

# Create gsettings defaults
mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-gnome-defaults <<'GCONF'
[org/gnome/desktop/interface]
gtk-theme='Adwaita'
icon-theme='Adwaita'
font-name='Cantarell 11'

[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/gnome/default.jpg'

[org/gnome/desktop/screensaver]
lock-enabled=false
GCONF

# Compile dconf database
if have_cmd dconf; then
    dconf update 2>/dev/null || true
fi

log_success "GNOME desktop installation complete"
INNEREOF

run_privileged chmod +x "$LFS/build-gnome.sh"
run_privileged chroot "$LFS" /bin/bash /build-gnome.sh
log_success "GNOME desktop environment installed successfully"
