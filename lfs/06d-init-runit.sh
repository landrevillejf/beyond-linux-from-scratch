#!/bin/bash
# 06d-init-runit.sh
# Build and configure runit init system.
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
log_info "Installing runit init system"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – creating minimal runit structure"
    mkdir -pv "$LFS"/{etc/runit,etc/sv,sbin,run/runit}
    cat >"$LFS/sbin/init" <<'EOF'
#!/bin/sh
echo "Starting minimal runit..."
exec /bin/bash
EOF
    chmod +x "$LFS/sbin/init"
    log_success "Minimal runit created for Docker"
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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-runit.sh" >/dev/null
#!/bin/bash
export PATH=/bin:/usr/bin:/sbin:/usr/sbin:/tools/bin
export SHELL=/bin/bash
export CONFIG_SHELL=/bin/bash

set -euo pipefail
cd /sources
mkdir -p /var/lib/lfs-builder/init-runit

JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/init-runit/$1.done"; }
find_archive() { compgen -G "${1}-*.tar.*" 2>/dev/null | sort -V | tail -n 1; }
extract_archive() {
    local archive="$1" dir
    dir="$(tar -tf "$archive" | head -n 1 | cut -d/ -f1)"
    rm -rf "$dir"
    tar -xf "$archive"
    printf '%s\n' "$dir"
}
have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_installed() {
    local pkg="$1"
    [ -f "$(marker_for "$pkg")" ] && return 0
    case "$pkg" in
        runit)  have_cmd runit-init || [ -x /sbin/runit-init ] || [ -x /sbin/runit ] ;;
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
    # runit uses a custom Makefile-based build system
    if [ -x ./configure ] || [ -f configure ]; then
        # shellcheck disable=SC2086
        ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static $extra_opts
        make -j"$JOBS"
        make install
    elif [ -f Makefile ]; then
        # runit's Makefile uses CC and prefix variables
        # shellcheck disable=SC2086
        make -j"$JOBS" CC=gcc $extra_opts
        make install
    elif [ -f meson.build ]; then
        rm -rf builddir
        # shellcheck disable=SC2086
        meson setup builddir --prefix=/usr --buildtype=release --sysconfdir=/etc --localstatedir=/var $extra_opts
        ninja -C builddir
        ninja -C builddir install
    else
        echo "[ERROR] $pkg has no recognised build system"; popd >/dev/null; return 1
    fi
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for "$pkg")"
    echo "=== $pkg done ==="
}

echo "Building runit..."
build_pkg runit \
    "CC=gcc" \
    "prefix=/usr" \
    "sysconfdir=/etc" \
    "localstatedir=/var" \
    || echo "WARNING: runit build failed"

# runit's build system installs to /package/admin/runit, fix the path
if [ -d /package/admin/runit ]; then
    cp -a /package/admin/runit/command/* /usr/bin/ 2>/dev/null || true
    cp -a /package/admin/runit/command/* /sbin/ 2>/dev/null || true
fi

# ---- Post-install configuration ----
echo "Configuring runit..."

# Create supervision tree
mkdir -p /etc/runit /run/runit /etc/sv /var/service

# Stage 1: one-time system initialization
cat > /etc/runit/1 <<'STAGE1'
#!/bin/sh
# Stage 1: one-time system initialization
PATH=/bin:/usr/bin:/sbin:/usr/sbin

# Set hostname
hostname lfs 2>/dev/null || true

# Mount essential filesystems
mount -o remount,rw / 2>/dev/null || true
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null || true

# Set initial path
echo lfs > /proc/sys/kernel/hostname 2>/dev/null || true

# Set kernel parameters
sysctl -p /etc/sysctl.conf 2>/dev/null || true

# Initialize hardware
if command -v udevd >/dev/null 2>&1; then
    udevd --daemon 2>/dev/null || true
    udevadm trigger --action=add 2>/dev/null || true
    udevadm settle 2>/dev/null || true
fi

# Generate SSH host keys
if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -A 2>/dev/null || true
fi

touch /etc/runit/.installed
STAGE1
chmod +x /etc/runit/1

# Stage 2: service supervision (runs indefinitely)
cat > /etc/runit/2 <<'STAGE2'
#!/bin/sh
# Stage 2: service supervision loop
PATH=/bin:/usr/bin:/sbin:/usr/sbin

# Set console font and keymap
if command -v loadkeys >/dev/null 2>&1; then
    loadkeys -u us 2>/dev/null || true
fi

# Start system services
if [ -x /etc/init.d/rc.local ]; then
    /etc/init.d/rc.local start 2>/dev/null || true
fi

# Run service supervision on /etc/service (or /var/service)
runsvdir -P /etc/service 2>/dev/null || runsvdir -P /var/service 2>/dev/null || {
    # Fallback: just spawn getty
    respawn_tty1 &
    respawn_tty2 &
    respawn_tty3 &
    respawn_tty4 &
    respawn_tty5 &
    respawn_tty6 &
    while true; do sleep 3600; done
}

respawn_tty1() {
    while true; do
        /sbin/agetty --noclear tty1 9600 linux
        sleep 1
    done
}
respawn_tty2() {
    while true; do
        /sbin/agetty --noclear tty2 9600 linux
        sleep 1
    done
}
respawn_tty3() {
    while true; do
        /sbin/agetty --noclear tty3 9600 linux
        sleep 1
    done
}
respawn_tty4() {
    while true; do
        /sbin/agetty --noclear tty4 9600 linux
        sleep 1
    done
}
respawn_tty5() {
    while true; do
        /sbin/agetty --noclear tty5 9600 linux
        sleep 1
    done
}
respawn_tty6() {
    while true; do
        /sbin/agetty --noclear tty6 9600 linux
        sleep 1
    done
}
STAGE2
chmod +x /etc/runit/2

# Stage 3: system shutdown
cat > /etc/runit/3 <<'STAGE3'
#!/bin/sh
# Stage 3: system shutdown
PATH=/bin:/usr/bin:/sbin:/usr/sbin

# Stop all services
sv shutdown /var/service/* 2>/dev/null || true
sv exit /var/service/* 2>/dev/null || true

# Kill remaining processes
killall5 -TERM 2>/dev/null || true
sleep 2
killall5 -KILL 2>/dev/null || true

# Unmount filesystems
umount -a 2>/dev/null || true
mount -o remount,ro / 2>/dev/null || true

STAGE3
chmod +x /etc/runit/3

# Create essential supervised services
# getty on tty1
mkdir -p /etc/sv/getty-tty1
cat > /etc/sv/getty-tty1/run <<'GETTY1'
#!/bin/sh
exec /sbin/agetty --noclear tty1 9600 linux
GETTY1
chmod +x /etc/sv/getty-tty1/run

# getty on tty2
mkdir -p /etc/sv/getty-tty2
cat > /etc/sv/getty-tty2/run <<'GETTY2'
#!/bin/sh
exec /sbin/agetty --noclear tty2 9600 linux
GETTY2
chmod +x /etc/sv/getty-tty2/run

# sshd service
mkdir -p /etc/sv/sshd/log
cat > /etc/sv/sshd/run <<'SSHD'
#!/bin/sh
ssh-keygen -A 2>/dev/null || true
exec /usr/sbin/sshd -D
SSHD
chmod +x /etc/sv/sshd/run
cat > /etc/sv/sshd/log/run <<'SSHDLOG'
#!/bin/sh
mkdir -p /var/log/sshd
exec svlogd /var/log/sshd
SSHDLOG
chmod +x /etc/sv/sshd/log/run

# udev service
mkdir -p /etc/sv/udev
cat > /etc/sv/udev/run <<'UDEV'
#!/bin/sh
exec udevd
UDEV
chmod +x /etc/sv/udev/run

# Network service
mkdir -p /etc/sv/networking
cat > /etc/sv/networking/run <<'NET'
#!/bin/sh
ip link set lo up 2>/dev/null || true
for iface in /sys/class/net/*; do
    dev=$(basename "$iface")
    [ "$dev" = "lo" ] && continue
    ip link set "$dev" up 2>/dev/null || true
    if command -v dhclient >/dev/null 2>&1; then
        dhclient "$dev" 2>/dev/null || true
    fi
done
exec sleep infinity
NET
chmod +x /etc/sv/networking/run

# Link services into /etc/service
ln -sf /etc/sv/getty-tty1 /etc/service/getty-tty1
ln -sf /etc/sv/getty-tty2 /etc/service/getty-tty2
ln -sf /etc/sv/sshd /etc/service/sshd
ln -sf /etc/sv/networking /etc/service/networking

# Link /sbin/init to runit-init
ln -sf /sbin/runit /sbin/init 2>/dev/null || true
ln -sf /sbin/runit-init /sbin/init 2>/dev/null || true

echo "runit configuration complete."
INNEREOF

run_privileged chmod +x "$LFS/build-runit.sh"
log_info "Entering chroot and building runit"
run_privileged chroot "$LFS" /bin/bash -c "export PATH=/bin:/usr/bin:/sbin:/usr/sbin:/tools/bin; /build-runit.sh"

run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true
run_privileged umount "$LFS"/run 2>/dev/null || true

log_success "runit init system installed successfully"
