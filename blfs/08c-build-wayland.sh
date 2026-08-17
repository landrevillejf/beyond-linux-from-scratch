#!/bin/bash
# 08c-build-wayland.sh
# Build Wayland protocol, libraries, and optional compositor (weston).
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

DESKTOP_TYPE="${LFS_CONFIG_DESKTOP_TYPE:-xfce}"
export DESKTOP_TYPE

log_info "========================================="
log_info "Building Wayland"
log_info "Desktop type: $DESKTOP_TYPE"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – skipping Wayland build"
    exit 0
fi

[ "$DESKTOP_TYPE" = "none" ] && { log_info "No desktop requested; skipping Wayland"; exit 0; }

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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-wayland.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/wayland

jobs() { nproc 2>/dev/null || echo 1; }
marker_for() { echo "/var/lib/lfs-builder/wayland/$1.done"; }
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
        wayland)             have_pc wayland-client ;;
        wayland-protocols)   [ -d /usr/share/wayland-protocols ] || have_pc wayland-protocols ;;
        libxkbcommon)        have_pc xkbcommon ;;
        weston)              [ -x /usr/bin/weston ] ;;
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
        # shellcheck disable=SC2086
        meson setup builddir --prefix=/usr --buildtype=release $extra_opts
        ninja -C builddir
        ninja -C builddir install
    elif [ -x ./configure ] || [ -f configure ]; then
        # shellcheck disable=SC2086
        ./configure --prefix=/usr --sysconfdir=/etc --disable-static $extra_opts
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

# Verify prerequisites (need Xorg for some Wayland features)
verify_prerequisites() {
    local missing=() pc
    for pc in libdrm expat glib-2.0; do
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

log_info "Building Wayland protocol and libraries"

# wayland-protocols: protocol definitions (no build, just install)
build_pkg wayland-protocols || log_warning "wayland-protocols build failed"

# wayland: core library
build_pkg wayland \
    -Ddocumentation=false \
    -Dtests=false \
    || log_warning "wayland build failed"

# libxkbcommon: keyboard handling for Wayland
build_pkg libxkbcommon \
    -Denable-docs=false \
    || log_warning "libxkbcommon build failed"

# Weston: reference compositor (optional, used for testing Wayland)
build_pkg weston \
    -Dbackend-drm=true \
    -Dbackend-wayland=true \
    -Dbackend-x11=true \
    -Dbackend-headless=true \
    -Dscreenshots=true \
    -Ddemo-clients=false \
    -Dsimple-clients=[] \
    -Drenderer-gl=true \
    || log_warning "weston build failed (optional reference compositor)"

log_success "Wayland build complete"
INNEREOF

run_privileged chmod +x "$LFS/build-wayland.sh"
run_privileged chroot "$LFS" /bin/bash -c \
    "export LFS_CONFIG_DESKTOP_TYPE=$DESKTOP_TYPE; /build-wayland.sh"

log_success "Wayland built successfully"
