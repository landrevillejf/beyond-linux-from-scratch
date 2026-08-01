#!/usr/bin/env bash
# LPM – Linux Package Manager
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
# Improved version: Robustness, security, and cycle detection

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
LPM_VERSION="2.1.0"
LPM_CONF="/etc/lpm/lpm.conf"
LPM_ETC="/etc/lpm"
LPM_DB="/var/lib/lpm"
LPM_LOGS="/var/log/lpm"
LPM_PACKAGES_DIR="/usr/share/lpm/packages"
LPM_REPOS=( "local" )
REPO_LOCAL_PATH="$LPM_PACKAGES_DIR"
LOCK_FILE="/var/lock/lpm.lock"
VERIFY_CHECKSUMS=true
LOG_TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"

# Runtime variables
QUIET=false; VERBOSE=false; DRY_RUN=false; FORCE=false; NO_COLOR=false
LOCK_FD=""
declare -a VISITED_DEPS=()

# ======================================================================
# Logging helpers (respecting NO_COLOR and USE_COLOR)
# ======================================================================
_apply_color() {
    if ! $NO_COLOR && $USE_COLOR; then
        echo "$1"
    fi
}

log_info()  { 
    $QUIET || echo -e "$(_apply_color "${C_GREEN}")[INFO]$(_apply_color "${C_NC}") $*"
}
log_warn()  { 
    echo -e "$(_apply_color "${C_YELLOW}")[WARNING]$(_apply_color "${C_NC}") $*" >&2
}
log_error() { 
    echo -e "$(_apply_color "${C_RED}")[ERROR]$(_apply_color "${C_NC}") $*" >&2
}
log_success(){ 
    echo -e "$(_apply_color "${C_GREEN}")[SUCCESS]$(_apply_color "${C_NC}") $*"
}
log_verbose(){ 
    $VERBOSE && echo -e "$(_apply_color "${C_BLUE}")[DEBUG]$(_apply_color "${C_NC}") $*" || true
}

# ======================================================================
# Utility functions
# ======================================================================
die() { log_error "$@"; exit 1; }

timestamp() { date +"$LOG_TIMESTAMP_FORMAT"; }

# Escape regex special characters for safe grep/sed usage
escape_regex() {
    printf '%s\n' "$1" | sed -e 's/[]\/$*.^[]/\\&/g'
}

# Acquire exclusive lock
acquire_lock() {
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
        die "Another lpm instance is running. Exiting."
    fi
}

release_lock() {
    flock -u "$LOCK_FD" 2>/dev/null || true
}

refresh_runtime_paths() {
    db_file="$LPM_DB/packages.list"
    installed_file="$LPM_DB/installed.list"
    file_index="$LPM_DB/file_index"
}

# Read configuration file (sourced)
load_config() {
    if [ -f "$LPM_CONF" ]; then
        # shellcheck disable=SC1090
        source "$LPM_CONF"
    fi
    refresh_runtime_paths
    log_verbose "Configuration loaded from $LPM_CONF"
}

# Ensure directories exist
init_dirs() {
    mkdir -p "$LPM_DB" "$LPM_LOGS" "$LPM_ETC" "$LPM_PACKAGES_DIR" "$(dirname "$LOCK_FILE")"
    touch "$LPM_DB/packages.list" "$LPM_DB/installed.list" "$LPM_DB/file_index"
}

# ======================================================================
# Package database helpers (pipe-separated format for robustness)
# Format: name|version|description|dependencies|checksum
# ======================================================================
refresh_runtime_paths

# Read package metadata from DB with proper field parsing
get_pkg_field() {
    local pkg="$1" field="$2"
    local line
    # Use grep -F for literal matching (prevents regex interpretation)
    line=$(grep -F "${pkg}|" "$db_file" 2>/dev/null | head -1 || true)
    [ -z "$line" ] && return
    
    case "$field" in
        version)      echo "$line" | cut -d'|' -f2 ;;
        description)  echo "$line" | cut -d'|' -f3 ;;
        dependencies) echo "$line" | cut -d'|' -f4 ;;
        checksum)     echo "$line" | cut -d'|' -f5 ;;
        *)            echo "$line" | cut -d'|' -f"$field" ;;
    esac
}

# Check if package is installed (using -F for literal matching)
is_installed() {
    grep -qF "$1 " "$installed_file" 2>/dev/null
}

# Get installed version
installed_version() {
    grep -F "$1 " "$installed_file" 2>/dev/null | head -1 | awk '{print $2}'
}

# Dependency resolver with circular dependency detection
resolve_deps() {
    local pkg="$1"
    local deps
    
    # Check for circular dependency
    if [[ " ${VISITED_DEPS[@]} " =~ " ${pkg} " ]]; then
        log_error "Circular dependency detected: $pkg"
        return 1
    fi
    
    # Mark as visited
    VISITED_DEPS+=("$pkg")
    
    deps=$(get_pkg_field "$pkg" dependencies)
    [ -z "$deps" ] && return 0
    
    IFS=',' read -ra DEPLIST <<< "$deps"
    for dep in "${DEPLIST[@]}"; do
        dep=$(echo "$dep" | xargs)  # trim whitespace
        [ -z "$dep" ] && continue
        if ! is_installed "$dep"; then
            log_info "Resolving dependency: $dep"
            echo "$dep"
            resolve_deps "$dep" || return 1
        else
            log_verbose "Dependency $dep already installed"
        fi
    done
}

# Topological sort for install order
install_order() {
    local pkgs="$*"
    local order=()
    local pkg
    VISITED_DEPS=()  # Reset circular dependency tracking
    
    for pkg in $pkgs; do
        if ! is_installed "$pkg"; then
            local deps
            if ! deps=$(resolve_deps "$pkg"); then
                die "Cannot resolve dependencies for $pkg (circular detected)"
            fi
            for d in $deps; do
                if ! printf '%s\n' "${order[@]}" | grep -qFx "$d"; then
                    order+=("$d")
                fi
            done
            if ! printf '%s\n' "${order[@]}" | grep -qFx "$pkg"; then
                order+=("$pkg")
            fi
        fi
    done
    printf '%s\n' "${order[@]}"
}

# ======================================================================
# Package installation
# ======================================================================
install_package() {
    local pkg_input="$1"
    local pkg_name pkg_version pkg_file
    
    # Parse package name and version more robustly
    # Support formats: name, name-version (where version starts with digit)
    if [[ "$pkg_input" =~ ^([a-zA-Z0-9._+-]+)-([0-9].*)$ ]]; then
        pkg_name="${BASH_REMATCH[1]}"
        pkg_version="${BASH_REMATCH[2]}"
    else
        pkg_name="$pkg_input"
        pkg_version=$(get_pkg_field "$pkg_name" version)
    fi
    
    [ -z "$pkg_name" ] && die "Usage: lpm install <package>"
    
    if is_installed "$pkg_name"; then
        if $FORCE; then
            log_warn "Package '$pkg_name' already installed, reinstalling (--force)"
            remove_package "$pkg_name" --keep-files
        else
            log_warn "Package '$pkg_name' is already installed. Use --force to reinstall."
            return 0
        fi
    fi
    
    # Locate package file (search repos)
    pkg_file=""
    for repo in "${LPM_REPOS[@]}"; do
        case "$repo" in
            local)
                if [ -f "$REPO_LOCAL_PATH/${pkg_name}-${pkg_version}.tar.xz" ]; then
                    pkg_file="$REPO_LOCAL_PATH/${pkg_name}-${pkg_version}.tar.xz"
                    break
                fi
                ;;
        esac
    done
    
    [ -z "$pkg_file" ] && die "Package file not found: ${pkg_name}-${pkg_version}.tar.xz"
    
    log_info "Installing $pkg_name-$pkg_version"
    
    # Checksum verification
    if $VERIFY_CHECKSUMS; then
        local expected_checksum actual_checksum
        expected_checksum=$(get_pkg_field "$pkg_name" checksum)
        if [ -n "$expected_checksum" ] && [ "$expected_checksum" != "sha256-dummy" ]; then
            actual_checksum=$(sha256sum "$pkg_file" | awk '{print $1}')
            if [ "$expected_checksum" != "$actual_checksum" ]; then
                die "Checksum mismatch for $pkg_name-$pkg_version"
            fi
            log_verbose "Checksum verified"
        fi
    fi
    
    local pkg_dir="$LPM_DB/$pkg_name-$pkg_version"
    mkdir -p "$pkg_dir"
    tar -xf "$pkg_file" -C "$pkg_dir" --no-same-owner --strip-components=0
    
    # Pre-install hook
    if [ -x "$pkg_dir/pre-install.sh" ]; then
        log_info "Running pre-install script"
        (cd "$pkg_dir" && bash pre-install.sh) || die "Pre-install script failed"
    fi
    
    # Install files
    if [ -d "$pkg_dir/files" ]; then
        # Track installed files
        (cd "$pkg_dir/files" && find . -type f -o -type l | sed 's/^\.//') | while read -r f; do
            echo "$f $pkg_name-$pkg_version" >> "$file_index"
        done
        cp -rL "$pkg_dir/files"/* / 2>/dev/null || true
    fi
    
    # Post-install hook
    if [ -x "$pkg_dir/post-install.sh" ]; then
        log_info "Running post-install script"
        (cd "$pkg_dir" && bash post-install.sh) || log_warn "Post-install script returned non-zero"
    fi
    
    # Record installation
    escaped_name=$(escape_regex "$pkg_name")
    if grep -qF "$pkg_name " "$installed_file"; then
        sed -i "/^${escaped_name} /d" "$installed_file"
    fi
    echo "$pkg_name $pkg_version" >> "$installed_file"
    echo "$(timestamp) - Installed $pkg_name-$pkg_version" >> "$LPM_LOGS/install.log"
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
            --keep-files) keep_files=true; shift ;;
            *) pkg_name="$1"; shift ;;
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
            (cd "$pkg_dir/files" && find . -type f -o -type l | sed 's/^\.//') | while read -r f; do
                local owners
                owners=$(grep -F "$f " "$file_index" 2>/dev/null | awk '{print $2}' || true)
                # Only remove if this package is the sole owner
                if [ -n "$owners" ]; then
                    local owner_count total_count
                    owner_count=$(echo "$owners" | grep -c "^${pkg_name}-${installed_ver}$" || true)
                    total_count=$(echo "$owners" | wc -l)
                    if [ "$owner_count" -eq "$total_count" ]; then
                        rm -f "/$f" 2>/dev/null || log_warn "Failed to remove /$f"
                        escaped_f=$(escape_regex "$f")
                        sed -i "/^${escaped_f} ${pkg_name}-${installed_ver}$/d" "$file_index"
                    else
                        log_verbose "File /$f is shared, not removing"
                    fi
                fi
            done
        fi
        
        # Post-remove hook
        if [ -x "$pkg_dir/post-remove.sh" ]; then
            log_info "Running post-remove script"
            (cd "$pkg_dir" && bash post-remove.sh) || log_warn "Post-remove script returned non-zero"
        fi
    fi
    
    escaped_name=$(escape_regex "$pkg_name")
    sed -i "/^${escaped_name} /d" "$installed_file"
    echo "$(timestamp) - Removed $pkg_name-$installed_ver" >> "$LPM_LOGS/remove.log"
    log_success "Package '$pkg_name' removed"
}

# ======================================================================
# Update (reinstall) a single package
# ======================================================================
update_package() {
    local pkg="$1"
    [ -z "$pkg" ] && die "Usage: lpm update <package>"
    if is_installed "$pkg"; then
        remove_package "$pkg"
    fi
    install_package "$pkg"
}

# ======================================================================
# Upgrade all installed packages that have newer versions
# ======================================================================
upgrade_all() {
    log_info "Checking for upgradable packages..."
    local installed_list
    # Read installed list once to prevent race conditions
    installed_list=$(cat "$installed_file")
    
    local upgradable=false
    echo "$installed_list" | while read -r line; do
        [ -z "$line" ] && continue
        local name version
        name=$(echo "$line" | awk '{print $1}')
        version=$(echo "$line" | awk '{print $2}')
        local latest
        latest=$(get_pkg_field "$name" version)
        if [ -n "$latest" ] && [ "$version" != "$latest" ]; then
            echo "  $name $version -> $latest"
            upgradable=true
        fi
    done
    
    if ! $DRY_RUN && [ "$upgradable" = true ]; then
        log_info "Upgrading packages..."
        echo "$installed_list" | while read -r line; do
            [ -z "$line" ] && continue
            local name version latest
            name=$(echo "$line" | awk '{print $1}')
            version=$(echo "$line" | awk '{print $2}')
            latest=$(get_pkg_field "$name" version)
            if [ -n "$latest" ] && [ "$version" != "$latest" ]; then
                update_package "$name"
            fi
        done
    elif $DRY_RUN; then
        log_info "Dry run complete, no changes made."
    else
        log_info "All packages are up to date."
    fi
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
    grep -i "$pattern" "$db_file" 2>/dev/null | while IFS='|' read -r name ver desc deps _chk; do
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
# Database update (sync with repositories)
# ======================================================================
update_db() {
    log_info "Updating package database..."
    # Example: fetch from remote repo (commented for demonstration)
    # curl -s https://repo.example.com/packages.list | tee "$db_file"
    # For now, initialize with sample data in pipe-separated format
    cat > "$db_file" << 'EOF'
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
# Help
# ======================================================================
show_help() {
    cat << 'HELP'
LPM - Linux Package Manager for LFS
Usage: lpm <command> [options]

Commands:
  install <pkg>         Install a package (and its dependencies)
  remove <pkg>          Remove a package
  update <pkg>          Update (reinstall) a specific package
  upgrade               Upgrade all installed packages to latest versions
  list                  List installed packages
  search <pattern>      Search for packages in database
  info <pkg>            Show detailed package information
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

Examples:
  lpm install bash
  lpm remove coreutils
  lpm upgrade --dry-run
  lpm search gcc
  lpm install --no-color bash
HELP
}

# ======================================================================
# Main command dispatcher
# ======================================================================
main() {
    # Parse global options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  DRY_RUN=true; shift ;;
            --force)    FORCE=true; shift ;;
            --quiet)    QUIET=true; shift ;;
            --verbose)  VERBOSE=true; shift ;;
            --no-color) NO_COLOR=true; shift ;;
            *) break ;;
        esac
    done
    
    local cmd="${1:-help}"
    shift || true
    
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
                done <<< "$pkgs_to_install"
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
        update-db)
            update_db
            ;;
        clean)
            clean_cache
            ;;
        help|--help|-h)
            show_help
            ;;
        version|--version|-v)
            echo "LPM version $LPM_VERSION (LFS Package Manager)"
            echo "Built for LFS 13.0 and Beyond Linux from Scratch"
            echo "Improvements: Circular dependency detection, robust parsing, secure regex handling"
            ;;
        *)
            log_error "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
