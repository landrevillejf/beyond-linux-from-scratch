#!/bin/bash
# 09a-build-xfce.sh
# Build XFCE desktop environment (called by 09-build-desktop.sh dispatcher).
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# Error policy (audit finding F-07): a required package failure aborts the
# stage.  Only packages that are explicitly optional (missing from
# packages/stable/12.4/sources.list) may fail with a warning.
#
# Book compliance (audit finding F-07, wave 3): every package that has a
# page in docs/books (xfce chapter) gets a dedicated build_<name>
# function reproducing that page; picom has no book page and uses the
# generic build_pkg fallback.
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
log_info "Building XFCE 4.20 desktop environment"
log_info "========================================="

install_xfce_docker_config() {
    log_info "Docker mode – installing launchable XFCE configuration in $LFS"
    run_privileged mkdir -pv "$LFS"/etc/X11/xorg.conf.d "$LFS"/etc/xdg/xfce4/xfconf/xfce-perchannel-xml "$LFS"/etc/xdg/autostart "$LFS"/usr/share/applications "$LFS"/usr/share/xsessions "$LFS"/usr/share/xfce4 "$LFS"/usr/bin "$LFS"/var/lib/lfs-builder/desktop
    run_privileged tee "$LFS/usr/share/xsessions/xfce.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Name=Xfce Session
Comment=Use this session to run Xfce as your desktop environment
Exec=startxfce4
Icon=xfce4
Type=Application
DesktopNames=XFCE
EOF
    run_privileged tee "$LFS/usr/bin/startxfce4" >/dev/null <<'EOF'
#!/bin/sh
if command -v dbus-launch >/dev/null 2>&1; then
    exec dbus-launch --exit-with-session xfce4-session
fi
exec xfce4-session
EOF
    run_privileged chmod 0755 "$LFS/usr/bin/startxfce4"
    run_privileged tee "$LFS/etc/X11/xinitrc" >/dev/null <<'EOF'
#!/bin/sh
exec startxfce4
EOF
    run_privileged chmod 0755 "$LFS/etc/X11/xinitrc"
    run_privileged tee "$LFS/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml" >/dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-session" version="1.0">
  <property name="general" type="empty">
    <property name="SaveOnExit" type="bool" value="false"/>
    <property name="SessionName" type="string" value="Default"/>
  </property>
</channel>
EOF
    run_privileged tee "$LFS/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml" >/dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <value type="int" value="2"/>
  </property>
  <property name="panel-1" type="empty">
    <property name="position" type="string" value="p=8;x=960;y=14"/>
    <property name="length" type="uint" value="100"/>
    <property name="size" type="uint" value="28"/>
    <property name="background-style" type="uint" value="1"/>
    <property name="background-rgba" type="array">
      <value type="double" value="0.08"/>
      <value type="double" value="0.08"/>
      <value type="double" value="0.16"/>
      <value type="double" value="0.55"/>
    </property>
    <property name="plugin-ids" type="array">
      <value type="int" value="1"/>
      <value type="int" value="2"/>
      <value type="int" value="3"/>
      <value type="int" value="4"/>
    </property>
  </property>
  <property name="panel-2" type="empty">
    <property name="position" type="string" value="p=2;x=960;y=1010"/>
    <property name="length" type="uint" value="60"/>
    <property name="length-adjust" type="bool" value="false"/>
    <property name="size" type="uint" value="56"/>
    <property name="background-style" type="uint" value="1"/>
    <property name="background-rgba" type="array">
      <value type="double" value="0.10"/>
      <value type="double" value="0.10"/>
      <value type="double" value="0.18"/>
      <value type="double" value="0.50"/>
    </property>
    <property name="enter-opacity" type="uint" value="100"/>
    <property name="leave-opacity" type="uint" value="70"/>
    <property name="plugin-ids" type="array">
      <value type="int" value="10"/>
      <value type="int" value="11"/>
      <value type="int" value="12"/>
      <value type="int" value="13"/>
      <value type="int" value="14"/>
      <value type="int" value="15"/>
    </property>
  </property>
  <property name="plugin-1" type="string" value="whiskermenu"/>
  <property name="plugin-2" type="string" value="clock"/>
  <property name="plugin-3" type="string" value="separator"><property name="expand" type="bool" value="true"/></property>
  <property name="plugin-4" type="string" value="systray"/>
  <property name="plugin-10" type="string" value="launcher"><property name="items" type="array"><value type="string" value="thunar.desktop"/></property></property>
  <property name="plugin-11" type="string" value="launcher"><property name="items" type="array"><value type="string" value="xfce4-terminal.desktop"/></property></property>
  <property name="plugin-12" type="string" value="launcher"><property name="items" type="array"><value type="string" value="firefox.desktop"/></property></property>
  <property name="plugin-13" type="string" value="separator"/>
  <property name="plugin-14" type="string" value="launcher"><property name="items" type="array"><value type="string" value="xfce-settings-manager.desktop"/></property></property>
  <property name="plugin-15" type="string" value="tasklist"><property name="show-labels" type="bool" value="false"/><property name="flat-buttons" type="bool" value="true"/></property>
</channel>
EOF
    run_privileged tee "$LFS/var/lib/lfs-builder/desktop/xfce-packages.list" >/dev/null <<'EOF'
xfce4-dev-tools
libxfce4util
xfconf
libxfce4ui
libxfce4windowing
garcon
exo
tumbler
xfce4-panel
thunar
thunar-volman
xfwm4
xfce4-session
xfdesktop
xfce4-settings
xfce4-appfinder
xfce4-terminal
xfce4-notifyd
xfce4-power-manager
picom
EOF
    log_success "XFCE Docker configuration installed"
}

if [ "$IN_DOCKER" = true ]; then
    install_xfce_docker_config
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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-xfce.sh" >/dev/null
#!/bin/bash
set -euo pipefail
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }
cd /sources
mkdir -p /var/lib/lfs-builder/desktop /usr/share/xsessions /etc/X11 /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
JOBS="$(nproc 2>/dev/null || echo 1)"
HAVE_SYSTEMD=false
marker_for() { echo "/var/lib/lfs-builder/desktop/$1.done"; }
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
extract_archive() { local archive="$1" dir; dir="$(tar -tf "$archive" | head -n 1 | cut -d/ -f1)"; rm -rf "$dir"; tar -xf "$archive"; printf '%s\n' "$dir"; }
is_installed() {
    local pkg="$1"; [ -f "$(marker_for "$pkg")" ] && return 0
    case "$pkg" in
        xfce4-dev-tools) [ -x /usr/bin/xdt-autogen ] ;;
        libxfce4util) pkg-config --exists libxfce4util-1.0 2>/dev/null ;;
        xfconf) [ -x /usr/bin/xfconf-query ] ;;
        libxfce4ui) pkg-config --exists libxfce4ui-2 2>/dev/null ;;
        libxfce4windowing) pkg-config --exists libxfce4windowing-0 2>/dev/null ;;
        garcon) pkg-config --exists garcon-1 2>/dev/null ;;
        exo) pkg-config --exists exo-2 2>/dev/null ;;
        tumbler) [ -x /usr/libexec/tumblerd ] || [ -x /usr/lib/tumbler-1/tumblerd ] ;;
        xfce4-panel) [ -x /usr/bin/xfce4-panel ] ;;
        thunar) [ -x /usr/bin/thunar ] || [ -x /usr/bin/Thunar ] ;;
        thunar-volman) [ -x /usr/bin/thunar-volman ] ;;
        xfwm4) [ -x /usr/bin/xfwm4 ] ;;
        xfce4-session) [ -x /usr/bin/xfce4-session ] ;;
        xfdesktop) [ -x /usr/bin/xfdesktop ] ;;
        xfce4-settings) [ -x /usr/bin/xfce4-settings-manager ] ;;
        xfce4-appfinder) [ -x /usr/bin/xfce4-appfinder ] ;;
        xfce4-terminal) [ -x /usr/bin/xfce4-terminal ] ;;
        xfce4-notifyd) [ -x /usr/lib/xfce4/notifyd/xfce4-notifyd ] || [ -x /usr/libexec/xfce4-notifyd ] ;;
        xfce4-power-manager) [ -x /usr/bin/xfce4-power-manager ] ;;
        picom) [ -x /usr/bin/picom ] ;;
        *) return 1 ;;
    esac
}
verify_prerequisites() {
    local missing=() pc
    for pc in glib-2.0 gtk+-3.0 cairo pango atk gdk-pixbuf-2.0 dbus-1 dbus-glib-1; do pkg-config --exists "$pc" 2>/dev/null || missing+=("$pc"); done
    if [ "${#missing[@]}" -ne 0 ]; then
        log_error "Missing XFCE prerequisites: ${missing[*]}"
        log_error "Build glib-2, gtk+3, cairo, pango, atk, gdk-pixbuf, dbus, dbus-glib before this stage."
        exit 1
    fi
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

# Generic fallback for packages that have no BLFS book page (picom).
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
        ./configure --prefix=/usr --sysconfdir=/etc --disable-static $extra_opts
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
# Per-package BLFS book commands (wave 3, xfce chapter).
# ======================================================================

build_xfce4_dev_tools() { book_install xfce4-dev-tools build_commands_xfce4_dev_tools; }
build_commands_xfce4_dev_tools() {
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

build_libxfce4util() { book_install libxfce4util build_commands_libxfce4util; }
build_commands_libxfce4util() {
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

build_xfconf() { book_install xfconf build_commands_xfconf; }
build_commands_xfconf() {
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

build_libxfce4ui() { book_install libxfce4ui build_commands_libxfce4ui; }
build_commands_libxfce4ui() {
    ./configure --prefix=/usr --sysconfdir=/etc &&
    make -j"$JOBS" && make install
}

build_libxfce4windowing() { book_install libxfce4windowing build_commands_libxfce4windowing; }
build_commands_libxfce4windowing() {
    ./configure --prefix=/usr     \
                --sysconfdir=/etc \
                --enable-x11      \
                --disable-debug   &&
    make -j"$JOBS" && make install
}

build_garcon() { book_install garcon build_commands_garcon; }
build_commands_garcon() {
    ./configure --prefix=/usr --sysconfdir=/etc &&
    make -j"$JOBS" && make install
}

build_exo() { book_install exo build_commands_exo; }
build_commands_exo() {
    ./configure --prefix=/usr --sysconfdir=/etc &&
    make -j"$JOBS" && make install
}

build_tumbler() { book_install tumbler build_commands_tumbler; }
build_commands_tumbler() {
    ./configure --prefix=/usr --sysconfdir=/etc &&
    make -j"$JOBS" && make install
}

build_xfce4_panel() { book_install xfce4-panel build_commands_xfce4_panel; }
build_commands_xfce4_panel() {
    ./configure --prefix=/usr --sysconfdir=/etc &&
    make -j"$JOBS" && make install
}

# BLFS xfce/thunar – the Makefile.in sed only applies on non-systemd
# builds (it drops an unneeded systemd user unit).
build_thunar() { book_install thunar build_commands_thunar; }
build_commands_thunar() {
    if [ "$HAVE_SYSTEMD" != true ]; then
        sed -i 's/\tinstall-systemd_userDATA/\t/' Makefile.in
    fi
    ./configure --prefix=/usr     \
                --sysconfdir=/etc \
                --docdir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install
}

build_thunar_volman() { book_install thunar-volman build_commands_thunar_volman; }
build_commands_thunar_volman() {
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

build_xfwm4() { book_install xfwm4 build_commands_xfwm4; }
build_commands_xfwm4() {
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

build_xfce4_session() { book_install xfce4-session build_commands_xfce4_session; }
build_commands_xfce4_session() {
    ./configure --prefix=/usr       \
                --sysconfdir=/etc   \
                --disable-legacy-sm &&
    make -j"$JOBS" && make install
}

build_xfdesktop() { book_install xfdesktop build_commands_xfdesktop; }
build_commands_xfdesktop() {
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

build_xfce4_settings() { book_install xfce4-settings build_commands_xfce4_settings; }
build_commands_xfce4_settings() {
    ./configure --prefix=/usr --sysconfdir=/etc &&
    make -j"$JOBS" && make install
}

build_xfce4_appfinder() { book_install xfce4-appfinder build_commands_xfce4_appfinder; }
build_commands_xfce4_appfinder() {
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

build_xfce4_terminal() { book_install xfce4-terminal build_commands_xfce4_terminal; }
build_commands_xfce4_terminal() {
    mkdir build && cd build &&
    meson setup ..      \
          --prefix=/usr \
          --buildtype=release &&
    ninja && ninja install
}

# BLFS xfce/xfce4-notifyd – --disable-systemd is the book (sysvinit)
# variant; it is dropped when systemd is installed.
build_xfce4_notifyd() { book_install xfce4-notifyd build_commands_xfce4_notifyd; }
build_commands_xfce4_notifyd() {
    sd_opts=""
    [ "$HAVE_SYSTEMD" != true ] && sd_opts="--disable-systemd"
    # shellcheck disable=SC2086
    ./configure --prefix=/usr --sysconfdir=/etc $sd_opts &&
    make -j"$JOBS" && make install
}

build_xfce4_power_manager() { book_install xfce4-power-manager build_commands_xfce4_power_manager; }
build_commands_xfce4_power_manager() {
    ./configure --prefix=/usr --sysconfdir=/etc &&
    make -j"$JOBS" && make install
}

# Policy wrapper (audit finding F-07).  required: any failure aborts the
# stage.  optional: failures are logged and the build continues.
# Packages without a BLFS book page (picom) use the generic build_pkg.
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
install_session_files() {
    cat > /usr/share/xsessions/xfce.desktop <<'EOF'
[Desktop Entry]
Name=Xfce Session
Comment=Use this session to run Xfce as your desktop environment
Exec=startxfce4
Icon=xfce4
Type=Application
DesktopNames=XFCE
EOF
    cat > /etc/X11/xinitrc <<'EOF'
#!/bin/sh
exec startxfce4
EOF
    chmod 0755 /etc/X11/xinitrc
    if [ ! -x /usr/bin/startxfce4 ]; then
        cat > /usr/bin/startxfce4 <<'EOF'
#!/bin/sh
if command -v dbus-launch >/dev/null 2>&1; then exec dbus-launch --exit-with-session xfce4-session; fi
exec xfce4-session
EOF
        chmod 0755 /usr/bin/startxfce4
    fi
}
verify_prerequisites

# Detect if systemd is installed (for thunar/notifyd book variants)
if [ -x /usr/lib/systemd/systemd ] || [ -d /usr/lib/systemd/system ]; then
    HAVE_SYSTEMD=true
fi
log_info "systemd detected: $HAVE_SYSTEMD"

log_info "Building XFCE 4.20 core in dependency order"
for pkg in xfce4-dev-tools libxfce4util xfconf libxfce4ui libxfce4windowing garcon exo tumbler xfce4-panel thunar thunar-volman xfwm4 xfce4-session xfdesktop xfce4-settings xfce4-appfinder xfce4-terminal xfce4-notifyd xfce4-power-manager; do
    run_build required "$pkg"
done
# picom is not in packages/stable/12.4/sources.list; optional compositor
run_build optional picom
install_session_files
log_success "XFCE desktop installation complete"
INNEREOF
run_privileged chmod +x "$LFS/build-xfce.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-xfce.sh
log_success "XFCE desktop environment installed successfully"
