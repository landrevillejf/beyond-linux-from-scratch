#!/bin/bash
# 09b-build-gnome.sh
# Build GNOME desktop environment (called by 09-build-desktop.sh dispatcher).
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# Error policy (audit finding F-07): a required package failure aborts the
# stage.  Only packages that are explicitly optional (missing from
# packages/stable/12.4/sources.list) may fail with a warning.
#
# Book compliance (audit finding F-07, wave 3): every package that has a
# page in docs/books gets a dedicated build_<name> function reproducing
# that page (sysvinit variants are adapted with HAVE_SYSTEMD); libgnomekbd
# and gnome-logs have no book page and use the generic build_pkg fallback.
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
HAVE_SYSTEMD=false
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

# Find and extract the source archive of a package, printing the
# extracted directory name.  libsoup 3 tarballs are named libsoup-3.x,
# and gcr 4 tarballs are named gcr-4.x (dot, not dash).
prep_src() {
    local pkg="$1" archive=""
    archive="$(find_archive "$pkg")"
    if [ -z "$archive" ]; then
        case "$pkg" in
            libsoup3) archive="$(find_archive libsoup)" ;;
            gcr-4)    archive="$(compgen -G 'gcr-4.*.tar.*' 2>/dev/null | sort -V | tail -n 1)" ;;
        esac
    fi
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
# (libgnomekbd, gnome-logs).
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
    else
        log_error "$pkg has no recognised build system"; popd >/dev/null; return 1
    fi
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for "$pkg")"
    log_success "$pkg installed"
}

# ======================================================================
# Per-package BLFS book commands (wave 3, gnome chapter).
# ======================================================================

build_gsettings_desktop_schemas() { book_install gsettings-desktop-schemas build_commands_gsettings_desktop_schemas; }
build_commands_gsettings_desktop_schemas() {
    sed -i -r 's:"(/system):"/org/gnome\1:g' schemas/*.in &&
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS x/libnotify
build_libnotify() { book_install libnotify build_commands_libnotify; }
build_commands_libnotify() {
    mkdir build && cd build &&
    meson setup --prefix=/usr       \
                --buildtype=release \
                -D gtk_doc=false    \
                -D man=false        \
                ..                  &&
    ninja && ninja install
}

# BLFS gnome/dconf – the meson.build sed is the book sysvinit variant;
# dconf-editor is built afterwards, as in the book.
build_dconf() { book_install dconf build_commands_dconf || return 1; build_dconf_editor; }
build_commands_dconf() {
    if [ "$HAVE_SYSTEMD" != true ]; then
        sed -i 's/install_dir: systemd_userunitdir,//' service/meson.build
    fi
    mkdir build && cd build &&
    meson setup --prefix=/usr            \
                --buildtype=release      \
                -D bash_completion=false \
                ..                       &&
    ninja && ninja install
}
build_dconf_editor() {
    local archive dir
    [ -x /usr/bin/dconf-editor ] && return 0
    archive="$(find_archive dconf-editor)"
    [ -n "$archive" ] || { log_info "dconf-editor tarball not found; skipping"; return 0; }
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null || return 1
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
    popd >/dev/null
    rm -rf "$dir"
}

# BLFS gnome/gcr (gcr-4)
build_gcr_4() { book_install gcr-4 build_commands_gcr_4; }
build_commands_gcr_4() {
    sed '/ssh.add/d; /ssh.agent/d' -i meson.build
    sed -i 's:"/desktop:"/org:' schema/*.xml &&
    mkdir build && cd build &&
    meson setup --prefix=/usr       \
                --buildtype=release \
                -D gtk_doc=false    \
                -D ssh_agent=false  \
                ..                  &&
    ninja && ninja install
}

# BLFS basicnet/glib-networking
build_glib_networking() { book_install glib-networking build_commands_glib_networking; }
build_commands_glib_networking() {
    mkdir build && cd build &&
    meson setup             \
       --prefix=/usr        \
       --buildtype=release  \
       -D libproxy=disabled \
       ..                   &&
    ninja && ninja install
}

# BLFS basicnet/libsoup3
build_libsoup3() { book_install libsoup3 build_commands_libsoup3; }
build_commands_libsoup3() {
    sed 's/apiversion/soup_version/' -i docs/reference/meson.build
    mkdir build && cd build &&
    meson setup --prefix=/usr          \
                --buildtype=release    \
                --wrap-mode=nofallback \
                ..                     &&
    ninja && ninja install
}

# BLFS gnome/libpeas
build_libpeas() { book_install libpeas build_commands_libpeas; }
build_commands_libpeas() {
    mkdir build && cd build &&
    meson setup --prefix=/usr          \
                --buildtype=release    \
                --wrap-mode=nofallback \
                -D python3=false       \
                ..                     &&
    ninja && ninja install
}

# BLFS gnome/gsound
build_gsound() { book_install gsound build_commands_gsound; }
build_commands_gsound() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS gnome/gnome-autoar
build_gnome_autoar() { book_install gnome-autoar build_commands_gnome_autoar; }
build_commands_gnome_autoar() {
    mkdir build && cd build &&
    meson setup --prefix=/usr       \
                --buildtype=release \
                -D vapi=true        \
                -D tests=true       \
                ..                  &&
    ninja && ninja install
}

# BLFS x/libadwaita
build_libadwaita() { book_install libadwaita build_commands_libadwaita; }
build_commands_libadwaita() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS gnome/gnome-menus
build_gnome_menus() { book_install gnome-menus build_commands_gnome_menus; }
build_commands_gnome_menus() {
    ./configure --prefix=/usr     \
                --sysconfdir=/etc \
                --disable-static  &&
    make -j"$JOBS" && make install
}

# BLFS gnome/gnome-backgrounds – data only
build_gnome_backgrounds() { book_install gnome-backgrounds build_commands_gnome_backgrounds; }
build_commands_gnome_backgrounds() {
    mkdir build && cd build &&
    meson setup --prefix=/usr .. &&
    ninja && ninja install
}

# BLFS x/adwaita-icon-theme
build_adwaita_icon_theme() { book_install adwaita-icon-theme build_commands_adwaita_icon_theme; }
build_commands_adwaita_icon_theme() {
    mkdir build && cd build &&
    meson setup --prefix=/usr .. &&
    ninja && ninja install
}

# BLFS gnome/gnome-keyring – systemd support follows the init system
build_gnome_keyring() { book_install gnome-keyring build_commands_gnome_keyring; }
build_commands_gnome_keyring() {
    local sd=disabled
    [ "$HAVE_SYSTEMD" = true ] && sd=enabled
    sed -i 's:"/desktop:"/org:' schema/*.xml &&
    mkdir build-gkr && cd build-gkr &&
    meson setup ..            \
          --prefix=/usr       \
          --buildtype=release \
          -D systemd="$sd"     \
          -D ssh-agent=true   &&
    ninja && ninja install
}

# BLFS gnome/gnome-online-accounts
build_gnome_online_accounts() { book_install gnome-online-accounts build_commands_gnome_online_accounts; }
build_commands_gnome_online_accounts() {
    mkdir build && cd build &&
    meson setup                                            \
          --prefix=/usr                                    \
          --buildtype=release                              \
          -D documentation=false                           \
          -D kerberos=false                                \
          -D google_client_secret=5ntt6GbbkjnTVXx-MSxbmx5e \
          -D google_client_id=595013732528-llk8trb03f0ldpqq6nprjp1s79596646.apps.googleusercontent.com \
          .. &&
    ninja && ninja install
}

# BLFS gnome/gnome-settings-daemon – the elogind seds are the book
# sysvinit variant; systemd builds skip them.
build_gnome_settings_daemon() { book_install gnome-settings-daemon build_commands_gnome_settings_daemon; }
build_commands_gnome_settings_daemon() {
    local sd=true
    if [ "$HAVE_SYSTEMD" != true ]; then
        sed -e 's/libsystemd/libelogind/' -i plugins/power/test.py
        sed -e 's/(backlight->logind_proxy)/(0)/' -i plugins/power/gsd-backlight.c
        sd=false
    fi
    mkdir build && cd build &&
    meson setup --prefix=/usr       \
                --buildtype=release \
                -D systemd="$sd"     \
                ..                  &&
    ninja && ninja install
}

# BLFS gnome/mutter
build_mutter() { book_install mutter build_commands_mutter; }
build_commands_mutter() {
    sed "/tests_c_args =/s/$/ + ['-U', 'G_DISABLE_ASSERT']/" -i src/tests/meson.build
    sed "/c_args:/a '-U', 'G_DISABLE_ASSERT'," -i src/tests/cogl/unit/meson.build
    mkdir build && cd build &&
    meson setup --prefix=/usr            \
                --buildtype=release      \
                -D tests=disabled        \
                -D profiler=false        \
                -D bash_completion=false \
                ..                       &&
    ninja && ninja install
}

# BLFS gnome/gnome-shell
build_gnome_shell() { book_install gnome-shell build_commands_gnome_shell; }
build_commands_gnome_shell() {
    local sd=false
    [ "$HAVE_SYSTEMD" = true ] && sd=true
    mkdir build && cd build &&
    meson setup --prefix=/usr       \
                --buildtype=release \
                -D systemd="$sd"     \
                -D tests=false      \
                ..                  &&
    ninja && ninja install
}

# BLFS gnome/gnome-session – systemduserunitdir=/tmp is the book
# sysvinit workaround; it is dropped on systemd builds.
build_gnome_session() { book_install gnome-session build_commands_gnome_session; }
build_commands_gnome_session() {
    local unit_opts=""
    [ "$HAVE_SYSTEMD" != true ] && unit_opts="-D systemduserunitdir=/tmp"
    sed 's@/bin/sh@/bin/sh -l@' -i gnome-session/gnome-session.in
    mkdir build && cd build
    # shellcheck disable=SC2086
    meson setup --prefix=/usr              \
                --buildtype=release        \
                -D man=false               \
                -D docbook=false           \
                $unit_opts                 \
                ..                         &&
    ninja && ninja install
}

# BLFS gnome/gnome-control-center
build_gnome_control_center() { book_install gnome-control-center build_commands_gnome_control_center; }
build_commands_gnome_control_center() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS x/gdm – pam sed and elogind provider are the book sysvinit
# variant; the udev rule comes from the book root commands.
build_gdm() { book_install gdm build_commands_gdm || return 1; gdm_post_install; }
build_commands_gdm() {
    local logind=systemd extra_opts=""
    sed -r 's/([(*])bool([) ])/\1boolval\2/' -i common/gdm-settings-utils.*
    if [ "$HAVE_SYSTEMD" != true ]; then
        sed -e 's@systemd@elogind@'                                \
            -e 's/-session optional/-session required/'            \
            -e '/elogind/isession  required       pam_loginuid.so' \
            -i data/pam-lfs/gdm-launch-environment.pam
        logind=elogind
        extra_opts="-D systemd-journal=false -D systemdsystemunitdir=no -D systemduserunitdir=no"
    fi
    mkdir build && cd build
    # shellcheck disable=SC2086
    meson setup ..                   \
          --prefix=/usr              \
          --buildtype=release        \
          -D gdm-xsession=true       \
          -D initial-vt=7            \
          -D run-dir=/run/gdm        \
          -D logind-provider="$logind" \
          $extra_opts                &&
    ninja && ninja install
}
gdm_post_install() {
    mkdir -p /etc/udev/rules.d
    ln -sf /dev/null /etc/udev/rules.d/61-gdm.rules
}

# BLFS gnome/nautilus
build_nautilus() { book_install nautilus build_commands_nautilus; }
build_commands_nautilus() {
    mkdir build && cd build &&
    meson setup --prefix=/usr       \
                --buildtype=release \
                ..                  &&
    ninja && ninja install
}

# BLFS gnome/gnome-terminal
build_gnome_terminal() { book_install gnome-terminal build_commands_gnome_terminal; }
build_commands_gnome_terminal() {
    if [ -f src/external.gschema.xml ]; then
        sed -i -r 's:"(/system):"/org/gnome\1:g' src/external.gschema.xml
    fi
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS postlfs/gedit – the libgedit-* dependency loop of the book runs
# first, then gedit itself.
build_gedit() {
    local package packagedir
    if ! is_installed gedit; then
        for package in libgedit-amtk-*.tar.* libgedit-gtksourceview-*.tar.* libgedit-gfls-*.tar.* libgedit-tepl-*.tar.*; do
            [ -f "$package" ] || continue
            packagedir="$(tar -tf "$package" | head -n 1 | cut -d/ -f1)"
            log_info "Building $packagedir (gedit dependency)"
            rm -rf "$packagedir"
            tar -xf "$package"
            pushd "$packagedir" >/dev/null || return 1
            mkdir -p build && cd build &&
            meson setup ..            \
                  --prefix=/usr       \
                  --buildtype=release \
                  -D gtk_doc=false    &&
            ninja && ninja install
            popd >/dev/null
            rm -rf "$packagedir"
        done
    fi
    book_install gedit build_commands_gedit
}
build_commands_gedit() {
    mkdir -p build && cd build &&
    meson setup ..            \
          --prefix=/usr       \
          --buildtype=release \
          -D gtk_doc=false    &&
    ninja && ninja install
}

# BLFS gnome/gnome-system-monitor
build_gnome_system_monitor() { book_install gnome-system-monitor build_commands_gnome_system_monitor; }
build_commands_gnome_system_monitor() {
    local sd=false
    [ "$HAVE_SYSTEMD" = true ] && sd=true
    # Book: find . -name meson.build | xargs sed -i -e '/catch2/d'
    find . -name meson.build -exec sed -i -e '/catch2/d' {} + &&
    sed -i '152,162d' src/meson.build
    mkdir build && cd build &&
    meson setup --prefix=/usr       \
                -D systemd="$sd"     \
                --buildtype=release \
                ..                  &&
    ninja && ninja install
}

# BLFS gnome/gnome-screenshot
build_gnome_screenshot() { book_install gnome-screenshot build_commands_gnome_screenshot; }
build_commands_gnome_screenshot() {
    sed -i '/merge_file/{n;d}' data/meson.build
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS gnome/yelp
build_yelp() { book_install yelp build_commands_yelp; }
build_commands_yelp() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# BLFS gnome/gnome-calculator
build_gnome_calculator() { book_install gnome-calculator build_commands_gnome_calculator; }
build_commands_gnome_calculator() {
    mkdir build && cd build &&
    meson setup --prefix=/usr --buildtype=release .. &&
    ninja && ninja install
}

# Policy wrapper (audit finding F-07).  required: any failure aborts the
# stage.  optional: failures are logged and the build continues.
# Packages without a BLFS book page (libgnomekbd, gnome-logs) use the
# generic build_pkg.
run_build() {
    local mode="$1" pkg="$2" fn
    shift 2
    fn="build_${pkg//-/_}"
    if declare -F "$fn" >/dev/null; then
        if "$fn" "$@"; then
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

# Detect if systemd is installed (for book sysvinit/systemd variants)
if [ -x /usr/lib/systemd/systemd ] || [ -d /usr/lib/systemd/system ]; then
    HAVE_SYSTEMD=true
fi
log_info "systemd detected: $HAVE_SYSTEMD"

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
run_build required mutter
run_build required gnome-shell
run_build required gnome-session
run_build required gnome-control-center
run_build required gdm

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
