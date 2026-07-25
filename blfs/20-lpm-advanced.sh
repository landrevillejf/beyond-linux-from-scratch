#!/usr/bin/env bash
# LPM – Linux Package Manager
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.

set -euo pipefail

# ----------------------------------------------------------------------
# Colors (can be disabled in config)
# ----------------------------------------------------------------------
# shellcheck disable=SC2034
C_RED='\033[0;31m' C_GREEN='\033[0;32m' C_YELLOW='\033[1;33m' C_BLUE='\033[0;34m' C_NC='\033[0m'
# shellcheck disable=SC2034
USE_COLOR=true

# ----------------------------------------------------------------------
# Default configuration
# ----------------------------------------------------------------------
LPM_VERSION="2.0.0"
LPM_CONF="/etc/lpm/lpm.conf"
LPM_ETC="/etc/lpm"
LPM_DB="/var/lib/lpm"
LPM_LOGS="/var/log/lpm"
LPM_PACKAGES_DIR="/usr/share/lpm/packages"          # Changed from /usr/local
LPM_REPOS=( "local" )
REPO_LOCAL_PATH="$LPM_PACKAGES_DIR"
LOCK_FILE="/var/lock/lpm.lock"
VERIFY_CHECKSUMS=true
LOG_TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"

# Runtime variables
QUIET=false; VERBOSE=false; DRY_RUN=false; FORCE=false
LOCK_FD=""

# ----------------------------------------------------------------------
# Logging helpers
# ----------------------------------------------------------------------
log_info()  { $QUIET || echo -e "${C_GREEN}[INFO]${C_NC} $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARNING]${C_NC} $*"; }
log_error() { echo -e "${C_RED}[ERROR]${C_NC} $*" >&2; }
log_success(){ echo -e "${C_GREEN}[SUCCESS]${C_NC} $*"; }
log_verbose(){ $VERBOSE && echo -e "${C_BLUE}[DEBUG]${C_NC} $*" || true; }

# ----------------------------------------------------------------------
# Utility functions
# ----------------------------------------------------------------------
die() { log_error "$@"; exit 1; }

timestamp() { date +"$LOG_TIMESTAMP_FORMAT"; }

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

# ----------------------------------------------------------------------
# Package database helpers (version:name:description:dep1,dep2:checksum)
# ----------------------------------------------------------------------
refresh_runtime_paths
# installed.list format: name version

# Read package metadata from DB
get_pkg_field() {
    local pkg="$1" field="$2"
    local line
    line=$(grep -m1 "^${pkg}:" "$db_file" 2>/dev/null || true)
    case "$field" in
        version) echo "$line" | cut -d: -f2 ;;
        description) echo "$line" | cut -d: -f3 ;;
        dependencies) echo "$line" | cut -d: -f4 ;;
        checksum) echo "$line" | cut -d: -f5 ;;
        *) echo "$line" | cut -d: -f"$field" ;;
    esac
}

# Check if package is installed
is_installed() {
    grep -q "^$1 " "$installed_file" 2>/dev/null
}

# Get installed version
installed_version() {
    grep "^$1 " "$installed_file" 2>/dev/null | head -1 | awk '{print $2}'
}

# Simple dependency resolver (recursive, no cycles)
resolve_deps() {
    local pkg="$1"
    local deps
    deps=$(get_pkg_field "$pkg" dependencies)
    IFS=',' read -ra DEPLIST <<< "$deps"
    for dep in "${DEPLIST[@]}"; do
        dep=$(echo "$dep" | xargs)  # trim
        [ -z "$dep" ] && continue
        if ! is_installed "$dep"; then
            log_info "Resolving dependency: $dep"
            echo "$dep"
            resolve_deps "$dep"
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
    for pkg in $pkgs; do
        if ! is_installed "$pkg"; then
            local deps
            deps=$(resolve_deps "$pkg" | sort -u)
            for d in $deps; do
                if ! echo "${order[*]}" | grep -qw "$d"; then
                    order+=("$d")
                fi
            done
            if ! echo "${order[*]}" | grep -qw "$pkg"; then
                order+=("$pkg")
            fi
        fi
    done
    echo "${order[@]}"
}

# ----------------------------------------------------------------------
# Package installation
# ----------------------------------------------------------------------
install_package() {
    local pkg_input="$1"
    local pkg_name pkg_version pkg_file

    # Support name or name-version
    if [[ "$pkg_input" == *-* ]]; then
        pkg_name="${pkg_input%-*}"
        pkg_version="${pkg_input##*-}"
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
            # Additional repository handlers can be added here
        esac
    done

    [ -z "$pkg_file" ] && die "Package file not found: ${pkg_name}-${pkg_version}.tar.xz"

    log_info "Installing $pkg_name-$pkg_version"

    # Checksum verification
    if $VERIFY_CHECKSUMS; then
        local expected_checksum actual_checksum
        expected_checksum=$(get_pkg_field "$pkg_name" checksum)
        if [ -n "$expected_checksum" ]; then
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
    if grep -q "^$pkg_name " "$installed_file"; then
        sed -i "/^$pkg_name /d" "$installed_file"
    fi
    echo "$pkg_name $pkg_version" >> "$installed_file"
    echo "$(timestamp) - Installed $pkg_name-$pkg_version" >> "$LPM_LOGS/install.log"
    log_success "Package '$pkg_name-$pkg_version' installed"
}

# ----------------------------------------------------------------------
# Package removal
# ----------------------------------------------------------------------
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
                owners=$(grep "^$f " "$file_index" 2>/dev/null | awk '{print $2}')
                # Only remove if this package is the sole owner
                if [ "$(echo "$owners" | grep -c "$pkg_name")" -eq "$(echo "$owners" | wc -l)" ]; then
                    rm -f "/$f" 2>/dev/null || log_warn "Failed to remove /$f"
                    sed -i "\|^$f $pkg_name-$installed_ver|d" "$file_index"
                else
                    log_verbose "File /$f is shared, not removing"
                fi
            done
        fi

        # Post-remove hook
        if [ -x "$pkg_dir/post-remove.sh" ]; then
            log_info "Running post-remove script"
            (cd "$pkg_dir" && bash post-remove.sh) || log_warn "Post-remove script returned non-zero"
        fi
    fi

    sed -i "/^$pkg_name /d" "$installed_file"
    echo "$(timestamp) - Removed $pkg_name-$installed_ver" >> "$LPM_LOGS/remove.log"
    log_success "Package '$pkg_name' removed"
}

# ----------------------------------------------------------------------
# Update (reinstall) a single package
# ----------------------------------------------------------------------
update_package() {
    local pkg="$1"
    [ -z "$pkg" ] && die "Usage: lpm update <package>"
    if is_installed "$pkg"; then
        remove_package "$pkg"
    fi
    install_package "$pkg"
}

# ----------------------------------------------------------------------
# Upgrade all installed packages that have newer versions
# ----------------------------------------------------------------------
upgrade_all() {
    log_info "Checking for upgradable packages..."
    local upgradable=false
    while read -r line; do
        local name version
        name=$(echo "$line" | awk '{print $1}')
        version=$(echo "$line" | awk '{print $2}')
        local latest
        latest=$(get_pkg_field "$name" version)
        if [ -n "$latest" ] && [ "$version" != "$latest" ]; then
            echo "  $name $version -> $latest"
            upgradable=true
        fi
    done < "$installed_file"

    if ! $upgradable; then
        log_info "All packages are up to date."
        return 0
    fi

    if ! $DRY_RUN; then
        log_info "Upgrading packages..."
        while read -r line; do
            local name version latest
            name=$(echo "$line" | awk '{print $1}')
            version=$(echo "$line" | awk '{print $2}')
            latest=$(get_pkg_field "$name" version)
            if [ -n "$latest" ] && [ "$version" != "$latest" ]; then
                update_package "$name"
            fi
        done < "$installed_file"
    else
        log_info "Dry run complete, no changes made."
    fi
}

# ----------------------------------------------------------------------
# Information and listing
# ----------------------------------------------------------------------
list_packages() {
    if [ ! -s "$installed_file" ]; then
        log_info "No packages installed"
        return
    fi
    echo -e "${C_BLUE}Installed packages:${C_NC}"
    sort "$installed_file" | while read -r name ver; do
        local desc
        desc=$(get_pkg_field "$name" description)
        printf "  %-20s %-10s %s\n" "$name" "$ver" "${desc:-}"
    done
}

search_package() {
    local pattern="$1"
    [ -z "$pattern" ] && die "Usage: lpm search <pattern>"
    echo -e "${C_BLUE}Search results for '$pattern':${C_NC}"
    grep -i "$pattern" "$db_file" 2>/dev/null | while IFS=: read -r name ver desc deps _chk; do
        printf "  %-20s %-10s %s\n" "$name" "$ver" "${desc:-}"
    done || echo "  No matches found"
}

show_info() {
    local pkg="$1"
    [ -z "$pkg" ] && die "Usage: lpm info <package>"
    if ! grep -q "^$pkg:" "$db_file" 2>/dev/null; then
        die "Package '$pkg' not found in database"
    fi
    echo -e "${C_BLUE}Package:${C_NC} $pkg"
    echo -e "${C_BLUE}Version:${C_NC} $(get_pkg_field "$pkg" version)"
    echo -e "${C_BLUE}Description:${C_NC} $(get_pkg_field "$pkg" description)"
    local deps
    deps=$(get_pkg_field "$pkg" dependencies)
    echo -e "${C_BLUE}Dependencies:${C_NC} ${deps:-none}"
    if is_installed "$pkg"; then
        echo -e "${C_BLUE}Status:${C_NC} installed ($(installed_version "$pkg"))"
    else
        echo -e "${C_BLUE}Status:${C_NC} not installed"
    fi
}

# ----------------------------------------------------------------------
# Database update (sync with repositories)
# ----------------------------------------------------------------------
update_db() {
    log_info "Updating package database..."
    # In a real scenario, fetch remote repository indices and merge.
    # For now, just rewrite a sample list (placeholder).
    cat > "$db_file" << EOF
bash:5.3:Bourne Again Shell:readline:sha256-dummy
coreutils:9.4:GNU core utilities:glibc:sha256-dummy
gcc:15.2.0:GNU Compiler Collection:glibc,binutils:sha256-dummy
glibc:2.43:GNU C Library:linux-headers:sha256-dummy
binutils:2.46.0:GNU Binary Utilities:glibc:sha256-dummy
openssl:3.6.1:OpenSSL library:glibc:sha256-dummy
curl:8.5.0:Command line URL fetcher:openssl,glibc:sha256-dummy
linux:6.12.20:Linux kernel::sha256-dummy
EOF
    log_success "Database updated"
}

# ----------------------------------------------------------------------
# Cleanup old package files
# ----------------------------------------------------------------------
clean_cache() {
    log_info "Cleaning package cache..."
    rm -rf "$LPM_PACKAGES_DIR"/*.tar.xz
    log_success "Cache cleaned"
}

# ----------------------------------------------------------------------
# Help
# ----------------------------------------------------------------------
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

Examples:
  lpm install bash
  lpm remove coreutils
  lpm upgrade --dry-run
  lpm search gcc
HELP
}

# ----------------------------------------------------------------------
# Main command dispatcher
# ----------------------------------------------------------------------
main() {
    # Parse global options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=true; shift ;;
            --force)   FORCE=true; shift ;;
            --quiet)   QUIET=true; shift ;;
            --verbose) VERBOSE=true; shift ;;
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
                echo "The following packages would be installed (in order): $pkgs_to_install"
            else
                for p in $pkgs_to_install; do
                    install_package "$p"
                done
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