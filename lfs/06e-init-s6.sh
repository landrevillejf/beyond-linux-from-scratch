#!/bin/bash
# 06e-init-s6.sh
# Build and configure s6 init system (skarnet toolchain).
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

run_privileged() { if [ "$(whoami)" = "root" ]; then "$@"; else sudo "$@"; fi; }

log_info "========================================="
log_info "Installing s6 init system"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – creating minimal s6 structure"
    mkdir -pv "$LFS"/{etc/s6,sbin}
    cat >"$LFS/sbin/init" <<'EOF'
#!/bin/sh
echo "Starting minimal s6..."
exec /bin/bash
EOF
    chmod +x "$LFS/sbin/init"
    log_success "Minimal s6 created for Docker"
    exit 0
fi

[ -x "$LFS/bin/bash" ] || { log_error "/bin/bash not found in $LFS/bin – run lfs-basic first"; exit 1; }
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
    log_error "chroot not working – run lfs-basic first"; exit 1
fi

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

log_info "Checking if gcc works in chroot..."
if ! run_privileged chroot "$LFS" /bin/bash -c "echo 'int main(){}' > /tmp/test.c && gcc /tmp/test.c -o /tmp/test 2>/dev/null && rm -f /tmp/test.c /tmp/test" 2>/dev/null; then
    log_error "gcc/cc1 missing or broken in chroot."
    log_error "Please rebuild the LFS system stage (05b-build-lfs-system) and then retry."
    exit 1
fi
log_success "Toolchain OK in chroot."

SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    if ! run_privileged chown -R lfs:lfs "$LFS/sources" 2>/dev/null; then log_warning "Could not chown $LFS/sources to lfs:lfs"; fi
fi

cat <<'INNEREOF' | run_privileged tee "$LFS/build-s6.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/init-s6

JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/init-s6/$1.done"; }
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
have_cmd() { command -v "$1" >/dev/null 2>&1; }
have_pc() { pkg-config --exists "$1" 2>/dev/null; }

is_installed() {
    local pkg="$1"
    [ -f "$(marker_for "$pkg")" ] && return 0
    case "$pkg" in
        skalibs)    have_pc skalibs ;;
        execline)   have_cmd execlineb || [ -x /usr/bin/execlineb ] ;;
        s6)         have_cmd s6-svscan || [ -x /usr/bin/s6-svscan ] ;;
        s6-rc)      have_cmd s6-rc || [ -x /usr/bin/s6-rc ] ;;
        nsss)       have_pc nsss ;;
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
    if [ -x ./configure ] || [ -f configure ]; then
        # skarnet packages use ./configure with --enable-* / --disable-* options
        # shellcheck disable=SC2086
        ./configure --prefix=/usr --libdir=/usr/lib --sysconfdir=/etc --localstatedir=/var \
            --enable-shared --disable-static --slashpackage=no $extra_opts
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

log_info "Building s6 ecosystem (skarnet toolchain)..."
# None of the skarnet packages are in packages/stable/12.4/sources.list
# (they are not packages of the LFS/BLFS books), so they stay optional
# until their tarballs are added.

# skalibs must be built first (all other packages depend on it)
run_build optional skalibs --enable-time-acc

# execline depends on skalibs
run_build optional execline --enable-foreach --enable-import --enable-multiparse

# nsss depends on skalibs
run_build optional nsss --enable-libc-nss

# s6 depends on skalibs and execline
run_build optional s6 --enable-shared

# s6-rc depends on skalibs, execline, and s6
run_build optional s6-rc --enable-shared

# ---- Post-install configuration ----
log_info "Configuring s6..."

# Create supervision directories
mkdir -p /etc/s6/sv /etc/s6/rc /etc/s6/current /run/s6 /var/log/s6

# Create the s6 init script (/sbin/init)
cat > /sbin/s6-init <<'S6INIT'
#!/bin/sh
# s6 init script: starts the supervision tree
PATH=/bin:/usr/bin:/sbin:/usr/sbin

# Stage 1: one-time setup
hostname lfs 2>/dev/null || true
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null || true

# Generate SSH host keys
if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -A 2>/dev/null || true
fi

# Start udev if available
if command -v udevd >/dev/null 2>&1; then
    udevd --daemon 2>/dev/null || true
    udevadm trigger --action=add 2>/dev/null || true
    udevadm settle 2>/dev/null || true
fi

# Stage 2: start supervision tree
exec s6-svscan /etc/s6/sv
S6INIT
chmod +x /sbin/s6-init

# Link /sbin/init to s6-init
ln -sf /sbin/s6-init /sbin/init

# Create essential supervised services

# getty on tty1
mkdir -p /etc/s6/sv/getty-tty1
cat > /etc/s6/sv/getty-tty1/run <<'GETTY1'
#!/bin/sh
exec /sbin/agetty --noclear tty1 9600 linux
GETTY1
chmod +x /etc/s6/sv/getty-tty1/run

# getty on tty2
mkdir -p /etc/s6/sv/getty-tty2
cat > /etc/s6/sv/getty-tty2/run <<'GETTY2'
#!/bin/sh
exec /sbin/agetty --noclear tty2 9600 linux
GETTY2
chmod +x /etc/s6/sv/getty-tty2/run

# getty on tty3
mkdir -p /etc/s6/sv/getty-tty3
cat > /etc/s6/sv/getty-tty3/run <<'GETTY3'
#!/bin/sh
exec /sbin/agetty --noclear tty3 9600 linux
GETTY3
chmod +x /etc/s6/sv/getty-tty3/run

# sshd service
mkdir -p /etc/s6/sv/sshd
cat > /etc/s6/sv/sshd/run <<'SSHD'
#!/bin/sh
ssh-keygen -A 2>/dev/null || true
exec /usr/sbin/sshd -D
SSHD
chmod +x /etc/s6/sv/sshd/run

# udev service
mkdir -p /etc/s6/sv/udev
cat > /etc/s6/sv/udev/run <<'UDEV'
#!/bin/sh
exec udevd
UDEV
chmod +x /etc/s6/sv/udev/run

# networking service
mkdir -p /etc/s6/sv/networking
cat > /etc/s6/sv/networking/run <<'NET'
#!/bin/sh
ip link set lo up 2>/dev/null || true
for iface in /sys/class/net/*; do
    dev=$(basename "$iface")
    [ "$dev" = "lo" ] && continue
    ip link set "$dev" up 2>/dev/null || true
    if command -v dhclient >/dev/null 2>&1; then
        dhclient "$dev" 2>/dev/null || true
    fi
done
exec sleep infinity
NET
chmod +x /etc/s6/sv/networking/run

# Create the s6-rc service database source directory
mkdir -p /etc/s6/rc/sources
cat > /etc/s6/rc/sources/getty-tty1 <<'RC1'
type:longrun
command:/etc/s6/sv/getty-tty1/run
RC1
cat > /etc/s6/rc/sources/getty-tty2 <<'RC2'
type:longrun
command:/etc/s6/sv/getty-tty2/run
RC2
cat > /etc/s6/rc/sources/sshd <<'RCSS'
type:longrun
command:/etc/s6/sv/sshd/run
depends-on:udev
RCSS
cat > /etc/s6/rc/sources/udev <<'RCD'
type:longrun
command:/etc/s6/sv/udev/run
RCD
cat > /etc/s6/rc/sources/networking <<'RCN'
type:longrun
command:/etc/s6/sv/networking/run
RCN

# Create the default bundle
cat > /etc/s6/rc/sources/default <<'BUNDLE'
type:bundle
contents:getty-tty1,getty-tty2,sshd,udev,networking
BUNDLE

# Compile the s6-rc database
if have_cmd s6-rc-compile; then
    s6-rc-compile /etc/s6/rc/compiled /etc/s6/rc/sources || \
        log_warning "s6-rc-compile failed (database not compiled)"
fi

# Create s6 shutdown script
cat > /sbin/s6-shutdown <<'SHUTDOWN'
#!/bin/sh
# s6 shutdown script
PATH=/bin:/usr/bin:/sbin:/usr/sbin

# Stop all supervised services
if command -v s6-svlist >/dev/null 2>&1; then
    for svc in $(s6-svlist /etc/s6/sv); do
        s6-svc -d "/etc/s6/sv/$svc" 2>/dev/null || true
    done
fi

# Kill remaining processes
killall5 -TERM 2>/dev/null || true
sleep 2
killall5 -KILL 2>/dev/null || true

# Unmount filesystems
umount -a 2>/dev/null || true
mount -o remount,ro / 2>/dev/null || true
SHUTDOWN
chmod +x /sbin/s6-shutdown

log_success "s6 configuration complete."
INNEREOF

run_privileged chmod +x "$LFS/build-s6.sh"
log_info "Entering chroot and building s6"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-s6.sh

log_success "s6 init system installed successfully"
