#!/bin/bash
set -euo pipefail
# 21-luks-encryption.sh
# Stage name: luks-encryption.  Builds the storage-encryption toolchain
# (device-mapper/LVM2, cryptsetup, mdadm and the libraries they need) into the
# target, then writes the LUKS configuration the installer and the initramfs
# rely on, so an encrypted root chosen at install time is actually unlockable
# at boot.
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# Opt-in: builder.py schedules this stage only when the profile sets
# security_hardening or security.encryption.enabled is true, and always BEFORE
# initramfs (final/12) so the tools installed here are the ones the initramfs
# bundles for its LUKS unlock path.
#
# Environment contract (exported by builder.py):
#   LFS, SKIP_MAN_PAGES
#
# Why this is a build stage and not just configuration: the previous version of
# this script only wrote /etc files and *warned* that cryptsetup was missing.
# Nothing in the tree compiled cryptsetup, LVM2 or mdadm, no kernel-config
# variant carried dm-crypt, and the initramfs had no unlock path -- so
# enableLuksAutomatedPartitioning in blfs/22 offered an encryption the
# installed system could never boot (the config was also written to the Debian
# path /etc/initramfs-tools/modules, which this project's busybox initramfs
# never reads, and probed the non-existent kernel symbols CONFIG_MD_CRYPT /
# CONFIG_MD_DM).  This stage now builds the real toolchain; the matching kernel
# symbols (CONFIG_DM_CRYPT, CONFIG_BLK_DEV_DM, CONFIG_MD, ...) are built into
# every config/kernel-config* variant, and final/12 bundles cryptsetup + lvm
# into the initramfs and unlocks cryptdevice= before switch_root.
#
# Build order (each is a link cryptsetup/LVM depend on):
#   json-c      cryptsetup 2.x reads and writes LUKS2 metadata through json-c.
#   popt        cryptsetup's CLI argument parser.  calamares-build (blfs/29)
#               also builds popt when that opt-in stage runs; is_installed
#               reuses it there instead of rebuilding.
#   LVM2        provides libdevmapper (cryptsetup's device backend) plus the
#               lvm/dmsetup tools the partition page and the initramfs use.
#   cryptsetup  the LUKS frontend, openssl backend (openssl is built by
#               blfs/08-build-blfs-base.sh).
#   mdadm       MD-RAID assembly for redundant installs.
#
# Error policy (same as the other build stages): every package here is
# required, because a hole in this chain is exactly what made encryption
# decorative before.  A failure aborts the stage rather than shipping an
# installer whose encryption option silently produces an unbootable system.

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

run_privileged() { if [ "$(whoami)" = "root" ]; then "$@"; else sudo "$@"; fi; }

write_file() {
    local path="$1" mode="$2"
    run_privileged mkdir -p "$(dirname "$LFS$path")"
    run_privileged tee "$LFS$path" >/dev/null
    run_privileged chmod "$mode" "$LFS$path"
}

log_info "========================================="
log_info "Building the LUKS/LVM storage-encryption toolchain"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode - skipping the LUKS build chain"
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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-luks.sh" >/dev/null
#!/bin/bash
set -euo pipefail
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }
cd /sources
mkdir -p /var/lib/lfs-builder/luks
JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/luks/$1.done"; }
# Match package names case-insensitively (LVM2.2.03.34.tgz), treat underscores
# like dashes, prefer name-<version> tarballs over documentation variants, and
# fall back to oddball layouts.  Same resolver the other build stages use.
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
        json-c)      have_pc json-c || have_lib 'libjson-c.so*' ;;
        popt)        have_pc popt || have_lib 'libpopt.so*' ;;
        lvm2)        have_cmd lvm && have_lib 'libdevmapper.so*' ;;
        cryptsetup)  have_cmd cryptsetup ;;
        mdadm)       have_cmd mdadm ;;
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
    log_info "Building $pkg from $archive" >&2
    extract_archive "$archive"
}

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
# json-c.  No book page; version pinned in packages/custom-sources.list.
# cryptsetup 2.x parses LUKS2 metadata with json-c, so it must land first.
# cmake is installed by blfs/08-build-blfs-base.sh.
# ======================================================================
build_json_c() { book_install json-c build_commands_json_c; }
# The policy floor is not cosmetic: json-c's apps/CMakeLists.txt declares
# cmake_minimum_required(VERSION 2.8) and the book's cmake 4.1 refuses to
# configure anything older than 3.5 without it (the same reason 08a, 09c
# and blfs/29 pass it).  Without the flag the apps subdirectory aborts with
# "Compatibility with CMake < 3.5 has been removed" and json-c -- cryptsetup's
# LUKS2 metadata backend -- never installs (lg3d nightly #58).
build_commands_json_c() {
    mkdir -p build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D CMAKE_BUILD_TYPE=Release \
          -D BUILD_SHARED_LIBS=ON \
          -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
          -W no-dev .. &&
    make -j"$JOBS" && make install
}

# ======================================================================
# general/popt.  cryptsetup's CLI parser.  Reused, not rebuilt, when the
# opt-in calamares-build stage already installed it.
# ======================================================================
build_popt() { book_install popt build_commands_popt; }
build_commands_popt() {
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# ======================================================================
# postlfs/lvm2.  Provides libdevmapper (cryptsetup's device backend) and
# the lvm/dmsetup tools.  udev sync and udev rules are disabled: nothing
# runs udev inside the build chroot, the device-mapper/LUKS/LVM kernel
# drivers are built in (config/kernel-config*), and the initramfs activates
# volumes explicitly (cryptsetup luksOpen / lvm vgchange -ay) rather than
# relying on udev events, so the sync would only stall the build.
# ======================================================================
build_lvm2() { book_install lvm2 build_commands_lvm2; }
build_commands_lvm2() {
    ./configure --prefix=/usr          \
                --sysconfdir=/etc      \
                --enable-pkgconfig     \
                --enable-cmdlib        \
                --disable-udev_sync    \
                --disable-udev_rules   &&
    make -j"$JOBS" &&
    make install
}

# ======================================================================
# postlfs/cryptsetup.  openssl backend (openssl built by blfs/08); the
# ssh-token helper is disabled so no libssh dependency is pulled in.
# Needs libdevmapper (lvm2 above), popt, json-c and util-linux's
# libuuid/libblkid (LFS chapter 8).
#
# --disable-asciidoc: cryptsetup's configure.ac defaults enable_asciidoc
# to yes and hard-errors ("Building man pages requires asciidoctor
# installed.") when asciidoctor is absent -- nightly lg3d #60 aborted the
# stage here.  The offline CI chroot builds no asciidoctor, and man pages
# are not part of the LUKS unlock path (the initramfs only needs the
# cryptsetup binary), so man-page generation is turned off rather than
# pulling in a Ruby toolchain.
# ======================================================================
build_cryptsetup() { book_install cryptsetup build_commands_cryptsetup; }
build_commands_cryptsetup() {
    ./configure --prefix=/usr                 \
                --sbindir=/usr/sbin           \
                --with-crypto_backend=openssl \
                --disable-ssh-token           \
                --disable-asciidoc            &&
    make -j"$JOBS" && make install
}

# ======================================================================
# postlfs/mdadm.  Plain Makefile; MD-RAID assembly for redundant installs.
# The matching CONFIG_MD* symbols are built into every kernel-config variant.
# ======================================================================
build_mdadm() { book_install mdadm build_commands_mdadm; }
build_commands_mdadm() {
    make -j"$JOBS" SYSCONFDIR=/etc &&
    make install SYSCONFDIR=/etc
}

# Policy wrapper: every package in this stage is required, so any failure
# aborts the stage instead of shipping an installer whose encryption option
# produces an unbootable system.
run_build() {
    local mode="$1" pkg="$2" fn=""
    shift 2
    fn="build_${pkg//-/_}"
    if ! declare -F "$fn" >/dev/null; then
        log_error "No build function for $pkg"
        return 1
    fi
    if "$fn" "$pkg" "$@"; then
        return 0
    fi
    if [ "$mode" = "required" ]; then
        log_error "Required package $pkg failed - aborting stage"
        exit 1
    fi
    log_warning "[OPTIONAL] $pkg failed or is missing - continuing"
}

log_info "Building json-c (LUKS2 metadata backend)"
run_build required json-c

log_info "Building popt (cryptsetup CLI parser)"
run_build required popt

log_info "Building LVM2 (libdevmapper + lvm/dmsetup)"
run_build required lvm2

log_info "Building cryptsetup (openssl backend)"
run_build required cryptsetup

log_info "Building mdadm (MD-RAID)"
run_build required mdadm

log_success "LUKS/LVM/MD storage-encryption toolchain installed"
INNEREOF

run_privileged chmod +x "$LFS/build-luks.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-luks.sh

# ----------------------------------------------------------------------
# Host-side post-conditions, checked against the tree the release pipeline
# actually ships.  A marker file inside the chroot cannot survive a resumed
# run that skipped the build, and these three binaries are the ones the
# initramfs bundles (final/12) and the installer's partition page shells out
# to; without them an encrypted install is unbootable, so their absence is a
# hard failure rather than a warning.
# ----------------------------------------------------------------------
find_tool() {
    local name="$1" d
    for d in usr/sbin usr/bin sbin bin; do
        if [ -x "$LFS/$d/$name" ]; then
            printf '%s\n' "$LFS/$d/$name"
            return 0
        fi
    done
    return 1
}
for tool in cryptsetup lvm dmsetup; do
    if ! found="$(find_tool "$tool")"; then
        log_error "$tool not found in $LFS after the build"
        log_error "LUKS/LVM would not work; the initramfs could not unlock an encrypted root"
        exit 1
    fi
    log_success "$tool: $found"
done

# ----------------------------------------------------------------------
# crypttab template.  The installer (Calamares luksbootkeyfile/fstab) fills in
# the real entries at install time; an empty template keeps the file present
# and documents the format for a manual setup in the live session.
# ----------------------------------------------------------------------
write_file /etc/crypttab 0640 <<'CRYPTTAB'
# <target name>  <source device>       <key file>  <options>
# Filled in by the installer for an encrypted root, e.g.:
# luks-root  UUID=xxxx-xxxx-xxxx  none  luks,discard
CRYPTTAB

log_success "LUKS encryption support built and configured"
log_success "  - cryptsetup/lvm/dmsetup/mdadm installed into the target"
log_success "  - crypttab template: /etc/crypttab"
log_success "  - initramfs (final/12) bundles these for the LUKS unlock at boot"
