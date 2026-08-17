#!/bin/bash
# 09c-build-kde.sh
# Build KDE Plasma desktop environment (called by 09-build-desktop.sh dispatcher).
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
log_info "Building KDE Plasma desktop environment"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – installing minimal KDE session config"
    run_privileged mkdir -pv "$LFS"/usr/share/xsessions "$LFS"/usr/share/wayland-sessions "$LFS"/var/lib/lfs-builder/desktop
    run_privileged tee "$LFS/usr/share/xsessions/plasma.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Name=Plasma
Comment=KDE Plasma Desktop
Exec=startplasma-x11
Type=Application
DesktopNames=KDE
EOF
    run_privileged tee "$LFS/usr/share/wayland-sessions/plasma.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Name=Plasma (Wayland)
Comment=KDE Plasma Desktop (Wayland)
Exec=startplasma-wayland
Type=Application
DesktopNames=KDE
EOF
    log_success "KDE Docker configuration installed"
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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-kde.sh" >/dev/null
#!/bin/bash
set -euo pipefail
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }
cd /sources
mkdir -p /var/lib/lfs-builder/desktop-kde /usr/share/xsessions /usr/share/wayland-sessions /usr/share/plasma
JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/desktop-kde/$1.done"; }
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
        extra-cmake-modules) have_cmd cmake && [ -d /usr/share/ECM ] ;;
        qt6-qtbase)          have_pc Qt6Core ;;
        qt6-qttools)         have_pc Qt6Linguist ;;
        qt6-qtdeclarative)   have_pc Qt6Quick ;;
        qt6-qtsvg)           have_pc Qt6Svg ;;
        qt6-qtwayland)       have_pc Qt6WaylandClient ;;
        attica)              have_pc KF6Attica ;;
        karchive)            have_pc KF6Archive ;;
        kcodecs)             have_pc KF6Codecs ;;
        kconfig)             have_pc KF6Config ;;
        kcoreaddons)         have_pc KF6CoreAddons ;;
        kdbusaddons)         have_pc KF6DBusAddons ;;
        kguiaddons)          have_pc KF6GuiAddons ;;
        ki18n)               have_pc KF6I18n ;;
        kitemmodels)         have_pc KF6ItemModels ;;
        kitemviews)          have_pc KF6ItemViews ;;
        kwidgetsaddons)     have_pc KF6WidgetsAddons ;;
        kwindowsystem)       have_pc KF6WindowSystem ;;
        solid)               have_pc KF6Solid ;;
        sonnet)              have_pc KF6Sonnet ;;
        kconfigwidgets)     have_pc KF6ConfigWidgets ;;
        kcompletion)         have_pc KF6Completion ;;
        kcrash)              have_pc KF6Crash ;;
        kglobalaccel)        have_pc KF6GlobalAccel ;;
        kiconthemes)         have_pc KF6IconThemes ;;
        kjobwidgets)         have_pc KF6JobWidgets ;;
        knotifications)      have_pc KF6Notifications ;;
        kservice)            have_pc KF6Service ;;
        ktextwidgets)        have_pc KF6TextWidgets ;;
        kxmlgui)             have_pc KF6XmlGui ;;
        kbookmarks)          have_pc KF6Bookmarks ;;
        kio)                 have_pc KF6KIO ;;
        kinit)               [ -x /usr/libexec/kf6/kioslave ] || have_pc KF6KIO ;;
        kirigami)            have_pc KirigamiWidgets ;;
        kwayland)            have_pc KWaylandClient ;;
        libksysguard)        have_pc KSysGuardSystemProcesses ;;
        kwin)                have_cmd kwin_x11 || have_cmd kwin_wayland ;;
        plasma-workspace)    have_cmd plasmashell ;;
        plasma-desktop)     [ -d /usr/share/plasma/desktop ] ;;
        sddm)                have_cmd sddm ;;
        dolphin)             have_cmd dolphin ;;
        konsole)             have_cmd konsole ;;
        kate)                have_cmd kate ;;
        okular)              have_cmd okular ;;
        breeze)              [ -d /usr/share/plasma/look-and-feel/org.kde.breeze.desktop ] ;;
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
    if [ -f CMakeLists.txt ]; then
        mkdir -p build
        cd build
        # shellcheck disable=SC2086
        cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_TESTING=OFF -DKF6_BUILD_DOCS=OFF $extra_opts
        make -j"$JOBS"
        make install
        cd ..
    elif [ -f meson.build ]; then
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
    for pc in glib-2.0 gtk+-3.0 cairo pango gdk-pixbuf-2.0 dbus-1 wayland-client libxkbcommon libdrm xkbcommon; do
        have_pc "$pc" 2>/dev/null || missing+=("$pc")
    done
    if ! have_cmd cmake; then
        missing+=("cmake (required for KDE/Qt builds)")
    fi
    if ! have_cmd ninja; then
        missing+=("ninja (required for Qt6 builds)")
    fi
    if [ "${#missing[@]}" -ne 0 ]; then
        log_error "Missing KDE prerequisites: ${missing[*]}"
        log_error "Build blfs-libs, xorg, and wayland before this stage."
        exit 1
    fi
}
verify_prerequisites

log_info "Building Qt6 layer"
build_pkg extra-cmake-modules   || log_warning "extra-cmake-modules failed"
build_pkg qt6-qtbase \
    -DQT_BUILD_TESTS=OFF \
    -DBUILD_SHARED_LIBS=ON \
    || log_warning "qt6-qtbase failed"
build_pkg qt6-qttools            || log_warning "qt6-qttools failed"
build_pkg qt6-qtdeclarative     || log_warning "qt6-qtdeclarative failed"
build_pkg qt6-qtsvg             || log_warning "qt6-qtsvg failed"
build_pkg qt6-qtwayland         || log_warning "qt6-qtwayland failed"

log_info "Building KDE Frameworks (Tier 1)"
build_pkg attica                || log_warning "attica failed"
build_pkg karchive              || log_warning "karchive failed"
build_pkg kcodecs               || log_warning "kcodecs failed"
build_pkg kconfig               || log_warning "kconfig failed"
build_pkg kcoreaddons           || log_warning "kcoreaddons failed"
build_pkg kdbusaddons           || log_warning "kdbusaddons failed"
build_pkg kguiaddons            || log_warning "kguiaddons failed"
build_pkg ki18n                 || log_warning "ki18n failed"
build_pkg kitemmodels           || log_warning "kitemmodels failed"
build_pkg kitemviews            || log_warning "kitemviews failed"
build_pkg kwidgetsaddons        || log_warning "kwidgetsaddons failed"
build_pkg kwindowsystem         || log_warning "kwindowsystem failed"
build_pkg solid                 || log_warning "solid failed"
build_pkg sonnet                || log_warning "sonnet failed"

log_info "Building KDE Frameworks (Tier 2-3)"
build_pkg kconfigwidgets        || log_warning "kconfigwidgets failed"
build_pkg kcompletion           || log_warning "kcompletion failed"
build_pkg kcrash                || log_warning "kcrash failed"
build_pkg kglobalaccel          || log_warning "kglobalaccel failed"
build_pkg kiconthemes           || log_warning "kiconthemes failed"
build_pkg kjobwidgets           || log_warning "kjobwidgets failed"
build_pkg knotifications        || log_warning "knotifications failed"
build_pkg kservice              || log_warning "kservice failed"
build_pkg ktextwidgets          || log_warning "ktextwidgets failed"
build_pkg kxmlgui               || log_warning "kxmlgui failed"
build_pkg kbookmarks            || log_warning "kbookmarks failed"
build_pkg kio                   || log_warning "kio failed"
build_pkg kinit                 || log_warning "kinit failed"
build_pkg kirigami              || log_warning "kirigami failed"

log_info "Building Plasma"
build_pkg kwayland              || log_warning "kwayland failed"
build_pkg libksysguard          || log_warning "libksysguard failed"
build_pkg libkscreen            || log_warning "libkscreen failed"
build_pkg kscreenlocker         || log_warning "kscreenlocker failed"
build_pkg breeze                || log_warning "breeze failed"
build_pkg kde-gtk-config        || log_warning "kde-gtk-config failed"
build_pkg kactivitymanagerd     || log_warning "kactivitymanagerd failed"
build_pkg kwin \
    -DCMAKE_INSTALL_PREFIX=/usr \
    || log_warning "kwin failed"
build_pkg plasma-workspace      || log_warning "plasma-workspace failed"
build_pkg plasma-desktop        || log_warning "plasma-desktop failed"
build_pkg plasma-nm             || log_warning "plasma-nm failed"
build_pkg plasma-pa             || log_warning "plasma-pa failed"
build_pkg powerdevil            || log_warning "powerdevil failed"
build_pkg sddm \
    -DCMAKE_INSTALL_PREFIX=/usr \
    || log_warning "sddm failed"
build_pkg sddm-kcm              || log_warning "sddm-kcm failed"
build_pkg systemsettings        || log_warning "systemsettings failed"

log_info "Building KDE applications"
build_pkg dolphin               || log_warning "dolphin failed"
build_pkg konsole               || log_warning "konsole failed"
build_pkg kate                  || log_warning "kate failed"
build_pkg kcalc                 || log_warning "kcalc failed"
build_pkg okular                || log_warning "okular failed"

# Install KDE session files
cat > /usr/share/xsessions/plasma.desktop <<'EOF'
[Desktop Entry]
Name=Plasma
Comment=KDE Plasma Desktop
Exec=startplasma-x11
Type=Application
DesktopNames=KDE
EOF

cat > /usr/share/wayland-sessions/plasma.desktop <<'EOF'
[Desktop Entry]
Name=Plasma (Wayland)
Comment=KDE Plasma Desktop (Wayland)
Exec=startplasma-wayland
Type=Application
DesktopNames=KDE
EOF

# Configure SDDM
if have_cmd sddm; then
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/kde-settings.conf <<'SDDMCONF'
[Theme]
Current=breeze

[Autologin]
User=lfsuser
Session=plasma
SDDMCONF
    # Enable sddm service
    if have_cmd systemctl; then
        systemctl enable sddm 2>/dev/null || true
    fi
    # Create sddm user/group
    getent group sddm >/dev/null 2>&1 || groupadd -r sddm 2>/dev/null || true
    getent passwd sddm >/dev/null 2>&1 || useradd -r -g sddm -d /var/lib/sddm -s /sbin/nologin sddm 2>/dev/null || true
    mkdir -p /var/lib/sddm /var/lib/sddm/.config
    chown -R sddm:sddm /var/lib/sddm 2>/dev/null || true
fi

# Set up environment variables
mkdir -p /etc/profile.d
cat > /etc/profile.d/kde.sh <<'KDEENV'
export XDG_CURRENT_DESKTOP=KDE
export KDE_FULL_SESSION=true
export QT_QPA_PLATFORMTHEME=qt5ct
KDEENV

log_success "KDE Plasma desktop installation complete"
INNEREOF

run_privileged chmod +x "$LFS/build-kde.sh"
run_privileged chroot "$LFS" /bin/bash /build-kde.sh
log_success "KDE Plasma desktop environment installed successfully"
