#!/usr/bin/env bash
# LPM – Linux Package Manager
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
# Version: 2.5.0

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
LPM_VERSION="2.5.0"
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
VISITED_DEPS="" # Visited packages as pipe-separated list (e.g., "pkg1|pkg2|pkg3|")

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
}

root_path() {
    local path="$1"
    if [ "$LPM_ROOT" = "/" ] || [ "\${path#"$LPM_ROOT"}" != "$path" ]; then
        printf '%s\n' "$path"
    else
        printf '%s%s\n' "\${LPM_ROOT%/}" "$path"
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

# Read configuration file (sourced)
load_config() {
    if [ -f "$LPM_CONF" ]; then
        # shellcheck disable=SC1090
        source "$LPM_CONF"
    fi
    apply_sysroot_paths
    refresh_runtime_paths
    log_verbose "Configuration loaded from $LPM_CONF"
}

# Ensure directories exist
init_dirs() {
    mkdir -p "$LPM_DB" "$LPM_LOGS" "$LPM_ETC" "$LPM_PACKAGES_DIR" "$(dirname "$LOCK_FILE")"
    touch "$LPM_DB/packages.list" "$LPM_DB/installed.list" "$LPM_DB/file_index"
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
            # Efficiently check if package already in order array using awk
            for d in $deps; do
                if ! printf '%s\n' "${order[@]}" | awk -v x="$d" '$0 == x { exit 1 }'; then
                    order+=("$d")
                fi
            done
            if ! printf '%s\n' "${order[@]}" | awk -v x="$pkg" '$0 == x { exit 1 }'; then
                order+=("$pkg")
            fi
        fi
    done
    printf '%s\n' "${order[@]}"
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
            if [ "$expected_checksum" = "sha256-dummy" ]; then
                # Dummy checksum - warn if configured to do so
                if [ "$ALLOW_DUMMY_CHECKSUMS" = "true" ]; then
                    log_warn "Package $pkg_name has dummy checksum (no integrity verification)"
                else
                    if $VERBOSE; then
                        log_warn "Package $pkg_name has dummy checksum; skipping verification"
                    fi
                fi
            else
                # Real checksum - verify
                actual_checksum=$(sha256_of "$pkg_file")
                if [ "$expected_checksum" != "$actual_checksum" ]; then
                    die "Checksum mismatch for $pkg_name-$pkg_version"
                fi
                log_verbose "Checksum verified: $expected_checksum"
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
    echo "$(timestamp) - Removed $pkg_name-$installed_ver" >>"$LPM_LOGS/remove.log"
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
    install_package "$pkg"
    FORCE=$old_force
}

# ======================================================================
# Upgrade all installed packages that have newer versions
# ======================================================================
upgrade_all() {
    log_info "Checking for upgradable packages..."
    local installed_list
    # Read installed list once to prevent race conditions
    installed_list=$(cat "$installed_file")

    # Build list of upgradable packages (no subshell: process substitution keeps vars)
    local -a to_upgrade=()
    local line name version latest
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        name=$(echo "$line" | awk '{print $1}')
        version=$(echo "$line" | awk '{print $2}')
        latest=$(get_pkg_field "$name" version)
        if [ -n "$latest" ] && [ "$version" != "$latest" ]; then
            echo "  $name $version -> $latest"
            to_upgrade+=("$name")
        fi
    done <<<"$installed_list"

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
            if curl -fsSL --connect-timeout 15 "$url/packages.list" >>"$tmp_db" 2>/dev/null; then
                merged=true
            else
                log_warn "Failed to sync from $url"
            fi
        done
        if $merged; then
            # Deduplicate by package name (first occurrence wins = repo priority order)
            awk -F'|' '!seen[$1]++' "$tmp_db" >"$db_file"
            rm -f "$tmp_db"
            log_success "Database updated ($(wc -l <"$db_file") packages)"
            return 0
        fi
        rm -f "$tmp_db"
        log_warn "All remote syncs failed, falling back to sample data"
    fi

    # Fallback: initialize with sample data in pipe-separated format
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
    log_success "Database updated"
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

# ======================================================================
# Help
# ======================================================================
show_help() {
    cat <<'HELP'
LPM - Linux Package Manager for LFS
Usage: lpm <command> [options]

Commands:
  install <pkg>         Install a package (and its dependencies)
  remove <pkg>          Remove a package
  update <pkg>          Update (reinstall) a specific package
  upgrade               Upgrade all installed packages to latest versions
  build <source|.lpm>   Build, package, and install from source
  add-profile <prof>    Install all packages from a build profile
  list-profiles         List available profiles
  list                  List installed packages
  search <pattern>      Search for packages in database
  info <pkg>            Show detailed package information
  verify [pkg]          Verify integrity of installed files (all if no pkg)
  update-db             Synchronize package database
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
  lpm search gcc
  lpm install --no-color bash
  lpm list-profiles
  lpm verify
  lpm verify bash
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
    update-db)
        update_db
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
        echo "Improvements: Source build support, automatic packaging, recipe system"
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
        "$target/usr/share/lpm/packages" "$target/etc/lpm"
    $run_privileged touch "$target/var/lib/lpm/packages.list" \
        "$target/var/lib/lpm/installed.list" "$target/var/lib/lpm/file_index"
    log_success "Installed LPM into $target/usr/bin/lpm"
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${LFS:-/}" != "/" ] && [ "$#" -eq 0 ]; then
    install_lpm_stage
elif [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
