#!/bin/bash
# 08d-build-display-manager.sh
# Build LightDM display manager and GTK greeter.
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# Error policy (audit finding F-07): a required package failure aborts the
# stage.  Only packages that are explicitly optional may fail with a warning.
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
INIT_SYSTEM="${INIT_SYSTEM:-sysvinit}"
export DESKTOP_TYPE INIT_SYSTEM

log_info "========================================="
log_info "Building display manager (LightDM)"
log_info "Desktop type: $DESKTOP_TYPE"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – skipping display manager build"
    exit 0
fi

[ "$DESKTOP_TYPE" = "none" ] && { log_info "No desktop requested; skipping display manager"; exit 0; }

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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-display-manager.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/display-manager /etc/lightdm /usr/share/xsessions \
    /usr/share/wayland-sessions

jobs() { nproc 2>/dev/null || echo 1; }
marker_for() { echo "/var/lib/lfs-builder/display-manager/$1.done"; }
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
        polkit)             have_pc polkit-gobject-1 ;;
        accountsservice)    have_pc accountsservice-glib ;;
        lightdm)            [ -x /usr/sbin/lightdm ] || [ -x /usr/bin/lightdm ] ;;
        lightdm-gtk-greeter) have_pc lightdm-gtk-greeter || [ -f /etc/lightdm/lightdm-gtk-greeter.conf ] ;;
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
    elif [ -x ./autogen.sh ]; then
        # shellcheck disable=SC2086
        ./autogen.sh --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static $extra_opts
        make -j"$(jobs)"
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

# Verify prerequisites
verify_prerequisites() {
    local missing=() pc
    for pc in glib-2.0 dbus-1 gtk+-3.0 x11; do
        if ! have_pc "$pc" 2>/dev/null; then
            missing+=("$pc")
        fi
    done
    if [ "${#missing[@]}" -ne 0 ]; then
        log_error "Missing prerequisites: ${missing[*]}"
        log_error "Build blfs-libs (08a) and xorg (08b) before this stage."
        exit 1
    fi
}
verify_prerequisites

# Detect systemd for service configuration
HAVE_SYSTEMD=false
if [ -d /usr/lib/systemd/system ]; then
    HAVE_SYSTEMD=true
fi

log_info "Building polkit (PolicyKit)"
# polkit: depends on glib2, dbus, js78/mozjs (use --disable-polkitd for minimal)
run_build required polkit \
    --disable-polkitd \
    --with-polkitd-user=polkitd

log_info "Building accountsservice"
# accountsservice: depends on glib2, dbus, polkit
run_build required accountsservice \
    -Dadmin_group=wheel \
    -Dsystemdsystemunitdir=/usr/lib/systemd/system

log_info "Building LightDM"
# LightDM: depends on glib2, dbus, Xorg, gtk3
LIGHTDM_OPTS=""
if $HAVE_SYSTEMD; then
    LIGHTDM_OPTS="--with-systemdsystemunitdir=/usr/lib/systemd/system"
fi
# shellcheck disable=SC2086  # LIGHTDM_OPTS is empty or one configure flag
run_build required lightdm \
    --disable-static \
    --disable-tests \
    $LIGHTDM_OPTS

log_info "Building LightDM GTK greeter"
run_build required lightdm-gtk-greeter \
    --disable-static

# Configure LightDM
log_info "Configuring LightDM"
mkdir -p /etc/lightdm

cat > /etc/lightdm/lightdm.conf <<'LDMCONF'
[LightDM]
run-directory=/run/lightdm

[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=xfce
session-wrapper=/usr/bin/startxfce4
autologin-user=lfsuser
autologin-user-timeout=0
autologin-session=xfce
LDMCONF

# Create lightdm group and user if not present; failures are tolerated
# because some hosts run without useradd in the early build stages.
if ! getent group lightdm >/dev/null 2>&1; then
    groupadd -r lightdm 2>/dev/null || log_warning "Could not create lightdm group"
fi
if ! getent passwd lightdm >/dev/null 2>&1; then
    useradd -r -g lightdm -d /var/lib/lightdm -s /sbin/nologin lightdm 2>/dev/null \
        || log_warning "Could not create lightdm user"
fi
mkdir -p /var/lib/lightdm /var/cache/lightdm
chown -R lightdm:lightdm /var/lib/lightdm /var/cache/lightdm 2>/dev/null \
    || log_warning "Could not chown lightdm directories"

# Configure PAM for lightdm if PAM is available
if [ -d /etc/pam.d ]; then
    cat > /etc/pam.d/lightdm <<'PAMCONF'
auth        include     system-auth
account     include     system-auth
password    include     system-auth
session     include     system-auth
PAMCONF

    cat > /etc/pam.d/lightdm-autologin <<'PAMAUTO'
auth        required    pam_unix.so
account     include     system-auth
session     include     system-auth
PAMAUTO
fi

# Enable lightdm service based on init system
if $HAVE_SYSTEMD; then
    systemctl enable lightdm.service 2>/dev/null \
        || log_warning "Could not enable lightdm.service via systemctl"
elif [ "$INIT_SYSTEM" = "sysvinit" ]; then
    # Create sysvinit service script
    cat > /etc/init.d/lightdm <<'SYSV'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          lightdm
# Required-Start:    $local_fs $remote_fs $network
# Required-Stop:     $local_fs $remote_fs $network
# Default-Start:     5
# Default-Stop:      0 1 2 6
# Short-Description: Light Display Manager
### END INIT INFO
DAEMON=/usr/sbin/lightdm
PIDFILE=/run/lightdm.pid
case "$1" in
    start) mkdir -p /run/lightdm; start-stop-daemon -S -b -m -p "$PIDFILE" -x "$DAEMON" ;;
    stop)  start-stop-daemon -K -p "$PIDFILE" ;;
    restart) "$0" stop; sleep 1; "$0" start ;;
    *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
SYSV
    chmod 0755 /etc/init.d/lightdm
    ln -sf /etc/init.d/lightdm /etc/rc.d/rc5.d/S90lightdm 2>/dev/null \
        || log_warning "Could not link lightdm into rc5.d"
fi

log_success "Display manager (LightDM) build and configuration complete"
INNEREOF

run_privileged chmod +x "$LFS/build-display-manager.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    INIT_SYSTEM="$INIT_SYSTEM" LFS_CONFIG_DESKTOP_TYPE="$DESKTOP_TYPE" \
    /bin/bash /build-display-manager.sh

log_success "Display manager built successfully"
