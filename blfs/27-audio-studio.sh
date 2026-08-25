#!/bin/bash
set -euo pipefail
#======================================================================
# 27-audio-studio.sh - audio production stack (audio profiles)
#
# Builds the LV2 host stack (zix, serd, sord, lv2, sratom, lilv),
# libsndfile (BLFS book commands) and NeuralRack v0.4.1, the neural
# amp modeller / impulse response loader from brummer10.  Runs only
# for the audio-cli and audio-studio profiles; NeuralRack itself is
# only built when a GUI stack (cairo + X11) is present, which means
# audio-studio in practice.
#
# On the audio-studio profile (the 'audio-plugins' package token) the
# stage additionally installs the LSP Plugins and Dragonfly Reverb LV2
# plugin packs, pre-loads any Neural Amp Modeler (.nam) starter models
# found in /sources, and applies the realtime audio tuning (audio
# group, /etc/security/limits.d, sysctl).  audio-cli stays a pure
# CLI/host stack: the plugin/token-gated phases are skipped there.
#
# Book deviation (documented in CHANGELOG.md): lv2/zix/serd/sord/
# sratom/lilv, NeuralRack, LSP Plugins and Dragonfly Reverb have no
# BLFS book page, so they are built from their canonical upstream
# release tarballs with pinned sha256 checksums verified BEFORE
# extraction.  The NeuralRack and LSP Plugins "-src" release tarballs
# bundle their git submodules / sub-projects; the generic GitHub
# refs/tags archive does not and cannot build.
#
# Environment contract (exported by builder.py): LFS, PROFILE,
# LFS_PROFILE_PACKAGES (comma-separated profile package tokens)
#======================================================================

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
[ -n "$LFS" ] || {
    log_error "LFS variable not set"
    exit 1
}

run_privileged() {
    if [ "$(whoami)" = "root" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

log_info "========================================="
log_info "Building audio studio stack (LV2 + NeuralRack)"
log_info "========================================="

# Defence in depth: builder.py only schedules this stage for the
# audio profiles, but a manual --resume-from must not poison other
# profiles with audio-only software.
case "${PROFILE:-audio-studio}" in
audio-*) ;;
*)
    log_info "audio-studio stage skipped (profile ${PROFILE} is not an audio profile)"
    exit 0
    ;;
esac

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – skipping audio studio packages"
    exit 0
fi

[ -x "$LFS/bin/bash" ] || {
    log_error "/bin/bash not found in $LFS/bin"
    exit 1
}
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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-audio-studio.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/audio-studio

JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/audio-studio/$1.done"; }

# Variant-safe archive lookup (same rules as the other BLFS stages):
# case-insensitive, underscores equal dashes, name-<version> tarballs
# preferred over oddball layouts, -src archives preferred.
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
    printf '%s\n' "${tier2[0]}"
    return 0
}

# Pinned upstream checksums.  Every archive is verified BEFORE it is
# extracted; a mismatch aborts the stage.
sha256_for() {
    case "$1" in
        lv2-1.18.10.tar.xz)
            echo "78c51bcf21b54e58bb6329accbb4dae03b2ed79b520f9a01e734bd9de530953f" ;;
        zix-0.4.2.tar.xz)
            echo "0c071cc11ab030bdc668bea3b46781b6dafd47ddd03b6d0c2bc1ebe7177e488d" ;;
        serd-0.32.4.tar.xz)
            echo "cbefb569e8db686be8c69cb3866a9538c7cb055e8f24217dd6a4471effa7d349" ;;
        sord-0.16.18.tar.xz)
            echo "4f398b635894491a4774b1498959805a08e11734c324f13d572dea695b13d3b3" ;;
        sratom-0.6.18.tar.xz)
            echo "4c6a6d9e0b4d6c01cc06a8849910feceb92e666cb38779c614dd2404a9931e92" ;;
        lilv-0.26.4.tar.xz)
            echo "1c8b5fcb78718173e67d76e51ad423f5113a9ff68463f2566195ae46396089e3" ;;
        libsndfile-1.2.2.tar.xz)
            echo "3799ca9924d3125038880367bf1468e53a1b7e3686a934f098b7e1d286cdb80e" ;;
        NeuralRack-v0.4.1-src.tar.xz)
            echo "82b88d2aa20155d7522b7eea030b5e888eb1ca5559af47be9a4870fa5d6226f7" ;;
        lsp-plugins-src-1.2.35.tar.gz)
            echo "2c95ec7bb219d561ea3db36051b6c732133bcd76426fb836b1dd850dc4b5bb6c" ;;
        dragonfly-reverb-3.2.10-src.tar.xz)
            echo "18af55a9592c9f50c4d5f86c9d5159132735d9ba53d49e9cfe7169b3109f7743" ;;
        *) return 1 ;;
    esac
}

verify_sha256() {
    local archive="$1" expected
    if ! expected="$(sha256_for "$archive")"; then
        log_error "No pinned sha256 for $archive; refusing to build"
        return 1
    fi
    if ! echo "$expected  $archive" | sha256sum -c - >/dev/null 2>&1; then
        log_error "sha256 mismatch for $archive (expected $expected)"
        return 1
    fi
    log_info "sha256 verified: $archive"
}

extract_archive() {
    local archive="$1" dir
    dir="$(tar -tf "$archive" | head -n 1 | cut -d/ -f1)"
    rm -rf "$dir"
    tar -xf "$archive"
    printf '%s\n' "$dir"
}

have_pc() { pkg-config --exists "$1" 2>/dev/null; }

# Profile package-token gate.  LFS_PROFILE_PACKAGES is the comma-separated
# package list exported by builder.py (_flatten_config of the profile
# 'packages' array).  'all' (the full profile) matches every token.
has_pkg() {
    case ",${LFS_PROFILE_PACKAGES:-}," in
        *,all,* | *,"$1",*) return 0 ;;
        *) return 1 ;;
    esac
}

is_installed() {
    local pkg="$1"
    [ -f "$(marker_for "$pkg")" ] && return 0
    case "$pkg" in
        zix) have_pc zix-0 ;;
        serd) have_pc serd-0 ;;
        sord) have_pc sord-0 ;;
        lv2) have_pc lv2 ;;
        sratom) have_pc sratom-0 ;;
        lilv) have_pc lilv-0 ;;
        libsndfile) have_pc sndfile ;;
        neuralrack) [ -d /usr/lib/lv2/NeuralRack.lv2 ] ;;
        lsp-plugins) compgen -G '/usr/lib/lv2/lsp-*.lv2' >/dev/null ;;
        dragonfly-reverb) [ -d /usr/lib/lv2/DragonflyHallReverb.lv2 ] ;;
        *) return 1 ;;
    esac
}

prep_src() {
    local pkg="$1" archive=""
    archive="$(find_archive "$pkg")"
    if [ -z "$archive" ]; then
        log_error "Source archive missing for $pkg"
        return 1
    fi
    verify_sha256 "$archive" || return 1
    log_info "Building $pkg from $archive" >&2
    extract_archive "$archive"
}

# Generic meson build for the drobilla LV2 host stack (no BLFS book
# page); docs/tests are disabled so no extra tooling is required.
meson_build() {
    local pkg="$1" dir
    shift
    if is_installed "$pkg"; then log_info "$pkg already installed; skipping"; return 0; fi
    dir="$(prep_src "$pkg")" || return 1
    pushd "$dir" >/dev/null || return 1
    rm -rf builddir
    meson setup builddir --prefix=/usr --buildtype=release \
        -Ddocs=disabled -Dtests=disabled "$@"
    ninja -C builddir
    ninja -C builddir install
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for "$pkg")"
    log_success "$pkg installed"
}

build_libsndfile() {
    local dir
    if is_installed libsndfile; then log_info "libsndfile already installed; skipping"; return 0; fi
    dir="$(prep_src libsndfile)" || return 1
    pushd "$dir" >/dev/null || return 1
    # BLFS book multimedia/libsndfile commands
    ./configure --prefix=/usr
    make -j"$JOBS"
    make install
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for libsndfile)"
    log_success "libsndfile installed"
}

build_neuralrack() {
    local dir
    if is_installed neuralrack; then log_info "NeuralRack already installed; skipping"; return 0; fi

    # The LV2 plugin links cairo/X11 through its Xputty GUI, so a
    # desktop stack is mandatory.  audio-studio ships one; audio-cli
    # does not and legitimately gets the LV2 host stack only.
    if ! have_pc cairo || ! have_pc x11; then
        if [ "${PROFILE:-audio-studio}" = "audio-studio" ]; then
            log_error "NeuralRack requires cairo and X11; desktop stack missing"
            return 1
        fi
        log_warning "Skipping NeuralRack (no GUI stack on profile ${PROFILE:-audio-cli})"
        return 0
    fi
    if ! have_pc sndfile || ! have_pc lilv-0 || ! have_pc lv2; then
        log_error "NeuralRack build prerequisites missing (sndfile/lilv-0/lv2)"
        return 1
    fi

    dir="$(prep_src NeuralRack)" || return 1
    pushd "$dir" >/dev/null || return 1
    # Upstream packaging status: `make lv2` then `make install` puts
    # NeuralRack.lv2 into /usr/lib/lv2.  The standalone app is only
    # attempted when an audio server API (JACK or ALSA) is present;
    # the Makefile itself skips it otherwise.
    make -j1 lv2
    if have_pc jack || have_pc alsa; then
        make -j1 standalone
    else
        log_warning "No jack/alsa pkg-config; standalone NeuralRack skipped"
    fi
    make install
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for neuralrack)"
    log_success "NeuralRack installed"
}

build_lsp_plugins() {
    local dir
    if is_installed lsp-plugins; then log_info "LSP Plugins already installed; skipping"; return 0; fi
    if ! have_pc cairo || ! have_pc x11 || ! have_pc sndfile; then
        log_error "LSP Plugins require cairo/x11/sndfile; desktop + audio stack missing"
        return 1
    fi
    dir="$(prep_src lsp-plugins)" || return 1
    pushd "$dir" >/dev/null || return 1
    # LSP auto-detects every format/backend; restrict to LV2 + LADSPA with
    # the cairo/X11 GUI so no JACK/GStreamer/OpenGL backend is required.
    make config PREFIX=/usr FEATURES="lv2 ladspa ui"
    make -j"$JOBS"
    make install
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for lsp-plugins)"
    log_success "LSP Plugins installed"
}

build_dragonfly_reverb() {
    local dir
    if is_installed dragonfly-reverb; then log_info "Dragonfly Reverb already installed; skipping"; return 0; fi
    if ! have_pc x11 || ! have_pc gl; then
        log_error "Dragonfly Reverb requires X11 + OpenGL (mesa); desktop stack missing"
        return 1
    fi
    dir="$(prep_src dragonfly-reverb)" || return 1
    pushd "$dir" >/dev/null || return 1
    # DPF framework is bundled under dpf/.  Build the LV2 bundles only
    # (skip VST2/VST3/DSSI/JACK-standalone); DPF has no install target,
    # so the bundles are copied into /usr/lib/lv2.
    make -j"$JOBS" BUILD_VST2=false BUILD_VST3=false BUILD_DSSI=false BUILD_JACK=false
    install -d /usr/lib/lv2
    cp -r bin/*.lv2 /usr/lib/lv2/
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for dragonfly-reverb)"
    log_success "Dragonfly Reverb installed"
}

# Best-effort Neural Amp Modeler starter content.  NeuralRack loads .nam
# models; any model pre-downloaded into /sources (add a pinned .nam URL
# to packages/custom-sources.list) is installed into the shared models
# directory.  A missing model set is a warning, never a build failure --
# models are optional open content with unstable hosting.
install_nam_models() {
    local models_dir=/usr/share/neuralrack/models f count=0
    install -d "$models_dir"
    for f in *.nam; do
        [ -f "$f" ] || continue
        if install -m 0644 "$f" "$models_dir/"; then
            count=$((count + 1))
            log_info "Installed NAM model: $f"
        fi
    done
    if [ "$count" -gt 0 ]; then
        log_success "$count NAM starter model(s) installed in $models_dir"
    else
        log_warning "No .nam starter models in /sources; NeuralRack ships functional but without presets"
    fi
}

# Realtime audio scheduling for members of the 'audio' group.  PipeWire
# grants realtime priority via RLIMIT when rtprio/memlock are raised, so
# no rtkit build is required.  The first-boot service already adds the
# created user to the 'audio' group (blfs/17-first-boot-service.sh); here
# we only make sure that group and the limits/sysctl actually exist.
realtime_tuning() {
    log_info "Applying realtime audio tuning"
    groupadd -f audio
    install -d /etc/security/limits.d
    cat > /etc/security/limits.d/audio.conf <<'EOF'
# Realtime audio scheduling for members of the audio group (audio profiles)
@audio   -   rtprio     99
@audio   -   memlock    unlimited
@audio   -   nice       -19
EOF
    install -d /etc/sysctl.d
    cat > /etc/sysctl.d/90-audio.conf <<'EOF'
# Low-latency audio tuning (audio profiles)
vm.swappiness = 10
fs.inotify.max_user_instances = 524288
EOF
    log_success "Realtime tuning applied (audio group + limits.d/audio.conf + sysctl)"
}

log_info "Phase 1: LV2 host stack (zix, serd, sord, lv2, sratom, lilv)"
meson_build zix
meson_build serd
meson_build sord
meson_build lv2 -Dplugins=disabled
meson_build sratom
meson_build lilv

log_info "Phase 2: libsndfile (BLFS book)"
build_libsndfile

log_info "Phase 3: NeuralRack v0.4.1 (LV2 + standalone)"
build_neuralrack

log_info "Phase 4: LV2 plugin packs (LSP Plugins + Dragonfly Reverb)"
if has_pkg audio-plugins; then
    build_lsp_plugins
    build_dragonfly_reverb
else
    log_info "Skipping plugin packs (no audio-plugins token on profile ${PROFILE:-audio-cli})"
fi

log_info "Phase 5: Neural Amp Modeler starter models (best-effort)"
if has_pkg audio-plugins; then
    install_nam_models
else
    log_info "Skipping NAM starter models (no audio-plugins token)"
fi

log_info "Phase 6: realtime audio tuning (audio group + limits + sysctl)"
realtime_tuning

log_success "Audio studio stack build complete"
INNEREOF

run_privileged chmod +x "$LFS/build-audio-studio.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    PROFILE="${PROFILE:-audio-studio}" \
    LFS_PROFILE_PACKAGES="${LFS_PROFILE_PACKAGES:-}" \
    /bin/bash /build-audio-studio.sh

log_success "Audio studio stack built successfully"
