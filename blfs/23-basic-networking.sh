#!/bin/bash
# 13-basic-networking.sh
# Build BLFS Basic Networking packages (Part IV of BLFS book)
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# Error policy (audit finding F-07): a required package failure aborts the
# stage.  Only packages that are explicitly optional (missing from
# packages/stable/12.4/sources.list) may fail with a warning.
#
# Book compliance (audit finding F-07, wave 3): every package gets a
# dedicated build_<name> function reproducing its docs/books (basicnet
# chapter) page.
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
log_info "Building BLFS Basic Networking"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – skipping networking packages"
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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-networking.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/networking

JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/networking/$1.done"; }
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
        curl) have_cmd curl ;;
        wget) have_cmd wget ;;
        libevent) have_pc libevent ;;
        libnl) have_pc libnl-3.0 ;;
        libmnl) have_pc libmnl ;;
        libpcap) have_pc libpcap ;;
        nghttp2) have_pc libnghttp2 ;;
        nmap) have_cmd nmap ;;
        lynx) have_cmd lynx ;;
        ntp) have_cmd ntpd || have_cmd ntpdate ;;
        nfs-utils) have_cmd showmount ;;
        wireless_tools) have_cmd iwconfig || have_cmd iw ;;
        wpa_supplicant) have_cmd wpa_supplicant ;;
        dhcpcd) have_cmd dhcpcd ;;
        libndp) have_pc libndp ;;
        networkmanager) have_cmd nmcli || have_cmd NetworkManager ;;
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

# Generic fallback for packages that have no BLFS book page.
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
# Per-package BLFS book commands (wave 3, basicnet chapter).
# ======================================================================

# BLFS basicnet/curl
build_curl() { book_install curl build_commands_curl; }
build_commands_curl() {
    ./configure --prefix=/usr    \
                --disable-static \
                --with-openssl   \
                --with-ca-path=/etc/ssl/certs &&
    make -j"$JOBS" && make install
}

# BLFS basicnet/wget
build_wget() { book_install wget build_commands_wget; }
build_commands_wget() {
    ./configure --prefix=/usr      \
                --sysconfdir=/etc  \
                --with-ssl=openssl &&
    make -j"$JOBS" && make install
}

# BLFS basicnet/libevent
build_libevent() { book_install libevent build_commands_libevent; }
build_commands_libevent() {
    if [ -f event_rpcgen.py ]; then
        sed -i 's/python/&3/' event_rpcgen.py
    fi
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS basicnet/libnl
build_libnl() { book_install libnl build_commands_libnl; }
build_commands_libnl() {
    ./configure --prefix=/usr     \
                --sysconfdir=/etc \
                --disable-static  &&
    make -j"$JOBS" && make install
}

# BLFS basicnet/libmnl
build_libmnl() { book_install libmnl build_commands_libmnl; }
build_commands_libmnl() {
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

# BLFS basicnet/nghttp2
build_nghttp2() { book_install nghttp2 build_commands_nghttp2; }
build_commands_nghttp2() {
    ./configure --prefix=/usr     \
                --disable-static  \
                --enable-lib-only \
                --docdir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install
}

# BLFS basicnet/libpcap – nmap's recommended dependency.  Without it
# nmap statically compiles its bundled libpcap, which picks up the
# installed libnl-3 netlink support and then fails the final link
# with undefined nl_*/genl_* symbols (nightly #186).
build_libpcap() { book_install libpcap build_commands_libpcap; }
build_commands_libpcap() {
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

# BLFS basicnet/nmap – the python packaging seds come from the book
build_nmap() { book_install nmap build_commands_nmap; }
build_commands_nmap() {
    if [ -f Makefile.in ]; then
        sed -ri Makefile.in \
            -e 's#-m build#& --no-isolation#'  \
            -e '/pip install/s#(ZENMAP|NDIFF)DIR\)/#&dist/*.whl#'
    fi
    if [ -f zenmap/pyproject.toml ]; then
        sed 's/, "setuptools-gettext"//' -i zenmap/pyproject.toml
    fi
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

# BLFS basicnet/lynx
build_lynx() { book_install lynx build_commands_lynx; }
build_commands_lynx() {
    ./configure --prefix=/usr           \
                --sysconfdir=/etc/lynx  \
                --with-zlib             \
                --with-bzlib            \
                --with-ssl              \
                --with-screen=ncursesw  \
                --enable-locale-charset \
                --datadir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install
}

# BLFS basicnet/ntp
build_ntp() { book_install ntp build_commands_ntp; }
build_commands_ntp() {
    sed -e "s;pthread_detach(NULL);pthread_detach(0);" -i configure
    if [ -f sntp/configure ]; then
        sed -e "s;pthread_detach(NULL);pthread_detach(0);" -i sntp/configure
    fi
    ./configure --prefix=/usr      \
                --bindir=/usr/sbin \
                --sysconfdir=/etc  \
                --enable-linuxcaps \
                --with-lineeditlibs=readline \
                --docdir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install
}

# BLFS basicnet/nfs-utils
build_nfs_utils() { book_install nfs-utils build_commands_nfs_utils; }
build_commands_nfs_utils() {
    ./configure --prefix=/usr       \
                --sysconfdir=/etc   \
                --sbindir=/usr/sbin \
                --disable-nfsv4     \
                --disable-gss       \
                LIBS="-lsqlite3 -levent_core" &&
    make -j"$JOBS" && make install
}

# BLFS basicnet/wireless_tools – no configure, plain make; the patch is
# applied only when shipped in the sources.
build_wireless_tools() { book_install wireless_tools build_commands_wireless_tools; }
build_commands_wireless_tools() {
    local p
    for p in ../wireless_tools-*-fix_iwlist_scanning-*.patch; do
        [ -f "$p" ] || continue
        patch -Np1 -i "$p" || return 1
    done
    make -j"$JOBS"
    make PREFIX=/usr INSTALL_MAN=/usr/share/man install
}

# BLFS basicnet/wpa_supplicant – .config creation, make with BINDIR/
# LIBDIR, then the book root install commands.
build_wpa_supplicant() { book_install wpa_supplicant build_commands_wpa_supplicant; }
build_commands_wpa_supplicant() {
    cat > wpa_supplicant/.config <<'EOF'
CONFIG_BACKEND=file
CONFIG_CTRL_IFACE=y
CONFIG_DEBUG_FILE=y
CONFIG_DEBUG_SYSLOG=y
CONFIG_DEBUG_SYSLOG_FACILITY=LOG_DAEMON
CONFIG_DRIVER_NL80211=y
CONFIG_DRIVER_WEXT=y
CONFIG_DRIVER_WIRED=y
CONFIG_EAP_GTC=y
CONFIG_EAP_LEAP=y
CONFIG_EAP_MD5=y
CONFIG_EAP_MSCHAPV2=y
CONFIG_EAP_OTP=y
CONFIG_EAP_PEAP=y
CONFIG_EAP_TLS=y
CONFIG_EAP_TTLS=y
CONFIG_IEEE8021X_EAPOL=y
CONFIG_IPV6=y
CONFIG_LIBNL32=y
CONFIG_PEERKEY=y
CONFIG_PKCS12=y
CONFIG_READLINE=y
CONFIG_SMARTCARD=y
CONFIG_WPS=y
CFLAGS += -I/usr/include/libnl3
EOF
    cat >> wpa_supplicant/.config <<'EOF'
CONFIG_CTRL_IFACE_DBUS=y
CONFIG_CTRL_IFACE_DBUS_NEW=y
CONFIG_CTRL_IFACE_DBUS_INTRO=y
EOF
    mkdir -p /usr/share/dbus-1/system.d
    cd wpa_supplicant &&
    make BINDIR=/usr/sbin LIBDIR=/usr/lib &&
    install -m755 wpa_cli wpa_passphrase wpa_supplicant /usr/sbin/ &&
    install -m644 doc/docbook/wpa_supplicant.conf.5 /usr/share/man/man5/ &&
    install -m644 doc/docbook/wpa_cli.8 doc/docbook/wpa_passphrase.8 doc/docbook/wpa_supplicant.8 /usr/share/man/man8/
    if [ -f dbus-freedesktop/dbus-wpa_supplicant.conf ]; then
        install -m644 dbus-freedesktop/dbus-wpa_supplicant.conf /usr/share/dbus-1/system.d/ || return 1
    fi
}

# BLFS basicnet/dhcpcd – RFC 2131 compliant DHCP client; built without
# privilege separation since the chroot has no dhcpcd user.
build_dhcpcd() { book_install dhcpcd build_commands_dhcpcd; }
build_commands_dhcpcd() {
    ./configure --prefix=/usr                \
                --sysconfdir=/etc            \
                --libexecdir=/usr/lib/dhcpcd \
                --dbdir=/var/lib/dhcpcd      \
                --runstatedir=/run           \
                --disable-privsep &&
    make -j"$JOBS" && make install
}

# BLFS basicnet/networkmanager (required dependency)
build_libndp() { book_install libndp build_commands_libndp; }
build_commands_libndp() {
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS basicnet/networkmanager – book commands; nmtui is disabled
# because newt is not in packages/stable/12.4/sources.list, and session
# tracking uses elogind only when the display-manager stage built it.
build_networkmanager() { book_install networkmanager build_commands_networkmanager; }
build_commands_networkmanager() {
    local session_tracking=none
    if have_pc elogind; then session_tracking=elogind; fi
    grep -rl '^#!.*python$' . 2>/dev/null | xargs -r sed -i '1s/python/&3/' || true
    mkdir -p build && cd build &&
    meson setup ..                    \
          --prefix=/usr               \
          --buildtype=release         \
          -D libaudit=no              \
          -D nmtui=false              \
          -D ovs=false                \
          -D ppp=false                \
          -D nbft=false               \
          -D selinux=false            \
          -D session_tracking="$session_tracking" \
          -D modem_manager=false      \
          -D systemdsystemunitdir=no  \
          -D systemd_journal=false    \
          -D nm_cloud_setup=false     \
          -D qt=false &&
    ninja -j"$JOBS" && ninja install
}

# Policy wrapper (audit finding F-07).  required: any failure aborts the
# stage.  optional: failures are logged and the build continues.
# Packages without a BLFS book page would use the generic build_pkg.
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

log_info "Phase 1: Network utilities"

# curl – command line tool for transferring data with URL syntax
run_build required curl

# wget – network utility to retrieve files from the Web
run_build required wget

log_info "Phase 2: Network libraries"

# libevent – event notification library
run_build required libevent

# libnl – netlink protocol library suite
run_build required libnl

# libmnl – minimalistic user-space library for netlink
run_build required libmnl

# nghttp2 – HTTP/2 library
run_build required nghttp2

# libpcap – packet capture library nmap links against
run_build required libpcap

log_info "Phase 3: Network tools"

# nmap – network exploration tool and security/port scanner
run_build required nmap

# lynx – text-based web browser; not in packages/stable/12.4/sources.list
run_build optional lynx

log_info "Phase 4: Time synchronization"

# ntp – Network Time Protocol daemon and utilities
run_build required ntp

log_info "Phase 5: Network file systems"

# nfs-utils – NFS server and client tools
run_build required nfs-utils

log_info "Phase 6: Wireless networking"

# wireless_tools – tools for manipulating Linux Wireless Extensions
run_build required wireless_tools

# wpa_supplicant – WPA/WPA2/EAP Authenticator and Supplicant
run_build required wpa_supplicant

log_info "Phase 7: Connection management"

# dhcpcd – RFC 2131 compliant DHCP client (BLFS basicnet/dhcpcd)
run_build required dhcpcd

# libndp – NetworkManager's only required dependency
run_build required libndp

# NetworkManager – its meson build needs GLib; profiles without the
# xorg stack (minimal/server/audio-cli) keep dhcpcd only, so the
# requirement is downgraded for them instead of aborting the stage.
if have_pc glib-2.0; then
    run_build required networkmanager
else
    run_build optional networkmanager
fi

log_success "BLFS Basic Networking build complete"
INNEREOF

run_privileged chmod +x "$LFS/build-networking.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-networking.sh

log_success "BLFS Basic Networking built successfully"
