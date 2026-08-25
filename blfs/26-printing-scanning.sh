#!/bin/bash
# 16-printing-scanning.sh
# Build BLFS Printing and Scanning packages (Part IX of BLFS book)
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# Error policy (audit finding F-07): a required package failure aborts the
# stage.  Only packages that are explicitly optional (missing from
# packages/stable/12.4/sources.list) may fail with a warning.
#
# Book compliance (audit finding F-07, wave 3): cups, cups-filters,
# ghostscript (pst/gs), gutenprint and sane-backends (pst/sane) are
# built with the commands of their docs/books pages.  gsfonts, hplip
# and sane-frontends have no book page and use the generic build_pkg
# fallback.
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
log_info "Building BLFS Printing and Scanning"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – skipping printing/scanning packages"
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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-printing.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/printing

JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/printing/$1.done"; }
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
have_pc() { pkg-config --exists "$1" 2>/dev/null; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_installed() {
    local pkg="$1"
    [ -f "$(marker_for "$pkg")" ] && return 0
    case "$pkg" in
        cups) have_cmd cupsd ;;
        cups-filters) have_pc libcupsfilters ;;
        ghostscript) have_cmd gs ;;
        gsfonts) [ -d /usr/share/fonts/ghostscript ] ;;
        gutenprint) have_pc gutenprint ;;
        hplip) have_cmd hp-setup ;;
        sane-backends) have_cmd sane-config || have_cmd scanimage ;;
        sane-frontends) have_cmd xscanimage || have_cmd xsane ;;
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
    log_info "Building $pkg from $archive" >&2
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
# (gsfonts, hplip, sane-frontends).
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

# ======================================================================
# Per-package BLFS book commands (wave 3, pst chapter).
# ======================================================================

# BLFS pst/cups
build_cups() { book_install cups build_commands_cups; }
build_commands_cups() {
    if [ -f desktop/cups.desktop.in ]; then
        sed -i 's#@CUPS_HTMLVIEW@#firefox#' desktop/cups.desktop.in
    fi
    ./configure --libdir=/usr/lib            \
                --with-rcdir=/tmp/cupsinit   \
                --with-rundir=/run/cups      \
                --with-system-groups=lpadmin \
                --with-docdir="/usr/share/cups/doc-${dir#cups-}" &&
    make -j"$JOBS" && make install || return 1
    if have_cmd gtk-update-icon-cache; then
        gtk-update-icon-cache -qtf /usr/share/icons/hicolor || return 1
    fi
}

# BLFS pst/cups-filters
build_cups_filters() { book_install cups-filters build_commands_cups_filters; }
build_commands_cups_filters() {
    if [ -f filter/foomatic-rip/process.h ]; then
        sed -i '/proc_func)()/s/()/(FILE*, FILE*, void*)/' filter/foomatic-rip/process.h
    fi
    ./configure --prefix=/usr    \
                --disable-static \
                --docdir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install
}

# BLFS pst/gs – bundled libraries are removed in favour of the system
# ones; the gcc15 patch is applied only when shipped.
build_ghostscript() { book_install ghostscript build_commands_ghostscript; }
build_commands_ghostscript() {
    local p
    rm -rf freetype lcms2mt jpeg libpng openjpeg
    for p in ../ghostscript-*-gcc15_fixes-*.patch; do
        [ -f "$p" ] || continue
        patch -Np1 -i "$p" || return 1
    done
    rm -rf zlib &&
    ./configure --prefix=/usr           \
                --disable-compile-inits \
                --with-system-libtiff   &&
    make -j"$JOBS" && make so &&
    make install && make soinstall
}

# BLFS pst/gutenprint
build_gutenprint() { book_install gutenprint build_commands_gutenprint; }
build_commands_gutenprint() {
    # shellcheck disable=SC2016
    sed -i 's|$(PACKAGE)/doc|doc/$(PACKAGE)-$(VERSION)|' \
           {,doc/,doc/developer/}Makefile.in &&
    ./configure --prefix=/usr    \
                --disable-static \
                --without-gimp2  \
                --without-gimp2-as-gutenprint &&
    make -j"$JOBS" && make install
}

# BLFS pst/sane – the book runs configure inside sg scanner; fall back
# to the current user when the scanner group does not exist yet.
build_sane_backends() { book_install sane-backends build_commands_sane_backends; }
build_commands_sane_backends() {
    local cfg
    cfg="PYTHON=python3 ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --with-lockdir=/run/lock --docdir=/usr/share/doc/$dir"
    if getent group scanner >/dev/null 2>&1 && have_cmd sg; then
        sg scanner -c "$cfg" || return 1
    else
        PYTHON=python3 ./configure --prefix=/usr        \
                                   --sysconfdir=/etc    \
                                   --localstatedir=/var \
                                   --with-lockdir=/run/lock \
                                   --docdir="/usr/share/doc/$dir" || return 1
    fi
    make -j"$JOBS" && make install
}

# Policy wrapper (audit finding F-07).  required: any failure aborts the
# stage.  optional: failures are logged and the build continues.
# Printing packages get their book commands; packages without a BLFS
# book page (gsfonts, hplip, sane-frontends) use the generic build_pkg.
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

log_info "Phase 1: CUPS printing system"

# cups – CUPS printing system
run_build required cups

# cups-filters – CUPS filters
run_build required cups-filters

log_info "Phase 2: Ghostscript and fonts"

# ghostscript – PostScript and PDF interpreter
run_build required ghostscript

# gsfonts – Ghostscript fonts; not in packages/stable/12.4/sources.list
run_build optional gsfonts

log_info "Phase 3: Printer drivers"

# gutenprint – Gutenprint printer drivers
run_build required gutenprint

# hplip – HP Linux Imaging and Printing; not in the source list
run_build optional hplip

log_info "Phase 4: SANE scanning system"

# sane-backends – SANE scanner backends
run_build required sane-backends

# sane-frontends – SANE scanner frontends; not in the source list
run_build optional sane-frontends

log_success "BLFS Printing and Scanning build complete"
INNEREOF

run_privileged chmod +x "$LFS/build-printing.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-printing.sh

log_success "BLFS Printing and Scanning built successfully"
