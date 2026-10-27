#!/bin/bash
# 31-build-selinux.sh
# Build the SELinux userspace stack and install the refpolicy targeted
# policy, then wire enforcing mode + first-boot relabel.
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -euo pipefail
#
# Phase 2 of the NSA/CIA/banking-grade hardening program.  BLFS 13.0 ships
# no SELinux book pages (verified against the stable index), so -- per the
# documented deviation from AGENTS.md rule 9 -- every component below is
# built from its pinned upstream SELinuxProject release (3.11) plus
# refpolicy (2.20260922) and audit-userspace (v4.2.1).  The pins and the
# rationale live in packages/custom-sources.list.
#
# The stage NEVER loads the policy or enables enforcing inside the build
# chroot: `load_policy` would push into the host kernel.  It only installs
# the userspace, drops the refpolicy files under /etc/selinux, writes
# /etc/selinux/config, leaves /.autorelabel behind, and wires an early-boot
# script that mounts selinuxfs, relabels once and loads the policy on the
# real first boot.
#
# Error policy mirrors blfs/23: a required component failure aborts the
# stage; optional components only warn.

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

# Resolved by builder.py's _apply_profile_settings() capability gate:
#   enforcing  -> native x86_64 (default)
#   permissive -> cross-compiled arm64 (unvalidated first-boot relabel)
#   disabled   -> GNU/Hurd (no Linux Security Module); stage is skipped
SELINUX_MODE="${LFS_CONFIG_SECURITY_SELINUX_MODE:-enforcing}"
SELINUX_TYPE="${LFS_CONFIG_SECURITY_SELINUX_TYPE:-targeted}"
INIT_SYSTEM="${INIT_SYSTEM:-sysvinit}"

case "$SELINUX_MODE" in
enforcing | permissive | disabled) ;;
*)
    log_warning "Unknown security.selinux.mode '$SELINUX_MODE'; falling back to enforcing"
    SELINUX_MODE="enforcing"
    ;;
esac

if [ "$SELINUX_MODE" = "disabled" ]; then
    log_info "SELinux mode is disabled - skipping the SELinux stage"
    exit 0
fi

run_privileged() {
    if [ "$(whoami)" = "root" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

log_info "========================================="
log_info "Building SELinux userspace ($SELINUX_TYPE, mode=$SELINUX_MODE)"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode - skipping SELinux userspace build"
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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-selinux.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/selinux

JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/selinux/$1.done"; }

# Same archive resolver the other BLFS stages use: case-insensitive prefix
# match, name-<version> tarballs preferred, newest version wins so a stale
# cache copy cannot shadow the pinned release.
find_archive() {
    local base=$1 f name_lc prefix_lc
    local -a tier1=() tier2=()
    prefix_lc=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    for f in *.tar.* *.tgz; do
        [ -f "$f" ] || continue
        name_lc=$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        case "$name_lc" in
            "$prefix_lc"*) ;;
            *) continue ;;
        esac
        case "$name_lc" in
            "$prefix_lc"-[0-9]* | "$prefix_lc"-v[0-9]*) tier1+=("$f") ;;
            *) tier2+=("$f") ;;
        esac
    done
    if [ "${#tier1[@]}" -gt 0 ]; then
        printf '%s\n' "${tier1[@]}" | sort -V | tail -n 1
        return 0
    fi
    if [ "${#tier2[@]}" -eq 0 ]; then
        echo "ERROR: no source archive found for $base" >&2
        return 0
    fi
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
        libsepol) [ -f /usr/lib/libsepol.a ] || [ -f /usr/lib/libsepol.so ] ;;
        libselinux) [ -f /usr/lib/libselinux.so ] ;;
        libsemanage) [ -f /usr/lib/libsemanage.so ] ;;
        checkpolicy) have_cmd checkpolicy ;;
        secilc) have_cmd secilc ;;
        policycoreutils) have_cmd semodule ;;
        selinux-python) have_cmd semanage ;;
        audit) have_cmd auditctl ;;
        mcstrans) have_cmd mcs ;;
        restorecond) have_cmd restorecond ;;
        refpolicy) [ -d /etc/selinux/targeted ] ;;
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

# run_build <required|optional> <pkg> <build_fn>
run_build() {
    local mode="$1" pkg="$2" fn="$3" rc=0
    if is_installed "$pkg"; then
        log_info "$pkg already installed; skipping"
        return 0
    fi
    # Invoke the build function in a STANDALONE errexit subshell and capture
    # its status.  A function used directly as an `if`/`||` condition runs
    # with errexit suspended (and even ignores an inner `set -e`), so a
    # failing `make` mid-function was masked and run_build saw the status of
    # the function's last command (`rm -rf "$dir"`, always 0) -- a refpolicy
    # build that died with "No enabled modules" was still reported as
    # "[SUCCESS] installed".  A standalone subshell makes any internal
    # failure fatal to the build, so `required` really aborts the stage.
    set +e
    (set -e; "$fn")
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        touch "$(marker_for "$pkg")"
        log_success "$pkg installed"
        return 0
    fi
    if [ "$mode" = "required" ]; then
        log_error "Required SELinux component $pkg failed - aborting stage"
        exit 1
    fi
    log_warning "[OPTIONAL] $pkg failed or is missing - continuing"
}

# The SELinux userspace components are plain Makefile trees that honour the
# PREFIX/LIBDIR/SHLIBDIR variables.  SHLIBDIR must equal LIBDIR (/usr/lib)
# or libselinux installs the runtime .so under /lib while the linker looks
# in /usr/lib and every later component fails to link.
se_make() {
    make -j"$JOBS" PREFIX=/usr LIBDIR=/usr/lib SHLIBDIR=/usr/lib "$@"
}
se_install() {
    make install PREFIX=/usr LIBDIR=/usr/lib SHLIBDIR=/usr/lib "$@"
}

# --- Component build functions -------------------------------------------
build_libsepol() {
    local dir; dir="$(prep_src libsepol)" || return 1
    pushd "$dir" >/dev/null || return 1
    se_make && se_install
    ldconfig 2>/dev/null || true
    popd >/dev/null; rm -rf "$dir"
}

build_libselinux() {
    local dir; dir="$(prep_src libselinux)" || return 1
    pushd "$dir" >/dev/null || return 1
    # pcre2 is in LFS core; USE_PCRE2 avoids the deprecated pcre1 path.
    se_make USE_PCRE2=y all
    se_install
    ldconfig 2>/dev/null || true
    popd >/dev/null; rm -rf "$dir"
}

build_audit() {
    local dir; dir="$(prep_src audit)" || return 1
    pushd "$dir" >/dev/null || return 1
    # audit-userspace is the one autotools component in this stack, and its
    # git tree -- which is exactly what the refs/tags archive builder.py
    # downloads contains -- ships no generated configure, only autogen.sh +
    # configure.ac.  Every other refs/tags pin in custom-sources.list uses
    # meson/cmake, so this is the first that needs a bootstrap.  The LFS
    # base system provides autoconf/automake/libtool/gettext, so regenerate
    # when configure is absent; a release tarball that already ships one is
    # used as-is.
    if [ ! -f ./configure ]; then
        sh ./autogen.sh 2>/dev/null || autoreconf -fi
    fi
    ./configure --prefix=/usr --sysconfdir=/etc --libdir=/usr/lib \
        --sbindir=/usr/sbin --disable-zos-remote
    make -j"$JOBS"
    make install
    ldconfig 2>/dev/null || true
    popd >/dev/null; rm -rf "$dir"
}

build_checkpolicy() {
    local dir; dir="$(prep_src checkpolicy)" || return 1
    pushd "$dir" >/dev/null || return 1
    se_make && se_install SBINDIR=/usr/sbin
    popd >/dev/null; rm -rf "$dir"
}

build_secilc() {
    local dir; dir="$(prep_src secilc)" || return 1
    pushd "$dir" >/dev/null || return 1
    se_make && se_install
    popd >/dev/null; rm -rf "$dir"
}

build_libsemanage() {
    local dir; dir="$(prep_src libsemanage)" || return 1
    pushd "$dir" >/dev/null || return 1
    se_make && se_install
    ldconfig 2>/dev/null || true
    popd >/dev/null; rm -rf "$dir"
}

build_policycoreutils() {
    local dir; dir="$(prep_src policycoreutils)" || return 1
    pushd "$dir" >/dev/null || return 1
    make -j"$JOBS" PREFIX=/usr LIBDIR=/usr/lib SBINDIR=/usr/sbin
    make install PREFIX=/usr LIBDIR=/usr/lib SBINDIR=/usr/sbin
    popd >/dev/null; rm -rf "$dir"
}

build_selinux_python() {
    local dir; dir="$(prep_src selinux-python)" || return 1
    pushd "$dir" >/dev/null || return 1
    se_make && se_install SBINDIR=/usr/sbin
    popd >/dev/null; rm -rf "$dir"
}

build_mcstrans() {
    local dir; dir="$(prep_src mcstrans)" || return 1
    pushd "$dir" >/dev/null || return 1
    se_make && se_install SBINDIR=/usr/sbin
    popd >/dev/null; rm -rf "$dir"
}

build_restorecond() {
    local dir; dir="$(prep_src restorecond)" || return 1
    pushd "$dir" >/dev/null || return 1
    se_make && se_install SBINDIR=/usr/sbin
    popd >/dev/null; rm -rf "$dir"
}

# refpolicy: set the policy NAME, generate the module configuration, compile
# the policy and install the module store under /etc/selinux/targeted.
# The policy is only installed, NEVER loaded from the build chroot -- loading
# it would push the policy into the host kernel.
build_refpolicy() {
    local dir; dir="$(prep_src refpolicy)" || return 1
    pushd "$dir" >/dev/null || return 1
    make clean >/dev/null 2>&1 || true
    # refpolicy has NO `targeted-conf` target: the policy TYPE/NAME live in the
    # shipped build.conf and the module configuration (modules.conf,
    # booleans.conf) is produced by `make conf`.  Invoking the non-existent
    # targeted-conf target left modules.conf ungenerated, so the following
    # `make` aborted with "No enabled modules! modules.conf may need to be
    # generated by using make conf".  Set NAME=targeted so the store installs
    # under /etc/selinux/targeted (matching SELINUXTYPE=targeted and the
    # is_installed probe); TYPE stays the build.conf default `standard`, which
    # is exactly how Fedora/RHEL build their targeted policy.  The sed is not
    # guarded: build.conf is a source file that must exist, and a silent
    # no-op here would reinstall the policy under the wrong NAME.
    sed -i 's/^NAME = .*/NAME = targeted/' build.conf
    make conf
    make -j"$JOBS"
    make install
    popd >/dev/null; rm -rf "$dir"
}

log_info "SELinux userspace: core libraries and tools"
run_build required libsepol build_libsepol
run_build required libselinux build_libselinux
run_build required audit build_audit
run_build required checkpolicy build_checkpolicy
run_build required secilc build_secilc
run_build required libsemanage build_libsemanage
run_build required policycoreutils build_policycoreutils

log_info "SELinux userspace: optional helpers"
run_build optional selinux-python build_selinux_python
run_build optional mcstrans build_mcstrans
run_build optional restorecond build_restorecond

log_info "SELinux policy: refpolicy targeted"
run_build required refpolicy build_refpolicy

# --- Runtime configuration (mode is exported by the outer stage) ---------
# Do NOT mkdir /sys/fs/selinux here.  Inside the build chroot /sys is a live
# sysfs mount (bound by mount_chroot_fs), so creating a directory under it
# fails with EPERM ("Operation not permitted") and, under top-level errexit,
# aborts the whole stage -- this is what killed nightly lg3d #48.  It is also
# unnecessary: the kernel auto-mounts selinuxfs at /sys/fs/selinux on the real
# first boot, and selinux-firstboot below re-attempts a guarded mount.
mkdir -p /etc/selinux /var/log/audit
cat >/etc/selinux/config <<SECONF
# SELinux configuration - managed by blfs/31-build-selinux.sh
# mode=${SELINUX_MODE} type=${SELINUX_TYPE}
SELINUX=${SELINUX_MODE}
SELINUXTYPE=${SELINUX_TYPE}
SECONF
chmod 0644 /etc/selinux/config

# First-boot relabel: the refpolicy files were installed into an unlabeled
# rootfs, so the very first boot must restorecon the whole tree before the
# policy can enforce.  Without this an enforcing boot bricks the system.
: >/.autorelabel
chmod 0644 /.autorelabel

# Shared early-boot helper: mount selinuxfs, honour /.autorelabel, then load
# the policy.  Both init systems call this before any other service.
cat >/usr/sbin/selinux-firstboot <<'FIRSTBOOT'
#!/bin/bash
# Early-boot SELinux bring-up (blfs/31-build-selinux.sh).
set -e
mountpoint -q /sys/fs/selinux 2>/dev/null || \
    mount -t selinuxfs selinuxfs /sys/fs/selinux 2>/dev/null || true
if [ -f /.autorelabel ]; then
    rm -f /.autorelabel
    if command -v fixfiles >/dev/null 2>&1; then
        fixfiles -F relabel 2>/dev/null || true
    elif command -v restorecon >/dev/null 2>&1; then
        restorecon -rF / 2>/dev/null || true
    fi
    # Relabeling / requires a clean remount before the policy loads.
    sync
fi
if command -v load_policy >/dev/null 2>&1; then
    load_policy -i 2>/dev/null || true
fi
FIRSTBOOT
chmod 0755 /usr/sbin/selinux-firstboot

# pam_selinux: set the login context.  Appended to the auth stacks that
# exist so a missing PAM file never aborts the stage.
for pamfile in /etc/pam.d/login /etc/pam.d/sshd /etc/pam.d/system-auth; do
    if [ -f "$pamfile" ] && ! grep -q pam_selinux.so "$pamfile"; then
        {
            echo "session  required  pam_selinux.so  close"
            echo "session  required  pam_selinux.so  open"
        } >>"$pamfile"
    fi
done

log_success "SELinux userspace and $SELINUX_TYPE policy installed"
INNEREOF

run_privileged chmod +x "$LFS/build-selinux.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin:/bin:/usr/local/bin:/sbin \
    SELINUX_MODE="$SELINUX_MODE" SELINUX_TYPE="$SELINUX_TYPE" \
    /bin/bash /build-selinux.sh

# ---------------------------------------------------------------------------
# Boot wiring is written from the host so it lands in the target root with
# the right ownership and never depends on the init being installed yet.
# The policy is loaded by /usr/sbin/selinux-firstboot on the real first
# boot; a mislabeled rootfs is rescued by /.autorelabel (already dropped
# above) and, as a last resort, by the kernel cmdline `enforcing=0` (boot
# permissive once) or `selinux=0` (disable the LSM for that boot).
# ---------------------------------------------------------------------------
write_host_file() {
    # write_host_file <path-under-LFS> <mode>  (content on stdin)
    local path="$1" mode="$2"
    run_privileged mkdir -p "$(dirname "$LFS$path")"
    run_privileged tee "$LFS$path" >/dev/null
    run_privileged chmod "$mode" "$LFS$path"
    log_info "wrote $path (mode $mode)"
}

case "$INIT_SYSTEM" in
systemd)
    write_host_file /etc/systemd/system/selinux-firstboot.service 0644 <<'UNIT'
[Unit]
Description=SELinux first-boot relabel and policy load
DefaultDependencies=no
Before=sysinit.target local-fs.target
After=local-fs-pre.target
ConditionPathExists=/usr/sbin/selinux-firstboot

[Service]
Type=oneshot
ExecStart=/usr/sbin/selinux-firstboot
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
UNIT
    run_privileged mkdir -p "$LFS/etc/systemd/system/sysinit.target.wants"
    run_privileged ln -sf /etc/systemd/system/selinux-firstboot.service \
        "$LFS/etc/systemd/system/sysinit.target.wants/selinux-firstboot.service" 2>/dev/null || true
    log_success "SELinux wired into systemd (selinux-firstboot.service)"
    ;;
*)
    write_host_file /etc/rc.d/init.d/selinux 0755 <<'INITD'
#!/bin/bash
# .        Start/stop SELinux policy load at boot
# BEGIN INIT INFO
# Provides:            selinux
# Required-Start:      $local_fs
# Required-Stop:       $local_fs
# Default-Start:       S
# Default-Stop:
# Short-Description:   Loads the SELinux policy at boot
# Description:         Mounts selinuxfs, honours /.autorelabel and loads
#                      the targeted policy before other services start.
# END INIT INFO

case "$1" in
    start)
        /usr/sbin/selinux-firstboot
        ;;
    stop)
        ;;
    *)
        echo "Usage: $0 {start|stop}" >&2
        exit 1
        ;;
esac
exit 0
INITD
    run_privileged mkdir -p "$LFS/etc/rc.d/rcS.d"
    run_privileged ln -sf ../init.d/selinux "$LFS/etc/rc.d/rcS.d/S02selinux" 2>/dev/null || true
    log_success "SELinux wired into sysvinit (rcS.d/S02selinux)"
    ;;
esac

log_success "SELinux stage complete (mode=$SELINUX_MODE type=$SELINUX_TYPE)"
