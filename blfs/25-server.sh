#!/bin/bash
# 15-server.sh
# Build BLFS Server packages (Part VII of BLFS book)
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# Error policy (audit finding F-07): a required package failure aborts the
# stage.  Only packages that are explicitly optional (missing from
# packages/stable/12.4/sources.list) may fail with a warning.
#
# Book compliance (audit finding F-07, wave 3): server packages are
# built with the commands of their docs/books (server chapter, plus
# postlfs/openssh and basicnet/samba) pages; the sysvinit book variant
# --without-systemd flags become conditional on HAVE_SYSTEMD.  vsftpd
# has no book page and uses the generic build_pkg fallback.
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

cat <<'INNEREOF' | run_privileged tee "$LFS/build-server.sh" >/dev/null
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }

cd /sources
mkdir -p /var/lib/lfs-builder/server

JOBS="$(nproc 2>/dev/null || echo 1)"
marker_for() { echo "/var/lib/lfs-builder/server/$1.done"; }
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
            *-src*) filtered+=("$f") ;;
        esac
    done
    if [ "${#filtered[@]}" -gt 0 ]; then
        # Newest -src archive wins: stale packages-cache copies (e.g.
        # icu4c-76_1) must never shadow the book version (nightly #198).
        printf '%s\n' "${filtered[@]}" | sort -V | tail -n 1
        return 0
    fi
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
        apache) have_cmd httpd ;;
        apr) have_cmd apr-1-config ;;
        apr-util) have_cmd apu-1-config ;;
        pcre2) have_cmd pcre2-config ;;
        fmt) [ -f /usr/include/fmt/format.h ] ;;
        icu) have_cmd icu-config ;;
        mariadb) have_cmd mariadbd || have_cmd mysqld ;;
        postgresql) have_cmd postgres ;;
        sqlite) have_cmd sqlite3 ;;
        lmdb) [ -f /usr/lib/liblmdb.so ] ;;
        cyrus-sasl) [ -f /usr/lib/libsasl2.so ] ;;
        openldap) have_cmd slapd ;;
        liburcu) have_pc liburcu ;;
        libuv) have_pc libuv ;;
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

# Find and extract the source archive of a package, printing the
# extracted directory name.
prep_src() {
    local pkg="$1" archive=""
    case "$pkg" in
        # The Apache HTTP Server tarball is named httpd-<version>.
        # Resolve it first: the apache-ant/apache-maven/apache-tomcat
        # tarballs restored to the source list (Nightly #195) share
        # the "apache" prefix and their -src archive would otherwise
        # shadow httpd through find_archive's fallback tier.
        apache) archive="$(find_archive httpd)" ;;
        # ICU ships as icu4c-<ver>-src.tgz; resolve the real prefix so
        # the -src tier cannot pick an unrelated archive (Nightly #198).
        icu)    archive="$(find_archive icu4c)" ;;
        # liburcu ships as userspace-rcu-<version>; resolve the real
        # prefix (Nightly #207).
        liburcu) archive="$(find_archive userspace-rcu)" ;;
        *)      archive="$(find_archive "$pkg")" ;;
    esac
    if [ -z "$archive" ]; then
        log_error "Source archive missing for $pkg"
        return 1
    fi
    log_info "Building $pkg from $archive" >&2
    extract_archive "$archive"
}

# Run the BLFS book commands of one package inside its freshly
# extracted source tree.  The second argument is the name of the
# build_commands_<name> function holding the book commands; JOBS,
# dir and HAVE_SYSTEMD are exported.
book_install() {
    local pkg="$1" build_cmds dir
    build_cmds="$2"
    if is_installed "$pkg"; then
        log_info "$pkg already installed; skipping"
        return 0
    fi
    dir="$(prep_src "$pkg")" || return 1
    pushd "$dir" >/dev/null || return 1
    if ! JOBS="$JOBS" dir="$dir" HAVE_SYSTEMD="$HAVE_SYSTEMD" "$build_cmds"; then
        popd >/dev/null
        return 1
    fi
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for "$pkg")"
    log_success "$pkg installed"
}

# Generic fallback for packages that have no BLFS book page (vsftpd).
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
# Per-package BLFS book commands (wave 3, server chapter).
# ======================================================================

# BLFS general/apr – required by Apr-Util and Apache HTTPD
build_apr() { book_install apr build_commands_apr; }
build_commands_apr() {
    ./configure --prefix=/usr \
                --disable-static \
                --with-installbuilddir=/usr/share/apr-1/build &&
    make -j"$JOBS" && make install
}

# BLFS general/apr-util – required by Apache HTTPD
build_apr_util() { book_install apr-util build_commands_apr_util; }
build_commands_apr_util() {
    ./configure --prefix=/usr \
                --with-apr=/usr \
                --with-gdbm=/usr \
                --with-openssl=/usr \
                --with-crypto &&
    make -j"$JOBS" && make install
}

# BLFS general/pcre2 – required by Apache HTTPD.  Desktop profiles
# already install it in blfs-libs; book_install skips it then.
build_pcre2() { book_install pcre2 build_commands_pcre2; }
build_commands_pcre2() {
    ./configure --prefix=/usr \
                --docdir="/usr/share/doc/$dir" \
                --enable-unicode \
                --enable-jit \
                --enable-pcre2-16 \
                --enable-pcre2-32 \
                --enable-pcre2grep-libz \
                --enable-pcre2grep-libbz2 \
                --enable-pcre2test-libreadline \
                --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS server/apache – BLFS layout patch and sed fixes, guarded.
build_apache() { book_install apache build_commands_apache; }
build_commands_apache() {
    local p
    # The book patch is named httpd-blfs_layout-1.patch (no version
    # segment before the tag); also accept versioned variants so the
    # BLFS layout always reaches config.layout (Nightly #196).
    for p in ../httpd-blfs_layout-*.patch ../httpd-*-blfs_layout-*.patch; do
        [ -f "$p" ] || continue
        patch -Np1 -i "$p" || return 1
    done
    sed '/dir.*CFG_PREFIX/s@^@#@' -i support/apxs.in || return 1
    # shellcheck disable=SC2016
    sed -e '/HTTPD_ROOT/s:${ap_prefix}:/etc/httpd:'       \
        -e '/SERVER_CONFIG_FILE/s:${rel_sysconfdir}/::'   \
        -e '/AP_TYPES_CONFIG_FILE/s:${rel_sysconfdir}/::' \
        -i configure &&
    ./configure --enable-authnz-fcgi                    \
                --enable-layout=BLFS                    \
                --enable-mods-shared="all cgi"          \
                --enable-mpms-shared=all                \
                --enable-suexec=shared                  \
                --with-apr=/usr/bin/apr-1-config        \
                --with-apr-util=/usr/bin/apu-1-config   \
                --with-suexec-bin=/usr/lib/httpd/suexec \
                --with-suexec-caller=apache             \
                --with-suexec-docroot=/srv/www          \
                --with-suexec-uidmin=100                \
                --with-suexec-userdir=public_html       \
                --with-suexec-logfile=/var/log/httpd/suexec.log &&
    make -j"$JOBS" && make install
}

# BLFS general/fmt – required before MariaDB: the build is offline
# (no DNS in the chroot), so MariaDB's ExternalProject cannot fetch
# fmt from GitHub and falls back on the system copy (Nightly #197).
build_fmt() { book_install fmt build_commands_fmt; }
build_commands_fmt() {
    mkdir build && cd build &&
    cmake -D CMAKE_INSTALL_PREFIX=/usr   \
          -D CMAKE_INSTALL_LIBDIR=/usr/lib \
          -D BUILD_SHARED_LIBS=ON        \
          -D FMT_TEST=OFF                \
          -G Ninja .. &&
    ninja && ninja install
}

# BLFS general/icu – configure lives in the source/ subdirectory.
# PostgreSQL fails with "ICU library not found" without it and
# headless profiles never run blfs-libs (Nightly #198).
build_icu() { book_install icu build_commands_icu; }
build_commands_icu() {
    cd source &&
    ./configure --prefix=/usr &&
    make -j"$JOBS" && make install
}

# BLFS server/mariadb
build_mariadb() { book_install mariadb build_commands_mariadb; }
build_commands_mariadb() {
    if [ -f storage/columnstore/columnstore/cmake/boost.cmake ]; then
        sed -i 's/regex system/regex/' \
               storage/columnstore/columnstore/cmake/boost.cmake
    fi
    mkdir build && cd build &&
    cmake -D CMAKE_BUILD_TYPE=Release                       \
          -D CMAKE_INSTALL_PREFIX=/usr                      \
          -D GRN_LOG_PATH=/var/log/groonga.log              \
          -D INSTALL_DOCDIR="share/doc/$dir"                \
          -D INSTALL_DOCREADMEDIR="share/doc/$dir"          \
          -D INSTALL_MANDIR=share/man                       \
          -D INSTALL_MYSQLSHAREDIR=share/mariadb            \
          -D INSTALL_MYSQLTESTDIR=share/mariadb/test        \
          -D INSTALL_PAMDIR=lib/security                    \
          -D INSTALL_PAMDATADIR=/etc/security               \
          -D INSTALL_PLUGINDIR=lib/mariadb/plugin           \
          -D INSTALL_SBINDIR=sbin                           \
          -D INSTALL_SCRIPTDIR=bin                          \
          -D INSTALL_SQLBENCHDIR=share/mariadb/bench        \
          -D INSTALL_SUPPORTFILESDIR=share/mariadb          \
          -D MYSQL_DATADIR=/srv/mariadb                     \
          -D MYSQL_UNIX_ADDR=/run/mariadb/mariadb.sock      \
          -D WITH_EXTRA_CHARSETS=complex                    \
          -D WITH_EMBEDDED_SERVER=ON                        \
          -D SKIP_TESTS=ON                                  \
          -D TOKUDB_OK=0                                    \
          -W no-dev                                         \
          .. &&
    make -j"$JOBS" && make install
}

# BLFS server/postgresql
build_postgresql() { book_install postgresql build_commands_postgresql; }
build_commands_postgresql() {
    sed -i '/DEFAULT_PGSOCKET_DIR/s@/tmp@/run/postgresql@' src/include/pg_config_manual.h &&
    ./configure --prefix=/usr \
                --docdir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install
}

# BLFS server/sqlite – the doc zip is unpacked only when shipped.
build_sqlite() { book_install sqlite build_commands_sqlite; }
build_commands_sqlite() {
    if ls ../*.zip >/dev/null 2>&1 && have_cmd unzip; then
        unzip -q ../*.zip
    fi
    ./configure --prefix=/usr     \
                --disable-static  \
                --enable-fts4     \
                --enable-fts5     \
                CPPFLAGS="-D SQLITE_ENABLE_COLUMN_METADATA=1 \
                          -D SQLITE_ENABLE_UNLOCK_NOTIFY=1   \
                          -D SQLITE_ENABLE_DBSTAT_VTAB=1     \
                          -D SQLITE_SECURE_DELETE=1" &&
    make -j"$JOBS" && make install
}

# BLFS server/lmdb – the tarball extracts to
# openldap-LMDB_<ver>-<hash> and the book build lives in
# libraries/liblmdb.  cyrus-sasl is configured --with-dblib=lmdb
# and openldap's mdb backend needs it too (Nightly #199).
build_lmdb() { book_install lmdb build_commands_lmdb; }
build_commands_lmdb() {
    cd libraries/liblmdb &&
    make &&
    sed -i 's| liblmdb.a||' Makefile &&
    make prefix=/usr install
}

# BLFS postlfs/cyrus-sasl – openldap's book commands pass
# --with-cyrus-sasl, so its configure aborts with "Could not locate
# Cyrus SASL" when the library is missing (Nightly #199).
build_cyrus_sasl() { book_install cyrus-sasl build_commands_cyrus_sasl; }
build_commands_cyrus_sasl() {
    local p
    # gcc15 fixes patch is REQUIRED by the book; apply when present.
    for p in ../cyrus-sasl-*-gcc15_fixes-*.patch; do
        [ -f "$p" ] || continue
        patch -Np1 -i "$p" || return 1
        autoreconf -fiv || return 1
    done
    # gcc-14 build fixes (book).
    sed '/saslint/a #include <time.h>'       -i lib/saslutil.c &&
    sed '/plugin_common/a #include <time.h>' -i plugins/cram.c &&
    ./configure --prefix=/usr                       \
                --sysconfdir=/etc                   \
                --enable-auth-sasldb                \
                --with-dblib=lmdb                   \
                --with-dbpath=/var/lib/sasl/sasldb2 \
                --with-sphinx-build=no              \
                --with-saslauthd=/var/run/saslauthd &&
    make -j1 &&
    make install &&
    install -v -dm755 "/usr/share/doc/$dir/html" &&
    install -v -m644 saslauthd/LDAP_SASLAUTHD "/usr/share/doc/$dir" &&
    install -v -m644 doc/legacy/*.html "/usr/share/doc/$dir/html" &&
    install -v -dm700 /var/lib/sasl
}

# BLFS server/openldap – the book builds the tree twice: a client-only
# pass first, then the full server pass on a fresh tree.
build_openldap() { book_install openldap build_commands_openldap; }
build_commands_openldap() {
    local p sd_opts=""
    if [ "$HAVE_SYSTEMD" != "true" ]; then
        sd_opts="--without-systemd"
    fi
    for p in ../openldap-*-consolidated-*.patch; do
        [ -f "$p" ] || continue
        patch -Np1 -i "$p" || return 1
    done
    autoconf &&
    ./configure --prefix=/usr     \
                --sysconfdir=/etc \
                --disable-static  \
                --enable-dynamic  \
                --disable-debug   \
                --disable-slapd   &&
    make depend &&
    make -j"$JOBS" && make install || return 1
    # Second pass on a fresh tree (book).
    cd /sources || return 1
    dir="$(prep_src openldap)" || return 1
    cd "$dir" || return 1
    for p in ../openldap-*-consolidated-*.patch; do
        [ -f "$p" ] || continue
        patch -Np1 -i "$p" || return 1
    done
    autoconf || return 1
    # shellcheck disable=SC2086
    ./configure --prefix=/usr         \
                --sysconfdir=/etc     \
                --localstatedir=/var  \
                --libexecdir=/usr/lib \
                --disable-static      \
                --disable-debug       \
                --with-tls=openssl    \
                --with-cyrus-sasl     \
                $sd_opts              \
                --enable-dynamic      \
                --enable-crypt        \
                --enable-spasswd      \
                --enable-slapd        \
                --enable-modules      \
                --enable-rlookups     \
                --enable-backends=mod \
                --disable-sql         \
                --disable-wt          \
                --enable-overlays=mod &&
    make depend &&
    make -j"$JOBS" && make install
}

# BLFS general/liburcu – bind 9.20 hard-requires liburcu >= 0.10 at
# configure time ("Package 'liburcu' not found", nightly #207); the
# tarball ships as userspace-rcu (prep_src resolves it).
build_liburcu() { book_install liburcu build_commands_liburcu; }
build_commands_liburcu() {
    ./configure --prefix=/usr    \
                --disable-static \
                --docdir="/usr/share/doc/$dir" &&
    make -j"$JOBS" && make install
}

# BLFS general/libuv – REQUIRED by bind; the GitHub archive ships no
# configure script, so the book runs autogen.sh first.  The chroot
# runs with env -i, so the ACLOCAL clash the book warns about cannot
# happen here.
build_libuv() { book_install libuv build_commands_libuv; }
build_commands_libuv() {
    sh autogen.sh &&
    ./configure --prefix=/usr --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS server/bind
build_bind() { book_install bind build_commands_bind; }
build_commands_bind() {
    ./configure --prefix=/usr           \
                --sysconfdir=/etc       \
                --localstatedir=/var    \
                --mandir=/usr/share/man \
                --disable-static        &&
    make -j"$JOBS" && make install
}

# BLFS server/postfix – optional backend support detected exactly like
# the book does.
build_postfix() { book_install postfix build_commands_postfix; }
build_commands_postfix() {
    local CCARGS AUXLIBS
    if ls README_FILES/* >/dev/null 2>&1; then
        sed -i 's/.\x08//g' README_FILES/*
    fi
    CCARGS="-DNO_NIS -DNO_DB"
    AUXLIBS=""
    if [ -r /usr/lib/libsasl2.so ]; then
        CCARGS="$CCARGS -DUSE_SASL_AUTH -DUSE_CYRUS_SASL -I/usr/include/sasl"
        AUXLIBS="$AUXLIBS -lsasl2"
    fi
    if [ -r /usr/lib/liblmdb.so ]; then
        CCARGS="$CCARGS -DHAS_LMDB"
        AUXLIBS="$AUXLIBS -llmdb"
    fi
    if [ -r /usr/lib/libldap.so ] && [ -r /usr/lib/liblber.so ]; then
        CCARGS="$CCARGS -DHAS_LDAP"
        AUXLIBS="$AUXLIBS -lldap -llber"
    fi
    if [ -r /usr/lib/libsqlite3.so ]; then
        CCARGS="$CCARGS -DHAS_SQLITE"
        AUXLIBS="$AUXLIBS -lsqlite3 -lpthread"
    fi
    if [ -r /usr/lib/libmysqlclient.so ]; then
        CCARGS="$CCARGS -DHAS_MYSQL -I/usr/include/mysql"
        AUXLIBS="$AUXLIBS -lmysqlclient -lz -lm"
    fi
    if [ -r /usr/lib/libpq.so ]; then
        CCARGS="$CCARGS -DHAS_PGSQL -I/usr/include/postgresql"
        AUXLIBS="$AUXLIBS -lpq -lz -lm"
    fi
    if [ -r /usr/lib/libssl.so ] && [ -r /usr/lib/libcrypto.so ]; then
        CCARGS="$CCARGS -DUSE_TLS -I/usr/include/openssl/"
        AUXLIBS="$AUXLIBS -lssl -lcrypto"
    fi
    make CC="gcc -std=gnu17" CCARGS="$CCARGS" AUXLIBS="$AUXLIBS" makefiles &&
    make -j"$JOBS"
    if [ -x /usr/sbin/postfix ]; then
        /usr/sbin/postfix -c /etc/postfix set-permissions || return 1
    fi
}

# BLFS server/dovecot – --with-systemd=no is the sysvinit book variant.
build_dovecot() { book_install dovecot build_commands_dovecot; }
build_commands_dovecot() {
    local sd_opts=""
    if [ "$HAVE_SYSTEMD" != "true" ]; then
        sd_opts="--with-systemd=no"
    fi
    # shellcheck disable=SC2086
    ./configure --prefix=/usr         \
                --sysconfdir=/etc     \
                --localstatedir=/var  \
                $sd_opts              \
                --docdir="/usr/share/doc/$dir" \
                --disable-static &&
    make -j"$JOBS" && make install
}

# BLFS postlfs/openssh
build_openssh() { book_install openssh build_commands_openssh; }
build_commands_openssh() {
    ./configure --prefix=/usr                            \
                --sysconfdir=/etc/ssh                    \
                --with-privsep-path=/var/lib/sshd        \
                --with-default-path=/usr/bin             \
                --with-superuser-path=/usr/sbin:/usr/bin \
                --with-pid-dir=/run                      &&
    make -j"$JOBS" && make install
}

# BLFS server/proftpd
build_proftpd() { book_install proftpd build_commands_proftpd; }
build_commands_proftpd() {
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/run &&
    make -j"$JOBS" && make install
}

# BLFS basicnet/samba – --without-systemd is the sysvinit book variant.
# The book installs cryptography/pyasn1/iso8601 into a venv for the AD DC
# features, but the chroot is offline so pip cannot reach PyPI, and
# --without-ad-dc below disables those features anyway.  A failed venv is
# therefore non-fatal: fall back to the system python3 instead of aborting
# the stage (Nightly #208: "No matching distribution found for
# cryptography" killed every headless job at samba).
build_samba() { book_install samba build_commands_samba; }
build_commands_samba() {
    local sd_opts="" pypath=""
    if [ "$HAVE_SYSTEMD" != "true" ]; then
        sd_opts="--without-systemd"
    fi
    if have_cmd python3 && python3 -m pip --version >/dev/null 2>&1; then
        if python3 -m venv --system-site-packages pyvenv &&
           ./pyvenv/bin/pip3 install cryptography pyasn1 iso8601; then
            pypath="PYTHON=$PWD/pyvenv/bin/python3 PATH=$PWD/pyvenv/bin:$PATH"
        else
            log_warning "samba: python venv unavailable (offline?); building with system python3"
            rm -rf pyvenv
        fi
    else
        log_warning "samba: python3/pip3 unavailable; building with system python3"
    fi
    # shellcheck disable=SC2086
    $pypath ./configure                    \
        --prefix=/usr                      \
        --sysconfdir=/etc                  \
        --localstatedir=/var               \
        --with-piddir=/run/samba           \
        --with-pammodulesdir=/usr/lib/security \
        --enable-fhs                       \
        --without-ad-dc                    \
        $sd_opts                           \
        --with-system-mitkrb5              \
        --enable-selftest                  \
        --disable-rpath-install &&
    make -j"$JOBS" && make install
}

HAVE_SYSTEMD=false
if [ -x /usr/lib/systemd/systemd ] || [ -d /usr/lib/systemd/system ]; then
    HAVE_SYSTEMD=true
fi

# Policy wrapper (audit finding F-07).  required: any failure aborts the
# stage.  optional: failures are logged and the build continues.
# Server packages get their book commands; packages without a BLFS book
# page (vsftpd) use the generic build_pkg.
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

log_info "Phase 1: Web server"

# apr – Apache Portable Runtime, prerequisite of apr-util
run_build required apr

# apr-util – required by Apache HTTPD (BLFS server/apache)
run_build required apr-util

# pcre2 – required by Apache HTTPD; no LFS stage builds it and the
# headless profiles skip blfs-libs, so build it here when missing
run_build required pcre2

# apache – Apache HTTP Server
run_build required apache

log_info "Phase 2: Database servers"

# fmt – header-only check lets MariaDB use the system libfmt instead
# of downloading fmt-11.1.4.zip from GitHub (impossible offline).
run_build required fmt

# mariadb – MariaDB database server (MySQL compatible)
run_build required mariadb

# icu – required by postgresql's configure; skipped when a desktop
# profile already built it in blfs-libs.
run_build required icu

# postgresql – PostgreSQL database server
run_build required postgresql

# sqlite – SQLite database library (already in LFS, verify)
run_build required sqlite

log_info "Phase 3: Directory server"

# lmdb – required by cyrus-sasl's --with-dblib=lmdb and openldap's
# mdb backend; the tarball extracts to openldap-LMDB_*-<hash>
run_build required lmdb

# cyrus-sasl – the openldap book commands pass --with-cyrus-sasl, so
# configure aborts with "Could not locate Cyrus SASL" without it
# (Nightly #199)
run_build required cyrus-sasl

# openldap – OpenLDAP directory server
run_build required openldap

log_info "Phase 4: DNS server"

# liburcu / libuv – both are REQUIRED bind dependencies per the book;
# bind 9.20 configure aborts on the missing pkg-config files
# (Nightly #207)
run_build required liburcu
run_build required libuv

# bind – BIND DNS server
run_build required bind

log_info "Phase 5: Mail servers"

# postfix – Postfix mail transfer agent
run_build required postfix

# dovecot – Dovecot IMAP/POP3 server
run_build required dovecot

log_info "Phase 6: SSH server"

# openssh – OpenSSH SSH client/server
run_build required openssh

log_info "Phase 7: FTP servers"

# vsftpd – Very Secure FTP Daemon; not in packages/stable/12.4/sources.list
run_build optional vsftpd

# proftpd – Professional FTP daemon
run_build required proftpd

log_info "Phase 8: File sharing"

# samba – Samba SMB/CIFS file sharing
run_build required samba

log_success "BLFS Server build complete"
INNEREOF

run_privileged chmod +x "$LFS/build-server.sh"
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-server.sh

log_success "BLFS Server built successfully"
