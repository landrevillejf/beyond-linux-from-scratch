#!/bin/bash
# theme-setup.sh - Applies theme and customizations.
# Uses resources from packages/custom-scripts/

set -e

log_info()    { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;34m[SUCCESS]\033[0m $1"; }
log_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }
log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; exit 1; }

# ============================================================================
# LOAD CONFIGURATION
# ============================================================================
# Read builder configuration if available
CONFIG_FILE="/etc/lfs-build.json"
if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
    DESKTOP_TYPE=$(jq -r '.desktop.type // "xfce"' "$CONFIG_FILE")
    THEME_NAME=$(jq -r '.branding.gtk_theme // "Arc-Dark"' "$CONFIG_FILE")
    ICON_THEME=$(jq -r '.branding.icon_theme // "Papirus"' "$CONFIG_FILE")
    FONT_NAME=$(jq -r '.desktop.font // "Noto Sans 10"' "$CONFIG_FILE")
    WALLPAPER_SRC=$(jq -r '.branding.wallpaper // ""' "$CONFIG_FILE")
else
    # Fallback to environment variables or defaults
    DESKTOP_TYPE="${DESKTOP_TYPE:-xfce}"
    THEME_NAME="${THEME_NAME:-Arc-Dark}"
    ICON_THEME="${ICON_THEME:-Papirus}"
    FONT_NAME="${FONT_NAME:-Noto Sans 10}"
    WALLPAPER_SRC="${WALLPAPER_SRC:-}"
fi

# Custom resources directory
CUSTOM_DIR="/packages/custom-scripts/wallpaper"

# Override wallpaper if a custom file exists in the custom directory
if [ -z "$WALLPAPER_SRC" ] && [ -f "$CUSTOM_DIR/lfs-wallpaper.png" ]; then
    WALLPAPER_SRC="$CUSTOM_DIR/lfs-wallpaper.png"
fi

# Target paths
TARGET_WALLPAPER="/usr/share/backgrounds/default.jpg"
TARGET_LOGO="/usr/share/icons/hicolor/256x256/apps/lfs-logo.png"
TARGET_CONFIG_DIR="/etc/skel/.config"

# ============================================================================
# INSTALL FONTS
# ============================================================================
install_fonts() {
    log_info "Installing fonts..."

    mkdir -p /usr/share/fonts/{TTF,OTF,Type1}

    cd /sources || { log_warning "/sources directory not found, skipping fonts."; return; }

    # Cascadia Code (Nerd Font)
    if [ ! -f CascadiaCode.zip ]; then
        wget -q https://github.com/ryanoasis/nerd-fonts/releases/download/v3.2.1/CascadiaCode.zip || log_warning "Failed to download Cascadia Code."
    fi
    if [ -f CascadiaCode.zip ]; then
        unzip -qo CascadiaCode.zip -d /usr/share/fonts/TTF/ 2>/dev/null || true
    fi

    # Noto Sans
    if [ ! -f NotoSans-hinted.zip ]; then
        wget -q https://noto-website-2.storage.googleapis.com/pkgs/NotoSans-hinted.zip || log_warning "Failed to download Noto Sans."
    fi
    if [ -f NotoSans-hinted.zip ]; then
        unzip -qo NotoSans-hinted.zip -d /usr/share/fonts/TTF/ 2>/dev/null || true
    fi

    fc-cache -fv > /dev/null 2>&1 || true
    log_success "Fonts installed."
}

# ============================================================================
# INSTALL ICON THEMES
# ============================================================================
install_icon_themes() {
    log_info "Installing icon themes..."

    cd /sources || { log_warning "/sources not found, skipping icon themes."; return; }

    # Papirus
    if [ ! -f Papirus-20231201.tar.gz ]; then
        wget -q https://github.com/PapirusDevelopmentTeam/papirus-icon-theme/archive/20231201/Papirus-20231201.tar.gz || log_warning "Failed to download Papirus."
    fi
    if [ -f Papirus-20231201.tar.gz ]; then
        tar -xzf Papirus-20231201.tar.gz 2>/dev/null || true
        cd papirus-icon-theme-20231201 2>/dev/null && ./install.sh > /dev/null 2>&1 && cd ..
    fi

    log_success "Icon themes installed."
}

# ============================================================================
# INSTALL GTK THEMES
# ============================================================================
install_gtk_themes() {
    log_info "Installing GTK themes..."

    cd /sources || { log_warning "/sources not found, skipping GTK themes."; return; }

    # Arc Theme
    if [ ! -f arc-theme-20221218.tar.gz ]; then
        wget -q https://github.com/jnsh/arc-theme/archive/refs/tags/20221218.tar.gz -O arc-theme-20221218.tar.gz || log_warning "Failed to download Arc theme."
    fi
    if [ -f arc-theme-20221218.tar.gz ]; then
        tar -xzf arc-theme-20221218.tar.gz 2>/dev/null || true
        cd arc-theme-20221218 2>/dev/null && {
            ./autogen.sh --prefix=/usr > /dev/null 2>&1
            make -j$(nproc) > /dev/null 2>&1
            make install > /dev/null 2>&1
            cd ..
        }
    fi

    log_success "GTK themes installed."
}

# ============================================================================
# INSTALL CUSTOM RESOURCES
# ============================================================================
install_custom_resources() {
    log_info "Installing custom resources..."

    # Wallpaper
    if [ -n "$WALLPAPER_SRC" ] && [ -f "$WALLPAPER_SRC" ]; then
        install -Dm644 "$WALLPAPER_SRC" "$TARGET_WALLPAPER"
        log_success "Custom wallpaper installed."
    else
        log_info "No custom wallpaper found, using default."
        mkdir -p /usr/share/backgrounds
        cd /usr/share/backgrounds
        if [ ! -f default.jpg ]; then
            wget -q -O default.jpg https://images.pexels.com/photos/147411/italy-mountains-dawn-daybreak-147411.jpeg || true
        fi
    fi

    # Logo
    if [ -f "$CUSTOM_DIR/logo.png" ]; then
        install -Dm644 "$CUSTOM_DIR/logo.png" "$TARGET_LOGO"
        for size in 48 64 128; do
            mkdir -p "/usr/share/icons/hicolor/${size}x${size}/apps/"
            cp "$TARGET_LOGO" "/usr/share/icons/hicolor/${size}x${size}/apps/lfs-logo.png"
        done
        log_success "Logo installed."
    fi

    # Custom configuration file (optional)
    if [ -f "$CUSTOM_DIR/custom-settings.conf" ]; then
        install -Dm644 "$CUSTOM_DIR/custom-settings.conf" /etc/lfs-custom.conf
        log_success "Custom configuration installed."
    fi
}

# ============================================================================
# CONFIGURE GTK
# ============================================================================
configure_gtk() {
    log_info "Configuring GTK..."

    # GTK 2
    mkdir -p /etc/gtk-2.0
    cat > /etc/gtk-2.0/gtkrc << EOF
gtk-theme-name="$THEME_NAME"
gtk-icon-theme-name="$ICON_THEME"
gtk-font-name="$FONT_NAME"
gtk-toolbar-style=GTK_TOOLBAR_ICONS
gtk-enable-event-sounds=0
gtk-enable-input-feedback-sounds=0
EOF

    # GTK 3 & 4
    for gtk_ver in 3.0 4.0; do
        mkdir -p "/etc/gtk-$gtk_ver"
        cat > "/etc/gtk-$gtk_ver/settings.ini" << EOF
[Settings]
gtk-theme-name=$THEME_NAME
gtk-icon-theme-name=$ICON_THEME
gtk-font-name=$FONT_NAME
gtk-cursor-theme-name=Adwaita
gtk-toolbar-style=GTK_TOOLBAR_BOTH_HORIZ
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintfull
gtk-xft-rgba=rgb
EOF
    done

    # Apply to root
    mkdir -p /root/.config/gtk-3.0
    cp /etc/gtk-3.0/settings.ini /root/.config/gtk-3.0/

    # Apply to skeleton for new users
    mkdir -p /etc/skel/.config/gtk-3.0
    cp /etc/gtk-3.0/settings.ini /etc/skel/.config/gtk-3.0/

    log_success "GTK configured."
}

# ============================================================================
# CONFIGURE DESKTOP-SPECIFIC SETTINGS
# ============================================================================
configure_desktop() {
    log_info "Configuring desktop: $DESKTOP_TYPE"

    case "$DESKTOP_TYPE" in
        xfce|xfce4)
            mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/

            # XFCE wallpaper
            cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml << EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="$TARGET_WALLPAPER"/>
          <property name="image-style" type="int" value="5"/>
          <property name="image-show" type="bool" value="true"/>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF

            # XFWM theme
            cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml << EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="$THEME_NAME"/>
    <property name="title_font" type="string" value="$FONT_NAME"/>
  </property>
</channel>
EOF
            ;;

        gnome)
            if command -v dconf >/dev/null 2>&1; then
                dconf write /org/gnome/desktop/background/picture-uri "'file://$TARGET_WALLPAPER'" 2>/dev/null || true
                dconf write /org/gnome/desktop/background/picture-uri-dark "'file://$TARGET_WALLPAPER'" 2>/dev/null || true
                dconf write /org/gnome/desktop/interface/gtk-theme "'$THEME_NAME'" 2>/dev/null || true
                dconf write /org/gnome/desktop/interface/icon-theme "'$ICON_THEME'" 2>/dev/null || true
                dconf write /org/gnome/desktop/interface/font-name "'$FONT_NAME'" 2>/dev/null || true
            else
                log_warning "dconf not found, GNOME settings not applied."
            fi
            ;;

        kde|plasma)
            if command -v plasmashell >/dev/null 2>&1; then
                cat > /etc/skel/.config/kdeglobals << EOF
[General]
ColorScheme=BreezeDark
Name=$THEME_NAME
IconTheme=$ICON_THEME
font=$FONT_NAME
EOF
            else
                log_warning "plasmashell not found, KDE settings not applied."
            fi
            ;;

        *)
            log_info "Desktop $DESKTOP_TYPE not supported for automatic configuration."
            ;;
    esac

    log_success "Desktop configured."
}

# ============================================================================
# CONFIGURE DISPLAY MANAGER
# ============================================================================
configure_display_manager() {
    log_info "Configuring display manager..."

    # LightDM
    if command -v lightdm >/dev/null 2>&1; then
        cat > /etc/lightdm/lightdm-gtk-greeter.conf << EOF
[greeter]
theme-name=$THEME_NAME
icon-theme-name=$ICON_THEME
font-name=$FONT_NAME
background=$TARGET_WALLPAPER
logo=$TARGET_LOGO
EOF
        log_success "LightDM configured."
    fi

    # SDDM
    if command -v sddm >/dev/null 2>&1; then
        cat > /etc/sddm.conf << EOF
[Theme]
Current=breeze
CursorTheme=Adwaita
Font=$FONT_NAME
EOF
        log_success "SDDM configured."
    fi
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    log_info "=== THEME SETUP STARTING ==="

    install_fonts
    install_icon_themes
    install_gtk_themes
    install_custom_resources
    configure_gtk
    configure_desktop
    configure_display_manager

    # Apply to existing lfsuser if present
    if [ -d /home/lfsuser ]; then
        cp -r /etc/skel/.config/* /home/lfsuser/.config/ 2>/dev/null || true
        chown -R lfsuser:lfsuser /home/lfsuser/.config 2>/dev/null || true
    fi

    log_success "=== THEME SETUP COMPLETED ==="
}

main "$@"