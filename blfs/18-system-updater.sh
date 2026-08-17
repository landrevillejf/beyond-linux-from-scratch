#!/bin/bash
# System updater for LFS
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

LFS=${LFS:-/output/image}

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_success() { echo "[SUCCESS] $*"; }

# Create required directories
mkdir -pv "$LFS/usr/bin"
mkdir -pv "$LFS/var/lib/lfs-updater"
mkdir -pv "$LFS/var/log"

# Write the actual system updater script
cat >"$LFS/usr/bin/lfs-update" <<'SCRIPT'
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

# Configuration
VERSION_FILE="/etc/lfs-version"
REPO_FILE="/var/lib/lfs-updater/repo.list"
BACKUP_DIR="/var/lib/lfs-updater/backups"

mkdir -p "$(dirname "$VERSION_FILE")" "$(dirname "$REPO_FILE")" "$BACKUP_DIR"

# Get current system version
get_current_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        echo "unknown"
    fi
}

# Check for updates
check_updates() {
    local current_version=$(get_current_version)
    log_info "Current system version: $current_version"

    # Try to read from local repo file first
    if [ -f "$REPO_FILE" ]; then
        local latest=$(grep -E '^LFS_VERSION=' "$REPO_FILE" | cut -d= -f2)
        if [ -n "$latest" ]; then
            if [ "$current_version" != "$latest" ]; then
                log_warn "Update available: $latest (current: $current_version)"
                return 0
            else
                log_success "System is up to date (version $current_version)"
                return 1
            fi
        fi
    fi

    # Fallback: fetch from official LFS site
    local default_url="https://www.linuxfromscratch.org/lfs/view/stable/version.txt"
    log_info "Fetching latest version from $default_url"
    if command -v wget >/dev/null 2>&1; then
        local remote_version=$(wget -qO- "$default_url" 2>/dev/null)
        if [ -n "$remote_version" ]; then
            if [ "$current_version" != "$remote_version" ]; then
                log_warn "Update available: $remote_version (current: $current_version)"
                return 0
            else
                log_success "System is up to date (version $remote_version)"
                return 1
            fi
        fi
    fi

    log_warn "Could not determine latest version"
    return 0
}

# Apply updates
apply_updates() {
    log_info "Starting system update..."

    # Create backup of /etc and /boot
    local backup_name="backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR/$backup_name"
    cp -a /etc "$BACKUP_DIR/$backup_name/"
    cp -a /boot "$BACKUP_DIR/$backup_name/" 2>/dev/null || true
    log_info "Backup saved to $BACKUP_DIR/$backup_name"

    # Use LPM to update packages if available
    if command -v lpm >/dev/null 2>&1; then
        log_info "Updating packages via LPM..."
        lpm update-db
        lpm upgrade
    else
        log_warn "LPM not found; skipping package updates"
    fi

    # Update version file
    echo "13.0" > "$VERSION_FILE"  # Replace with actual detection
    log_success "System update completed"
}

# Main command handler
case "$1" in
    check)
        check_updates
        ;;
    upgrade)
        check_updates && apply_updates
        ;;
    status)
        echo "Current version: $(get_current_version)"
        echo "System status: $(systemctl is-system-running 2>/dev/null || echo 'unknown')"
        ;;
    *)
        echo "Usage: $0 [check|upgrade|status]"
        echo "  check   - Check for available updates"
        echo "  upgrade - Apply available updates"
        echo "  status  - Show system status"
        exit 1
        ;;
esac
SCRIPT

chmod +x "$LFS/usr/bin/lfs-update"

# Create default repo manifest if missing
if [ ! -f "$LFS/var/lib/lfs-updater/repo.list" ]; then
    cat >"$LFS/var/lib/lfs-updater/repo.list" <<'EOF'
LFS_VERSION=13.0
# Additional packages could be listed here
EOF
fi

# Create initial version file if missing
if [ ! -f "$LFS/etc/lfs-version" ]; then
    echo "13.0" >"$LFS/etc/lfs-version"
fi

log_success "System updater installed (lfs-update)"
log_info "Usage: lfs-update [check|upgrade|status]"
