#!/bin/bash
# 14-multimedia.sh
# Build BLFS Multimedia packages (Part VI of BLFS book)
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# Error policy (audit finding F-07): a required package failure aborts the
# stage.  Only packages that are explicitly optional (missing from
# packages/stable/12.4/sources.list) may fail with a warning.
#
# Book compliance (audit finding F-07, wave 3): multimedia packages are
# built with the commands of their docs/books (multimedia chapter)
# pages; ffmpeg enables each codec backend only when its dev library is
# available.  libtheora and mplayer have no book page and use the
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

run_privileged() {
    if [ "$(whoami)" = "root" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

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
    run_privileged umount "$LFS/dev/pts" 2>/dev/null || log_warning "Could not unmount $LFS/dev/pts"
    run_privileged umount "$LFS/dev" 2>/dev/null || log_warning "Could not unmount $LFS/dev"
    run_privileged umount "$LFS/proc" 2>/dev/null || log_warning "Could not unmount $LFS/proc"
    run_privileged umount "$LFS/sys" 2>/dev/null || log_warning "Could not unmount $LFS/sys"
    run_privileged umount "$LFS/run" 2>/dev/null || log_warning "Could not unmount $LFS/run"
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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-multimedia.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/multimedia

JOBS="$(nproc 2>/dev/null || echo 1)"
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
# build_commands_<name> function holding the book commands; JOBS and
# dir are exported.
book_install() {
    local pkg="$1" build_cmds dir
    build_cmds="$2"
    if is_installed "$pkg"; then
        log_info "$pkg already installed; skipping"
        return 0
    fi
    dir="$(prep_src "$pkg")" || return 1
    pushd "$dir" >/dev/null || return 1
    if ! JOBS="$JOBS" dir="$dir" "$build_cmds"; then
        popd >/dev/null
        return 1
    fi
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for "$pkg")"
    log_success "$pkg installed"
}

# Generic fallback for packages that have no BLFS book page
# (libtheora, mplayer).
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
    elif [ -f Makefile ]; then
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

# Book post-install step shared by mpv and vlc.
desktop_post_install() {
    if have_cmd gtk-update-icon-cache; then
        gtk-update-icon-cache -qtf /usr/share/icons/hicolor || return 1
    fi
    if have_cmd update-desktop-database; then
        update-desktop-database -q || return 1
    fi
}

# ======================================================================
# Per-package BLFS book commands (wave 3, multimedia chapter).
# ======================================================================

# BLFS multimedia/libogg
build_libogg() { book_install libogg build_commands_libogg; }
build_commands_libogg() {
    ./configure --prefix=/usr    \
                --disable-static \
                --docdir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install
}

# BLFS multimedia/libvorbis
build_libvorbis() { book_install libvorbis build_commands_libvorbis; }
build_commands_libvorbis() {
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS multimedia/flac
build_flac() { book_install flac build_commands_flac; }
build_commands_flac() {
    ./configure --prefix=/usr            \
                --disable-thorough-tests \
                --docdir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install
}

# BLFS multimedia/opus
build_opus() { book_install opus build_commands_opus; }
build_commands_opus() {
    mkdir build && cd build &&
    meson setup ..                \
              --prefix=/usr       \
              --buildtype=release \
              -D docdir="/usr/share/doc/$dir" &&
    ninja && ninja install
}

# BLFS multimedia/speex – the book also builds the sibling speexdsp
# tarball when it is present.
build_speex() { book_install speex build_commands_speex; }
build_commands_speex() {
    local dsp_archive dsp_dir
    ./configure --prefix=/usr    \
                --disable-static \
                --docdir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install || return 1
    cd .. || return 1
    dsp_archive="$(find_archive speexdsp)"
    if [ -n "$dsp_archive" ]; then
        dsp_dir="$(extract_archive "$dsp_archive")" || return 1
        cd "$dsp_dir" || return 1
        ./configure --prefix=/usr    \
                    --disable-static \
                    --docdir="/usr/share/doc/$dsp_dir" &&
        make -j"$JOBS" && make install || return 1
        cd .. || return 1
        rm -rf "$dsp_dir"
    fi
}

# BLFS multimedia/lame
build_lame() { book_install lame build_commands_lame; }
build_commands_lame() {
    # shellcheck disable=SC2016
    sed -i -e 's/^\(\s*hardcode_libdir_flag_spec\s*=\).*/\1/' configure &&
    ./configure --prefix=/usr --enable-mp3rtp --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS multimedia/alsa-lib
build_alsa_lib() { book_install alsa-lib build_commands_alsa_lib; }
build_commands_alsa_lib() {
    sed 's/playmidi1//' -i test/Makefile.am &&
    autoreconf -fi &&
    ./configure &&
    make -j"$JOBS" && make install
}

# BLFS multimedia/alsa-utils
build_alsa_utils() { book_install alsa-utils build_commands_alsa_utils; }
build_commands_alsa_utils() {
    ./configure --disable-alsaconf \
                --disable-bat      \
                --disable-xmlto    \
                --with-curses=ncursesw &&
    make -j"$JOBS" && make install
}

# BLFS multimedia/alsa-plugins
build_alsa_plugins() { book_install alsa-plugins build_commands_alsa_plugins; }
build_commands_alsa_plugins() {
    ./configure --sysconfdir=/etc &&
    make -j"$JOBS" && make install
}

# BLFS multimedia/pulseaudio
build_pulseaudio() { book_install pulseaudio build_commands_pulseaudio; }
build_commands_pulseaudio() {
    mkdir build && cd build &&
    meson setup ..                \
              --prefix=/usr       \
              --buildtype=release \
              -D database=gdbm    \
              -D doxygen=false    \
              -D bluez5=disabled  \
              -D tests=false &&
    ninja && ninja install
}

# BLFS multimedia/pipewire
build_pipewire() { book_install pipewire build_commands_pipewire; }
build_commands_pipewire() {
    mkdir build && cd build &&
    meson setup ..                 \
          --prefix=/usr            \
          --buildtype=release      \
          -D session-managers="[]" &&
    ninja && ninja install
}

# BLFS multimedia/gstreamer10
build_gstreamer() { book_install gstreamer build_commands_gstreamer; }
build_commands_gstreamer() {
    mkdir build && cd build &&
    meson setup ..            \
          --prefix=/usr       \
          --buildtype=release \
          -D gst_debug=false  &&
    ninja && ninja install
}

# BLFS multimedia/gst10-plugins-base
build_gst_plugins_base() { book_install gst-plugins-base build_commands_gst_plugins_base; }
build_commands_gst_plugins_base() {
    mkdir build && cd build &&
    meson setup ..               \
          --prefix=/usr          \
          --buildtype=release    \
          --wrap-mode=nodownload &&
    ninja && ninja install
}

# BLFS multimedia/gst10-plugins-good
build_gst_plugins_good() { book_install gst-plugins-good build_commands_gst_plugins_good; }
build_commands_gst_plugins_good() {
    mkdir build && cd build &&
    meson setup ..            \
          --prefix=/usr       \
          --buildtype=release &&
    ninja && ninja install
}

# BLFS multimedia/gst10-plugins-bad
build_gst_plugins_bad() { book_install gst-plugins-bad build_commands_gst_plugins_bad; }
build_commands_gst_plugins_bad() {
    mkdir build && cd build &&
    meson setup ..            \
          --prefix=/usr       \
          --buildtype=release \
          -D gpl=enabled      &&
    ninja && ninja install
}

# BLFS multimedia/gst10-plugins-ugly
build_gst_plugins_ugly() { book_install gst-plugins-ugly build_commands_gst_plugins_ugly; }
build_commands_gst_plugins_ugly() {
    mkdir build && cd build &&
    meson setup ..            \
          --prefix=/usr       \
          --buildtype=release \
          -D gpl=enabled      &&
    ninja && ninja install
}

# BLFS multimedia/ffmpeg – the chromium_method patch is applied only
# when shipped; codec backends are enabled when their dev libraries are
# available (the book enables them all unconditionally).
build_ffmpeg() { book_install ffmpeg build_commands_ffmpeg; }
build_commands_ffmpeg() {
    local p ff_opts=""
    for p in ../ffmpeg-*-chromium_method-*.patch; do
        [ -f "$p" ] || continue
        patch -Np1 -i "$p" || return 1
    done
    if have_pc aom; then     ff_opts="$ff_opts --enable-libaom"; fi
    if have_pc libass; then  ff_opts="$ff_opts --enable-libass"; fi
    if have_pc fdk-aac; then ff_opts="$ff_opts --enable-libfdk-aac"; fi
    if have_pc vpx; then     ff_opts="$ff_opts --enable-libvpx"; fi
    if have_pc x264; then    ff_opts="$ff_opts --enable-libx264"; fi
    if have_pc x265; then    ff_opts="$ff_opts --enable-libx265"; fi
    # shellcheck disable=SC2086
    ./configure --prefix=/usr        \
                --enable-gpl         \
                --enable-version3    \
                --enable-nonfree     \
                --disable-static     \
                --enable-shared      \
                --disable-debug      \
                --enable-libfreetype \
                --enable-libmp3lame  \
                --enable-libopus     \
                --enable-libvorbis   \
                --enable-openssl     \
                $ff_opts             \
                --ignore-tests=enhanced-flv-av1 \
                --docdir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install &&
    gcc tools/qt-faststart.c -o tools/qt-faststart &&
    install -m755 tools/qt-faststart /usr/bin
}

# BLFS multimedia/mpv
build_mpv() { book_install mpv build_commands_mpv; }
build_commands_mpv() {
    if [ -f filters/f_lavfi.c ]; then
        sed -i 's/AV_OPT_TYPE_CHANNEL_LAYOUT/AV_OPT_TYPE_CHLAYOUT/' filters/f_lavfi.c
    fi
    mkdir build && cd build &&
    meson setup ..                \
          --prefix=/usr           \
          --buildtype=release     \
          -D x11=enabled &&
    ninja && ninja install &&
    desktop_post_install
}

# BLFS multimedia/vlc – patches are applied only when shipped.
build_vlc() { book_install vlc build_commands_vlc; }
build_commands_vlc() {
    local p
    for p in ../vlc-*-taglib-*.patch ../vlc-*-fedora_ffmpeg7-*.patch; do
        [ -f "$p" ] || continue
        patch -Np1 -i "$p" || return 1
    done
    BUILDCC=gcc ./configure --prefix=/usr --disable-libplacebo &&
    make -j"$JOBS" && make install &&
    desktop_post_install
}

# Policy wrapper (audit finding F-07).  required: any failure aborts the
# stage.  optional: failures are logged and the build continues.
# Multimedia packages get their book commands; packages without a BLFS
# book page (libtheora, mplayer) use the generic build_pkg.
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

log_info "Phase 1: Audio libraries"

# libogg – Ogg bitstream library
run_build required libogg

# libvorbis – Ogg Vorbis codec library
run_build required libvorbis

# libtheora – Theora video codec; not in packages/stable/12.4/sources.list
run_build optional libtheora

# flac – Free Lossless Audio Codec
run_build required flac

# opus – Opus audio codec
run_build required opus

# speex – Speex audio codec
run_build required speex

# lame – LAME MP3 encoder
run_build required lame

log_info "Phase 2: ALSA (Advanced Linux Sound Architecture)"

# alsa-lib – ALSA library
run_build required alsa-lib

# alsa-utils – ALSA utilities
run_build required alsa-utils

# alsa-plugins – ALSA plugins
run_build required alsa-plugins

log_info "Phase 3: PulseAudio (optional sound server)"

# pulseaudio – PulseAudio sound server
run_build required pulseaudio

log_info "Phase 4: PipeWire (modern audio/video server)"

# pipewire – PipeWire multimedia framework
run_build required pipewire

log_info "Phase 5: GStreamer multimedia framework"

# gstreamer – Core GStreamer library
run_build required gstreamer

# gst-plugins-base – Base GStreamer plugins
run_build required gst-plugins-base

# gst-plugins-good – Good quality GStreamer plugins
run_build required gst-plugins-good

# gst-plugins-bad – GStreamer plugins with licensing issues
run_build required gst-plugins-bad

# gst-plugins-ugly – GStreamer plugins with distribution issues
run_build required gst-plugins-ugly

log_info "Phase 6: FFmpeg and multimedia players"

# ffmpeg – Complete solution to record, convert and stream audio and video
run_build required ffmpeg

# mplayer – Movie player; not in packages/stable/12.4/sources.list
run_build optional mplayer

# mpv – Modern media player
run_build required mpv

# vlc – VLC media player
run_build required vlc

log_success "BLFS Multimedia build complete"
INNEREOF

run_privileged chmod +x "$LFS/build-multimedia.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-multimedia.sh

log_success "BLFS Multimedia built successfully"
