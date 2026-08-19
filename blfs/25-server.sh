#!/bin/bash
# 15-server.sh
# Build BLFS Server packages (Part VII of BLFS book)
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

run_privileged() {
    if [ "$(whoami)" = "root" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

log_info "========================================="
log_info "Building BLFS Server"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – skipping server packages"
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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-server.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/server

jobs() { nproc 2>/dev/null || echo 1; }
marker_for() { echo "/var/lib/lfs-builder/server/$1.done"; }
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
        apache) have_cmd httpd ;;
        mariadb) have_cmd mariadbd || have_cmd mysqld ;;
        postgresql) have_cmd postgres ;;
        sqlite) have_cmd sqlite3 ;;
        openldap) have_cmd slapd ;;
        bind) have_cmd named ;;
        postfix) have_cmd postfix || have_cmd sendmail ;;
        dovecot) have_cmd dovecot ;;
        openssh) have_cmd sshd ;;
        vsftpd) have_cmd vsftpd ;;
        proftpd) have_cmd proftpd ;;
        samba) have_cmd smbd ;;
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

log_info "Phase 1: Web server"

# apache – Apache HTTP Server
build_pkg apache || log_warning "apache build failed"

log_info "Phase 2: Database servers"

# mariadb – MariaDB database server (MySQL compatible)
build_pkg mariadb || log_warning "mariadb build failed"

# postgresql – PostgreSQL database server
build_pkg postgresql || log_warning "postgresql build failed"

# sqlite – SQLite database library (already in LFS, verify)
build_pkg sqlite || log_warning "sqlite build failed"

log_info "Phase 3: Directory server"

# openldap – OpenLDAP directory server
build_pkg openldap || log_warning "openldap build failed"

log_info "Phase 4: DNS server"

# bind – BIND DNS server
build_pkg bind || log_warning "bind build failed"

log_info "Phase 5: Mail servers"

# postfix – Postfix mail transfer agent
build_pkg postfix || log_warning "postfix build failed"

# dovecot – Dovecot IMAP/POP3 server
build_pkg dovecot || log_warning "dovecot build failed"

log_info "Phase 6: SSH server"

# openssh – OpenSSH SSH client/server
build_pkg openssh || log_warning "openssh build failed"

log_info "Phase 7: FTP servers"

# vsftpd – Very Secure FTP Daemon
build_pkg vsftpd || log_warning "vsftpd build failed"

# proftpd – Professional FTP daemon
build_pkg proftpd || log_warning "proftpd build failed"

log_info "Phase 8: File sharing"

# samba – Samba SMB/CIFS file sharing
build_pkg samba || log_warning "samba build failed"

log_success "BLFS Server build complete"
INNEREOF

run_privileged chmod +x "$LFS/build-server.sh"
run_privileged chroot "$LFS" /bin/bash /build-server.sh

log_success "BLFS Server built successfully"
