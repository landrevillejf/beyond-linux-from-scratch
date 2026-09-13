#!/bin/bash
set -euo pipefail
# 29-build-calamares.sh
# Stage name: calamares-build.  Compiles the graphical installer itself plus
# every dependency no earlier stage installs, so that the calamares stage
# (blfs/22) configures an installer that actually exists.
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# Opt-in: builder.py resolves installer.type to "calamares" from the profile's
# graphical_installer flag or the --installer CLI override, and only schedules
# this stage then.  The guard below keeps a direct invocation (or a
# --resume-from run against a stale config) from compiling Qt6 anyway.
#
# Environment contract (exported by builder.py):
#   LFS_CONFIG_INSTALLER_TYPE        "calamares" runs the stage
#   LFS_PROFILE_GRAPHICAL_INSTALLER  profile declaration, logged only
#   LFS, SKIP_MAN_PAGES
#
# Book compliance: popt (general/popt), dosfstools (postlfs/dosfstools),
# gptfdisk (postlfs/gptfdisk), parted (postlfs/parted), qt6 (x/qt6),
# extra-cmake-modules plus the KF6 trio (kde/extra-cmake-modules and the
# kde/frameworks6 chapter loop) and polkit-qt-1 (kde/polkit-qt) reproduce
# their docs/books pages.  Three documented deviations:
#   * Qt6 is built trimmed -- see build_qt6 for the keep list and why.
#   * The books' optional documentation passes (parted's makeinfo/texi2pdf,
#     popt's doxygen) are skipped: texlive is deliberately dropped from the
#     sources by builder.py's UNUSED_SOURCE_PATTERNS and no stage installs
#     doxygen, so both would only fail offline.
#   * The books install Qt6/KF6 under /opt; here everything goes to /usr to
#     match the rest of the built system, exactly as blfs/09c does.
#
# yaml-cpp, kpmcore and calamares have no book page.  Their versions are
# pinned in packages/custom-sources.list and their flags come from each
# upstream CMakeLists, which is where the facts in the comments below were
# read from.
#
# Error policy (same as the other build stages): every package here is
# required, because each one is a link in the chain Calamares' partition page
# depends on.  A failure aborts the stage rather than shipping a half-built
# installer.

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

# ----------------------------------------------------------------------
# Guard: the graphical installer is strictly opt-in
# ----------------------------------------------------------------------
INSTALLER_TYPE="${LFS_CONFIG_INSTALLER_TYPE:-none}"
if [ "$INSTALLER_TYPE" != "calamares" ]; then
    log_info "graphical installer disabled (installer.type=$INSTALLER_TYPE) - calamares-build stage skipped"
    exit 0
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

run_privileged() { if [ "$(whoami)" = "root" ]; then "$@"; else sudo "$@"; fi; }

log_info "========================================="
log_info "Building the Calamares installer chain"
log_info "Profile flag graphical_installer: ${LFS_PROFILE_GRAPHICAL_INSTALLER:-unset}"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode - skipping the Calamares build chain"
    exit 0
fi

[ -x "$LFS/bin/bash" ] || {
    log_error "/bin/bash not found in $LFS/bin - run lfs-basic first"
    exit 1
}
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
    log_error "chroot not working - run lfs-basic first"
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
    for m in dev/pts dev proc sys run; do
        if run_privileged mountpoint -q "$LFS/$m" && ! run_privileged umount "$LFS/$m" 2>/dev/null; then
            log_warning "Could not unmount $LFS/$m"
        fi
    done
}
trap cleanup EXIT
mount_chroot_fs

SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    if ! run_privileged chown -R lfs:lfs "$LFS/sources" 2>/dev/null; then
        log_warning "Could not chown $LFS/sources to lfs:lfs"
    fi
fi

cat <<'INNEREOF' | run_privileged tee "$LFS/build-calamares.sh" >/dev/null
#!/bin/bash
set -euo pipefail
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }
cd /sources
mkdir -p /var/lib/lfs-builder/calamares
JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/calamares/$1.done"; }
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
# Shared-library probe that survives either libdir spelling: the ECM
# lib64->lib sed below only applies to the KDE packages, and a future
# toolchain could still put a plain cmake project under /usr/lib64.
have_lib() {
    local pattern="$1" d
    for d in /usr/lib /usr/lib64; do
        [ -d "$d" ] || continue
        if compgen -G "$d/$pattern" >/dev/null 2>&1; then return 0; fi
    done
    return 1
}

is_installed() {
    local pkg="$1"
    [ -f "$(marker_for "$pkg")" ] && return 0
    case "$pkg" in
        popt)                 have_pc popt ;;
        dosfstools)           have_cmd mkfs.vfat ;;
        gptfdisk)             have_cmd sgdisk ;;
        parted)               have_cmd parted ;;
        qt6)                  have_pc Qt6Core ;;
        extra-cmake-modules)  have_cmd cmake && [ -d /usr/share/ECM ] ;;
        kcoreaddons)          have_pc KF6CoreAddons ;;
        ki18n)                have_pc KF6I18n ;;
        kwidgetsaddons)       have_pc KF6WidgetsAddons ;;
        polkit-qt-1)          have_lib 'libpolkit-qt6-core-1.so*' ;;
        yaml-cpp)             have_pc yaml-cpp || have_lib 'libyaml-cpp.so*' ;;
        kpmcore)              have_lib 'libkpmcore.so*' ;;
        calamares)            [ -x /usr/bin/calamares ] ;;
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

# Run the book commands of one package inside its freshly extracted
# source tree.  The second argument is the name of the
# build_commands_<name> function holding them; JOBS and dir are exported.
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

# ======================================================================
# Filesystem tools.  kpmcore only shells out to these -- its CMakeLists
# links blkid (util-linux, LFS chapter 8) and nothing else -- but the
# partition page cannot create an ESP without mkfs.vfat, cannot write a
# GPT without sgdisk, and cannot resize without parted.  None of the
# three exists in the target today.
# ======================================================================

# general/popt -- required by gptfdisk's sgdisk (the book lists popt-1.19
# as gptfdisk's only required dependency).
build_popt() { book_install popt build_commands_popt; }
build_commands_popt() {
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# postlfs/dosfstools
build_dosfstools() { book_install dosfstools build_commands_dosfstools; }
build_commands_dosfstools() {
    local srcname
    srcname="$(basename "$PWD")"
    ./configure --prefix=/usr                  \
                --enable-compat-symlinks       \
                --mandir=/usr/share/man        \
                --docdir="/usr/share/doc/$srcname" &&
    make -j"$JOBS" && make install
}

# postlfs/gptfdisk
build_gptfdisk() { book_install gptfdisk build_commands_gptfdisk; }
build_commands_gptfdisk() {
    local p rc=0 patched=0
    # The book's "convenience" patch is what gives gptfdisk's rudimentary
    # Makefile a usable build and install interface, so the make install
    # below has something to run.  Both of the book's naming conventions
    # are tried; a missing patch is reported rather than passed over in
    # silence (nightly #186, httpd's blfs_layout patch).
    for p in ../gptfdisk-*-convenience-*.patch ../gptfdisk-convenience-*.patch; do
        [ -f "$p" ] || continue
        patched=1
        patch -Np1 -i "$p" || rc=1
    done
    if [ "$rc" -ne 0 ]; then
        log_error "gptfdisk convenience patch failed to apply"
        return 1
    fi
    if [ "$patched" -eq 0 ]; then
        log_warning "no gptfdisk convenience patch in /sources; building the stock Makefile"
    fi
    sed -i 's|ncursesw/||' gptcurses.cc &&
    sed -i 's|sbin|usr/sbin|' Makefile &&
    make && make install
}

# postlfs/parted.  LVM2 is the book's recommended dependency and no stage
# builds device-mapper, so parted is configured without it; kpmcore's GPT
# work goes through sgdisk either way.
build_parted() { book_install parted build_commands_parted; }
build_commands_parted() {
    sed -i 's/do_version ()/do_version (PedDevice** dev, PedDisk** diskp)/' parted/parted.c &&
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# ======================================================================
# Qt6.  x/qt6, trimmed (documented deviation).
#
# Calamares 3.3.14 asks for Qt6 Concurrent Core DBus Gui LinguistTools
# Network Svg Widgets, and Quick/QuickWidgets only when WITH_QML is on --
# which it is not here.  qtbase covers all of those but Svg and
# LinguistTools, and each kept module's dependencies.yaml at 6.9.2 lists
# qtbase as its only required dependency (qttranslations needs qttools),
# so the four modules below are a closed set.  Everything else in
# qt-everywhere-src is skipped: building the whole tarball is what pushes
# the kde and full legs past GitHub's hard six-hour cap.
#
# The skip list is derived from the tarball instead of being hardcoded, so
# a book version bump cannot silently add an hour of compilation back.
# If qttools ever fails to configure without qtdeclarative, add it to
# QT_KEEP_MODULES and update the note above.
# ======================================================================
QT_KEEP_MODULES="qtbase qtsvg qttools qttranslations"
build_qt6() {
    local archive dir module rc=0
    local -a skip=()
    if have_pc Qt6Core && have_pc Qt6Svg && have_pc Qt6Widgets; then
        log_info "qt6 already installed; skipping"
        touch "$(marker_for qt6)"
        return 0
    fi
    archive="$(find_archive qt-everywhere-src)"
    if [ -z "$archive" ]; then
        log_error "Source archive missing for qt6 (qt-everywhere-src)"
        return 1
    fi
    log_info "Building qt6 from $archive (trimmed: keeping $QT_KEEP_MODULES)" >&2
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null || return 1
    for module in qt*; do
        # Only real module repositories carry .cmake.conf; anything else in
        # the tarball is left alone rather than passed to -skip, which
        # configure rejects for names it does not know.
        [ -d "$module" ] || continue
        [ -f "$module/.cmake.conf" ] || continue
        case " $QT_KEEP_MODULES " in
            *" $module "*) continue ;;
        esac
        skip+=(-skip "$module")
    done
    if [ "${#skip[@]}" -eq 0 ]; then
        log_error "no Qt module to skip: refusing to build all of qt-everywhere-src"
        popd >/dev/null
        return 1
    fi
    log_info "qt6: skipping $(( ${#skip[@]} / 2 )) modules" >&2
    # The book's i686 qtypes.h sed is not reproduced: no profile targets
    # 32-bit x86, and the guard below would never fire.
    ./configure -prefix /usr              \
                -sysconfdir /etc/xdg      \
                -dbus-linked              \
                -openssl-linked           \
                -system-sqlite            \
                -nomake examples          \
                -no-rpath                 \
                -no-sbom                  \
                -syslog                   \
                "${skip[@]}" &&
    ninja &&
    ninja install &&
    find /usr/ -name '*.prl' -exec sed -i -e '/^QMAKE_PRL_BUILD_DIR/d' {} \; || rc=1
    popd >/dev/null
    # run_build calls this from an "if" condition, where set -e is
    # suspended: without its own status tracking a failed ninja would
    # still reach the marker and be reported as installed (nightly #232).
    if [ "$rc" -ne 0 ]; then
        log_error "qt6 build failed"
        return "$rc"
    fi
    rm -rf "$dir"
    touch "$(marker_for qt6)"
    log_success "qt6 installed"
}

# kde/extra-cmake-modules.  Calamares' CMakeLists does
# find_package(ECM 5.240 NO_MODULE) and kpmcore's does
# find_package(ECM 5.240.0 REQUIRED NO_MODULE), so this must land before
# both of them.
build_extra_cmake_modules() { book_install extra-cmake-modules build_commands_extra_cmake_modules; }
build_commands_extra_cmake_modules() {
    local p rc=0 patched=0
    for p in ../extra-cmake-modules-*-upstream_fix-*.patch; do
        [ -f "$p" ] || continue
        patched=1
        patch -Np1 -i "$p" || rc=1
    done
    if [ "$rc" -ne 0 ]; then
        log_error "extra-cmake-modules upstream_fix patch failed to apply"
        return 1
    fi
    if [ "$patched" -eq 0 ]; then
        log_warning "no extra-cmake-modules upstream_fix patch in /sources; building the stock tree"
    fi
    # shellcheck disable=SC2016
    sed -i '/"lib64"/s/64//' kde-modules/KDEInstallDirsCommon.cmake &&
    sed -e '/PACKAGE_INIT/i set(SAVE_PACKAGE_PREFIX_DIR "${PACKAGE_PREFIX_DIR}")' \
        -e '/^include/a set(PACKAGE_PREFIX_DIR "${SAVE_PACKAGE_PREFIX_DIR}")' \
        -i ECMConfig.cmake.in &&
    mkdir build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr -D BUILD_WITH_QT6=ON .. &&
    make -j"$JOBS" && make install
}

# kde/frameworks6 chapter loop: kpmcore requires CoreAddons, I18n and
# WidgetsAddons (>= 5.240), and Calamares' KPMcoreHelper.cmake requires
# I18n and WidgetsAddons again once it has found kpmcore.
build_commands_kf6() {
    mkdir build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr        \
          -D CMAKE_INSTALL_LIBEXECDIR=libexec \
          -D CMAKE_SKIP_INSTALL_RPATH=ON      \
          -D CMAKE_BUILD_TYPE=Release         \
          -D BUILD_TESTING=OFF                \
          -D BUILD_PYTHON_BINDINGS=OFF        \
          -W no-dev .. &&
    make -j"$JOBS" && make install
}
build_kf6_pkg() { book_install "$1" build_commands_kf6; }

# kde/polkit-qt.  QT_MAJOR_VERSION=6 is the book's flag: it is what makes
# the package install libpolkit-qt6-*-1.so and PolkitQt6-1Config.cmake,
# which both kpmcore and Calamares (INSTALL_POLKIT=ON) look up by name.
build_polkit_qt_1() { book_install polkit-qt-1 build_commands_polkit_qt_1; }
build_commands_polkit_qt_1() {
    mkdir build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D CMAKE_BUILD_TYPE=Release  \
          -D QT_MAJOR_VERSION=6        \
          -W no-dev .. &&
    make -j"$JOBS" && make install
}

# ======================================================================
# Packages with no book page.  Versions pinned in
# packages/custom-sources.list, flags read off each upstream CMakeLists.
# ======================================================================

# yaml-cpp 0.7.0 -- Calamares' FindYAMLCPP.cmake only needs
# /usr/include/yaml-cpp/yaml.h and a libyaml-cpp to link, so the shared
# build is what satisfies it.  Tests stay off: they pull in a bundled
# googletest the offline chroot cannot fetch.  The policy floor is not
# cosmetic -- yaml-cpp declares cmake_minimum_required(VERSION 3.4) and
# the book's cmake 4.1 refuses to configure anything older than 3.5
# without it (the same reason 08a and 09c pass it to libportal and sddm).
build_yaml_cpp() { book_install yaml-cpp build_commands_yaml_cpp; }
build_commands_yaml_cpp() {
    mkdir build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr         \
          -D CMAKE_BUILD_TYPE=Release          \
          -D CMAKE_POLICY_VERSION_MINIMUM=3.5  \
          -D CMAKE_SKIP_INSTALL_RPATH=ON       \
          -D YAML_BUILD_SHARED_LIBS=ON         \
          -D YAML_CPP_BUILD_TESTS=OFF          \
          -W no-dev .. &&
    make -j"$JOBS" && make install
}

# kpmcore 25.08.0 -- the partition page's engine.  Its CMakeLists requires
# ECM, Qt6 (Core DBus Gui Widgets), KF6 (CoreAddons I18n WidgetsAddons),
# PolkitQt6-1 and blkid >= 2.33.2, and it adds its test subdirectory
# unconditionally, so Qt6Test (qtbase) has to be present whether or not
# BUILD_TESTING is off.  It installs KPMcoreConfig.cmake, which is how
# Calamares' find_package(KPMcore 24.01.75) resolves it.
build_kpmcore() { book_install kpmcore build_commands_kpmcore; }
build_commands_kpmcore() {
    mkdir build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr        \
          -D CMAKE_INSTALL_LIBEXECDIR=libexec \
          -D CMAKE_SKIP_INSTALL_RPATH=ON      \
          -D CMAKE_BUILD_TYPE=Release         \
          -D BUILD_TESTING=OFF                \
          -W no-dev .. &&
    make -j"$JOBS" && make install
}

# calamares 3.3.14.  WITH_QML=OFF is what keeps qtdeclarative out of the
# trimmed Qt6 above; WITH_PYTHON=OFF drops the Boost/Python job-module API,
# which the blfs/22 sequence does not use; BUILD_CRASH_REPORTING=OFF avoids
# a KF6Crash dependency; INSTALL_POLKIT=ON ships the polkit policy the
# launcher uses to run the installer as root; INSTALL_CONFIG=ON installs the
# stock settings.conf and per-module .conf files that /etc/calamares then
# overrides.
build_calamares() { book_install calamares build_commands_calamares; }
build_commands_calamares() {
    mkdir build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr        \
          -D CMAKE_INSTALL_LIBDIR=lib         \
          -D CMAKE_INSTALL_LIBEXECDIR=libexec \
          -D CMAKE_BUILD_TYPE=Release         \
          -D CMAKE_SKIP_INSTALL_RPATH=ON      \
          -D WITH_QT6=ON                      \
          -D WITH_QML=OFF                     \
          -D WITH_PYTHON=OFF                  \
          -D BUILD_CRASH_REPORTING=OFF        \
          -D INSTALL_POLKIT=ON                \
          -D INSTALL_CONFIG=ON                \
          -D BUILD_TESTING=OFF                \
          -W no-dev .. &&
    make -j"$JOBS" && make install
}

# Policy wrapper: every package in this stage is required, so any failure
# aborts the stage instead of shipping an installer with a hole in it.
run_build() {
    local mode="$1" pkg="$2" fn=""
    shift 2
    fn="build_${pkg//-/_}"
    if ! declare -F "$fn" >/dev/null; then
        case "$pkg" in
            kcoreaddons|ki18n|kwidgetsaddons) fn=build_kf6_pkg ;;
            *) fn="" ;;
        esac
    fi
    if [ -n "$fn" ]; then
        if "$fn" "$pkg" "$@"; then
            return 0
        fi
    else
        log_error "No build function for $pkg"
        return 1
    fi
    if [ "$mode" = "required" ]; then
        log_error "Required package $pkg failed - aborting stage"
        exit 1
    fi
    log_warning "[OPTIONAL] $pkg failed or is missing - continuing"
}

verify_prerequisites() {
    local missing=() pc
    # Everything below is installed by an earlier stage of a desktop
    # profile: cmake by blfs-base, ninja by lfs-system, dbus and the X
    # stack by blfs-libs/xorg, polkit by display-manager, blkid and
    # sqlite by LFS chapter 8.  Nothing this stage builds itself may
    # appear here (nightly #183 asked blfs-libs for its own pcre2).
    for pc in blkid dbus-1 openssl sqlite3 polkit-gobject-1; do
        have_pc "$pc" 2>/dev/null || missing+=("$pc")
    done
    if ! have_cmd cmake; then
        missing+=("cmake (required for the KF6/kpmcore/calamares builds)")
    fi
    if ! have_cmd ninja; then
        missing+=("ninja (required for Qt6 builds)")
    fi
    if [ "${#missing[@]}" -ne 0 ]; then
        log_error "Missing Calamares prerequisites: ${missing[*]}"
        log_error "Build blfs-base, blfs-libs and display-manager before this stage."
        exit 1
    fi
}

# Hard post-condition.  Calamares' CMakeModules/KPMcoreHelper.cmake calls
# calamares_skip_module("partition (missing suitable KPMcore)") when it
# cannot find kpmcore, and a skipped module is only a line in the cmake
# output: the installer still builds, still runs, and still lists
# "partition" in its sequence -- with no page behind it.  That is exactly
# how blfs/22 came to configure an installer nobody had compiled, so the
# stage now fails instead of reporting success without the plugin.
# CalamaresAddPlugin.cmake installs view modules under
# <libdir>/calamares/modules/<module name>/libcalamares_viewmodule_<name>.so.
verify_partition_module() {
    local d found=""
    for d in /usr/lib /usr/lib64; do
        [ -d "$d/calamares/modules" ] || continue
        found="$(find "$d/calamares/modules" -name 'libcalamares_viewmodule_partition.so' -print -quit)"
        if [ -n "$found" ]; then
            break
        fi
    done
    if [ -z "$found" ]; then
        log_error "Calamares installed without its partition view module"
        log_error "expected libcalamares_viewmodule_partition.so under /usr/lib*/calamares/modules"
        log_error "the installer would start with no partition page; refusing to continue"
        return 1
    fi
    log_success "partition module: $found"
}

verify_prerequisites

log_info "Building filesystem tools (popt, gptfdisk, dosfstools, parted)"
run_build required popt
run_build required gptfdisk
run_build required dosfstools
run_build required parted

log_info "Building Qt6 layer"
run_build required qt6
run_build required extra-cmake-modules

log_info "Building the KF6 frameworks kpmcore requires"
run_build required kcoreaddons
run_build required ki18n
run_build required kwidgetsaddons

log_info "Building polkit-qt-1 (Qt6 variant)"
run_build required polkit-qt-1

log_info "Building yaml-cpp"
run_build required yaml-cpp

log_info "Building kpmcore"
run_build required kpmcore

log_info "Building calamares"
run_build required calamares

verify_partition_module

log_success "Calamares build chain installed"
INNEREOF

run_privileged chmod +x "$LFS/build-calamares.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-calamares.sh

# Re-assert the post-condition from the host side, against the tree the
# release pipeline actually ships: a marker file inside the chroot cannot
# survive a resumed run that skipped the build, and the partition plugin is
# the one artifact without which the installer is decorative.
partition_plugin=""
for libdir in "$LFS/usr/lib" "$LFS/usr/lib64"; do
    [ -d "$libdir/calamares/modules" ] || continue
    partition_plugin="$(run_privileged find "$libdir/calamares/modules" \
        -name 'libcalamares_viewmodule_partition.so' -print -quit)"
    if [ -n "$partition_plugin" ]; then
        break
    fi
done
if [ -z "$partition_plugin" ]; then
    log_error "No libcalamares_viewmodule_partition.so under $LFS/usr/lib*/calamares/modules"
    log_error "The calamares stage would configure an installer with no partition page."
    exit 1
fi
if [ ! -x "$LFS/usr/bin/calamares" ]; then
    log_error "$LFS/usr/bin/calamares is missing or not executable"
    exit 1
fi

log_success "Calamares installer chain built: $partition_plugin"
