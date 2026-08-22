#!/bin/bash
# 06a-init-system.sh
# Install the init system (sysvinit or systemd) inside the chroot.
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

run_privileged() {
    if [ "$(whoami)" = "root" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

log_info "========================================="
log_info "Installing init system"
log_info "========================================="

INIT_SYSTEM="${INIT_SYSTEM:-sysvinit}"
log_info "Init system selected: $INIT_SYSTEM"

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – creating minimal init structure"
    mkdir -pv "$LFS"/{etc/init.d,bin,sbin,usr/sbin}
    cat >"$LFS/etc/init.d/rcS" <<'EOF'
#!/bin/sh
echo "Starting minimal init..."
exec /bin/bash
EOF
    chmod +x "$LFS/etc/init.d/rcS"
    ln -sf /etc/init.d/rcS "$LFS/sbin/init"
    log_success "Minimal init created for Docker"
    exit 0
fi

# ---- Dispatch to dedicated scripts for openrc, runit, or s6 ----
if [ "$INIT_SYSTEM" = "openrc" ]; then
    log_info "Dispatching to OpenRC build script"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/06c-init-openrc.sh"
    exit 0
elif [ "$INIT_SYSTEM" = "runit" ]; then
    log_info "Dispatching to runit build script"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/06d-init-runit.sh"
    exit 0
elif [ "$INIT_SYSTEM" = "s6" ]; then
    log_info "Dispatching to s6 build script"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/06e-init-s6.sh"
    exit 0
fi

# Only sysvinit and systemd are handled directly by this script.

[ -x "$LFS/bin/bash" ] || { log_error "/bin/bash not found in $LFS/bin"; exit 1; }
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
    log_error "chroot not working"
    exit 1
fi

# Ensure /bin/sh resolves to a working shell inside chroot for make/autotools.
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

# -----------------------------------------------------------------
# Check toolchain in chroot – if broken, abort with clear instruction.
# The chapter 8 coreutils already provide every build utility, so no
# host tool is imported (audit finding F-05).
# -----------------------------------------------------------------
log_info "Checking if gcc works in chroot..."
if ! run_privileged chroot "$LFS" /bin/bash -c "echo 'int main(){}' > /tmp/test.c && gcc /tmp/test.c -o /tmp/test 2>/dev/null && rm -f /tmp/test.c /tmp/test" 2>/dev/null; then
    log_error "gcc/cc1 missing or broken in chroot."
    log_error "The final toolchain (gcc, glibc, binutils) was not correctly installed."
    log_error "Please rebuild the LFS system stage (05b-build-lfs-system) and then retry."
    exit 1
fi
log_success "Toolchain OK in chroot."
# -----------------------------------------------------------------

# Sources
SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    if ! run_privileged chown -R lfs:lfs "$LFS/sources" 2>/dev/null; then log_warning "Could not chown $LFS/sources to lfs:lfs"; fi
fi

cat <<'INNEREOF' | run_privileged tee "$LFS/build-init.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/init-system

INIT_SYSTEM="${1:-sysvinit}"
JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/init-system/$1.done"; }
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
        sysvinit)      [ -x /sbin/init ] && ! readlink /sbin/init 2>/dev/null | grep -q systemd ;;
        lfs-bootscripts) [ -f /etc/init.d/rcS ] ;;
        libgpg-error)  have_pc gpg-error ;;
        libgcrypt)     have_pc libgcrypt ;;
        libseccomp)    have_pc libseccomp ;;
        kmod)          have_cmd kmod || have_cmd lsmod ;;
        systemd)       have_pc libsystemd || [ -x /usr/lib/systemd/systemd ] ;;
        *) return 1 ;;
    esac
}

build_pkg() {
    local pkg="$1" archive dir extra_opts=""
    shift
    extra_opts="$*"
    if is_installed "$pkg"; then log_info "$pkg already installed; skipping"; return 0; fi
    archive="$(find_archive "$pkg")"
    if [ -z "$archive" ]; then
        log_error "Source archive missing for $pkg"
        return 1
    fi
    log_info "Building $pkg from $archive"
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
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

# -----------------------------------------------------------------------
# sysvinit
# -----------------------------------------------------------------------
if [ "$INIT_SYSTEM" = "sysvinit" ]; then
    # sysvinit itself was already built by LFS chapter 8; rebuild it only
    # when the detection above decides it is missing.
    run_build required sysvinit

    # Install lfs-bootscripts (LFS book: make install)
    run_build required lfs-bootscripts

    # Create /etc/inittab (LFS book chapter 9.4)
    cat > /etc/inittab <<'INITTAB'
id:3:initdefault:
si::sysinit:/etc/init.d/rcS
l1:1:wait:/etc/init.d/rc 1
l2:2:wait:/etc/init.d/rc 2
l3:3:wait:/etc/init.d/rc 3
l4:4:wait:/etc/init.d/rc 4
l5:5:wait:/etc/init.d/rc 5
l6:6:wait:/etc/init.d/rc 6
ca:12345:ctrlaltdel:/sbin/shutdown -t1 -a -r now
1:2345:respawn:/sbin/agetty --noclear tty1 9600 linux
2:2345:respawn:/sbin/agetty --noclear tty2 9600 linux
3:2345:respawn:/sbin/agetty --noclear tty3 9600 linux
4:2345:respawn:/sbin/agetty --noclear tty4 9600 linux
5:2345:respawn:/sbin/agetty --noclear tty5 9600 linux
6:2345:respawn:/sbin/agetty --noclear tty6 9600 linux
INITTAB

# -----------------------------------------------------------------------
# systemd
# -----------------------------------------------------------------------
elif [ "$INIT_SYSTEM" = "systemd" ]; then
    log_info "Building systemd dependencies..."

    run_build required libgpg-error
    run_build required libgcrypt
    run_build required libseccomp
    # kmod is normally provided by LFS chapter 8; detection skips it.
    run_build required kmod

    log_info "Building systemd..."
    run_build required systemd \
        -Ddefault-hierarchy=unified \
        -Dcgroup-controller=systemd \
        -Db_lto=false \
        -Dsysvinit-path= \
        -Dsysvrcnd-path= \
        -Dadmin-group=wheel \
        -Dwheel-group=wheel \
        -Dbacklight=true \
        -Dbinfmt=true \
        -Dcoredump=true \
        -Dfirstboot=true \
        -Dhostnamed=true \
        -Dhwdb=true \
        -Dlocaled=true \
        -Dlogind=true \
        -Dmachined=true \
        -Dnetworkd=true \
        -Dportabled=false \
        -Dresolve=true \
        -Dtimedated=true \
        -Dtimesyncd=true \
        -Dtmpfiles=true \
        -Duserdb=true \
        -Dhomed=false \
        -Dpolkit=true \
        -Dman=true \
        -Dhtml=disabled \
        -Dlz4=enabled \
        -Dzstd=enabled

    # ---- Post-install configuration ----
    log_info "Configuring systemd..."

    # Create /etc/machine-id
    if [ ! -f /etc/machine-id ] || [ ! -s /etc/machine-id ]; then
        if have_cmd systemd-machine-id-setup; then
            systemd-machine-id-setup || log_warning "systemd-machine-id-setup failed"
        else
            head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > /etc/machine-id
        fi
    fi

    # Create /etc/os-release if not present
    if [ ! -f /etc/os-release ]; then
        cat > /etc/os-release <<'OSREL'
NAME="LFS"
VERSION="13.0"
ID=lfs
PRETTY_NAME="Linux From Scratch 13.0"
OSREL
    fi

    # Link systemd as /sbin/init
    ln -sf /usr/lib/systemd/systemd /sbin/init
    ln -sf /usr/bin/systemctl /sbin/service || log_warning "Could not link /sbin/service"

    # Set default target
    if have_cmd systemctl && systemctl set-default multi-user.target 2>/dev/null; then
        log_info "Default target set via systemctl"
    else
        mkdir -p /etc/systemd/system
        ln -sf /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target
    fi

    # Enable essential services (systemctl may not run fully at
    # build time; enabling only creates symlinks, so failures are
    # tolerated with an explicit warning).
    for unit in getty@tty1.service getty@tty2.service \
                systemd-networkd.service systemd-resolved.service \
                systemd-timesyncd.service; do
        systemctl enable "$unit" 2>/dev/null || log_warning "Could not enable $unit"
    done

    # Basic network configuration
    mkdir -p /etc/systemd/network
    cat > /etc/systemd/network/20-wired.network <<'NETCONF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
NETCONF

    # Journald configuration
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/lfs-defaults.conf <<'JCONF'
[Journal]
Storage=persistent
Compress=yes
RateLimitIntervalSec=30s
RateLimitBurst=1000
JCONF

    # Logind configuration
    mkdir -p /etc/systemd/logind.conf.d
    cat > /etc/systemd/logind.conf.d/lfs-defaults.conf <<'LCONF'
[Login]
KillUserProcesses=no
LCONF

    # Resolved configuration
    mkdir -p /etc/systemd/resolved.conf.d
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || \
        log_warning "Could not point /etc/resolv.conf at systemd-resolved"

    log_success "systemd configuration complete."

else
    log_error "Unknown init system $INIT_SYSTEM"
    exit 1
fi

log_success "Init system installation complete."
INNEREOF

run_privileged chmod +x "$LFS/build-init.sh"

# Execute in a clean environment (audit finding F-04).
log_info "Entering chroot and building init system with argument: $INIT_SYSTEM"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-init.sh "$INIT_SYSTEM"

log_success "Init system ($INIT_SYSTEM) installed successfully"
