#!/bin/bash
# System updater for LFS
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

# Re-launch with sudo if not root (preserve environment).  Every write below
# lands inside $LFS, whose /usr, /etc and /var were populated as root by the
# earlier stages, so the unprivileged builder user cannot create them.  Same
# class as the branding stage (Nightly #214).
if [ "$EUID" -ne 0 ]; then
    echo "[INFO] Relaunching with sudo..."
    exec sudo -E "$0" "$@"
fi

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

# Fetch a URL to stdout: curl first, wget fallback.
fetch_url() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$url"
    else
        return 1
    fi
}

# Count packages lpm could upgrade (0 when lpm is missing).
count_upgradable() {
    if command -v lpm >/dev/null 2>&1; then
        lpm upgradable --no-color 2>/dev/null | grep -c ' -> ' || true
    else
        echo 0
    fi
}

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

    if command -v lpm >/dev/null 2>&1; then
        log_info "Package updates available: $(count_upgradable)"
    fi

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
    local remote_version
    if remote_version=$(fetch_url "$default_url" 2>/dev/null) && [ -n "$remote_version" ]; then
        if [ "$current_version" != "$remote_version" ]; then
            log_warn "Update available: $remote_version (current: $current_version)"
            return 0
        else
            log_success "System is up to date (version $remote_version)"
            return 1
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

    # Record kernel version before update
    local old_kernel=""
    if [ -f /boot/vmlinuz ]; then
        old_kernel=$(readlink -f /boot/vmlinuz 2>/dev/null | sed 's/.*vmlinuz-//' || uname -r 2>/dev/null || true)
    fi

    # Use LPM to update packages if available
    if command -v lpm >/dev/null 2>&1; then
        log_info "Updating packages via LPM..."
        lpm update-db
        lpm upgrade

        # Check if kernel was updated and rebuild kernel-dependent packages
        local new_kernel=""
        if [ -f /boot/vmlinuz ]; then
            new_kernel=$(readlink -f /boot/vmlinuz 2>/dev/null | sed 's/.*vmlinuz-//' || uname -r 2>/dev/null || true)
        fi

        if [ -n "$old_kernel" ] && [ -n "$new_kernel" ] && [ "$old_kernel" != "$new_kernel" ]; then
            log_warn "Kernel changed: $old_kernel -> $new_kernel"
            log_info "Checking for kernel-dependent packages that need rebuilding..."
            lpm kernel-deps
            log_info "Rebuilding kernel-dependent packages..."
            lpm rebuild-kernel || log_warn "Some kernel-dependent packages failed to rebuild"
            # Update bootloader config
            if command -v grub-mkconfig >/dev/null 2>&1; then
                log_info "Updating bootloader configuration..."
                grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || log_warn "Failed to update GRUB config"
            fi
        fi
    else
        log_warn "LPM not found; skipping package updates"
    fi

    # Update the version marker only when the repo manifest declares a
    # version; never overwrite it with a hardcoded value.
    local declared_version
    declared_version=$(grep -E '^LFS_VERSION=' "$REPO_FILE" 2>/dev/null | head -1 | cut -d= -f2 || true)
    if [ -n "$declared_version" ]; then
        echo "$declared_version" > "$VERSION_FILE"
    fi
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
        if command -v lpm >/dev/null 2>&1; then
            echo "Installed packages: $(lpm list --no-color 2>/dev/null | grep -c '^  ' || true)"
            echo "Upgradable packages: $(count_upgradable)"
        else
            echo "LPM: not installed"
        fi
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

# Optional weekly update check, only on systems that ship cron.weekly
# (nothing is scheduled on minimal images without cron).
if [ -d "$LFS/etc/cron.weekly" ]; then
    cat >"$LFS/etc/cron.weekly/lfs-update-check" <<'CRON'
#!/bin/sh
/usr/bin/lfs-update check >>/var/log/lfs-update-check.log 2>&1 || true
CRON
    chmod 0755 "$LFS/etc/cron.weekly/lfs-update-check"
    log_info "Weekly update check installed: /etc/cron.weekly/lfs-update-check"
fi

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
