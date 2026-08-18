#!/bin/bash
# 14-multimedia.sh
# Build BLFS Multimedia packages (Part VI of BLFS book)
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
log_info "Building BLFS Multimedia"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – skipping multimedia packages"
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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-multimedia.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/multimedia

jobs() { nproc 2>/dev/null || echo 1; }
marker_for() { echo "/var/lib/lfs-builder/multimedia/$1.done"; }
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
        alsa-lib) have_pc alsa ;;
        alsa-utils) have_cmd aplay ;;
        alsa-plugins) [ -d /usr/lib/alsa-lib ] ;;
        pulseaudio) have_cmd pulseaudio ;;
        pipewire) have_cmd pipewire ;;
        gstreamer) have_pc gstreamer-1.0 ;;
        gst-plugins-base) have_pc gstreamer-plugins-base-1.0 ;;
        gst-plugins-good) have_pc gstreamer-plugins-good-1.0 ;;
        gst-plugins-bad) have_pc gstreamer-plugins-bad-1.0 ;;
        gst-plugins-ugly) have_pc gstreamer-plugins-ugly-1.0 ;;
        libogg) have_pc ogg ;;
        libvorbis) have_pc vorbis ;;
        libtheora) have_pc theora ;;
        flac) have_cmd flac ;;
        opus) have_pc opus ;;
        speex) have_pc speex ;;
        lame) have_cmd lame ;;
        ffmpeg) have_cmd ffmpeg ;;
        mplayer) have_cmd mplayer ;;
        mpv) have_cmd mpv ;;
        vlc) have_cmd vlc ;;
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

log_info "Phase 1: Audio libraries"

# libogg – Ogg bitstream library
build_pkg libogg || log_warning "libogg build failed"

# libvorbis – Ogg Vorbis codec library
build_pkg libvorbis || log_warning "libvorbis build failed"

# libtheora – Theora video codec
build_pkg libtheora || log_warning "libtheora build failed"

# flac – Free Lossless Audio Codec
build_pkg flac || log_warning "flac build failed"

# opus – Opus audio codec
build_pkg opus || log_warning "opus build failed"

# speex – Speex audio codec
build_pkg speex || log_warning "speex build failed"

# lame – LAME MP3 encoder
build_pkg lame || log_warning "lame build failed"

log_info "Phase 2: ALSA (Advanced Linux Sound Architecture)"

# alsa-lib – ALSA library
build_pkg alsa-lib || log_warning "alsa-lib build failed"

# alsa-utils – ALSA utilities
build_pkg alsa-utils || log_warning "alsa-utils build failed"

# alsa-plugins – ALSA plugins
build_pkg alsa-plugins || log_warning "alsa-plugins build failed"

log_info "Phase 3: PulseAudio (optional sound server)"

# pulseaudio – PulseAudio sound server
build_pkg pulseaudio || log_warning "pulseaudio build failed"

log_info "Phase 4: PipeWire (modern audio/video server)"

# pipewire – PipeWire multimedia framework
build_pkg pipewire || log_warning "pipewire build failed"

log_info "Phase 5: GStreamer multimedia framework"

# gstreamer – Core GStreamer library
build_pkg gstreamer || log_warning "gstreamer build failed"

# gst-plugins-base – Base GStreamer plugins
build_pkg gst-plugins-base || log_warning "gst-plugins-base build failed"

# gst-plugins-good – Good quality GStreamer plugins
build_pkg gst-plugins-good || log_warning "gst-plugins-good build failed"

# gst-plugins-bad – GStreamer plugins with licensing issues
build_pkg gst-plugins-bad || log_warning "gst-plugins-bad build failed"

# gst-plugins-ugly – GStreamer plugins with distribution issues
build_pkg gst-plugins-ugly || log_warning "gst-plugins-ugly build failed"

log_info "Phase 6: FFmpeg and multimedia players"

# ffmpeg – Complete solution to record, convert and stream audio and video
build_pkg ffmpeg || log_warning "ffmpeg build failed"

# mplayer – Movie player
build_pkg mplayer || log_warning "mplayer build failed"

# mpv – Modern media player
build_pkg mpv || log_warning "mpv build failed"

# vlc – VLC media player
build_pkg vlc || log_warning "vlc build failed"

log_success "BLFS Multimedia build complete"
INNEREOF

run_privileged chmod +x "$LFS/build-multimedia.sh"
run_privileged chroot "$LFS" /bin/bash /build-multimedia.sh

log_success "BLFS Multimedia built successfully"
