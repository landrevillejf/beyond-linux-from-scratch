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
#   /var/lib/lpm/db.list      -> installed packages metadata (pipe-separated)
#   /var/lib/lpm/files/<pkg>  -> file manifest per package
#   /usr/share/lpm/base-packages.list -> canonical list of base packages
# Format v2.1.0 (pipe-separated):
#   name|version|description|deps|checksum
# ---------------------------------------------------------------------------

run_privileged mkdir -p "$LFS/var/cache/lpm"
run_privileged mkdir -p "$LFS/var/lib/lpm/files"
run_privileged mkdir -p "$LFS/usr/share/lpm"
run_privileged mkdir -p "$LFS/etc/lpm"

BASE_LIST="$LFS/usr/share/lpm/base-packages.list"
DB_FILE="$LFS/var/lib/lpm/db.list"
FILES_DIR="$LFS/var/lib/lpm/files"

# ---------------------------------------------------------------------------
# Canonical base package set (LFS 12.4 + minimal BLFS runtime)
# name|version|description|deps
# ---------------------------------------------------------------------------
BASE_PACKAGES=$(
    cat <<'LIST'
# ============================================================================
# LFS 12.4 base package registry
# Format: name|version|description|comma-separated-deps
# Managed by LPM (LFS Package Manager) v2.1.0+
# ============================================================================

# --- Toolchain / Core runtime (Chapter 5-8) -----------------------------------
glibc|2.40|GNU C Library, the core runtime for all Linux userspace|
gcc|14.2.0|GNU Compiler Collection C/C++ runtime libraries|glibc
binutils|2.43.1|Binary utilities (ld, as, ar, objdump)|glibc
bash|5.2.32|GNU Bourne Again Shell, the default LFS shell|glibc,ncurses,readline
coreutils|9.5|GNU core utilities (ls, cp, mv, mkdir, ...)|glibc
findutils|4.10.0|find, xargs, locate|glibc
grep|3.11|GNU grep, egrep, fgrep|glibc,pcre2
sed|4.9|GNU stream editor|glibc
gawk|5.3.0|GNU awk implementation|glibc,mpfr,readline
tar|1.35|GNU tar archiver|glibc,acl,attr
gzip|1.13|GNU gzip compressor|glibc
bzip2|1.0.8|bzip2 compressor|glibc
xz|5.6.2|XZ/LZMA compressor|glibc
diffutils|3.10|GNU diffutils (diff, cmp, patch reference impl)|glibc
patch|2.7.6|GNU patch|glibc
make|4.4.1|GNU Make|glibc
util-linux|2.40.2|Miscellaneous system utilities (mount, dmesg, ...)|glibc,ncurses
procps-ng|4.0.4|/proc reading utilities (ps, top, kill, ...)|glibc,ncurses
psmisc|23.7|pstree, killall, fuser|glibc,ncurses
iproute2|6.10.0|IPv4/6 routing utilities (ip, tc, ss)|glibc,libmnl,libcap
kbd|2.6.4|Keyboard tables and console utilities|glibc,pam
kmod|33|Linux kernel module utilities|glibc,xz,zlib
inetutils|2.5|Network client suite (ping, telnet, ftp)|glibc,ncurses,readline
less|661|Terminal pager|glibc,ncurses
nano|8.1|Nano text editor|glibc,ncurses
readline|8.2.13|GNU readline command-line library|glibc,ncurses
ncurses|6.5|Terminal handling library|glibc
zlib|1.3.1|Deflate compression library|glibc
file|5.45|File type identification utility|glibc,zlib

# --- Boot / init --------------------------------------------------------------
systemd|256.7|System and service manager (systemd profile only)|glibc,libcap,util-linux
sysvinit|3.11|Classic SysV init (sysvinit profile)|glibc
grub|2.12|GNU GRUB2 bootloader|glibc,freetype

# --- Networking / security base ----------------------------------------------
openssl|3.3.2|OpenSSL cryptographic library and CLI|glibc,zlib
ca-certificates|2024.09|Mozilla-derived CA bundle|openssl
curl|8.10.1|Multi-protocol network transfer|glibc,openssl,zlib,libssh2
wget|1.24.5|GNU Wget network retriever|glibc,openssl,pcre2
openssh|9.9p1|OpenSSH client and server|glibc,openssl,zlib
sudo|1.9.15p5|Delegate root privileges|glibc,pam

# --- Development staples ------------------------------------------------------
python|3.12.6|Python 3 interpreter|glibc,openssl,zlib,expat,sqlite
perl|5.40.0|Perl 5 interpreter|glibc,gdbm
git|2.46.0|Distributed version control|glibc,openssl,curl,pcre2,zlib
cmake|3.30.4|Cross-platform build system|glibc,openssl
LIST
)

log_info "Writing canonical base-packages list to $BASE_LIST"
echo "$BASE_PACKAGES" | run_privileged tee "$BASE_LIST" >/dev/null

# ---------------------------------------------------------------------------
# Populate LPM database with the base set
# ---------------------------------------------------------------------------
log_info "Populating LPM database at $DB_FILE"

# Preserve any existing entries (idempotent), then merge
TMP_DB=$(mktemp)
if [ -f "$DB_FILE" ]; then
    cp "$DB_FILE" "$TMP_DB"
fi

echo "$BASE_PACKAGES" | while IFS= read -r line; do
    # Skip comments and blank lines
    case "$line" in
    '' | \#*) continue ;;
    esac
    # Ensure line has 4 pipe-separated fields (name|version|desc|deps)
    IFS='|' read -r name version description deps <<<"$line"
    [ -z "$name" ] && continue
    # Append a checksum placeholder (real one is set at real install time by LPM)
    checksum="base-$(printf '%s' "$name-$version" | sha256sum | cut -c1-16)"
    # Idempotency: only add if not already in db
    if ! grep -F -q "^$name|" "$TMP_DB" 2>/dev/null; then
        printf '%s|%s|%s|%s|%s\n' "$name" "$version" "$description" "$deps" "$checksum" >>"$TMP_DB"
    fi
    # Empty file manifest for base packages (they are installed outside LPM)
    manifest="$FILES_DIR/$name"
    [ -f "$manifest" ] || : >"$manifest"
done

run_privileged install -m 0644 "$TMP_DB" "$DB_FILE"
rm -f "$TMP_DB"

# ---------------------------------------------------------------------------
# LPM configuration file
# ---------------------------------------------------------------------------
if [ ! -f "$LFS/etc/lpm/lpm.conf" ]; then
    log_info "Writing default LPM configuration to /etc/lpm/lpm.conf"
    run_privileged tee "$LFS/etc/lpm/lpm.conf" >/dev/null <<'CONF'
# LFS Package Manager configuration
# See /usr/share/doc/lpm/README for details

# Package cache directory
CACHE_DIR=/var/cache/lpm

# Database location
DB_DIR=/var/lib/lpm

# Remote repository (override with `lpm --repo <url>`)
REPO_URL=https://packages.beyond-lfs.org/stable

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
log_success "Registered $PKG_COUNT base packages in LPM database"
log_success "Base package list: $BASE_LIST"
log_success "LPM database:      $DB_FILE"
log_success "LPM config:        $LFS/etc/lpm/lpm.conf"
log_success "LPM profiles:      $LFS/etc/lpm/profiles.json"
exit 0
