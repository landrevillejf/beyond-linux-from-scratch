#!/bin/bash
# 06c-init-openrc.sh
# Build and configure OpenRC init system.
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

mount_chroot_fs() {
    run_privileged mkdir -p "$LFS"/{dev,dev/pts,proc,sys,run,sources}
    run_privileged mountpoint -q "$LFS/dev" || run_privileged mount --bind /dev "$LFS/dev"
    run_privileged mountpoint -q "$LFS/dev/pts" || run_privileged mount -t devpts devpts "$LFS/dev/pts"
    run_privileged mountpoint -q "$LFS/proc" || run_privileged mount -t proc proc "$LFS/proc"
    run_privileged mountpoint -q "$LFS/sys" || run_privileged mount -t sysfs sysfs "$LFS/sys"
    run_privileged mountpoint -q "$LFS/run" || run_privileged mount -t tmpfs tmpfs "$LFS/run"
}
cleanup() {
    run_privileged umount "$LFS/dev/pts" 2>/dev/null || log_warning "Could not unmount $LFS/dev/pts"
    run_privileged umount "$LFS/dev" 2>/dev/null || log_warning "Could not unmount $LFS/dev"
    run_privileged umount "$LFS/proc" 2>/dev/null || log_warning "Could not unmount $LFS/proc"
    run_privileged umount "$LFS/sys" 2>/dev/null || log_warning "Could not unmount $LFS/sys"
    run_privileged umount "$LFS/run" 2>/dev/null || log_warning "Could not unmount $LFS/run"
}
trap cleanup EXIT
mount_chroot_fs

log_info "Checking if gcc works in chroot..."
if ! run_privileged chroot "$LFS" /bin/bash -c "echo 'int main(){}' > /tmp/test.c && gcc /tmp/test.c -o /tmp/test 2>/dev/null && rm -f /tmp/test.c /tmp/test" 2>/dev/null; then
    log_error "gcc/cc1 missing or broken in chroot."
    log_error "Please rebuild the LFS system stage (05b-build-lfs-system) and then retry."
    exit 1
fi
log_success "Toolchain OK in chroot."

SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    if ! run_privileged chown -R lfs:lfs "$LFS/sources" 2>/dev/null; then log_warning "Could not chown $LFS/sources to lfs:lfs"; fi
fi

cat <<'INNEREOF' | run_privileged tee "$LFS/build-openrc.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/init-openrc

JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/init-openrc/$1.done"; }
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
        openrc)     have_cmd openrc-init || [ -x /sbin/openrc-init ] ;;
        *) return 1 ;;
    esac
}

build_pkg() {
    local pkg="$1" archive dir
    if is_installed "$pkg"; then log_info "$pkg already installed; skipping"; return 0; fi
    archive="$(find_archive "$pkg")"
    if [ -z "$archive" ]; then
        log_error "Source archive missing for $pkg"
        return 1
    fi
    log_info "Building $pkg from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
    # OpenRC uses its own Makefile-based build system.
    if [ -f Makefile ]; then
        make -j"$JOBS"
        make install LIBDIR=/usr/lib SYSCONFDIR=/etc
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

log_info "Building OpenRC..."
# openrc is not in packages/stable/12.4/sources.list (and not a package of
# the LFS/BLFS books), so it stays optional until its tarball is added.
run_build optional openrc

# ---- Post-install configuration ----
log_info "Configuring OpenRC..."

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
ln -sf /etc/init.d/udev /etc/runlevels/sysinit/udev
ln -sf /etc/init.d/hostname /etc/runlevels/boot/hostname
ln -sf /etc/init.d/networking /etc/runlevels/default/networking
ln -sf /etc/init.d/sshd /etc/runlevels/default/sshd

# Create /etc/conf.d/hostname
mkdir -p /etc/conf.d
echo 'hostname="lfs"' > /etc/conf.d/hostname

log_success "OpenRC configuration complete."
INNEREOF

run_privileged chmod +x "$LFS/build-openrc.sh"
log_info "Entering chroot and building OpenRC"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-openrc.sh

log_success "OpenRC init system installed successfully"
