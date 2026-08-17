#!/bin/bash
# 06e-init-s6.sh
# Build and configure s6 init system (skarnet toolchain).
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
log_info "Installing s6 init system"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – creating minimal s6 structure"
    mkdir -pv "$LFS"/{etc/s6,sbin}
    cat >"$LFS/sbin/init" <<'EOF'
#!/bin/sh
echo "Starting minimal s6..."
exec /bin/bash
EOF
    chmod +x "$LFS/sbin/init"
    log_success "Minimal s6 created for Docker"
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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-s6.sh" >/dev/null
#!/bin/bash
export PATH=/bin:/usr/bin:/sbin:/usr/sbin:/tools/bin
export SHELL=/bin/bash
export CONFIG_SHELL=/bin/bash

set -euo pipefail
cd /sources
mkdir -p /var/lib/lfs-builder/init-s6

JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/init-s6/$1.done"; }
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
        skalibs)    have_pc skalibs ;;
        execline)   have_cmd execlineb || [ -x /usr/bin/execlineb ] ;;
        s6)         have_cmd s6-svscan || [ -x /usr/bin/s6-svscan ] ;;
        s6-rc)      have_cmd s6-rc || [ -x /usr/bin/s6-rc ] ;;
        nsss)       have_pc nsss ;;
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
    if [ -x ./configure ] || [ -f configure ]; then
        # skarnet packages use ./configure with --enable-* / --disable-* options
        # shellcheck disable=SC2086
        ./configure --prefix=/usr --libdir=/usr/lib --sysconfdir=/etc --localstatedir=/var \
            --enable-shared --disable-static --slashpackage=no $extra_opts
        make -j"$JOBS"
        make install
    elif [ -f meson.build ]; then
        rm -rf builddir
        # shellcheck disable=SC2086
        meson setup builddir --prefix=/usr --buildtype=release --sysconfdir=/etc --localstatedir=/var $extra_opts
        ninja -C builddir
        ninja -C builddir install
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

echo "Building s6 ecosystem (skarnet toolchain)..."

# skalibs must be built first (all other packages depend on it)
build_pkg skalibs \
    --enable-time-acc \
    || echo "WARNING: skalibs build failed"

# execline depends on skalibs
build_pkg execline \
    --enable-foreach \
    --enable-import \
    --enable-multiparse \
    || echo "WARNING: execline build failed"

# nsss depends on skalibs
build_pkg nsss \
    --enable-libc-nss \
    || echo "WARNING: nsss build failed (optional)"

# s6 depends on skalibs and execline
build_pkg s6 \
    --enable-shared \
    || echo "WARNING: s6 build failed"

# s6-rc depends on skalibs, execline, and s6
build_pkg s6-rc \
    --enable-shared \
    || echo "WARNING: s6-rc build failed"

# ---- Post-install configuration ----
echo "Configuring s6..."

# Create supervision directories
mkdir -p /etc/s6/sv /etc/s6/rc /etc/s6/current /run/s6 /var/log/s6

# Create the s6 init script (/sbin/init)
cat > /sbin/s6-init <<'S6INIT'
#!/bin/sh
# s6 init script: starts the supervision tree
PATH=/bin:/usr/bin:/sbin:/usr/sbin

# Stage 1: one-time setup
hostname lfs 2>/dev/null || true
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null || true

# Generate SSH host keys
if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -A 2>/dev/null || true
fi

# Start udev if available
if command -v udevd >/dev/null 2>&1; then
    udevd --daemon 2>/dev/null || true
    udevadm trigger --action=add 2>/dev/null || true
    udevadm settle 2>/dev/null || true
fi

# Stage 2: start supervision tree
exec s6-svscan /etc/s6/sv
S6INIT
chmod +x /sbin/s6-init

# Link /sbin/init to s6-init
ln -sf /sbin/s6-init /sbin/init

# Create essential supervised services

# getty on tty1
mkdir -p /etc/s6/sv/getty-tty1
cat > /etc/s6/sv/getty-tty1/run <<'GETTY1'
#!/bin/sh
exec /sbin/agetty --noclear tty1 9600 linux
GETTY1
chmod +x /etc/s6/sv/getty-tty1/run

# getty on tty2
mkdir -p /etc/s6/sv/getty-tty2
cat > /etc/s6/sv/getty-tty2/run <<'GETTY2'
#!/bin/sh
exec /sbin/agetty --noclear tty2 9600 linux
GETTY2
chmod +x /etc/s6/sv/getty-tty2/run

# getty on tty3
mkdir -p /etc/s6/sv/getty-tty3
cat > /etc/s6/sv/getty-tty3/run <<'GETTY3'
#!/bin/sh
exec /sbin/agetty --noclear tty3 9600 linux
GETTY3
chmod +x /etc/s6/sv/getty-tty3/run

# sshd service
mkdir -p /etc/s6/sv/sshd
cat > /etc/s6/sv/sshd/run <<'SSHD'
#!/bin/sh
ssh-keygen -A 2>/dev/null || true
exec /usr/sbin/sshd -D
SSHD
chmod +x /etc/s6/sv/sshd/run

# udev service
mkdir -p /etc/s6/sv/udev
cat > /etc/s6/sv/udev/run <<'UDEV'
#!/bin/sh
exec udevd
UDEV
chmod +x /etc/s6/sv/udev/run

# networking service
mkdir -p /etc/s6/sv/networking
cat > /etc/s6/sv/networking/run <<'NET'
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
chmod +x /etc/s6/sv/networking/run

# Create the s6-rc service database source directory
mkdir -p /etc/s6/rc/sources
cat > /etc/s6/rc/sources/getty-tty1 <<'RC1'
type:longrun
command:/etc/s6/sv/getty-tty1/run
RC1
cat > /etc/s6/rc/sources/getty-tty2 <<'RC2'
type:longrun
command:/etc/s6/sv/getty-tty2/run
RC2
cat > /etc/s6/rc/sources/sshd <<'RCSS'
type:longrun
command:/etc/s6/sv/sshd/run
depends_on:udev
RCSS
cat > /etc/s6/rc/sources/udev <<'RCD'
type:longrun
command:/etc/s6/sv/udev/run
RCD
cat > /etc/s6/rc/sources/networking <<'RCN'
type:longrun
command:/etc/s6/sv/networking/run
RCN

# Create the default bundle
cat > /etc/s6/rc/sources/default <<'BUNDLE'
type:bundle
contents:getty-tty1,getty-tty2,sshd,udev,networking
BUNDLE

# Compile the s6-rc database
if have_cmd s6-rc-compile; then
    s6-rc-compile /etc/s6/rc/compiled /etc/s6/rc/sources 2>/dev/null || \
        echo "WARNING: s6-rc-compile failed (database not compiled)"
fi

# Create s6 shutdown script
cat > /sbin/s6-shutdown <<'SHUTDOWN'
#!/bin/sh
# s6 shutdown script
PATH=/bin:/usr/bin:/sbin:/usr/sbin

# Stop all supervised services
if command -v s6-svlist >/dev/null 2>&1; then
    for svc in $(s6-svlist /etc/s6/sv); do
        s6-svc -d /etc/s6/sv/$svc 2>/dev/null || true
    done
fi

# Kill remaining processes
killall5 -TERM 2>/dev/null || true
sleep 2
killall5 -KILL 2>/dev/null || true

# Unmount filesystems
umount -a 2>/dev/null || true
mount -o remount,ro / 2>/dev/null || true
SHUTDOWN
chmod +x /sbin/s6-shutdown

echo "s6 configuration complete."
INNEREOF

run_privileged chmod +x "$LFS/build-s6.sh"
log_info "Entering chroot and building s6"
run_privileged chroot "$LFS" /bin/bash -c "export PATH=/bin:/usr/bin:/sbin:/usr/sbin:/tools/bin; /build-s6.sh"

run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true
run_privileged umount "$LFS"/run 2>/dev/null || true

log_success "s6 init system installed successfully"
