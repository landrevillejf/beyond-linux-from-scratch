#!/bin/bash
# 09b-build-gnome.sh
# Build GNOME desktop environment (called by 09-build-desktop.sh dispatcher).
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
        mutter)                    compgen -G '/usr/lib/pkgconfig/libmutter-*.pc' >/dev/null ;;
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
    if [ -z "$archive" ]; then
        case "$pkg" in
            # libsoup 3 tarballs are named libsoup-3.x, and gcr 4 tarballs
            # are named gcr-4.x (dot, not dash).
            libsoup3) archive="$(find_archive libsoup)" ;;
            gcr-4)    archive="$(compgen -G 'gcr-4.*.tar.*' 2>/dev/null | sort -V | tail -n 1)" ;;
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
run_build required gsettings-desktop-schemas
run_build required libnotify
run_build required dconf
run_build required gcr-4
run_build required glib-networking
run_build required libsoup3
run_build required libpeas
run_build required gsound
run_build required gnome-autoar
# libgnomekbd is not in packages/stable/12.4/sources.list
run_build optional libgnomekbd
run_build required libadwaita

log_info "Building GNOME core"
run_build required gnome-menus
run_build required gnome-backgrounds
run_build required adwaita-icon-theme
run_build required gnome-keyring
run_build required gnome-online-accounts
run_build required gnome-settings-daemon
run_build required mutter \
    -Dtests=false \
    -Dwayland=true \
    -Dx11=true \
    -Dnative_backend=true
run_build required gnome-shell
run_build required gnome-session
run_build required gnome-control-center
run_build required gdm \
    -Dplymouth=disabled

log_info "Building GNOME applications"
run_build required nautilus
run_build required gnome-terminal
run_build required gedit
run_build required gnome-system-monitor
run_build required gnome-screenshot
run_build required yelp
run_build required gnome-calculator
# gnome-logs is not in packages/stable/12.4/sources.list
run_build optional gnome-logs

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
        systemctl enable gdm 2>/dev/null \
            || log_warning "Could not enable gdm via systemctl"
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
    dconf update 2>/dev/null \
        || log_warning "dconf update failed (database will refresh on demand)"
fi

log_success "GNOME desktop installation complete"
INNEREOF

run_privileged chmod +x "$LFS/build-gnome.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-gnome.sh
log_success "GNOME desktop environment installed successfully"
