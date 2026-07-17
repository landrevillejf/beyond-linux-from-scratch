#!/bin/bash
# Apply LFS branding - themes, wallpapers, and customizations
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LFS=${LFS:-/mnt/lfs}
BRANDING_DIR="${SCRIPT_DIR}/../branding/default"

# Source utilities if available
if [ -f "$SCRIPT_DIR/../common/utils.sh" ]; then
    source "$SCRIPT_DIR/../common/utils.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warning() { echo "[WARNING] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
fi

log_info "Applying LFS branding and customizations"
log_info "LFS: $LFS"
log_info "Branding source: $BRANDING_DIR"

# Check if LFS directory exists
if [ ! -d "$LFS" ]; then
    log_error "LFS directory does not exist: $LFS"
    exit 1
fi

# Install GTK themes
install_gtk_themes() {
    log_info "Installing GTK themes..."
    
    # Create GTK theme directories
    mkdir -p "$LFS/usr/share/themes/LFS-Dark/gtk-3.0"
    mkdir -p "$LFS/usr/share/themes/LFS-Dark/gtk-4.0"
    mkdir -p "$LFS/usr/share/themes/LFS-Light/gtk-3.0"
    mkdir -p "$LFS/usr/share/themes/LFS-Light/gtk-4.0"
    
    # Copy GTK3 and GTK4 CSS files
    if [ -f "$BRANDING_DIR/themes/gtk-3.20/gtk.css" ]; then
        cp "$BRANDING_DIR/themes/gtk-3.20/gtk.css" "$LFS/usr/share/themes/LFS-Dark/gtk-3.0/gtk.css"
        cp "$BRANDING_DIR/themes/gtk-3.20/gtk.css" "$LFS/usr/share/themes/LFS-Light/gtk-3.0/gtk.css"
        log_success "GTK3 CSS installed"
    fi
    
    if [ -f "$BRANDING_DIR/themes/gtk-4.0/gtk.css" ]; then
        cp "$BRANDING_DIR/themes/gtk-4.0/gtk.css" "$LFS/usr/share/themes/LFS-Dark/gtk-4.0/gtk.css"
        cp "$BRANDING_DIR/themes/gtk-4.0/gtk.css" "$LFS/usr/share/themes/LFS-Light/gtk-4.0/gtk.css"
        log_success "GTK4 CSS installed"
    fi
    
    # Install theme index files
    if [ -f "$BRANDING_DIR/themes/LFS-Dark/index.theme" ]; then
        cp "$BRANDING_DIR/themes/LFS-Dark/index.theme" "$LFS/usr/share/themes/LFS-Dark/index.theme"
    fi
    
    if [ -f "$BRANDING_DIR/themes/LFS-Light/index.theme" ]; then
        cp "$BRANDING_DIR/themes/LFS-Light/index.theme" "$LFS/usr/share/themes/LFS-Light/index.theme"
    fi
}

# Install wallpapers
install_wallpapers() {
    log_info "Installing wallpapers..."
    
    mkdir -p "$LFS/usr/share/backgrounds/lfs"
    
    if [ -d "$BRANDING_DIR/wallpaper" ]; then
        cp "$BRANDING_DIR/wallpaper"/*.png "$LFS/usr/share/backgrounds/lfs/" 2>/dev/null || log_warning "No wallpapers found"
        
        # Set default wallpaper
        if [ -f "$LFS/usr/share/backgrounds/lfs/lfs-wallpaper.png" ]; then
            ln -sf /usr/share/backgrounds/lfs/lfs-wallpaper.png "$LFS/usr/share/backgrounds/xfce/xfce-default.png" 2>/dev/null || true
        fi
        
        log_success "Wallpapers installed ($(find "$LFS/usr/share/backgrounds/lfs" -name "*.png" 2>/dev/null | wc -l) files)"
    else
        log_warning "Wallpaper directory not found: $BRANDING_DIR/wallpaper"
    fi
}

# Configure XFCE branding
configure_xfce_branding() {
    log_info "Configuring XFCE branding..."
    
    mkdir -p "$LFS/etc/xdg/xfce4"
    
    # Create xfce4-panel configuration
    if [ -f "$BRANDING_DIR/themes/xfce.xml" ]; then
        cp "$BRANDING_DIR/themes/xfce.xml" "$LFS/etc/xdg/xfce4/xfce-theme.xml"
        log_success "XFCE theme configuration installed"
    fi
}

# Configure GNOME branding
configure_gnome_branding() {
    log_info "Configuring GNOME branding..."
    
    mkdir -p "$LFS/etc/dconf/db/local.d"
    
    cat > "$LFS/etc/dconf/db/local.d/01-lfs-branding" << 'EOF'
[org/gnome/desktop/interface]
gtk-theme='LFS-Dark'
icon-theme='Papirus-Dark'

[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/lfs/lfs-wallpaper.png'
picture-uri-dark='file:///usr/share/backgrounds/lfs/lfs-wallpaper.png'

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/backgrounds/lfs/lfs-wallpaper.png'
EOF
    
    log_success "GNOME theme configuration installed"
}

# Configure system wallpaper
configure_wallpaper() {
    log_info "Configuring system wallpaper..."
    
    # For lightdm/XFCE default
    mkdir -p "$LFS/etc/lightdm"
    
    if [ -f "$LFS/usr/share/backgrounds/lfs/lfs-wallpaper.png" ]; then
        cat >> "$LFS/etc/lightdm/lightdm-gtk-greeter.conf" << 'EOF'
[greeter]
background=/usr/share/backgrounds/lfs/lfs-wallpaper.png
theme-name=LFS-Dark
icon-theme-name=Papirus-Dark
EOF
        log_success "Wallpaper configured for login screen"
    fi
}

# Set default GSSettings for user
configure_user_settings() {
    log_info "Configuring user theme preferences..."
    
    mkdir -p "$LFS/home/lfsuser/.config/dconf"
    
    cat > "$LFS/home/lfsuser/.config/dconf/user-branding" << 'EOF'
[org/gnome/desktop/interface]
gtk-theme='LFS-Dark'
icon-theme='Papirus-Dark'

[org/xfce4/xfwm4]
theme='LFS-Dark'

[org/xfce4/panel/profiles/default]
background-color='#0a0a14'
background-alpha=100
EOF
    
    # Make symlinks for common config locations
    mkdir -p "$LFS/root/.config/dconf"
    cp "$LFS/home/lfsuser/.config/dconf/user-branding" "$LFS/root/.config/dconf/user-branding" 2>/dev/null || true
    
    log_success "User branding preferences configured"
}

# Persist all builder-provided parameters for traceability and downstream scripts
write_builder_parameters_snapshot() {
    log_info "Saving builder parameter snapshot..."
    mkdir -p "$LFS/etc"
    env | LC_ALL=C sort | awk '
        /^LFS=/ ||
        /^LFS_TGT=/ ||
        /^MAKEFLAGS=/ ||
        /^PROFILE=/ ||
        /^INIT_SYSTEM=/ ||
        /^SYSVINIT_STYLE=/ ||
        /^PARALLEL_STARTUP=/ ||
        /^AUTO_RESTART=/ ||
        /^JAVA_DEV=/ ||
        /^LPM_ENABLED=/ ||
        /^SECURITY_HARDENING=/ ||
        /^PRIVACY_TOOLS=/ ||
        /^LIVE_SYSTEM=/ ||
        /^KERNEL_TYPE=/ ||
        /^SYSTEM_UPDATER=/ ||
        /^LFS_VERSION=/ ||
        /^LFS_CONFIG_/ ||
        /^LFS_PROFILE_/
    ' > "$LFS/etc/lfs-builder-params.env"
    log_success "Builder parameters saved to /etc/lfs-builder-params.env"
}

# Install splash screens and logos
install_branding_assets() {
    log_info "Installing branding assets..."
    
    mkdir -p "$LFS/usr/share/pixmaps/lfs"
    mkdir -p "$LFS/boot"
    
    if [ -d "$BRANDING_DIR/logo" ]; then
        cp "$BRANDING_DIR/logo"/* "$LFS/usr/share/pixmaps/lfs/" 2>/dev/null || true
        log_success "Logos and splash screens installed"
    fi
}

# Main execution
log_info "Starting LFS branding installation..."

install_gtk_themes
install_wallpapers
configure_xfce_branding
configure_gnome_branding
configure_wallpaper
configure_user_settings
write_builder_parameters_snapshot
install_branding_assets

log_success "LFS branding successfully applied!"
log_info "Themes: LFS-Dark and LFS-Light installed"
log_info "Wallpapers: Installed to /usr/share/backgrounds/lfs/"
log_info "XFCE: Configured with LFS branding"
log_info "GNOME: Configured with LFS branding"
log_info "User preferences: Applied to lfsuser and root"

exit 0
