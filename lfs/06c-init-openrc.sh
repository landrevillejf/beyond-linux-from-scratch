#!/bin/bash
# 06c-init-openrc.sh
# Build and configure OpenRC init system.
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

run_privileged() { if [ "$(whoami)" = "root" ]; then "$@"; else sudo -E "$@"; fi; }

log_info "========================================="
log_info "Installing OpenRC init system"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – creating minimal OpenRC structure"
    mkdir -pv "$LFS"/{etc/init.d,etc/runlevels,etc/conf.d,sbin,usr/sbin}
    cat >"$LFS/sbin/init" <<'EOF'
#!/bin/sh
echo "Starting minimal OpenRC..."
exec /bin/bash
EOF
    chmod +x "$LFS/sbin/init"
    log_success "Minimal OpenRC created for Docker"
    exit 0
fi

[ -x "$LFS/bin/bash" ] || { log_error "/bin/bash not found in $LFS/bin – run lfs-basic first"; exit 1; }
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
    log_error "chroot not working – run lfs-basic first"; exit 1
fi

run_privileged ln -sfn /bin/bash "$LFS/bin/sh"

cleanup_mounts() {
    run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
    run_privileged umount "$LFS"/dev 2>/dev/null || true
    run_privileged umount "$LFS"/proc 2>/dev/null || true
    run_privileged umount "$LFS"/sys 2>/dev/null || true
    run_privileged umount "$LFS"/run 2>/dev/null || true
}
trap cleanup_mounts EXIT

run_privileged mkdir -p "$LFS"/{dev,dev/pts,proc,sys,run,sources}
run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t devpts devpts "$LFS"/dev/pts 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true
run_privileged mount -t tmpfs tmpfs "$LFS"/run 2>/dev/null || true

log_info "Checking if gcc works in chroot..."
if ! run_privileged chroot "$LFS" /bin/bash -c "echo 'int main(){}' > /tmp/test.c && gcc /tmp/test.c -o /tmp/test 2>/dev/null && rm -f /tmp/test.c /tmp/test" 2>/dev/null; then
    log_error "gcc/cc1 missing or broken in chroot."
    log_error "Please rebuild the LFS system stage (05-lfs-system) and then retry."
    exit 1
fi
log_success "Toolchain OK in chroot."

SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    run_privileged chown -R lfs:lfs "$LFS/sources"
fi

cat <<'INNEREOF' | run_privileged tee "$LFS/build-openrc.sh" >/dev/null
#!/bin/bash
export PATH=/bin:/usr/bin:/sbin:/usr/sbin:/tools/bin
export SHELL=/bin/bash
export CONFIG_SHELL=/bin/bash

set -euo pipefail
cd /sources
mkdir -p /var/lib/lfs-builder/init-openrc

JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/init-openrc/$1.done"; }
find_archive() { compgen -G "${1}-*.tar.*" 2>/dev/null | sort -V | tail -n 1; }
extract_archive() {
    local archive="$1" dir
    dir="$(tar -tf "$archive" | head -n 1 | cut -d/ -f1)"
    rm -rf "$dir"
    tar -xf "$archive"
    printf '%s\n' "$dir"
}
have_cmd() { command -v "$1" >/dev/null 2>&1; }
have_pc() { pkg-config --exists "$1" 2>/dev/null; }

is_installed() {
    local pkg="$1"
    [ -f "$(marker_for "$pkg")" ] && return 0
    case "$pkg" in
        openrc)     have_cmd openrc-init || [ -x /sbin/openrc-init ] ;;
        pambase)    [ -f /etc/pam.d/system-auth ] ;;
        *) return 1 ;;
    esac
}

build_pkg() {
    local pkg="$1" archive dir extra_opts=""
    shift
    extra_opts="$*"
    if is_installed "$pkg"; then echo "[INFO] $pkg already installed; skipping"; return 0; fi
    archive="$(find_archive "$pkg")"
    if [ -z "$archive" ]; then echo "[WARNING] Source archive missing for $pkg; skipping"; return 0; fi
    echo "=== Building $pkg from $archive ==="
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
    elif [ -f Makefile ]; then
        make -j"$JOBS"
        make install
    else
        echo "[ERROR] $pkg has no recognised build system"; popd >/dev/null; return 1
    fi
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for "$pkg")"
    echo "=== $pkg done ==="
}

echo "Building OpenRC..."
build_pkg openrc \
    --sysconfdir=/etc \
    --libdir=/usr/lib \
    --with-rootprefix=/ \
    --with-sysvinit-dir=/etc/init.d \
    --with-sysvinit-script=/etc/init.d \
    --with-sh=/bin/sh \
    --with-pam-modulesdir=/usr/lib/security \
    || echo "WARNING: openrc build failed"

# ---- Post-install configuration ----
echo "Configuring OpenRC..."

# Create runlevels directory structure
mkdir -p /etc/runlevels/{sysinit,boot,default,shutdown,single,recovery}

# Link /sbin/init to openrc-init
ln -sf /sbin/openrc-init /sbin/init

# Create /etc/rc.conf
cat > /etc/rc.conf <<'RCCONF'
rc_logger="YES"
rc_log_path="/var/log/rc.log"
rc_dep_default_resolve="SOFT"
rc_parallel="NO"
rc_devicescanner_devfs="YES"
rc_devicescanner_udev="YES"
rc_devicescanner_mdev="NO"
RCCONF

# Create essential service scripts
# hostname service
cat > /etc/init.d/hostname <<'HOSTNAME'
#!/sbin/openrc-run
description="Set system hostname"
depend() { keyword nojail; }
start() {
    ebegin "Setting hostname"
    hostname "${hostname:-localhost}" 2>/dev/null || true
    eend $?
}
HOSTNAME
chmod +x /etc/init.d/hostname

# networking service
cat > /etc/init.d/networking <<'NETING'
#!/sbin/openrc-run
description="Network management"
depend() { after hostname; }
start() {
    ebegin "Starting network"
    if command -v dhclient >/dev/null 2>&1; then
        ip link set lo up 2>/dev/null || true
        for iface in /sys/class/net/*; do
            dev=$(basename "$iface")
            [ "$dev" = "lo" ] && continue
            dhclient "$dev" 2>/dev/null || true
        done
    fi
    eend 0
}
stop() {
    ebegin "Stopping network"
    eend 0
}
NETING
chmod +x /etc/init.d/networking

# sshd service
cat > /etc/init.d/sshd <<'SSHD'
#!/sbin/openrc-run
description="OpenSSH server"
depend() { use networking; }
start() {
    ebegin "Starting sshd"
    ssh-keygen -A 2>/dev/null || true
    start-stop-daemon --start --exec /usr/sbin/sshd --pidfile /run/sshd.pid
    eend $?
}
stop() {
    ebegin "Stopping sshd"
    start-stop-daemon --stop --exec /usr/sbin/sshd --pidfile /run/sshd.pid
    eend $?
}
SSHD
chmod +x /etc/init.d/sshd

# udev service (if udev is available)
cat > /etc/init.d/udev <<'UDEV'
#!/sbin/openrc-run
description="Device manager (udev)"
depend() { need sysfs; before modules; }
start() {
    ebegin "Starting udev"
    if command -v udevd >/dev/null 2>&1; then
        udevd --daemon 2>/dev/null
        udevadm trigger --action=add --type=subsystems 2>/dev/null || true
        udevadm trigger --action=add --type=devices 2>/dev/null || true
        udevadm settle 2>/dev/null || true
    fi
    eend 0
}
stop() {
    ebegin "Stopping udev"
    udevadm control --exit 2>/dev/null || true
    eend 0
}
UDEV
chmod +x /etc/init.d/udev

# Add services to runlevels
ln -sf /etc/init.d/udev /etc/runlevels/sysinit/udev 2>/dev/null || true
ln -sf /etc/init.d/hostname /etc/runlevels/boot/hostname 2>/dev/null || true
ln -sf /etc/init.d/networking /etc/runlevels/default/networking 2>/dev/null || true
ln -sf /etc/init.d/sshd /etc/runlevels/default/sshd 2>/dev/null || true

# Create /etc/conf.d/hostname
mkdir -p /etc/conf.d
echo 'hostname="lfs"' > /etc/conf.d/hostname

echo "OpenRC configuration complete."
INNEREOF

run_privileged chmod +x "$LFS/build-openrc.sh"
log_info "Entering chroot and building OpenRC"
run_privileged chroot "$LFS" /bin/bash -c "export PATH=/bin:/usr/bin:/sbin:/usr/sbin:/tools/bin; /build-openrc.sh"

run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true
run_privileged umount "$LFS"/run 2>/dev/null || true

log_success "OpenRC init system installed successfully"
