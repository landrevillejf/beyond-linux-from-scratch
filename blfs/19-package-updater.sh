#!/bin/bash
# Package updater for LPM
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

LFS=${LFS:-/output/image}

log_info()    { echo "[INFO] $*"; }
log_error()   { echo "[ERROR] $*" >&2; }
log_success() { echo "[SUCCESS] $*"; }

# Create required directories
mkdir -pv "$LFS/usr/bin"
mkdir -pv "$LFS/var/lib/lpm-updater"
mkdir -pv "$LFS/var/log"

# Write the actual package updater script
cat > "$LFS/usr/bin/lpm-update" << 'SCRIPT'
#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_warn()    { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

# Paths
LPM_DB="/var/lib/lpm"
LPM_PACKAGES_DIR="/usr/share/lpm/packages"
UPDATER_DB="/var/lib/lpm-updater"
mkdir -p "$LPM_DB" "$LPM_PACKAGES_DIR" "$UPDATER_DB"

# Get list of installed packages
get_installed_packages() {
    if [ -f "$LPM_DB/installed.list" ]; then
        cat "$LPM_DB/installed.list" | sort -u
    else
        echo ""
    fi
}

# Check if a package has an update available (dummy check – always true for now)
# This could be extended with real version checks from a repository
has_update() {
    local pkg="$1"
    # For demonstration, we assume every package has an update if a newer source exists.
    # In a real system, you would compare versions from a repo.
    # We'll just check if the package is still installed.
    grep -q "^$pkg$" "$LPM_DB/installed.list" 2>/dev/null
}

# Update a single package
update_package() {
    local pkg="$1"
    if ! command -v lpm >/dev/null 2>&1; then
        log_error "LPM not installed. Cannot update packages."
        return 1
    fi
    if ! grep -q "^$pkg$" "$LPM_DB/installed.list" 2>/dev/null; then
        log_warn "Package '$pkg' is not installed. Skipping."
        return 0
    fi
    log_info "Updating package: $pkg"
    if lpm update "$pkg" 2>&1; then
        log_success "Package '$pkg' updated"
        echo "$(date -Iseconds) - Updated $pkg" >> "$UPDATER_DB/update.log"
    else
        log_error "Failed to update package '$pkg'"
        return 1
    fi
}

# Update all installed packages
update_all() {
    local failed=0
    local packages=$(get_installed_packages)
    if [ -z "$packages" ]; then
        log_info "No packages installed. Nothing to update."
        return 0
    fi
    log_info "Updating all installed packages..."
    echo "$packages" | while read pkg; do
        [ -z "$pkg" ] && continue
        update_package "$pkg" || failed=$((failed + 1))
    done
    if [ $failed -eq 0 ]; then
        log_success "All packages updated successfully"
    else
        log_warn "$failed package(s) failed to update"
        return 1
    fi
}

# List packages with available updates (simplified)
list_outdated() {
    local packages=$(get_installed_packages)
    if [ -z "$packages" ]; then
        log_info "No packages installed."
        return 0
    fi
    echo -e "${BLUE}Checking for outdated packages...${NC}"
    local found=0
    echo "$packages" | while read pkg; do
        [ -z "$pkg" ] && continue
        if has_update "$pkg"; then
            echo "  $pkg (update available)"
            found=$((found + 1))
        fi
    done
    if [ $found -eq 0 ]; then
        log_success "All packages are up to date"
    else
        log_info "$found package(s) have updates available"
    fi
}

# Main command
case "$1" in
    list|outdated)
        list_outdated
        ;;
    update)
        shift
        if [ $# -eq 0 ]; then
            update_all
        else
            for pkg in "$@"; do
                update_package "$pkg"
            done
        fi
        ;;
    *)
        echo "Usage: $0 [list|update [package...]]"
        echo ""
        echo "  list                     Show packages with available updates"
        echo "  update                   Update all packages"
        echo "  update <pkg1> [pkg2...]  Update specific packages"
        exit 1
        ;;
esac
SCRIPT

chmod +x "$LFS/usr/bin/lpm-update"

# Create initial log file
touch "$LFS/var/lib/lpm-updater/update.log"

log_success "Package updater installed (lpm-update)"
log_info "Usage: lpm-update [list|update [package...]]"