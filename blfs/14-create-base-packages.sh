#!/bin/bash
# 14-create-base-packages.sh
# Register the LFS/BLFS base package set in the LPM database.
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
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
fi

if [ "$IN_DOCKER" = true ]; then
    LFS=${LFS:-/output/image}
else
    LFS=${LFS:-/mnt/lfs}
fi

if [ -z "${LFS:-}" ] || [ ! -d "$LFS" ]; then
    log_error "LFS directory not set or does not exist: ${LFS:-<unset>}"
    exit 1
fi

run_privileged() {
    if [ "$(whoami)" = "root" ]; then "$@"; else sudo "$@"; fi
}

log_info "========================================="
log_info "Registering base packages in LPM database"
log_info "========================================="

# ---------------------------------------------------------------------------
# LPM database layout (see blfs/19-lpm.sh):
#   /var/lib/lpm/packages.list -> available package metadata (pipe-separated)
#   /var/lib/lpm/installed.list -> installed packages ("name version" lines)
#   /usr/share/lpm/base-packages.list -> canonical list of base packages
# Format v2.1.0 (pipe-separated):
#   name|version|description|deps|checksum
# ---------------------------------------------------------------------------

run_privileged mkdir -p "$LFS/var/cache/lpm"
run_privileged mkdir -p "$LFS/var/lib/lpm"
run_privileged mkdir -p "$LFS/usr/share/lpm"
run_privileged mkdir -p "$LFS/etc/lpm"

BASE_LIST="$LFS/usr/share/lpm/base-packages.list"
DB_FILE="$LFS/var/lib/lpm/packages.list"
INSTALLED_FILE="$LFS/var/lib/lpm/installed.list"

# ---------------------------------------------------------------------------
# Canonical base package set (LFS 13.0 + minimal BLFS runtime)
# name|fallback-version|description|deps
# Field 2 is only a fallback: the real version is resolved from the
# source tarballs actually used by this build when available.
# ---------------------------------------------------------------------------
BASE_PACKAGES=$(
    cat <<'LIST'
# ============================================================================
# LFS 13.0 base package registry
# Format: name|fallback-version|description|comma-separated-deps
# Managed by LPM (LFS Package Manager) v2.7.0+
# ============================================================================

# --- Toolchain / Core runtime (Chapter 5-8) -----------------------------------
glibc|2.42|GNU C Library, the core runtime for all Linux userspace|
gcc|15.2.0|GNU Compiler Collection C/C++ runtime libraries|glibc
binutils|2.46.0|Binary utilities (ld, as, ar, objdump)|glibc
bash|5.3|GNU Bourne Again Shell, the default LFS shell|glibc,ncurses,readline
coreutils|9.7|GNU core utilities (ls, cp, mv, mkdir, ...)|glibc
findutils|4.10.0|find, xargs, locate|glibc
grep|3.12|GNU grep, egrep, fgrep|glibc,pcre2
sed|4.9|GNU stream editor|glibc
gawk|5.3.2|GNU awk implementation|glibc,mpfr,readline
tar|1.35|GNU tar archiver|glibc,acl,attr
gzip|1.14|GNU gzip compressor|glibc
bzip2|1.0.8|bzip2 compressor|glibc
xz|5.8.1|XZ/LZMA compressor|glibc
diffutils|3.12|GNU diffutils (diff, cmp, patch reference impl)|glibc
patch|2.8|GNU patch|glibc
make|4.4.1|GNU Make|glibc
util-linux|2.41.1|Miscellaneous system utilities (mount, dmesg, ...)|glibc,ncurses
procps-ng|4.0.5|/proc reading utilities (ps, top, kill, ...)|glibc,ncurses
psmisc|23.7|pstree, killall, fuser|glibc,ncurses
iproute2|6.16.0|IPv4/6 routing utilities (ip, tc, ss)|glibc,libmnl,libcap
kbd|2.7.1|Keyboard tables and console utilities|glibc,pam
kmod|34|Linux kernel module utilities|glibc,xz,zlib
inetutils|2.6|Network client suite (ping, telnet, ftp)|glibc,ncurses,readline
less|681|Terminal pager|glibc,ncurses
nano|8.5|Nano text editor|glibc,ncurses
readline|8.3|GNU readline command-line library|glibc,ncurses
ncurses|6.5|Terminal handling library|glibc
zlib|1.3.1|Deflate compression library|glibc
file|5.46|File type identification utility|glibc,zlib

# --- Boot / init --------------------------------------------------------------
systemd|257.8|System and service manager (systemd profile only)|glibc,libcap,util-linux
sysvinit|3.14|Classic SysV init (sysvinit profile)|glibc
grub|2.12|GNU GRUB2 bootloader|glibc,freetype

# --- Networking / security base ----------------------------------------------
openssl|3.6.1|OpenSSL cryptographic library and CLI|glibc,zlib
ca-certificates|2025.05.18|Mozilla-derived CA bundle|openssl
curl|8.15.0|Multi-protocol network transfer|glibc,openssl,zlib,libssh2
wget|1.25.0|GNU Wget network retriever|glibc,openssl,pcre2
openssh|10.0p1|OpenSSH client and server|glibc,openssl,zlib
sudo|1.9.17p2|Delegate root privileges|glibc,pam

# --- Development staples ------------------------------------------------------
python|3.13.5|Python 3 interpreter|glibc,openssl,zlib,expat,sqlite
perl|5.42.0|Perl 5 interpreter|glibc,gdbm
git|2.50.1|Distributed version control|glibc,openssl,curl,pcre2,zlib
cmake|4.0.3|Cross-platform build system|glibc,openssl
LIST
)

# ---------------------------------------------------------------------------
# Resolve real versions from the source tarballs used by this build.
# Same name-version split rule as LPM itself: the version must start
# with a digit, everything before it is the package name.
# ---------------------------------------------------------------------------
sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

TARBALL_VERSIONS=$(mktemp)
if [ -d "$LFS/sources" ]; then
    for tarball in "$LFS/sources"/*.tar.*; do
        [ -e "$tarball" ] || continue
        base=$(basename "$tarball")
        base="${base%%.tar.*}"
        if [[ "$base" =~ ^([a-zA-Z0-9._+-]+)-([0-9][a-zA-Z0-9._+-]*)$ ]]; then
            printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
            # Case-insensitive alias (Python-3.13.x.tar.xz -> python).
            printf '%s %s\n' \
                "$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')" \
                "${BASH_REMATCH[2]}"
        fi
    done | sort -u >"$TARBALL_VERSIONS"
    log_info "Version hints from source tarballs: $(wc -l <"$TARBALL_VERSIONS")"
else
    log_warning "No sources directory at $LFS/sources; using curated fallback versions"
fi

resolve_version() {
    local name="$1" fallback="$2" found
    found=$(awk -v n="$name" '$1 == n { print $2; exit }' "$TARBALL_VERSIONS")
    if [ -n "$found" ]; then
        printf '%s\n' "$found"
    else
        printf '%s\n' "$fallback"
    fi
}

RESOLVED=$(mktemp)
while IFS= read -r line; do
    case "$line" in
    '' | \#*) continue ;;
    esac
    IFS='|' read -r name version description deps <<<"$line"
    [ -z "$name" ] && continue
    version=$(resolve_version "$name" "$version")
    printf '%s|%s|%s|%s\n' "$name" "$version" "$description" "$deps" >>"$RESOLVED"
done <<<"$BASE_PACKAGES"
rm -f "$TARBALL_VERSIONS"

log_info "Writing canonical base-packages list to $BASE_LIST"
run_privileged tee "$BASE_LIST" >/dev/null <"$RESOLVED"

# ---------------------------------------------------------------------------
# Populate the available-packages database (name|version|desc|deps|checksum)
# ---------------------------------------------------------------------------
log_info "Populating LPM database at $DB_FILE"

TMP_DB=$(mktemp)
if [ -f "$DB_FILE" ]; then
    cp "$DB_FILE" "$TMP_DB"
fi

while IFS='|' read -r name version description deps; do
    [ -z "$name" ] && continue
    # Checksum placeholder; LPM replaces it on a real install/build.
    checksum="base-$(printf '%s' "$name-$version" | sha256_stdin | cut -c1-16)"
    # Replace any stale entry for this package, then append the fresh one.
    awk -F'|' -v n="$name" '$1 != n' "$TMP_DB" >"$TMP_DB.new"
    mv "$TMP_DB.new" "$TMP_DB"
    printf '%s|%s|%s|%s|%s\n' "$name" "$version" "$description" "$deps" "$checksum" >>"$TMP_DB"
done <"$RESOLVED"

run_privileged install -m 0644 "$TMP_DB" "$DB_FILE"

# ---------------------------------------------------------------------------
# Seed the installed registry so lpm list/upgrade/verify work on the
# finished system: every base package was compiled by the LFS stages.
# Entries LPM installed itself are preserved.
# ---------------------------------------------------------------------------
log_info "Seeding installed registry at $INSTALLED_FILE"

TMP_INSTALLED=$(mktemp)
touch "$TMP_INSTALLED"
if [ -f "$INSTALLED_FILE" ]; then
    cp "$INSTALLED_FILE" "$TMP_INSTALLED"
fi

awk 'NR == FNR { split($0, f, "|"); seed[f[1]] = 1; next } !($1 in seed)' \
    "$RESOLVED" "$TMP_INSTALLED" >"$TMP_INSTALLED.new"
cut -d'|' -f1,2 "$RESOLVED" | tr '|' ' ' >>"$TMP_INSTALLED.new"

run_privileged install -m 0644 "$TMP_INSTALLED.new" "$INSTALLED_FILE"
rm -f "$TMP_DB" "$TMP_INSTALLED" "$TMP_INSTALLED.new"

# ---------------------------------------------------------------------------
# Export the repository manifest for the release pipeline. Installed
# systems fetch it from the GitHub release assets via `lpm update-db`.
# ---------------------------------------------------------------------------
REPO_DIR="${LFS_CONFIG_OUTPUT_DIR:-$(dirname "$LFS")}/lpm-repo"
mkdir -p "$REPO_DIR"
install -m 0644 "$DB_FILE" "$REPO_DIR/packages.list" 2>/dev/null ||
    cp "$LFS/var/lib/lpm/packages.list" "$REPO_DIR/packages.list"
(
    cd "$REPO_DIR"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum packages.list >packages.list.sha256
    else
        shasum -a 256 packages.list | awk '{print $1 "  packages.list"}' >packages.list.sha256
    fi
)
if command -v gpg >/dev/null 2>&1 && gpg --list-secret-keys 2>/dev/null | grep -q sec; then
    if gpg --batch --yes --armor --detach-sign \
        --output "$REPO_DIR/packages.list.sig" "$REPO_DIR/packages.list" 2>/dev/null; then
        log_success "Repository manifest signed: $REPO_DIR/packages.list.sig"
    else
        log_warning "GPG signing of the repository manifest failed; shipping unsigned"
    fi
else
    log_info "No GPG secret key available; repository manifest shipped unsigned"
fi
rm -f "$RESOLVED"
log_success "Repository manifest exported to $REPO_DIR"

# ---------------------------------------------------------------------------
# LPM configuration file
# ---------------------------------------------------------------------------
if [ ! -f "$LFS/etc/lpm/lpm.conf" ]; then
    log_info "Writing default LPM configuration to /etc/lpm/lpm.conf"
    run_privileged tee "$LFS/etc/lpm/lpm.conf" >/dev/null <<'CONF'
# LFS Package Manager configuration
# See /usr/share/doc/lpm/README for details

# LPM runtime paths
LPM_DB=/var/lib/lpm
LPM_LOGS=/var/log/lpm
LPM_PACKAGES_DIR=/usr/share/lpm/packages

# Remote repositories. Leave empty until a signed repository is published.
REPO_REMOTE_URLS=()

# Number of parallel jobs for compilation
JOBS=0   # 0 = auto (nproc)

# Disable ANSI colours (also honoured via NO_COLOR env var)
USE_COLOR=1
CONF
fi

# ---------------------------------------------------------------------------
# LPM profiles database
# ---------------------------------------------------------------------------
if [ ! -f "$LFS/etc/lpm/profiles.json" ]; then
    log_info "Installing LPM profiles database to /etc/lpm/profiles.json"
    if [ -f "$SCRIPT_DIR/../config/lpm-profiles.json" ]; then
        run_privileged install -m 0644 "$SCRIPT_DIR/../config/lpm-profiles.json" "$LFS/etc/lpm/profiles.json"
    else
        log_warning "LPM profiles template not found at $SCRIPT_DIR/../config/lpm-profiles.json"
    fi
fi

PKG_COUNT=$(grep -cE '^[^#|]+\|' "$DB_FILE" || echo 0)
INSTALLED_COUNT=$(wc -l <"$INSTALLED_FILE" | tr -d ' ')
log_success "Registered $PKG_COUNT base packages in LPM database"
log_success "Seeded $INSTALLED_COUNT packages in the installed registry"
log_success "Base package list: $BASE_LIST"
log_success "LPM database:      $DB_FILE"
log_success "LPM installed:     $INSTALLED_FILE"
log_success "LPM repo manifest: $REPO_DIR/packages.list"
log_success "LPM config:        $LFS/etc/lpm/lpm.conf"
log_success "LPM profiles:      $LFS/etc/lpm/profiles.json"
exit 0
