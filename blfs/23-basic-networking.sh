#!/bin/bash
# 13-basic-networking.sh
# Build BLFS Basic Networking packages (Part IV of BLFS book)
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

run_privileged() { if [ "$(whoami)" = "root"; then "$@"; else sudo "$@"; fi; }

log_info "========================================="
log_info "Building BLFS Basic Networking"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – skipping networking packages"
    exit 0
fi

[ -x "$LFS/bin/bash" ] || { log_error "/bin/bash not found in $LFS/bin"; exit 1; }
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
    log_error "chroot not working"
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
    run_privileged umount "$LFS/dev/pts" 2>/dev/null || true
    run_privileged umount "$LFS/dev" 2>/dev/null || true
    run_privileged umount "$LFS/proc" 2>/dev/null || true
    run_privileged umount "$LFS/sys" 2>/dev/null || true
    run_privileged umount "$LFS/run" 2>/dev/null || true
}
trap cleanup EXIT
mount_chroot_fs

SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    run_privileged chown -R lfs:lfs "$LFS/sources" 2>/dev/null || true
fi

cat <<'INNEREOF' | run_privileged tee "$LFS/build-networking.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/networking

jobs() { nproc 2>/dev/null || echo 1; }
marker_for() { echo "/var/lib/lfs-builder/networking/$1.done"; }
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
        curl) have_cmd curl ;;
        wget) have_cmd wget ;;
        libevent) have_pc libevent ;;
        libnl) have_pc libnl-3.0 ;;
        libmnl) have_pc libmnl ;;
        nghttp2) have_pc libnghttp2 ;;
        nmap) have_cmd nmap ;;
        lynx) have_cmd lynx ;;
        ntp) have_cmd ntpd || have_cmd ntpdate ;;
        nfs-utils) have_cmd showmount ;;
        wireless_tools) have_cmd iwconfig || have_cmd iw ;;
        wpa_supplicant) have_cmd wpa_supplicant ;;
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
    if [ -f meson.build ]; then
        rm -rf builddir
        meson setup builddir --prefix=/usr --buildtype=release --sysconfdir=/etc --localstatedir=/var $extra_opts
        ninja -C builddir
        ninja -C builddir install
    elif [ -x ./configure ] || [ -f configure ]; then
        ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static $extra_opts
        make -j"$(jobs)"
        make install
    elif [ -f Makefile ]; then
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

log_info "Phase 1: Network utilities"

# curl – command line tool for transferring data with URL syntax
build_pkg curl || log_warning "curl build failed"

# wget – network utility to retrieve files from the Web
build_pkg wget || log_warning "wget build failed"

log_info "Phase 2: Network libraries"

# libevent – event notification library
build_pkg libevent || log_warning "libevent build failed"

# libnl – netlink protocol library suite
build_pkg libnl || log_warning "libnl build failed"

# libmnl – minimalistic user-space library for netlink
build_pkg libmnl || log_warning "libmnl build failed"

# nghttp2 – HTTP/2 library
build_pkg nghttp2 || log_warning "nghttp2 build failed"

log_info "Phase 3: Network tools"

# nmap – network exploration tool and security/port scanner
build_pkg nmap || log_warning "nmap build failed"

# lynx – text-based web browser
build_pkg lynx || log_warning "lynx build failed"

log_info "Phase 4: Time synchronization"

# ntp – Network Time Protocol daemon and utilities
build_pkg ntp || log_warning "ntp build failed"

log_info "Phase 5: Network file systems"

# nfs-utils – NFS server and client tools
build_pkg nfs-utils || log_warning "nfs-utils build failed"

log_info "Phase 6: Wireless networking"

# wireless_tools – tools for manipulating Linux Wireless Extensions
build_pkg wireless_tools || log_warning "wireless_tools build failed"

# wpa_supplicant – WPA/WPA2/EAP Authenticator and Supplicant
build_pkg wpa_supplicant || log_warning "wpa_supplicant build failed"

log_success "BLFS Basic Networking build complete"
INNEREOF

run_privileged chmod +x "$LFS/build-networking.sh"
run_privileged chroot "$LFS" /bin/bash /build-networking.sh

log_success "BLFS Basic Networking built successfully"
