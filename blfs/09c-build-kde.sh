#!/bin/bash
set -euo pipefail
# 09c-build-kde.sh
# Build KDE Plasma desktop environment (called by 09-build-desktop.sh dispatcher).
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# Error policy (audit finding F-07): a required package failure aborts the
# stage.  Only packages that are explicitly optional (missing from
# packages/stable/12.4/sources.list) may fail with a warning.
#
# Book compliance (audit finding F-07, wave 3): qt6, extra-cmake-modules,
# sddm, konsole, dolphin and okular get dedicated build functions
# reproducing their docs/books pages; KDE Frameworks and Plasma packages
# use the cmake commands of the book frameworks6/plasma-all chapter
# loops.  The book installs Qt6/KF6 into /opt; here everything goes to
# /usr to match the rest of the built system.  Packages without a book
# page (kate, kcalc, kinit) use the generic build_pkg fallback.

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
HAVE_SYSTEMD=false
marker_for() { echo "/var/lib/lfs-builder/desktop-kde/$1.done"; }
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
    rm -rf "$dir"; tar -xf "$archive"; printf '%s\n' "$dir"
}
have_pc() { pkg-config --exists "$1" 2>/dev/null; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_installed() {
    local pkg="$1"
    [ -f "$(marker_for "$pkg")" ] && return 0
    case "$pkg" in
        qt6)                 have_pc Qt6Core ;;
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

# Find and extract the source archive of a package, printing the
# extracted directory name.
prep_src() {
    local pkg="$1" archive=""
    archive="$(find_archive "$pkg")"
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
    if ! JOBS="$JOBS" dir="$dir" HAVE_SYSTEMD="$HAVE_SYSTEMD" "$build_cmds"; then
        popd >/dev/null
        return 1
    fi
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for "$pkg")"
    log_success "$pkg installed"
}

# Generic fallback for packages that have no BLFS book page
# (kate, kcalc, kinit).
build_pkg() {
    local pkg="$1" dir extra_opts=""
    shift
    extra_opts="$*"
    if is_installed "$pkg"; then log_info "$pkg already installed; skipping"; return 0; fi
    dir="$(prep_src "$pkg")" || return 1
    pushd "$dir" >/dev/null || return 1
    if [ -f CMakeLists.txt ]; then
        mkdir -p build
        cd build
        # shellcheck disable=SC2086
        cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_TESTING=OFF $extra_opts
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

# ======================================================================
# Per-package BLFS book commands (wave 3, kde chapter).
# ======================================================================

# BLFS x/qt6 – shipped as a single qt-everywhere-src tarball.  The book
# installs into /opt/qt6; here the prefix is /usr.
build_qt6() {
    local archive dir
    if have_pc Qt6Core; then log_info "qt6 already installed; skipping"; return 0; fi
    archive="$(find_archive qt-everywhere-src)"
    if [ -z "$archive" ]; then
        log_error "Source archive missing for qt6 (qt-everywhere-src)"
        return 1
    fi
    log_info "Building qt6 from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null || return 1
    if [ "$(uname -m)" = "i686" ]; then
        sed -e "/^#elif defined(Q_CC_GNU_ONLY)/s/.*/& \&\& 0/" \
             -i qtbase/src/corelib/global/qtypes.h
        CXXFLAGS="${CXXFLAGS:-} -DDISABLE_SIMD -DPFFFT_SIMD_DISABLE"
        export CXXFLAGS
    fi
    ./configure -prefix /usr              \
                -sysconfdir /etc/xdg      \
                -dbus-linked              \
                -openssl-linked           \
                -system-sqlite            \
                -nomake examples          \
                -no-rpath                 \
                -no-sbom                  \
                -syslog                   \
                -skip qt3d                \
                -skip qtquick3dphysics    \
                -skip qtwebengine         &&
    ninja &&
    ninja install &&
    find /usr/ -name '*.prl' -exec sed -i -e '/^QMAKE_PRL_BUILD_DIR/d' {} \;
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for qt6)"
    log_success "qt6 installed"
}

# BLFS kde/extra-cmake-modules
build_extra_cmake_modules() { book_install extra-cmake-modules build_commands_extra_cmake_modules; }
build_commands_extra_cmake_modules() {
    local p
    for p in ../extra-cmake-modules-*-upstream_fix-*.patch; do
        [ -f "$p" ] || continue
        patch -Np1 -i "$p" || return 1
    done
    # shellcheck disable=SC2016
    sed -i '/"lib64"/s/64//' kde-modules/KDEInstallDirsCommon.cmake &&
    sed -e '/PACKAGE_INIT/i set(SAVE_PACKAGE_PREFIX_DIR "${PACKAGE_PREFIX_DIR}")' \
        -e '/^include/a set(PACKAGE_PREFIX_DIR "${SAVE_PACKAGE_PREFIX_DIR}")' \
        -i ECMConfig.cmake.in &&
    mkdir build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr -D BUILD_WITH_QT6=ON .. &&
    make -j"$JOBS" && make install
}

# BLFS kde/frameworks6 chapter loop: every KDE Frameworks package is
# built with the same cmake command.
build_commands_kf6() {
    mkdir build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr        \
          -D CMAKE_INSTALL_LIBEXECDIR=libexec \
          -D CMAKE_SKIP_INSTALL_RPATH=ON      \
          -D CMAKE_BUILD_TYPE=Release         \
          -D BUILD_TESTING=OFF                \
          -D BUILD_PYTHON_BINDINGS=OFF        \
          -W no-dev .. &&
    make -j"$JOBS" && make install
}
build_kf6_pkg() { book_install "$1" build_commands_kf6; }

# BLFS kde/plasma-all chapter loop: every Plasma package is built with
# the same cmake command.
build_commands_plasma() {
    mkdir build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr        \
          -D CMAKE_INSTALL_LIBEXECDIR=libexec \
          -D CMAKE_BUILD_TYPE=Release         \
          -D BUILD_QT5=OFF                    \
          -D BUILD_TESTING=OFF                \
          -W no-dev .. &&
    make -j"$JOBS" && make install
}
build_plasma_pkg() { book_install "$1" build_commands_plasma; }

# BLFS x/sddm – elogind flags are the book sysvinit variant; systemd
# builds flip them.  The sddm.conf tweak comes from the book root cmds.
build_sddm() { book_install sddm build_commands_sddm || return 1; sddm_post_install; }
build_commands_sddm() {
    local sd_opts="-D NO_SYSTEMD=ON -D ENABLE_JOURNALD=OFF -D USE_ELOGIND=ON"
    [ "$HAVE_SYSTEMD" = true ] && sd_opts="-D NO_SYSTEMD=OFF -D ENABLE_JOURNALD=ON -D USE_ELOGIND=OFF"
    mkdir build && cd build
    # shellcheck disable=SC2086
    cmake -D CMAKE_INSTALL_PREFIX=/usr        \
          -D CMAKE_BUILD_TYPE=Release         \
          -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
          $sd_opts                            \
          -D RUNTIME_DIR=/run/sddm            \
          -D BUILD_MAN_PAGES=ON               \
          -D BUILD_WITH_QT6=ON                \
          -D DATA_INSTALL_DIR=/usr/share/sddm \
          -D DBUS_CONFIG_FILENAME=sddm_org.freedesktop.DisplayManager.conf \
          .. &&
    make -j"$JOBS" && make install
}
sddm_post_install() {
    if [ -f /etc/sddm.conf ]; then
        sed -i 's/-nolisten tcp//' /etc/sddm.conf
    fi
}

# BLFS kde/konsole
build_konsole() { book_install konsole build_commands_konsole; }
build_commands_konsole() {
    local p
    for p in ../konsole-adjust_scrollbar-*.patch; do
        [ -f "$p" ] || continue
        patch -Np1 -i "$p" || return 1
    done
    mkdir build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D CMAKE_BUILD_TYPE=Release  \
          -D BUILD_TESTING=OFF         \
          -W no-dev .. &&
    make -j"$JOBS" && make install
}

# BLFS kde/dolphin
build_dolphin() { book_install dolphin build_commands_dolphin; }
build_commands_dolphin() {
    mkdir build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D CMAKE_BUILD_TYPE=Release  \
          -D BUILD_TESTING=OFF         \
          -W no-dev .. &&
    make -j"$JOBS" && make install
}

# BLFS kde/okular
build_okular() { book_install okular build_commands_okular; }
build_commands_okular() {
    local skip_optional='Discount;DjVuLibre;EPub;LibSpectre;LibZip'
    mkdir build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D CMAKE_BUILD_TYPE=Release  \
          -D BUILD_TESTING=OFF         \
          -D FORCE_NOT_REQUIRED_DEPENDENCIES="$skip_optional" \
          -W no-dev .. &&
    make -j"$JOBS" && make install
}

# Policy wrapper (audit finding F-07).  required: any failure aborts the
# stage.  optional: failures are logged and the build continues.
# KDE Frameworks and Plasma packages get the book chapter loop commands;
# packages without a BLFS book page use the generic build_pkg.
run_build() {
    local mode="$1" pkg="$2" fn=""
    shift 2
    fn="build_${pkg//-/_}"
    if ! declare -F "$fn" >/dev/null; then
        case "$pkg" in
            attica|karchive|kcodecs|kconfig|kcoreaddons|kdbusaddons|kguiaddons|ki18n|kitemmodels|kitemviews|kwidgetsaddons|kwindowsystem|solid|sonnet|kconfigwidgets|kcompletion|kcrash|kglobalaccel|kiconthemes|kjobwidgets|knotifications|kservice|ktextwidgets|kxmlgui|kbookmarks|kio|kirigami)
                fn=build_kf6_pkg ;;
            kwayland|libksysguard|libkscreen|kscreenlocker|breeze|kde-gtk-config|kactivitymanagerd|kwin|plasma-workspace|plasma-desktop|plasma-nm|plasma-pa|powerdevil|sddm-kcm|systemsettings)
                fn=build_plasma_pkg ;;
            *)
                fn="" ;;
        esac
    fi
    if [ -n "$fn" ]; then
        if "$fn" "$pkg" "$@"; then
            return 0
        fi
    else
        if build_pkg "$pkg" "$@"; then
            return 0
        fi
    fi
    if [ "$mode" = "required" ]; then
        log_error "Required package $pkg failed – aborting stage"
        exit 1
    fi
    log_warning "[OPTIONAL] $pkg failed or is missing – continuing"
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

# Detect if systemd is installed (for sddm book sysvinit/systemd variants)
if [ -x /usr/lib/systemd/systemd ] || [ -d /usr/lib/systemd/system ]; then
    HAVE_SYSTEMD=true
fi
log_info "systemd detected: $HAVE_SYSTEMD"

log_info "Building Qt6 layer"
run_build required qt6
run_build required extra-cmake-modules

log_info "Building KDE Frameworks (Tier 1)"
# Only kconfig, kwindowsystem and solid are in the source list; the rest
# is kept optional until the KF6 set is added to sources.list.
run_build optional attica
run_build optional karchive
run_build optional kcodecs
run_build required kconfig
run_build optional kcoreaddons
run_build optional kdbusaddons
run_build optional kguiaddons
run_build optional ki18n
run_build optional kitemmodels
run_build optional kitemviews
run_build optional kwidgetsaddons
run_build required kwindowsystem
run_build required solid
run_build optional sonnet

log_info "Building KDE Frameworks (Tier 2-3)"
run_build optional kconfigwidgets
run_build optional kcompletion
run_build optional kcrash
run_build optional kglobalaccel
run_build optional kiconthemes
run_build optional kjobwidgets
run_build optional knotifications
run_build optional kservice
run_build optional ktextwidgets
run_build optional kxmlgui
run_build optional kbookmarks
run_build optional kio
run_build optional kinit
run_build optional kirigami

log_info "Building Plasma"
run_build required kwayland
run_build optional libksysguard
run_build required libkscreen
run_build optional kscreenlocker
run_build optional breeze
run_build optional kde-gtk-config
run_build optional kactivitymanagerd
run_build optional kwin
run_build optional plasma-workspace
run_build optional plasma-desktop
run_build optional plasma-nm
run_build optional plasma-pa
run_build optional powerdevil
run_build optional sddm
run_build optional sddm-kcm
run_build optional systemsettings

log_info "Building KDE applications"
run_build required dolphin
run_build required konsole
run_build required kate
run_build optional kcalc
run_build required okular

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
        systemctl enable sddm 2>/dev/null \
            || log_warning "Could not enable sddm via systemctl"
    fi
    # Create sddm user/group
    getent group sddm >/dev/null 2>&1 || groupadd -r sddm 2>/dev/null \
        || log_warning "Could not create sddm group"
    getent passwd sddm >/dev/null 2>&1 || useradd -r -g sddm -d /var/lib/sddm -s /sbin/nologin sddm 2>/dev/null \
        || log_warning "Could not create sddm user"
    mkdir -p /var/lib/sddm /var/lib/sddm/.config
    chown -R sddm:sddm /var/lib/sddm 2>/dev/null \
        || log_warning "Could not chown /var/lib/sddm"
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
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-kde.sh
log_success "KDE Plasma desktop environment installed successfully"
