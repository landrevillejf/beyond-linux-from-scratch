#!/usr/bin/env bash
# LPM – Linux Package Manager
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
# Version: 2.7.0

set -euo pipefail

# Database format uses pipe (|) as separator for robustness
# Format: name|version|description|dep1,dep2|checksum

# ======================================================================
# Colors (can be disabled in config)
# ======================================================================
# shellcheck disable=SC2034
C_RED='\033[0;31m' C_GREEN='\033[0;32m' C_YELLOW='\033[1;33m' C_BLUE='\033[0;34m' C_NC='\033[0m'
# shellcheck disable=SC2034
USE_COLOR=true

# ======================================================================
# Default configuration
# ======================================================================
LPM_VERSION="2.7.0"
LPM_CONF="${LPM_CONF:-/etc/lpm/lpm.conf}"
LPM_ETC="${LPM_ETC:-/etc/lpm}"
LPM_DB="${LPM_DB:-/var/lib/lpm}"
LPM_LOGS="${LPM_LOGS:-/var/log/lpm}"
LPM_PACKAGES_DIR="${LPM_PACKAGES_DIR:-/usr/share/lpm/packages}"
LPM_ROOT="${LPM_ROOT:-/}"                            # Install root (alias: --sysroot; for chroots/testing)
LPM_BUILD_DIR="${LPM_BUILD_DIR:-/var/lib/lpm/build}" # Source build directory
# shellcheck disable=SC2034  # kept for config file compat
LPM_REPOS=("local")
REPO_LOCAL_PATH="${REPO_LOCAL_PATH:-$LPM_PACKAGES_DIR}"
REPO_REMOTE_URLS=() # HTTP(S) repo base URLs
LOCK_FILE="${LOCK_FILE:-/var/lock/lpm.lock}"
VERIFY_CHECKSUMS=true
VERIFY_SIGNATURES=false # GPG signature verification
GPG_KEYRING="${GPG_KEYRING:-/etc/lpm/trusted.gpg}"
LOG_TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"          # Keep logs for 30 days
ALLOW_DUMMY_CHECKSUMS="${ALLOW_DUMMY_CHECKSUMS:-false}" # Warn on dummy checksums
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
KEEP_BUILD_ARTIFACTS="${KEEP_BUILD_ARTIFACTS:-false}"
HAS_JQ=false # Detect jq availability at runtime

# Runtime variables
QUIET=false
VERBOSE=false
DRY_RUN=false
FORCE=false
NO_COLOR=false
LOCK_FD=""
VISITED_DEPS=""        # Visited packages as pipe-separated list (e.g., "pkg1|pkg2|pkg3|")
HISTORY_ACTION="install" # Transaction type recorded by install_package

# ======================================================================
# Logging helpers (respecting NO_COLOR and USE_COLOR)
# ======================================================================
_apply_color() {
    if ! $NO_COLOR && $USE_COLOR; then
        echo "$1"
    fi
}

log_info() {
    $QUIET || echo -e "$(_apply_color "${C_GREEN}")[INFO]$(_apply_color "${C_NC}") $*" >&2
}
log_warn() {
    echo -e "$(_apply_color "${C_YELLOW}")[WARNING]$(_apply_color "${C_NC}") $*" >&2
}
log_error() {
    echo -e "$(_apply_color "${C_RED}")[ERROR]$(_apply_color "${C_NC}") $*" >&2
}
log_success() {
    echo -e "$(_apply_color "${C_GREEN}")[SUCCESS]$(_apply_color "${C_NC}") $*" >&2
}
log_verbose() {
    $VERBOSE && echo -e "$(_apply_color "${C_BLUE}")[DEBUG]$(_apply_color "${C_NC}") $*" >&2 || true
}

# ======================================================================
# Utility functions
# ======================================================================
die() {
    log_error "$@"
    exit 1
}

timestamp() { date +"$LOG_TIMESTAMP_FORMAT"; }

# Escape regex special characters for safe grep/sed usage
escape_regex() {
    printf '%s\n' "$1" | sed -e 's/[]\/$*.^[]/\\&/g'
}

# Portable in-place sed (GNU sed on Linux, BSD sed on macOS/BSD)
sed_inplace() {
    if sed --version >/dev/null 2>&1; then
        sed -i "$@"
    else
        local expr="$1"
        shift
        sed -i '' "$expr" "$@"
    fi
}

# Portable SHA256
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Acquire exclusive lock (flock on Linux, atomic mkdir fallback elsewhere)
LOCK_DIR_USED=false
acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec {LOCK_FD}>"$LOCK_FILE"
        if ! flock -n "$LOCK_FD"; then
            die "Another lpm instance is running. Exiting."
        fi
    else
        if ! mkdir "${LOCK_FILE}.d" 2>/dev/null; then
            die "Another lpm instance is running. Exiting."
        fi
        LOCK_DIR_USED=true
    fi
}

release_lock() {
    if [ -n "$LOCK_FD" ]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
    fi
    if [ "$LOCK_DIR_USED" = true ]; then
        rmdir "${LOCK_FILE}.d" 2>/dev/null || true
    fi
}

# Detect jq availability at runtime
detect_jq() {
    if command -v jq >/dev/null 2>&1; then
        HAS_JQ=true
        log_verbose "jq detected for robust JSON parsing"
    else
        HAS_JQ=false
        log_verbose "jq not available; using portable sed/grep parser"
    fi
}

# Validate JSON structure (requires Python or jq)
validate_json() {
    local json_file="$1"
    if [ ! -f "$json_file" ]; then
        return 1
    fi
    if $HAS_JQ; then
        jq empty "$json_file" 2>/dev/null
    else
        python3 -m json.tool "$json_file" >/dev/null 2>&1
    fi
}

# Rotate logs based on LOG_RETENTION_DAYS
rotate_logs() {
    if [ ! -d "$LPM_LOGS" ]; then
        return 0
    fi

    local retention_days=${LOG_RETENTION_DAYS:-30}
    local rotated=0

    # Find and remove logs older than retention_days
    while IFS= read -r logfile; do
        rm -f "$logfile"
        rotated=$((rotated + 1))
    done < <(find "$LPM_LOGS" -name "*.log*" -type f -mtime "+$retention_days" 2>/dev/null)

    if [ "$rotated" -gt 0 ]; then
        log_verbose "Rotated $rotated log files older than $retention_days days"
    fi
}

refresh_runtime_paths() {
    db_file="$LPM_DB/packages.list"
    installed_file="$LPM_DB/installed.list"
    file_index="$LPM_DB/file_index"
    kernel_deps_file="$LPM_DB/kernel_deps.list"
    holds_file="$LPM_DB/holds.list"
    history_file="$LPM_DB/history.log"
}

root_path() {
    local path="$1"
    local stripped="${path#"$LPM_ROOT"}"
    if [ "$LPM_ROOT" = "/" ] || [ "$stripped" != "$path" ]; then
        printf '%s\n' "$path"
    else
        printf '%s%s\n' "${LPM_ROOT%/}" "$path"
    fi
}

apply_sysroot_paths() {
    LPM_CONF=$(root_path "$LPM_CONF")
    LPM_ETC=$(root_path "$LPM_ETC")
    LPM_DB=$(root_path "$LPM_DB")
    LPM_LOGS=$(root_path "$LPM_LOGS")
    LPM_PACKAGES_DIR=$(root_path "$LPM_PACKAGES_DIR")
    LPM_BUILD_DIR=$(root_path "$LPM_BUILD_DIR")
    LOCK_FILE=$(root_path "$LOCK_FILE")
    REPO_LOCAL_PATH=$(root_path "$REPO_LOCAL_PATH")
    GPG_KEYRING=$(root_path "$GPG_KEYRING")
}

# Read repository definitions from $LPM_ETC/repos.d/*.conf (name=url lines)
# and append their URLs to REPO_REMOTE_URLS. Config files keep working even
# when lpm.conf leaves REPO_REMOTE_URLS empty.
load_repos_d() {
    local repos_dir="$LPM_ETC/repos.d"
    [ -d "$repos_dir" ] || return 0
    local conf line url
    for conf in "$repos_dir"/*.conf; do
        [ -f "$conf" ] || continue
        while IFS= read -r line; do
            case "$line" in
            '' | \#*) continue ;;
            *=*) : ;;
            *) continue ;;
            esac
            url="${line#*=}"
            if [ -z "$url" ]; then
                continue
            fi
            # Skip duplicates (config array may already hold the URL).
            local known
            known=false
            local existing
            for existing in "${REPO_REMOTE_URLS[@]:-}"; do
                if [ "$existing" = "$url" ]; then
                    known=true
                    break
                fi
            done
            $known || REPO_REMOTE_URLS+=("$url")
        done <"$conf"
    done
}

# Read configuration file (sourced)
load_config() {
    if [ -f "$LPM_CONF" ]; then
        # shellcheck disable=SC1090
        source "$LPM_CONF"
    fi
    apply_sysroot_paths
    load_repos_d
    refresh_runtime_paths
    log_verbose "Configuration loaded from $LPM_CONF"
}

# Ensure directories exist
init_dirs() {
    mkdir -p "$LPM_DB" "$LPM_LOGS" "$LPM_ETC" "$LPM_PACKAGES_DIR" "$(dirname "$LOCK_FILE")"
    touch "$LPM_DB/packages.list" "$LPM_DB/installed.list" "$LPM_DB/file_index" "$LPM_DB/kernel_deps.list" \
        "$LPM_DB/holds.list" "$LPM_DB/history.log"
    mkdir -p "$LPM_BUILD_DIR"/{sources,src,pkg}
    # Rotate old logs and detect jq availability
    rotate_logs
    detect_jq
}

# ======================================================================
# Package database helpers (pipe-separated format for robustness)
# Format: name|version|description|dependencies|checksum
# ======================================================================
refresh_runtime_paths

# Read package metadata from DB with proper field parsing
# Exact name match on field 1 (fixes prefix collisions like foo vs libfoo)
get_pkg_field() {
    local pkg="$1" field="$2"
    local line
    line=$(awk -F'|' -v p="$pkg" '$1 == p { print; exit }' "$db_file" 2>/dev/null || true)
    [ -z "$line" ] && return

    case "$field" in
    version) echo "$line" | cut -d'|' -f2 ;;
    description) echo "$line" | cut -d'|' -f3 ;;
    dependencies) echo "$line" | cut -d'|' -f4 ;;
    checksum) echo "$line" | cut -d'|' -f5 ;;
    *) echo "$line" | cut -d'|' -f"$field" ;;
    esac
}

# Check if package is installed (exact first-column match)
is_installed() {
    awk -v p="$1" '$1 == p { found=1; exit } END { exit !found }' "$installed_file" 2>/dev/null
}

# Get installed version (exact first-column match)
installed_version() {
    awk -v p="$1" '$1 == p { print $2; exit }' "$installed_file" 2>/dev/null
}

# Append a transaction record: timestamp|action|package|version
record_history() {
    local action="$1" pkg="$2" version="${3:-}"
    printf '%s|%s|%s|%s\n' "$(timestamp)" "$action" "$pkg" "$version" >>"$history_file"
}

# Show the transaction history (newest entries last), optional line limit
show_history() {
    local limit="${1:-50}"
    if [ ! -s "$history_file" ]; then
        log_info "No transaction history recorded"
        return 0
    fi
    echo -e "$(_apply_color "${C_BLUE}")Transaction history (last $limit entries):$(_apply_color "${C_NC}")"
    tail -n "$limit" "$history_file" | while IFS='|' read -r ts action pkg version; do
        printf "  %-19s %-9s %-20s %s\n" "$ts" "$action" "$pkg" "$version"
    done
}

# Hold management: held packages are skipped by lpm upgrade
is_held() {
    [ -s "$holds_file" ] || return 1
    awk -v p="$1" '$1 == p { found=1; exit } END { exit !found }' "$holds_file" 2>/dev/null
}

hold_package() {
    local pkg="$1"
    [ -z "$pkg" ] && die "Usage: lpm hold <package>"
    if is_held "$pkg"; then
        log_info "Package '$pkg' is already held"
        return 0
    fi
    echo "$pkg" >>"$holds_file"
    record_history "hold" "$pkg" "$(installed_version "$pkg")"
    log_success "Package '$pkg' held; lpm upgrade will skip it"
}

unhold_package() {
    local pkg="$1"
    [ -z "$pkg" ] && die "Usage: lpm unhold <package>"
    if ! is_held "$pkg"; then
        log_info "Package '$pkg' is not held"
        return 0
    fi
    local tmp
    tmp=$(mktemp)
    awk -v p="$pkg" '$1 != p' "$holds_file" >"$tmp"
    mv "$tmp" "$holds_file"
    record_history "unhold" "$pkg" "$(installed_version "$pkg")"
    log_success "Package '$pkg' unheld"
}

list_holds() {
    if [ ! -s "$holds_file" ]; then
        log_info "No held packages"
        return 0
    fi
    echo -e "$(_apply_color "${C_BLUE}")Held packages (skipped by upgrade):$(_apply_color "${C_NC}")"
    local pkg
    while read -r pkg; do
        [ -z "$pkg" ] && continue
        printf "  %-20s %s\n" "$pkg" "$(installed_version "$pkg")"
    done <"$holds_file"
}

# Compare versions: returns 0 if $1 >= $2 (portable, handles suffixes like a, b, rc)
version_gte() {
    local v1="$1" v2="$2"

    # Extract suffix (alpha, beta, rc, etc) - e.g., "1.2.3rc1" -> base="1.2.3", suffix="rc1"
    local base1 base2 suffix1 suffix2
    # Use parameter expansion to extract base (before first letter)
    # shellcheck disable=SC2001
    base1=$(echo "$v1" | sed 's/[a-zA-Z].*//')
    # shellcheck disable=SC2001
    base2=$(echo "$v2" | sed 's/[a-zA-Z].*//')
    # shellcheck disable=SC2001
    suffix1=$(echo "$v1" | sed 's/^[0-9.]*//')
    # shellcheck disable=SC2001
    suffix2=$(echo "$v2" | sed 's/^[0-9.]*//')

    # If base is empty, use the whole version
    base1=${base1:-$v1}
    base2=${base2:-$v2}

    # Use awk for numeric comparison to avoid array issues
    awk -v v1="$base1" -v v2="$base2" -v s1="$suffix1" -v s2="$suffix2" 'BEGIN {
        # Split versions
        n1 = split(v1, p1, ".")
        n2 = split(v2, p2, ".")
        max = (n1 > n2) ? n1 : n2
        
        # Compare numeric parts
        for (i = 1; i <= max; i++) {
            a = p1[i] + 0
            b = p2[i] + 0
            if (a > b) exit 0
            if (a < b) exit 1
        }
        
        # If bases equal, release > rc > beta > alpha
        if (s1 == "" && s2 != "") exit 0
        if (s1 != "" && s2 == "") exit 1
        if (s1 > s2) exit 0
        exit 1
    }' && return 0 || return 1
}

# Parse dep spec "name>=1.2" / "name=1.2" / "name" -> sets DEP_NAME, DEP_OP, DEP_VER
parse_dep_spec() {
    local spec="$1"
    if [[ $spec =~ ^([a-zA-Z0-9._+-]+)(>=|=)(.+)$ ]]; then
        DEP_NAME="${BASH_REMATCH[1]}"
        DEP_OP="${BASH_REMATCH[2]}"
        DEP_VER="${BASH_REMATCH[3]}"
    else
        DEP_NAME="$spec"
        DEP_OP=""
        DEP_VER=""
    fi
}

# Check installed/available version satisfies constraint
dep_satisfied() {
    local name="$1" op="$2" want="$3"
    is_installed "$name" || return 1
    [ -z "$op" ] && return 0
    local have
    have=$(installed_version "$name")
    case "$op" in
    '>=') version_gte "$have" "$want" ;;
    '=') [ "$have" = "$want" ] ;;
    esac
}

# Dependency resolver with circular dependency detection and version constraints
resolve_deps() {
    local pkg="$1"
    local deps

    # Check for circular dependency (pipe-separated list, fast substring search)
    if [[ $VISITED_DEPS == *"|${pkg}|"* ]]; then
        log_error "Circular dependency detected: $pkg"
        return 1
    fi

    # Mark as visited (append to pipe-separated list)
    VISITED_DEPS="${VISITED_DEPS}${pkg}|"

    deps=$(get_pkg_field "$pkg" dependencies)
    [ -z "$deps" ] && return 0

    IFS=',' read -ra DEPLIST <<<"$deps"
    for dep in "${DEPLIST[@]}"; do
        dep=$(echo "$dep" | xargs) # trim whitespace
        [ -z "$dep" ] && continue
        parse_dep_spec "$dep"
        if ! dep_satisfied "$DEP_NAME" "$DEP_OP" "$DEP_VER"; then
            if [ -n "$DEP_OP" ]; then
                # Verify repo version can satisfy the constraint
                local avail
                avail=$(get_pkg_field "$DEP_NAME" version)
                [ -z "$avail" ] && {
                    log_error "Dependency '$DEP_NAME' not found in database"
                    return 1
                }
                case "$DEP_OP" in
                '>=') version_gte "$avail" "$DEP_VER" || {
                    log_error "No version of '$DEP_NAME' satisfies >=$DEP_VER (available: $avail)"
                    return 1
                } ;;
                '=') [ "$avail" = "$DEP_VER" ] || {
                    log_error "No version of '$DEP_NAME' satisfies =$DEP_VER (available: $avail)"
                    return 1
                } ;;
                esac
            fi
            log_info "Resolving dependency: $DEP_NAME"
            echo "$DEP_NAME"
            resolve_deps "$DEP_NAME" || return 1
        else
            log_verbose "Dependency $DEP_NAME already satisfied"
        fi
    done
}

# Topological sort for install order
install_order() {
    local pkgs="$*"
    local order=()
    local pkg
    VISITED_DEPS="|" # Reset circular dependency tracking (pipe-separated list, starts with |)

    for pkg in $pkgs; do
        if ! is_installed "$pkg"; then
            local deps
            if ! deps=$(resolve_deps "$pkg"); then
                die "Cannot resolve dependencies for $pkg (circular detected)"
            fi
            # Membership checks must not rely on the exit status of an
            # inverted pipeline: on bash >= 4.4 an empty order array
            # made "${order[@]}" expand to nothing, awk exited 0 and
            # `install` silently installed nothing (CI-only failure;
            # macOS bash 3.2 masked it with a set -u error instead).
            local d
            for d in $deps; do
                if ! printf '%s\n' "${order[@]:-}" | grep -qxF "$d"; then
                    order+=("$d")
                fi
            done
            if ! printf '%s\n' "${order[@]:-}" | grep -qxF "$pkg"; then
                order+=("$pkg")
            fi
        fi
    done
    [ "${#order[@]}" -eq 0 ] || printf '%s\n' "${order[@]}"
}

# ======================================================================
# Package fetching (local + HTTP repos)
# ======================================================================
fetch_package() {
    local pkg_name="$1" pkg_version="$2"
    local fname="${pkg_name}-${pkg_version}.tar.xz"

    # 1. Local repo
    if [ -f "$REPO_LOCAL_PATH/$fname" ]; then
        echo "$REPO_LOCAL_PATH/$fname"
        return 0
    fi

    # 2. Remote HTTP(S) repos
    local url
    for url in "${REPO_REMOTE_URLS[@]}"; do
        log_info "Fetching $fname from $url"
        if curl -fsSL --connect-timeout 15 -o "$REPO_LOCAL_PATH/$fname.part" "$url/$fname" 2>/dev/null; then
            mv "$REPO_LOCAL_PATH/$fname.part" "$REPO_LOCAL_PATH/$fname"
            # Fetch detached signature if signature verification enabled
            if $VERIFY_SIGNATURES; then
                curl -fsSL --connect-timeout 15 -o "$REPO_LOCAL_PATH/$fname.sig" "$url/$fname.sig" 2>/dev/null ||
                    log_warn "No signature available for $fname"
            fi
            echo "$REPO_LOCAL_PATH/$fname"
            return 0
        fi
        rm -f "$REPO_LOCAL_PATH/$fname.part"
    done

    return 1
}

# GPG signature verification
verify_signature() {
    local pkg_file="$1"
    local sig_file="${pkg_file}.sig"

    command -v gpg >/dev/null 2>&1 || die "gpg not found but VERIFY_SIGNATURES=true"
    [ -f "$sig_file" ] || die "Signature file missing: $sig_file"
    [ -f "$GPG_KEYRING" ] || die "Trusted keyring not found: $GPG_KEYRING"

    if gpg --no-default-keyring --keyring "$GPG_KEYRING" --verify "$sig_file" "$pkg_file" >/dev/null 2>&1; then
        log_verbose "GPG signature verified for $(basename "$pkg_file")"
        return 0
    fi
    die "GPG signature verification FAILED for $(basename "$pkg_file")"
}

# ======================================================================
# Package installation (transactional with rollback)
# ======================================================================
install_package() {
    local pkg_input="$1"
    local pkg_name pkg_version pkg_file

    # Parse package name and version more robustly
    # Support formats: name, name-version (where version starts with digit)
    # Allow hyphens in package names (e.g. lib-foo-1.0)
    if [[ $pkg_input =~ ^([a-zA-Z0-9._+-]+)-([0-9].*)$ ]]; then
        pkg_name="${BASH_REMATCH[1]}"
        pkg_version="${BASH_REMATCH[2]}"
    else
        pkg_name="$pkg_input"
        pkg_version=$(get_pkg_field "$pkg_name" version)
    fi

    [ -z "$pkg_name" ] && die "Usage: lpm install <package>"
    [ -z "$pkg_version" ] && die "Package '$pkg_name' not found in database (run: lpm update-db)"

    if is_installed "$pkg_name"; then
        if $FORCE; then
            log_warn "Package '$pkg_name' already installed, reinstalling (--force)"
            remove_package "$pkg_name" --keep-files
        else
            log_warn "Package '$pkg_name' is already installed. Use --force to reinstall."
            return 0
        fi
    fi

    # Locate/fetch package file
    if ! pkg_file=$(fetch_package "$pkg_name" "$pkg_version"); then
        die "Package file not found: ${pkg_name}-${pkg_version}.tar.xz (local + remote repos)"
    fi

    log_info "Installing $pkg_name-$pkg_version"

    # GPG signature verification (authenticity)
    if $VERIFY_SIGNATURES; then
        verify_signature "$pkg_file"
    fi

    # Checksum verification (integrity)
    if $VERIFY_CHECKSUMS; then
        local expected_checksum actual_checksum
        expected_checksum=$(get_pkg_field "$pkg_name" checksum)
        if [ -n "$expected_checksum" ]; then
            if [[ $expected_checksum =~ ^[0-9a-f]{64}$ ]]; then
                # Real sha256 - verify it
                actual_checksum=$(sha256_of "$pkg_file")
                if [ "$expected_checksum" != "$actual_checksum" ]; then
                    die "Checksum mismatch for $pkg_name-$pkg_version"
                fi
                log_verbose "Checksum verified: $expected_checksum"
            else
                # Placeholder checksum (sha256-dummy, base-<hash>, ...):
                # integrity verification is not possible, never compare
                # it against the real file hash (Nightly audit fix).
                if [ "$ALLOW_DUMMY_CHECKSUMS" = "true" ]; then
                    log_warn "Package $pkg_name has a placeholder checksum (no integrity verification)"
                else
                    log_verbose "Package $pkg_name has a placeholder checksum; skipping verification"
                fi
            fi
        fi
    fi

    local pkg_dir="$LPM_DB/$pkg_name-$pkg_version"
    rm -rf "$pkg_dir"
    mkdir -p "$pkg_dir"
    # Package archives are laid out as "<name>-<version>/{files,hooks}" (see docs);
    # strip that leading directory so files land directly under $pkg_dir.
    tar -xf "$pkg_file" -C "$pkg_dir" --no-same-owner --strip-components=1

    # Pre-install hook
    if [ -x "$pkg_dir/pre-install.sh" ]; then
        log_info "Running pre-install script"
        (cd "$pkg_dir" && bash pre-install.sh) || die "Pre-install script failed"
    fi

    # ------------------------------------------------------------------
    # Transactional file installation with rollback
    # ------------------------------------------------------------------
    if [ -d "$pkg_dir/files" ]; then
        local backup_dir="$LPM_DB/.txn-$pkg_name-$pkg_version"
        local -a installed_files=()
        rm -rf "$backup_dir"
        mkdir -p "$backup_dir"

        rollback_install() {
            log_error "Installation failed - rolling back $pkg_name-$pkg_version"
            local rf
            for rf in "${installed_files[@]}"; do
                if [ -f "$backup_dir/$rf" ] || [ -L "$backup_dir/$rf" ]; then
                    mkdir -p "$(dirname "${LPM_ROOT%/}/$rf")"
                    cp -a "$backup_dir/$rf" "${LPM_ROOT%/}/$rf" 2>/dev/null || true
                else
                    rm -f "${LPM_ROOT%/}/$rf" 2>/dev/null || true
                fi
                escaped_rf=$(escape_regex "/$rf")
                sed_inplace "/^${escaped_rf} ${pkg_name}-${pkg_version}$/d" "$file_index" 2>/dev/null || true
            done
            rm -rf "$backup_dir" "$pkg_dir"
            die "Rolled back $pkg_name-$pkg_version (system unchanged)"
        }

        local f src dest
        while IFS= read -r f; do
            f="${f#./}"
            [ -z "$f" ] && continue
            src="$pkg_dir/files/$f"
            dest="${LPM_ROOT%/}/$f"

            # Backup existing file for rollback
            if [ -e "$dest" ] || [ -L "$dest" ]; then
                mkdir -p "$(dirname "$backup_dir/$f")"
                cp -a "$dest" "$backup_dir/$f" 2>/dev/null || true
            fi

            mkdir -p "$(dirname "$dest")"
            if ! cp -a "$src" "$dest"; then
                installed_files+=("$f")
                rollback_install
            fi
            installed_files+=("$f")
            echo "/$f $pkg_name-$pkg_version" >>"$file_index"
        done < <(cd "$pkg_dir/files" && find . \( -type f -o -type l \) | sed 's|^\./||')

        rm -rf "$backup_dir"
    fi

    # Post-install hook
    if [ -x "$pkg_dir/post-install.sh" ]; then
        log_info "Running post-install script"
        (cd "$pkg_dir" && bash post-install.sh) || log_warn "Post-install script returned non-zero"
    fi

    # Record installation
    escaped_name=$(escape_regex "$pkg_name")
    if grep -qF "$pkg_name " "$installed_file"; then
        sed_inplace "/^${escaped_name} /d" "$installed_file"
    fi
    echo "$pkg_name $pkg_version" >>"$installed_file"
    echo "$(timestamp) - Installed $pkg_name-$pkg_version" >>"$LPM_LOGS/install.log"
    record_history "$HISTORY_ACTION" "$pkg_name" "$pkg_version"
    HISTORY_ACTION="install"
    log_success "Package '$pkg_name-$pkg_version' installed"
}

# ======================================================================
# Package removal
# ======================================================================
remove_package() {
    local pkg_name=""
    local keep_files=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --keep-files)
            keep_files=true
            shift
            ;;
        *)
            pkg_name="$1"
            shift
            ;;
        esac
    done

    [ -z "$pkg_name" ] && die "Usage: lpm remove <package>"

    if ! is_installed "$pkg_name"; then
        log_warn "Package '$pkg_name' not installed"
        return 0
    fi

    local installed_ver
    installed_ver=$(installed_version "$pkg_name")
    local pkg_dir="$LPM_DB/$pkg_name-$installed_ver"

    if [ ! -d "$pkg_dir" ]; then
        log_warn "Package directory not found, attempting removal anyway"
    else
        # Pre-remove hook
        if [ -x "$pkg_dir/pre-remove.sh" ]; then
            log_info "Running pre-remove script"
            (cd "$pkg_dir" && bash pre-remove.sh) || log_warn "Pre-remove script returned non-zero"
        fi

        if ! $keep_files && [ -d "$pkg_dir/files" ]; then
            log_info "Removing installed files (if not owned by other packages)"
            local f owners owner_count total_count escaped_f
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                owners=$(grep -F "$f " "$file_index" 2>/dev/null | awk '{print $2}' || true)
                # Only remove if this package is the sole owner (use awk for efficient counting)
                if [ -n "$owners" ]; then
                    owner_count=$(echo "$owners" | awk -v pkg="$pkg_name-$installed_ver" '$0 == pkg { count++ } END { print count+0 }')
                    total_count=$(echo "$owners" | awk 'END { print NR }')
                    if [ "$owner_count" -eq "$total_count" ]; then
                        rm -f "${LPM_ROOT%/}$f" 2>/dev/null || log_warn "Failed to remove ${LPM_ROOT%/}$f"
                        escaped_f=$(escape_regex "$f")
                        sed_inplace "/^${escaped_f} ${pkg_name}-${installed_ver}$/d" "$file_index"
                    else
                        log_verbose "File $f is shared, not removing"
                    fi
                fi
            done < <(cd "$pkg_dir/files" && find . \( -type f -o -type l \) | sed 's/^\.//')
        fi

        # Post-remove hook
        if [ -x "$pkg_dir/post-remove.sh" ]; then
            log_info "Running post-remove script"
            (cd "$pkg_dir" && bash post-remove.sh) || log_warn "Post-remove script returned non-zero"
        fi
    fi

    escaped_name=$(escape_regex "$pkg_name")
    sed_inplace "/^${escaped_name} /d" "$installed_file"
    # Also remove from kernel dependency registry
    unregister_kernel_dep "$pkg_name"
    echo "$(timestamp) - Removed $pkg_name-$installed_ver" >>"$LPM_LOGS/remove.log"
    record_history "remove" "$pkg_name" "$installed_ver"
    log_success "Package '$pkg_name' removed"
}

# ======================================================================
# Update (reinstall) a single package — atomic via transactional install
# ======================================================================
update_package() {
    local pkg="$1"
    [ -z "$pkg" ] && die "Usage: lpm update <package>"
    # Transactional install with FORCE: old files stay in place until the
    # new version's files are copied (with rollback on failure).
    local old_force=$FORCE
    FORCE=true
    HISTORY_ACTION="upgrade"
    install_package "$pkg"
    FORCE=$old_force
}

# Reinstall an already-installed package at the DB version (forced re-fetch)
reinstall_package() {
    local pkg="$1"
    [ -z "$pkg" ] && die "Usage: lpm reinstall <package>"
    if ! is_installed "$pkg"; then
        die "Package '$pkg' is not installed (use: lpm install $pkg)"
    fi
    HISTORY_ACTION="reinstall"
    update_package "$pkg"
}

# ======================================================================
# Upgrade all installed packages that have newer versions
# ======================================================================

# List installed packages that have a newer version in the database.
# Prints "name installed-version available-version" lines; shared by
# the upgradable and upgrade commands.
list_upgradable() {
    [ -s "$installed_file" ] || return 0
    local line name version latest
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        name=$(echo "$line" | awk '{print $1}')
        version=$(echo "$line" | awk '{print $2}')
        latest=$(get_pkg_field "$name" version)
        if [ -n "$latest" ] && [ "$version" != "$latest" ]; then
            printf '%s %s %s\n' "$name" "$version" "$latest"
        fi
    done <"$installed_file"
}

show_upgradable() {
    local -a lines=()
    local name old new
    while read -r name old new; do
        [ -z "$name" ] && continue
        if is_held "$name"; then
            printf '  %-20s %-10s -> %-10s (held)\n' "$name" "$old" "$new"
        else
            printf '  %-20s %-10s -> %s\n' "$name" "$old" "$new"
        fi
        lines+=("$name")
    done <<<"$(list_upgradable)"
    if [ ${#lines[@]} -eq 0 ]; then
        log_info "All packages are up to date."
    fi
}

upgrade_all() {
    log_info "Checking for upgradable packages..."

    # Build list of upgradable packages (held packages are skipped)
    local -a to_upgrade=()
    local name version latest
    while read -r name version latest; do
        [ -z "$name" ] && continue
        if is_held "$name"; then
            log_warn "Skipping held package: $name ($version -> $latest)"
            continue
        fi
        echo "  $name $version -> $latest"
        to_upgrade+=("$name")
    done <<<"$(list_upgradable)"

    if [ ${#to_upgrade[@]} -eq 0 ]; then
        log_info "All packages are up to date."
        return 0
    fi

    if $DRY_RUN; then
        log_info "Dry run complete, no changes made."
        return 0
    fi

    log_info "Upgrading ${#to_upgrade[@]} package(s)..."
    local pkg
    for pkg in "${to_upgrade[@]}"; do
        update_package "$pkg"
    done
}

# ======================================================================
# Reverse dependencies (lpm why)
# ======================================================================
why_package() {
    local pkg="$1"
    [ -z "$pkg" ] && die "Usage: lpm why <package>"
    echo -e "$(_apply_color "${C_BLUE}")Packages depending on '$pkg':$(_apply_color "${C_NC}")"
    local found=false
    local name deps dep
    while IFS='|' read -r name _ver _desc deps _chk; do
        [ -z "$name" ] && [ -z "$deps" ] && continue
        [ "$name" = "$pkg" ] && continue
        [ -z "$deps" ] && continue
        local dep_list
        IFS=',' read -ra dep_list <<<"$deps"
        for dep in "${dep_list[@]}"; do
            dep=$(echo "$dep" | tr -d '[:space:]')
            [ -z "$dep" ] && continue
            parse_dep_spec "$dep"
            if [ "$DEP_NAME" = "$pkg" ]; then
                local status=""
                if is_installed "$name"; then
                    status=" [installed]"
                fi
                printf "  %-20s (%s)%s\n" "$name" "$dep" "$status"
                found=true
                break
            fi
        done
    done <"$db_file"
    $found || echo "  No known dependents (not required by any package in the database)"
}

# ======================================================================
# Orphan removal (lpm autoremove)
# ======================================================================
autoremove_orphans() {
    local base_list
    base_list=$(root_path "/usr/share/lpm/base-packages.list")

    if [ ! -s "$installed_file" ]; then
        log_info "No packages installed"
        return 0
    fi

    # Every dependency required by an installed package (names only).
    local required
    required=$(
        while read -r name _ver; do
            [ -z "$name" ] && continue
            get_pkg_field "$name" dependencies
        done <"$installed_file" | tr ',' '\n' | sed -e 's/>=.*//' -e 's/=.*//' | sort -u
    )

    local -a orphans=()
    local name
    while read -r name _ver; do
        [ -z "$name" ] && continue
        if is_held "$name"; then
            log_verbose "Keeping held package: $name"
            continue
        fi
        # Base packages are part of the core system: never auto-remove.
        if [ -s "$base_list" ] &&
            awk -F'|' -v n="$name" '$1 == n { found=1; exit } END { exit !found }' "$base_list" 2>/dev/null; then
            continue
        fi
        # Keep packages another installed package depends on.
        if printf '%s\n' "$required" | awk -v n="$name" '$0 == n { found=1; exit } END { exit !found }'; then
            continue
        fi
        orphans+=("$name")
    done <"$installed_file"

    if [ ${#orphans[@]} -eq 0 ]; then
        log_info "No orphan packages to remove."
        return 0
    fi

    echo -e "$(_apply_color "${C_BLUE}")Orphan packages (not in the base set, not required):$(_apply_color "${C_NC}")"
    local o
    for o in "${orphans[@]}"; do
        echo "  $o $(installed_version "$o")"
    done

    if $DRY_RUN; then
        log_info "Dry run complete, no changes made."
        return 0
    fi

    for o in "${orphans[@]}"; do
        remove_package "$o"
    done
}

# ======================================================================
# Information and listing
# ======================================================================
list_packages() {
    if [ ! -s "$installed_file" ]; then
        log_info "No packages installed"
        return
    fi
    echo -e "$(_apply_color "${C_BLUE}")Installed packages:$(_apply_color "${C_NC}")"
    sort "$installed_file" | while read -r name ver; do
        local desc
        desc=$(get_pkg_field "$name" description)
        printf "  %-20s %-10s %s\n" "$name" "$ver" "${desc:-}"
    done
}

search_package() {
    local pattern="$1"
    [ -z "$pattern" ] && die "Usage: lpm search <pattern>"
    echo -e "$(_apply_color "${C_BLUE}")Search results for '$pattern':$(_apply_color "${C_NC}")"
    # Use fixed-string matching (-F) so regex metacharacters (., *, [, etc.)
    # in the pattern are treated literally and cannot alter the search.
    grep -iF "$pattern" "$db_file" 2>/dev/null | while IFS='|' read -r name ver desc deps _chk; do
        printf "  %-20s %-10s %s\n" "$name" "$ver" "${desc:-}"
    done || echo "  No matches found"
}

show_info() {
    local pkg="$1"
    [ -z "$pkg" ] && die "Usage: lpm info <package>"
    if ! grep -qF "${pkg}|" "$db_file" 2>/dev/null; then
        die "Package '$pkg' not found in database"
    fi
    echo -e "$(_apply_color "${C_BLUE}")Package:$(_apply_color "${C_NC}") $pkg"
    echo -e "$(_apply_color "${C_BLUE}")Version:$(_apply_color "${C_NC}") $(get_pkg_field "$pkg" version)"
    echo -e "$(_apply_color "${C_BLUE}")Description:$(_apply_color "${C_NC}") $(get_pkg_field "$pkg" description)"
    local deps
    deps=$(get_pkg_field "$pkg" dependencies)
    echo -e "$(_apply_color "${C_BLUE}")Dependencies:$(_apply_color "${C_NC}") ${deps:-none}"
    if is_installed "$pkg"; then
        echo -e "$(_apply_color "${C_BLUE}")Status:$(_apply_color "${C_NC}") installed ($(installed_version "$pkg"))"
        # Show kernel dependency info if registered
        if [ -s "$kernel_deps_file" ]; then
            local kdep_line
            kdep_line=$(awk -F'|' -v p="$pkg" '$1 == p { print; exit }' "$kernel_deps_file" 2>/dev/null || true)
            if [ -n "$kdep_line" ]; then
                local kver ktype
                kver=$(echo "$kdep_line" | cut -d'|' -f2)
                ktype=$(echo "$kdep_line" | cut -d'|' -f3)
                local cur_kernel
                cur_kernel=$(get_installed_kernel_version)
                local kstatus
                if [ "$kver" = "$cur_kernel" ]; then
                    kstatus="matched"
                else
                    kstatus="STALE (needs rebuild)"
                fi
                echo -e "$(_apply_color "${C_BLUE}")Kernel dep:$(_apply_color "${C_NC}") $ktype (built for $kver, $kstatus)"
            fi
        fi
    else
        echo -e "$(_apply_color "${C_BLUE}")Status:$(_apply_color "${C_NC}") not installed"
    fi
}

# ======================================================================
# Integrity verification of installed packages
# Compares files currently on disk against the pristine copies retained
# in the package database ($LPM_DB/<pkg>-<ver>/files). Detects files that
# were modified or removed after installation.
# ======================================================================
verify_package() {
    local target="$1"
    local -a pkgs=()

    if [ -n "$target" ]; then
        if ! is_installed "$target"; then
            die "Package '$target' is not installed"
        fi
        pkgs=("$target")
    else
        local _name _ver
        while read -r _name _ver; do
            [ -z "$_name" ] && continue
            pkgs+=("$_name")
        done <"$installed_file"
    fi

    if [ ${#pkgs[@]} -eq 0 ]; then
        log_info "No packages installed to verify"
        return 0
    fi

    local total_ok=0 total_modified=0 total_missing=0 pkg
    for pkg in "${pkgs[@]}"; do
        local ver pkg_dir
        ver=$(installed_version "$pkg")
        pkg_dir="$LPM_DB/$pkg-$ver"

        if [ ! -d "$pkg_dir/files" ]; then
            log_verbose "No file manifest for $pkg-$ver; skipping"
            continue
        fi

        local ok=0 modified=0 missing=0 f ref dest
        while IFS= read -r f; do
            f="${f#./}"
            [ -z "$f" ] && continue
            ref="$pkg_dir/files/$f"
            dest="${LPM_ROOT%/}/$f"

            if [ -L "$ref" ]; then
                if [ ! -L "$dest" ]; then
                    log_warn "MISSING  $dest (symlink)"
                    missing=$((missing + 1))
                    continue
                fi
                if [ "$(readlink "$ref")" != "$(readlink "$dest")" ]; then
                    log_warn "MODIFIED $dest (symlink target)"
                    modified=$((modified + 1))
                    continue
                fi
                ok=$((ok + 1))
            elif [ -f "$ref" ]; then
                if [ ! -f "$dest" ]; then
                    log_warn "MISSING  $dest"
                    missing=$((missing + 1))
                    continue
                fi
                if [ "$(sha256_of "$ref")" != "$(sha256_of "$dest")" ]; then
                    log_warn "MODIFIED $dest"
                    modified=$((modified + 1))
                    continue
                fi
                ok=$((ok + 1))
            fi
        done < <(cd "$pkg_dir/files" && find . \( -type f -o -type l \) | sed 's|^\./||')

        if [ "$modified" -eq 0 ] && [ "$missing" -eq 0 ]; then
            log_success "$pkg-$ver: OK ($ok files verified)"
        else
            log_error "$pkg-$ver: $ok OK, $modified modified, $missing missing"
        fi
        total_ok=$((total_ok + ok))
        total_modified=$((total_modified + modified))
        total_missing=$((total_missing + missing))
    done

    log_info "Verification complete: $total_ok OK, $total_modified modified, $total_missing missing"
    if [ "$total_modified" -gt 0 ] || [ "$total_missing" -gt 0 ]; then
        return 1
    fi
    return 0
}

# ======================================================================
# Database update (sync with repositories)
# ======================================================================
update_db() {
    log_info "Updating package database..."

    # Sync from remote repositories if configured
    if [ ${#REPO_REMOTE_URLS[@]} -gt 0 ]; then
        local url tmp_db merged=false
        tmp_db=$(mktemp)
        for url in "${REPO_REMOTE_URLS[@]}"; do
            log_info "Syncing package list from $url"
            local tmp_index tmp_sig
            tmp_index=$(mktemp)
            tmp_sig=$(mktemp)
            if curl -fsSL --connect-timeout 15 -o "$tmp_index" "$url/packages.list" 2>/dev/null; then
                # Verify signed index if signature verification is enabled
                if $VERIFY_SIGNATURES; then
                    if curl -fsSL --connect-timeout 15 -o "$tmp_sig" "$url/packages.list.sig" 2>/dev/null; then
                        if gpg --no-default-keyring --keyring "$GPG_KEYRING" \
                               --verify "$tmp_sig" "$tmp_index" >/dev/null 2>&1; then
                            log_info "Repository index signature verified for $url"
                            cat "$tmp_index" >> "$tmp_db"
                            merged=true
                        else
                            log_error "Signature verification FAILED for $url/packages.list – skipping"
                        fi
                    else
                        log_warn "No signature for $url/packages.list – skipping (VERIFY_SIGNATURES=true)"
                    fi
                else
                    cat "$tmp_index" >> "$tmp_db"
                    merged=true
                fi
            else
                log_warn "Failed to sync from $url"
            fi
            rm -f "$tmp_index" "$tmp_sig"
        done
        if $merged; then
            # Deduplicate by package name (first occurrence wins = repo priority order)
            awk -F'|' '!seen[$1]++' "$tmp_db" >"$db_file"
            rm -f "$tmp_db"
            log_success "Database updated ($(wc -l <"$db_file") packages)"
            return 0
        fi
        rm -f "$tmp_db"
        # Honesty over convenience: never overwrite a working database
        # with sample data just because the network failed.
        if [ -s "$db_file" ]; then
            log_warn "All remote syncs failed; keeping the existing local database"
        else
            log_warn "All remote syncs failed and no local database exists"
        fi
        return 0
    fi

    # No remote repositories configured: keep whatever is already there.
    if [ -s "$db_file" ]; then
        log_info "Database unchanged (no remote repositories configured)"
        return 0
    fi

    # Empty database and no remotes: seed minimal sample data so the
    # commands have something to show. A real deployment should point
    # /etc/lpm/repos.d at a published manifest instead.
    cat >"$db_file" <<'EOF'
bash|5.3|Bourne Again Shell|readline|sha256-dummy
coreutils|9.4|GNU core utilities|glibc|sha256-dummy
gcc|15.2.0|GNU Compiler Collection|glibc,binutils|sha256-dummy
glibc|2.43|GNU C Library|linux-headers|sha256-dummy
binutils|2.46.0|GNU Binary Utilities|glibc|sha256-dummy
readline|8.2|GNU Readline|ncurses|sha256-dummy
ncurses|6.4|Terminal control library||sha256-dummy
openssl|3.6.1|OpenSSL library|glibc|sha256-dummy
curl|8.5.0|Command line URL fetcher|openssl,glibc|sha256-dummy
linux|6.16.1|Linux kernel||sha256-dummy
EOF
    log_warn "Database seeded with SAMPLE data; configure /etc/lpm/repos.d for a real repository"
}

# ======================================================================
# Cleanup old package files
# ======================================================================
clean_cache() {
    log_info "Cleaning package cache..."
    rm -rf "$LPM_PACKAGES_DIR"/*.tar.xz
    log_success "Cache cleaned"
}

# ======================================================================
# SOURCE-BASED BUILD SYSTEM
# ======================================================================

# Download or copy source archive
fetch_source() {
    local src="$1"
    local dest
    dest="$LPM_BUILD_DIR/sources/$(basename "$src")"
    mkdir -p "$LPM_BUILD_DIR/sources"
    if [[ $src =~ ^https?:// ]]; then
        log_info "Downloading source: $src"
        if ! curl -fsSL --connect-timeout 30 -o "$dest" "$src"; then
            die "Failed to download $src"
        fi
    elif [ -f "$src" ]; then
        cp -f "$src" "$dest"
    else
        die "Source not found: $src"
    fi
    echo "$dest"
}

# Extract archive (tar.xz, tar.gz, tar.bz2, etc.)
extract_source() {
    local archive="$1"
    local destdir="$2"
    mkdir -p "$destdir"
    tar -xf "$archive" -C "$destdir" --strip-components=1 2>/dev/null || tar -xf "$archive" -C "$destdir"
    # Return the actual directory (the one containing the files)
    find "$destdir" -maxdepth 1 -mindepth 1 -type d | head -1
}

# Determine build system and create a build script dynamically
detect_build_system() {
    local srcdir="$1"
    if [ -f "$srcdir/configure" ]; then
        echo "autotools"
    elif [ -f "$srcdir/meson.build" ]; then
        echo "meson"
    elif [ -f "$srcdir/CMakeLists.txt" ]; then
        echo "cmake"
    else
        echo "generic"
    fi
}

# Execute build following a recipe if provided, else auto-detect
run_build() {
    local srcdir="$1"
    local pkg_name="$2"
    local pkg_version="$3"
    local staging="$LPM_BUILD_DIR/pkg/${pkg_name}-${pkg_version}/files"
    local recipe="$4" # optional recipe file

    # If recipe provided, source it and run build()
    if [ -n "$recipe" ] && [ -f "$recipe" ]; then
        log_info "Using build recipe: $recipe"
        # shellcheck disable=SC1090
        source "$recipe"
        if declare -f build >/dev/null 2>&1; then
            # Expose build context to the recipe:
            #   PKG  - staging directory; recipes should `make DESTDIR="$PKG" install`
            #          so the result is packaged and tracked by LPM.
            #   SRC  - extracted source directory (== cwd when build() runs).
            #   JOBS - number of parallel jobs (recipes may use `make -j"$JOBS"`).
            # Toolchain/temporary phase recipes that install directly into $LFS may
            # ignore PKG; their package archive will simply be empty.
            mkdir -p "$staging"
            export PKG="$staging"
            export SRC="$srcdir"
            export JOBS="$BUILD_JOBS"
            cd "$srcdir"
            build
        else
            die "Recipe does not define a build() function"
        fi
        return
    fi

    # Auto-detect build system
    local system
    system=$(detect_build_system "$srcdir")
    log_info "Detected build system: $system"
    mkdir -p "$staging"
    cd "$srcdir"

    case "$system" in
    autotools)
        ./configure --prefix=/usr \
            --sysconfdir=/etc \
            --localstatedir=/var \
            ${BUILD_CFLAGS:+"CFLAGS=$BUILD_CFLAGS"} \
            ${BUILD_CXXFLAGS:+"CXXFLAGS=$BUILD_CXXFLAGS"}
        make -j"$BUILD_JOBS"
        make install DESTDIR="$staging"
        ;;
    meson)
        meson setup builddir --prefix=/usr
        ninja -C builddir
        DESTDIR="$staging" ninja -C builddir install
        ;;
    cmake)
        cmake -B builddir -DCMAKE_INSTALL_PREFIX=/usr
        cmake --build builddir -j"$BUILD_JOBS"
        DESTDIR="$staging" cmake --install builddir
        ;;
    generic)
        # Default: try configure, then fallback to make
        if [ -f ./configure ]; then
            ./configure --prefix=/usr
            make -j"$BUILD_JOBS"
            make install DESTDIR="$staging"
        elif [ -f ./Makefile ]; then
            make -j"$BUILD_JOBS"
            make install DESTDIR="$staging"
        else
            die "Unable to determine build method. Provide a recipe with --recipe."
        fi
        ;;
    esac
    cd "$OLDPWD"
}

# Assemble LPM package archive from staged files
assemble_package() {
    local pkg_name="$1"
    local pkg_version="$2"
    local staging="$LPM_BUILD_DIR/pkg/${pkg_name}-${pkg_version}/files"
    local pkg_dir="$LPM_BUILD_DIR/pkg/${pkg_name}-${pkg_version}"
    local archive_name="${pkg_name}-${pkg_version}.tar.xz"
    local dest_archive="$REPO_LOCAL_PATH/$archive_name"

    log_info "Assembling package $pkg_name-$pkg_version"

    # Create the package directory structure
    mkdir -p "$pkg_dir/files"
    # Move staged files into the package files/ directory (if not already there)
    if [ "$staging" != "$pkg_dir/files" ]; then
        rm -rf "$pkg_dir/files"
        mv "$staging" "$pkg_dir/files"
    fi

    # Add optional hooks (could be empty, but we keep the structure)
    [ -x "$pkg_dir/pre-install.sh" ] || touch "$pkg_dir/pre-install.sh"
    [ -x "$pkg_dir/post-install.sh" ] || touch "$pkg_dir/post-install.sh"
    [ -x "$pkg_dir/pre-remove.sh" ] || touch "$pkg_dir/pre-remove.sh"
    [ -x "$pkg_dir/post-remove.sh" ] || touch "$pkg_dir/post-remove.sh"

    # Create archive
    cd "$LPM_BUILD_DIR/pkg"
    tar -Jcf "$dest_archive" "${pkg_name}-${pkg_version}"
    log_success "Package archive created: $dest_archive"
    echo "$dest_archive"
}

# Register the package in the database
register_package() {
    local pkg_name="$1"
    local pkg_version="$2"
    local description="$3"
    local dependencies="$4"
    local archive="$5"
    local checksum
    checksum=$(sha256_of "$archive")
    # Remove existing entry if present
    sed_inplace "/^${pkg_name}|/d" "$db_file"
    echo "${pkg_name}|${pkg_version}|${description}|${dependencies}|${checksum}" >>"$db_file"
    log_success "Package $pkg_name-$pkg_version registered in database"
}

# Main build command
build_package() {
    local src=""
    local recipe=""
    local install_after_build=true
    local description=""
    local dependencies=""
    local kernel_dep=""

    # Parse build-specific options
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --recipe)
            recipe="$2"
            shift 2
            ;;
        --no-install)
            install_after_build=false
            shift
            ;;
        --desc | --description)
            description="$2"
            shift 2
            ;;
        --deps | --dependencies)
            dependencies="$2"
            shift 2
            ;;
        -*)
            die "Unknown build option: $1"
            ;;
        *)
            if [ -z "$src" ]; then
                src="$1"
                shift
            else
                die "Too many arguments: $1"
            fi
            ;;
        esac
    done

    [ -z "$src" ] && die "Usage: lpm build <source.tar.xz|URL|.lpm recipe> [--recipe <recipe>] [--no-install] [--desc ...] [--deps ...]"

    # Detect if argument is a recipe file (ending in .lpm)
    if [ -z "$recipe" ] && [[ $src == *.lpm ]]; then
        recipe="$src"
        # Source the recipe to get name, version, source, etc.
        # shellcheck disable=SC1090
        source "$recipe"
        [ -n "${name:-}" ] || die "Recipe missing 'name'"
        [ -n "${version:-}" ] || die "Recipe missing 'version'"
        src="${source:-${name}-${version}.tar.xz}"
        # description and dependencies from recipe if not overridden
        description="${description:-${desc:-}}"
        dependencies="${dependencies:-${deps:-}}"
        kernel_dep="${kernel_dep:-}"
    fi

    # If recipe not yet set, try to infer name/version from src filename
    if [ -z "$recipe" ]; then
        local base
        base=$(basename "$src")
        # Remove common extensions
        base="${base%.tar.*}"
        base="${base%.tgz}"
        base="${base%.tar}"
        # Parse name-version (last dash before digit? heuristic)
        if [[ $base =~ ^(.+)-([0-9].*)$ ]]; then
            pkg_name="${BASH_REMATCH[1]}"
            pkg_version="${BASH_REMATCH[2]}"
        else
            pkg_name="$base"
            pkg_version="unknown"
        fi
    else
        pkg_name="${name}"
        pkg_version="${version}"
    fi

    [ -z "$pkg_name" ] && die "Could not determine package name"
    [ -z "$pkg_version" ] && die "Could not determine package version"

    # Resolve build dependencies? For now, we just ensure runtime dependencies are installed.
    # The user can pre-install them manually or via recipe deps.
    if [ -n "$dependencies" ]; then
        log_info "Ensuring dependencies: $dependencies"
        local deps_order
        # shellcheck disable=SC2086  # intentional word split of the dep list
        deps_order=$(install_order $dependencies)
        if [ -n "$deps_order" ]; then
            while IFS= read -r dep; do
                [ -z "$dep" ] && continue
                if ! is_installed "$dep"; then
                    log_info "Installing missing dependency: $dep"
                    install_package "$dep"
                fi
            done <<<"$deps_order"
        fi
    fi

    # Fetch and extract source
    local archive_path
    archive_path=$(fetch_source "$src")
    local srcdir="$LPM_BUILD_DIR/src/${pkg_name}-${pkg_version}"
    rm -rf "$srcdir"
    mkdir -p "$srcdir"
    extract_source "$archive_path" "$srcdir" >/dev/null

    # Build
    log_info "Building $pkg_name-$pkg_version"
    run_build "$srcdir" "$pkg_name" "$pkg_version" "$recipe"

    # Assemble
    local pkg_archive
    pkg_archive=$(assemble_package "$pkg_name" "$pkg_version")

    # Register in database
    description="${description:-User built package}"
    dependencies="${dependencies:-}"
    register_package "$pkg_name" "$pkg_version" "$description" "$dependencies" "$pkg_archive"

    # Register kernel dependency if declared in recipe
    if [ -n "$kernel_dep" ]; then
        local kernel_ver
        kernel_ver=$(get_installed_kernel_version)
        register_kernel_dep "$pkg_name" "${kernel_ver:-unknown}" "$kernel_dep"
        log_info "Registered kernel dependency: $pkg_name (kernel=${kernel_ver:-unknown}, type=$kernel_dep)"
    fi

    # Optionally install
    if $install_after_build; then
        log_info "Installing newly built package: $pkg_name-$pkg_version"
        install_package "$pkg_name"
    else
        log_info "Package built but not installed (use lpm install $pkg_name)"
    fi

    # Cleanup build artifacts unless KEEP_BUILD_ARTIFACTS
    if ! $KEEP_BUILD_ARTIFACTS; then
        rm -rf "$srcdir" "$LPM_BUILD_DIR/pkg/${pkg_name}-${pkg_version}"
    fi
}

# =======================================================================
# Kernel dependency tracking
# =======================================================================
# Kernel deps registry format: pkg_name|kernel_version|dep_type
# dep_type: modules | headers | runtime
#
# Recipes can declare kernel dependency with:
#   kernel_dep="modules"   # installs kernel modules (e.g. kmod, nvidia)
#   kernel_dep="headers"   # compiled against kernel headers (e.g. virtualbox)
#   kernel_dep="runtime"   # needs compatible kernel (e.g. glibc --enable-kernel)
#
# When the kernel is upgraded, `lpm rebuild-kernel` detects which installed
# packages were built against the old kernel and rebuilds them.
# =======================================================================

# Register a package's kernel dependency
register_kernel_dep() {
    local pkg_name="$1" kernel_ver="$2" dep_type="$3"
    [ -z "$pkg_name" ] || [ -z "$dep_type" ] && return 1
    # Remove existing entry for this package
    sed_inplace "/^${pkg_name}|/d" "$kernel_deps_file"
    echo "${pkg_name}|${kernel_ver}|${dep_type}" >> "$kernel_deps_file"
    log_verbose "Registered kernel dependency: $pkg_name (kernel=$kernel_ver, type=$dep_type)"
}

# Remove a package from the kernel deps registry
unregister_kernel_dep() {
    local pkg_name="$1"
    [ -z "$pkg_name" ] && return
    sed_inplace "/^${pkg_name}|/d" "$kernel_deps_file"
}

# Get the running/installed kernel version
get_installed_kernel_version() {
    # Try uname -r first (running kernel), then fall back to /boot/vmlinuz symlink
    if command -v uname >/dev/null 2>&1; then
        uname -r 2>/dev/null && return
    fi
    # Fallback: parse vmlinuz symlink in /boot
    local vmlinuz
    vmlinuz=$(readlink -f "${LPM_ROOT%/}/boot/vmlinuz" 2>/dev/null || true)
    if [ -n "$vmlinuz" ]; then
        basename "$vmlinuz" | sed 's/^vmlinuz-//'
        return
    fi
    # Fallback: config file
    if [ -f "${LPM_ROOT%/}/etc/lfs-builder-params.env" ]; then
        grep -oP 'KERNEL_VERSION=\K[^\s]+' "${LPM_ROOT%/}/etc/lfs-builder-params.env" 2>/dev/null || true
    fi
}

# List all installed packages that depend on the kernel
list_kernel_deps() {
    local kernel_ver
    kernel_ver=$(get_installed_kernel_version)
    local show_all=false
    [ "${1:-}" = "--all" ] && show_all=true

    if [ ! -s "$kernel_deps_file" ]; then
        log_info "No kernel-dependent packages registered."
        log_info "Tip: recipes can declare kernel_dep=\"modules|headers|runtime\""
        return 0
    fi

    echo -e "$(_apply_color "${C_BLUE}")Kernel-dependent packages (kernel: ${kernel_ver:-unknown}):$(_apply_color "${C_NC}")"
    echo -e "$(_apply_color "${C_BLUE}")$(printf '  %-20s %-15s %-10s %s' 'PACKAGE' 'BUILT FOR' 'TYPE' 'STATUS')$(_apply_color "${C_NC}")"

    local stale_count=0
    while IFS='|' read -r pkg_name pkg_kernel_ver dep_type; do
        [ -z "$pkg_name" ] && continue
        local status marker
        if [ "$pkg_kernel_ver" = "$kernel_ver" ]; then
            status="up to date"
            marker="${C_GREEN}"
        else
            status="STALE (needs rebuild)"
            marker="${C_RED}"
            stale_count=$((stale_count + 1))
        fi
        if $show_all || [ "$pkg_kernel_ver" != "$kernel_ver" ]; then
            local installed_ver
            installed_ver=$(installed_version "$pkg_name")
            printf "  %-20s %-15s %-10s " "$pkg_name${installed_ver:+-$installed_ver}" "$pkg_kernel_ver" "$dep_type"
            echo -e "$(_apply_color "${marker}")${status}$(_apply_color "${C_NC}")"
        fi
    done < "$kernel_deps_file"

    if [ "$stale_count" -gt 0 ]; then
        echo ""
        log_warn "$stale_count package(s) built for a different kernel version."
        log_info "Run: lpm rebuild-kernel"
    fi
}

# Rebuild all kernel-dependent packages that are stale
rebuild_kernel_deps() {
    local kernel_ver
    kernel_ver=$(get_installed_kernel_version)

    if [ -z "$kernel_ver" ]; then
        die "Cannot determine installed kernel version. Is the kernel installed?"
    fi

    if [ ! -s "$kernel_deps_file" ]; then
        log_info "No kernel-dependent packages to rebuild."
        return 0
    fi

    # Collect stale packages
    local -a stale_pkgs=()
    while IFS='|' read -r pkg_name pkg_kernel_ver dep_type; do
        [ -z "$pkg_name" ] && continue
        if [ "$pkg_kernel_ver" != "$kernel_ver" ]; then
            stale_pkgs+=("$pkg_name")
        fi
    done < "$kernel_deps_file"

    if [ ${#stale_pkgs[@]} -eq 0 ]; then
        log_success "All kernel-dependent packages are up to date (kernel $kernel_ver)."
        return 0
    fi

    log_info "Kernel version: $kernel_ver"
    log_info "${#stale_pkgs[@]} package(s) need rebuilding for the new kernel:"
    for pkg in "${stale_pkgs[@]}"; do
        local old_ver
        old_ver=$(awk -F'|' -v p="$pkg" '$1 == p { print $2; exit }' "$kernel_deps_file")
        echo "  $pkg (built for kernel $old_ver)"
    done

    if $DRY_RUN; then
        log_info "Dry run — no packages rebuilt."
        return 0
    fi

    # Sort stale_pkgs so that 'modules' type comes before 'headers' and 'runtime'
    # (modules like kmod should be rebuilt first since others may depend on it)
    local -a ordered=()
    for pkg in "${stale_pkgs[@]}"; do
        local dtype
        dtype=$(awk -F'|' -v p="$pkg" '$1 == p { print $3; exit }' "$kernel_deps_file")
        if [ "$dtype" = "modules" ]; then
            ordered=("$pkg" "${ordered[@]}")
        else
            ordered+=("$pkg")
        fi
    done

    local rebuilt=0 failed=0
    for pkg in "${ordered[@]}"; do
        log_info "Rebuilding $pkg for kernel $kernel_ver..."
        # Find the recipe for this package
        local recipe=""
        local candidate
        for candidate in \
            "$LPM_PACKAGES_DIR/$pkg.lpm" \
            "/usr/share/lpm/recipes/$pkg.lpm" \
            "/usr/share/lpm/recipes/$(basename "$pkg").lpm"; do
            if [ -f "$candidate" ]; then
                recipe="$candidate"
                break
            fi
        done

        if [ -n "$recipe" ]; then
            if build_package "$recipe" --force; then
                # Update kernel dep registry with new kernel version
                local dep_type
                dep_type=$(awk -F'|' -v p="$pkg" '$1 == p { print $3; exit }' "$kernel_deps_file")
                register_kernel_dep "$pkg" "$kernel_ver" "${dep_type:-runtime}"
                rebuilt=$((rebuilt + 1))
            else
                log_error "Failed to rebuild $pkg"
                failed=$((failed + 1))
            fi
        else
            log_warn "No recipe found for $pkg — skipping (rebuild manually with: lpm build <source>)"
            # Still update the registry to avoid repeated warnings
            local dep_type
            dep_type=$(awk -F'|' -v p="$pkg" '$1 == p { print $3; exit }' "$kernel_deps_file")
            register_kernel_dep "$pkg" "$kernel_ver" "${dep_type:-runtime}"
            rebuilt=$((rebuilt + 1))
        fi
    done

    echo ""
    log_success "Kernel rebuild complete: $rebuilt rebuilt, $failed failed."
    if [ "$failed" -gt 0 ]; then
        return 1
    fi
}

# =======================================================================
# Repository index generation with GPG signing
# =======================================================================
repo_add() {
    local repo_dir="${1:-$REPO_LOCAL_PATH}"
    local index_file="$repo_dir/packages.list"
    local sig_file="$repo_dir/packages.list.sig"

    if [ ! -d "$repo_dir" ]; then
        die "Repository directory not found: $repo_dir"
    fi

    log_info "Generating repository index from $repo_dir"

    # Scan for package archives and build index
    local count=0
    local tmp_index
    tmp_index=$(mktemp)

    for archive in "$repo_dir"/*.tar.xz; do
        [ -f "$archive" ] || continue
        local basename
        basename=$(basename "$archive" .tar.xz)

        # Extract name-version from filename (name-version.tar.xz)
        local pkg_name pkg_version
        if [[ $basename =~ ^([a-zA-Z0-9._+-]+)-([0-9].*)$ ]]; then
            pkg_name="${BASH_REMATCH[1]}"
            pkg_version="${BASH_REMATCH[2]}"
        else
            log_warn "Skipping unrecognized archive: $basename"
            continue
        fi

        # Compute SHA256 checksum
        local checksum
        checksum=$(sha256_of "$archive")

        # Extract description from package if it has a .info file
        local desc=""
        if [ -f "$repo_dir/$basename.info" ]; then
            desc=$(grep -m1 '^desc=' "$repo_dir/$basename.info" 2>/dev/null | cut -d= -f2-)
        fi
        [ -z "$desc" ] && desc="Package $pkg_name"

        # Extract dependencies if available
        local deps=""
        if [ -f "$repo_dir/$basename.info" ]; then
            deps=$(grep -m1 '^deps=' "$repo_dir/$basename.info" 2>/dev/null | cut -d= -f2-)
        fi

        # Write pipe-separated entry: name|version|description|deps|checksum
        echo "${pkg_name}|${pkg_version}|${desc}|${deps}|${checksum}" >> "$tmp_index"
        count=$((count + 1))
    done

    if [ "$count" -eq 0 ]; then
        rm -f "$tmp_index"
        die "No package archives found in $repo_dir"
    fi

    # Sort by package name and write final index
    sort -t'|' -k1,1 "$tmp_index" > "$index_file"
    rm -f "$tmp_index"

    log_success "Repository index created: $index_file ($count packages)"

    # Sign the index if GPG is available
    if command -v gpg >/dev/null 2>&1; then
        log_info "Signing repository index..."
        if gpg --batch --yes --armor --detach-sign \
               --output "$sig_file" "$index_file" 2>/dev/null; then
            log_success "Repository index signed: $sig_file"
            log_info "Distribute both packages.list and packages.list.sig"
        else
            log_warn "Failed to sign index (no GPG key configured?)"
            log_info "Index is still usable without signature verification"
        fi
    else
        log_warn "GPG not found – index not signed"
        log_info "Install GPG and configure a signing key for repository authentication"
    fi

    # Generate a human-readable summary
    local summary_file="$repo_dir/packages.summary"
    {
        echo "# Repository Index Summary"
        echo "# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "# Packages:  $count"
        echo "#"
        printf '# %-30s %-15s %s\n' "Package" "Version" "Description"
        printf '# %-30s %-15s %s\n' "-------" "-------" "-----------"
        while IFS='|' read -r name ver desc deps checksum; do
            printf '# %-30s %-15s %s\n' "$name" "$ver" "$desc"
        done < "$index_file"
    } > "$summary_file"
    log_info "Summary written to $summary_file"
}

# =======================================================================
# Verify signed repository index
# =======================================================================
verify_repo_index() {
    local index_file="$1"
    local sig_file="${index_file}.sig"

    if [ ! -f "$sig_file" ]; then
        log_warn "No signature file for $index_file"
        return 1
    fi

    if [ ! -f "$GPG_KEYRING" ]; then
        log_warn "Trusted keyring not found: $GPG_KEYRING"
        return 1
    fi

    if ! command -v gpg >/dev/null 2>&1; then
        log_warn "GPG not found – cannot verify repository signature"
        return 1
    fi

    if gpg --no-default-keyring --keyring "$GPG_KEYRING" \
           --verify "$sig_file" "$index_file" >/dev/null 2>&1; then
        log_info "Repository index signature verified"
        return 0
    else
        log_error "Repository index signature VERIFICATION FAILED"
        return 1
    fi
}

# =======================================================================
# Help
# =======================================================================
show_help() {
    cat <<'HELP'
LPM - Linux Package Manager for LFS
Usage: lpm <command> [options]

Commands:
  install <pkg>         Install a package (and its dependencies)
  remove <pkg>          Remove a package
  update <pkg>          Update (reinstall) a specific package
  upgrade               Upgrade all installed packages to latest versions
  upgradable            List installed packages with a newer version available
  reinstall <pkg>       Force re-fetch and re-install an installed package
  autoremove            Remove orphan packages (not base, not required)
  why <pkg>             Show which packages depend on <pkg>
  hold <pkg>            Pin a package: lpm upgrade will skip it
  unhold <pkg>          Remove the pin on a package
  holds                 List held packages
  history [N]           Show the last N transactions (default 50)
  build <source|.lpm>   Build, package, and install from source
  add-profile <prof>    Install all packages from a build profile
  list-profiles         List available profiles
  list                  List installed packages
  search <pattern>      Search for packages in database
  info <pkg>            Show detailed package information
  verify [pkg]          Verify integrity of installed files (all if no pkg)
  kernel-deps [--all]   List packages that depend on the kernel (--all includes up-to-date)
  rebuild-kernel        Rebuild all stale kernel-dependent packages
  update-db             Synchronize package database
  repo-add [dir]        Generate signed repository index from package archives
  clean                 Remove downloaded package files (cache)
  help                  Show this help
  version               Display version information

Options:
  --dry-run             Simulate actions (no changes)
  --force               Force reinstallation even if already installed
  --quiet               Suppress non-error output
  --verbose             Enable detailed debug output
  --no-color            Disable colored output
  --sysroot <dir>       Operate on an alternate root (chroots); alias of LPM_ROOT

Build options (with 'build' command):
  --recipe <file>       Use a .lpm recipe file for custom build steps
  --no-install          Build and package but do not install
  --desc <description>  Set package description
  --deps <pkg1,pkg2>    Specify runtime dependencies (comma-separated)

Recipe format (.lpm file):
  name="myapp"
  version="1.0"
  source="https://example.com/myapp-1.0.tar.xz"
  desc="My application"
  deps="glibc>=2.37,openssl"
  kernel_dep="modules"   # optional: modules | headers | runtime
  build() {
      # Available: PKG (staging dir), SRC (source dir), JOBS (parallel jobs)
      ./configure --prefix=/usr
      make -j"$JOBS"
      make DESTDIR="$PKG" install
  }

Configuration (/etc/lpm/lpm.conf):
  REPO_REMOTE_URLS=("https://repo.example.com/x86_64")   # HTTP(S) repos
  VERIFY_SIGNATURES=true                                  # GPG verification
  GPG_KEYRING=/etc/lpm/trusted.gpg                        # Trusted keys
  VERIFY_CHECKSUMS=true                                   # SHA256 integrity
  BUILD_JOBS=4                                            # Parallel compilation jobs
  KEEP_BUILD_ARTIFACTS=false                              # Retain build directories

Examples:
  lpm install bash
  lpm remove coreutils
  lpm build https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz
  lpm build mypkg.lpm
  lpm build myapp-2.0.tar.xz --desc "My App" --deps "glibc,curl"
  lpm add-profile audio-studio
  lpm upgrade --dry-run
  lpm upgradable
  lpm why glibc
  lpm hold openssl
  lpm history
  lpm autoremove --dry-run
  lpm search gcc
  lpm install --no-color bash
  lpm list-profiles
  lpm verify
  lpm verify bash
  lpm kernel-deps
  lpm kernel-deps --all
  lpm rebuild-kernel
  lpm rebuild-kernel --dry-run
  lpm --sysroot /mnt/lfs install coreutils
HELP
}

# ======================================================================
list_available_profiles() {
    local profiles_file="$LPM_ETC/profiles.json"

    if [ ! -f "$profiles_file" ]; then
        log_warn "No profiles database found at $profiles_file"
        return 1
    fi

    # Validate JSON structure first
    if ! validate_json "$profiles_file"; then
        log_error "profiles.json is not valid JSON"
        return 1
    fi

    echo -e "$(_apply_color "${C_BLUE}")Available profiles:$(_apply_color "${C_NC}")"

    # Use jq if available (more robust), otherwise fallback to sed/grep
    if $HAS_JQ; then
        jq -r 'to_entries | .[] | "\(.key) \(.value.description // \"No description\")"' "$profiles_file" |
            awk '{ printf "  %-20s %s\n", $1, substr($0, index($0, $2)) }'
    else
        # Fallback: grep to extract profile names from JSON
        grep -o '"[^"]*": {' "$profiles_file" | sed 's/": {$//' | sed 's/^"//' | while read -r name; do
            # Extract description for this profile
            desc=$(sed -n "/\"$name\": {/,/^  },*$/p" "$profiles_file" | grep '"description"' | sed 's/.*"description": "//' | sed 's/".*//')
            printf "  %-20s %s\n" "$name" "${desc:- No description}"
        done
    fi
}

get_profile_packages() {
    local profile="$1"
    local profiles_file="$LPM_ETC/profiles.json"

    if [ ! -f "$profiles_file" ]; then
        die "Profiles database not found at $profiles_file"
    fi

    # Validate JSON structure first
    if ! validate_json "$profiles_file"; then
        die "profiles.json is not valid JSON"
    fi

    # Use jq if available (more robust), otherwise fallback to sed/grep
    if $HAS_JQ; then
        jq -r ".\"$profile\".packages[]?" "$profiles_file" 2>/dev/null
    else
        # Fallback: extract packages array for profile from JSON
        sed -n "/\"$profile\": {/,/^  },*$/p" "$profiles_file" |
            sed -n '/"packages": \[/,/\]/p' |
            grep -o '"[^"]*"' |
            sed 's/"//g' |
            grep -v '^packages$'
    fi
}

add_profile() {
    local profile="$1"
    [ -z "$profile" ] && die "Missing profile name"

    log_info "Adding profile: $profile"

    local packages
    packages=$(get_profile_packages "$profile") || die "Profile '$profile' not found or has no packages"

    if [ -z "$packages" ]; then
        die "Profile '$profile' has no packages defined"
    fi

    log_info "Installing packages for profile '$profile'..."

    local pkg_list
    pkg_list=$(echo "$packages" | grep -v '^[[:space:]]*$' | tr '\n' ' ')
    log_verbose "Package list: $pkg_list"

    # Install all packages in dependency order
    local pkgs_to_install
    # shellcheck disable=SC2086  # intentional word split of the package list
    pkgs_to_install=$(install_order $pkg_list) || die "Failed to resolve profile dependencies"

    if $DRY_RUN; then
        echo "The following packages would be installed for profile '$profile' (in order):"
        printf '%s\n' "$pkgs_to_install"
    else
        local count=0
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            count=$((count + 1))
            log_info "[$count] Installing: $p"
            install_package "$p" || log_warn "Failed to install $p (may have partial data)"
        done <<<"$pkgs_to_install"
        log_success "Profile '$profile' installation complete"
    fi
}

main() {
    # Parse global options
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --quiet)
            QUIET=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --no-color)
            NO_COLOR=true
            shift
            ;;
        --sysroot)
            LPM_ROOT="${2:?--sysroot requires a directory}"
            shift 2
            ;;
        --sysroot=*)
            LPM_ROOT="${1#*=}"
            shift
            ;;
        *) break ;;
        esac
    done

    local cmd="${1:-help}"
    shift || true

    apply_sysroot_paths
    load_config
    init_dirs

    if [ "$cmd" != "help" ] && [ "$cmd" != "version" ]; then
        acquire_lock
        trap release_lock EXIT
    fi

    case "$cmd" in
    install)
        if [ "$#" -eq 0 ]; then die "Missing package name"; fi
        local pkgs_to_install
        pkgs_to_install=$(install_order "$@")
        if $DRY_RUN; then
            echo "The following packages would be installed (in order):"
            printf '%s\n' "$pkgs_to_install"
        else
            while IFS= read -r p; do
                [ -z "$p" ] && continue
                install_package "$p"
            done <<<"$pkgs_to_install"
        fi
        ;;
    remove)
        [ "$#" -eq 0 ] && die "Missing package name"
        remove_package "$1"
        ;;
    update)
        [ "$#" -eq 0 ] && die "Missing package name"
        update_package "$1"
        ;;
    upgrade)
        upgrade_all
        ;;
    upgradable)
        show_upgradable
        ;;
    reinstall)
        [ "$#" -eq 0 ] && die "Missing package name"
        reinstall_package "$1"
        ;;
    autoremove)
        autoremove_orphans
        ;;
    why | rdepends)
        [ "$#" -eq 0 ] && die "Missing package name"
        why_package "$1"
        ;;
    hold)
        [ "$#" -eq 0 ] && die "Missing package name"
        hold_package "$1"
        ;;
    unhold)
        [ "$#" -eq 0 ] && die "Missing package name"
        unhold_package "$1"
        ;;
    holds)
        list_holds
        ;;
    history)
        show_history "${1:-50}"
        ;;
    build)
        build_package "$@"
        ;;
    list)
        list_packages
        ;;
    search)
        [ "$#" -eq 0 ] && die "Missing search pattern"
        search_package "$1"
        ;;
    info)
        [ "$#" -eq 0 ] && die "Missing package name"
        show_info "$1"
        ;;
    verify | check)
        verify_package "${1:-}"
        ;;
    kernel-deps)
        list_kernel_deps "${1:-}"
        ;;
    rebuild-kernel)
        rebuild_kernel_deps
        ;;
    update-db)
        update_db
        ;;
    repo-add)
        repo_add "${1:-}"
        ;;
    clean)
        clean_cache
        ;;
    add-profile)
        [ "$#" -eq 0 ] && die "Missing profile name"
        add_profile "$1"
        ;;
    list-profiles)
        list_available_profiles
        ;;
    help | --help | -h)
        show_help
        ;;
    version | --version | -v)
        echo "LPM version $LPM_VERSION (LFS Package Manager)"
        echo "Built for LFS 13.0 and Beyond Linux from Scratch"
        echo "Improvements: build-time DB seeding, holds, history, autoremove"
        ;;
    *)
        log_error "Unknown command: $cmd"
        show_help
        exit 1
        ;;
    esac
}

install_lpm_stage() {
    local target="${LFS:?LFS must be set for the LPM build stage}"
    local run_privileged=""
    if [ "$(id -u)" -ne 0 ]; then
        run_privileged="sudo"
    fi

    $run_privileged install -Dm755 "$0" "$target/usr/bin/lpm"
    $run_privileged mkdir -p "$target/var/lib/lpm" "$target/var/log/lpm" \
        "$target/usr/share/lpm/packages" "$target/etc/lpm" \
        "$target/etc/lpm/repos.d"
    $run_privileged touch "$target/var/lib/lpm/packages.list" \
        "$target/var/lib/lpm/installed.list" "$target/var/lib/lpm/file_index"

    # Install LPM configuration file
    if [ -f "${SCRIPT_DIR:-.}/../config/lpm.conf" ]; then
        $run_privileged cp "${SCRIPT_DIR:-.}/../config/lpm.conf" "$target/etc/lpm/lpm.conf"
        $run_privileged chmod 0644 "$target/etc/lpm/lpm.conf"
    fi

    # Configure default remote repositories. The manifest is published
    # by the release pipeline (blfs/14-create-base-packages.sh exports
    # lpm-repo/packages.list, uploaded as a GitHub release asset).
    cat > "$target/etc/lpm/repos.d/default.conf" <<'REPOS'
# LPM default remote repositories
# Format: name=url
# The first matching repo is tried first; falls back to the next.
# update-db fetches <url>/packages.list (and .sig when VERIFY_SIGNATURES=true).

lfs-releases=https://github.com/landrevillejf/beyond-linux-from-scratch/releases/latest/download
REPOS
    $run_privileged chmod 0644 "$target/etc/lpm/repos.d/default.conf"

    log_success "Installed LPM into $target/usr/bin/lpm"
    log_success "LPM config: $target/etc/lpm/lpm.conf"
    log_success "LPM repos:  $target/etc/lpm/repos.d/default.conf"
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${LFS:-/}" != "/" ] && [ "$#" -eq 0 ]; then
    install_lpm_stage
elif [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
