#!/bin/bash
# Apply LFS branding - themes, wallpapers, and desktop customizations
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LFS="${LFS:-/mnt/lfs}"

# Source utilities if available
if [ -f "$SCRIPT_DIR/../common/utils.sh" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/../common/utils.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warning() { echo "[WARNING] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
fi

if [ ! -d "$LFS" ]; then
    log_error "LFS directory does not exist: $LFS"
    exit 1
fi

to_lower() {
    echo "${1:-}" | tr '[:upper:]' '[:lower:]'
}

is_true() {
    case "$(to_lower "${1:-}")" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
    esac
}

fail_or_warn() {
    local message="$1"
    if is_true "$BRANDING_STRICT"; then
        log_error "$message"
        exit 1
    fi
    log_warning "$message"
}

resolve_branding_dir() {
    BRANDING_PRESET="${LFS_CONFIG_BRANDING_PRESET:-default}"
    local override="${LFS_CONFIG_BRANDING_DIR:-}"
    local repo_root="$SCRIPT_DIR/.."

    if [ -n "$override" ]; then
        if [[ $override == /* ]]; then
            BRANDING_DIR="$override"
        else
            BRANDING_DIR="$repo_root/$override"
        fi
    else
        BRANDING_DIR="$repo_root/branding/$BRANDING_PRESET"
    fi

    if [ ! -d "$BRANDING_DIR" ]; then
        fail_or_warn "Branding directory not found: $BRANDING_DIR. Falling back to branding/default."
        BRANDING_DIR="$repo_root/branding/default"
    fi

    if [ ! -d "$BRANDING_DIR" ]; then
        log_error "No usable branding directory found."
        exit 1
    fi
}

resolve_branding_settings() {
    resolve_branding_dir

    BRANDING_THEME_VARIANT="$(to_lower "${LFS_CONFIG_BRANDING_THEME_VARIANT:-dark}")"
    case "$BRANDING_THEME_VARIANT" in
    dark | light) ;;
    *)
        fail_or_warn "Invalid branding theme_variant '$BRANDING_THEME_VARIANT', using 'dark'."
        BRANDING_THEME_VARIANT="dark"
        ;;
    esac

    if [ "$BRANDING_THEME_VARIANT" = "light" ]; then
        DEFAULT_GTK_THEME="LFS-Light"
        DEFAULT_ICON_THEME="Papirus"
    else
        DEFAULT_GTK_THEME="LFS-Dark"
        DEFAULT_ICON_THEME="Papirus-Dark"
    fi

    GTK_THEME="${LFS_CONFIG_BRANDING_GTK_THEME:-$DEFAULT_GTK_THEME}"
    ICON_THEME="${LFS_CONFIG_BRANDING_ICON_THEME:-$DEFAULT_ICON_THEME}"
    WALLPAPER_SETTING="${LFS_CONFIG_BRANDING_WALLPAPER:-lfs-wallpaper.png}"
    APPLY_DESKTOPS_RAW="$(to_lower "${LFS_CONFIG_BRANDING_APPLY_DESKTOPS:-auto}")"
    BRANDING_STRICT="${LFS_CONFIG_BRANDING_STRICT:-false}"
    PROFILE_DESKTOP="$(to_lower "${LFS_PROFILE_DESKTOP:-}")"
}

resolve_wallpaper_path() {
    local source=""
    local candidate=""

    if [[ $WALLPAPER_SETTING == /* ]]; then
        source="$WALLPAPER_SETTING"
    else
        candidate="$BRANDING_DIR/wallpaper/$WALLPAPER_SETTING"
        if [ -f "$candidate" ]; then
            source="$candidate"
        fi
    fi

    if [ -z "$source" ] && [ -f "$BRANDING_DIR/wallpaper/lfs-wallpaper.png" ]; then
        source="$BRANDING_DIR/wallpaper/lfs-wallpaper.png"
    fi

    if [ -z "$source" ] && [ -d "$BRANDING_DIR/wallpaper" ]; then
        source="$(find "$BRANDING_DIR/wallpaper" -maxdepth 1 -type f -name '*.png' | head -n1)"
    fi

    if [ -z "$source" ]; then
        fail_or_warn "No wallpaper source found in $BRANDING_DIR/wallpaper"
    fi

    BRANDING_WALLPAPER_SOURCE="$source"
    BRANDING_WALLPAPER_TARGET="/usr/share/backgrounds/lfs/$(basename "${source:-lfs-wallpaper.png}")"
}

should_apply_desktop() {
    local target="$1"
    local selected="$APPLY_DESKTOPS_RAW"

    if [ "$selected" = "all" ]; then
        return 0
    fi

    if [ "$selected" = "auto" ]; then
        if [ -n "$PROFILE_DESKTOP" ] && [ "$PROFILE_DESKTOP" != "none" ]; then
            selected="$PROFILE_DESKTOP"
        else
            selected="xfce,gnome"
        fi
    fi

    if echo "$selected" | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -qx "$target"; then
        return 0
    fi
    return 1
}

install_gtk_themes() {
    log_info "Installing GTK themes from $BRANDING_DIR..."
    mkdir -p "$LFS/usr/share/themes/LFS-Dark/gtk-3.0"
    mkdir -p "$LFS/usr/share/themes/LFS-Dark/gtk-4.0"
    mkdir -p "$LFS/usr/share/themes/LFS-Light/gtk-3.0"
    mkdir -p "$LFS/usr/share/themes/LFS-Light/gtk-4.0"

    if [ -f "$BRANDING_DIR/themes/gtk-3.20/gtk.css" ]; then
        cp "$BRANDING_DIR/themes/gtk-3.20/gtk.css" "$LFS/usr/share/themes/LFS-Dark/gtk-3.0/gtk.css"
        cp "$BRANDING_DIR/themes/gtk-3.20/gtk.css" "$LFS/usr/share/themes/LFS-Light/gtk-3.0/gtk.css"
    else
        fail_or_warn "Missing GTK3 CSS: $BRANDING_DIR/themes/gtk-3.20/gtk.css"
    fi

    if [ -f "$BRANDING_DIR/themes/gtk-4.0/gtk.css" ]; then
        cp "$BRANDING_DIR/themes/gtk-4.0/gtk.css" "$LFS/usr/share/themes/LFS-Dark/gtk-4.0/gtk.css"
        cp "$BRANDING_DIR/themes/gtk-4.0/gtk.css" "$LFS/usr/share/themes/LFS-Light/gtk-4.0/gtk.css"
    else
        fail_or_warn "Missing GTK4 CSS: $BRANDING_DIR/themes/gtk-4.0/gtk.css"
    fi

    if [ -f "$BRANDING_DIR/themes/LFS-Dark/index.theme" ]; then
        cp "$BRANDING_DIR/themes/LFS-Dark/index.theme" "$LFS/usr/share/themes/LFS-Dark/index.theme"
    fi
    if [ -f "$BRANDING_DIR/themes/LFS-Light/index.theme" ]; then
        cp "$BRANDING_DIR/themes/LFS-Light/index.theme" "$LFS/usr/share/themes/LFS-Light/index.theme"
    fi

    log_success "GTK themes installed"
}

install_wallpapers() {
    log_info "Installing wallpapers..."
    mkdir -p "$LFS/usr/share/backgrounds/lfs"

    if [ -d "$BRANDING_DIR/wallpaper" ]; then
        find "$BRANDING_DIR/wallpaper" -maxdepth 1 -type f -name '*.png' -exec cp {} "$LFS/usr/share/backgrounds/lfs/" \;
    else
        fail_or_warn "Wallpaper directory not found: $BRANDING_DIR/wallpaper"
    fi

    if [ -n "${BRANDING_WALLPAPER_SOURCE:-}" ] && [ -f "$BRANDING_WALLPAPER_SOURCE" ]; then
        cp "$BRANDING_WALLPAPER_SOURCE" "$LFS${BRANDING_WALLPAPER_TARGET}"
    fi

    log_success "Wallpapers installed"
}

configure_xfce_branding() {
    should_apply_desktop "xfce" || return 0
    log_info "Applying XFCE branding..."

    mkdir -p "$LFS/etc/xdg/xfce4"
    mkdir -p "$LFS/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"

    if [ -f "$BRANDING_DIR/themes/xfce.xml" ]; then
        cp "$BRANDING_DIR/themes/xfce.xml" "$LFS/etc/xdg/xfce4/xfce-theme.xml"
    fi

    cat >"$LFS/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="$GTK_THEME"/>
    <property name="IconThemeName" type="string" value="$ICON_THEME"/>
  </property>
</channel>
EOF
}

configure_gnome_branding() {
    should_apply_desktop "gnome" || return 0
    log_info "Applying GNOME branding..."

    mkdir -p "$LFS/etc/dconf/db/local.d"
    cat >"$LFS/etc/dconf/db/local.d/01-lfs-branding" <<EOF
[org/gnome/desktop/interface]
gtk-theme='$GTK_THEME'
icon-theme='$ICON_THEME'

[org/gnome/desktop/background]
picture-uri='file://${BRANDING_WALLPAPER_TARGET}'
picture-uri-dark='file://${BRANDING_WALLPAPER_TARGET}'

[org/gnome/desktop/screensaver]
picture-uri='file://${BRANDING_WALLPAPER_TARGET}'
EOF
}

configure_kde_branding() {
    should_apply_desktop "kde" || return 0
    log_info "Applying KDE branding..."

    mkdir -p "$LFS/etc/xdg"
    mkdir -p "$LFS/etc/xdg/plasma-workspace/env"

    cat >"$LFS/etc/xdg/kdeglobals" <<EOF
[Icons]
Theme=$ICON_THEME

[KDE]
widgetStyle=Breeze
EOF

    cat >"$LFS/etc/xdg/plasma-workspace/env/lfs-branding.sh" <<EOF
export GTK_THEME="$GTK_THEME"
export XDG_CURRENT_DESKTOP="\${XDG_CURRENT_DESKTOP:-KDE}"
EOF
}

configure_lxqt_branding() {
    should_apply_desktop "lxqt" || return 0
    log_info "Applying LXQt branding..."

    mkdir -p "$LFS/etc/xdg/lxqt"
    cat >"$LFS/etc/xdg/lxqt/lxqt.conf" <<EOF
[General]
theme=$GTK_THEME
icon_theme=$ICON_THEME
EOF
}

configure_phosh_branding() {
    should_apply_desktop "phosh" || return 0
    log_info "Applying Phosh branding..."
    mkdir -p "$LFS/etc/skel/.config/phosh"
    cat >"$LFS/etc/skel/.config/phosh/phoc.ini" <<EOF
[output:default]
bg-color=0a0a14ff
EOF
}

configure_display_manager() {
    log_info "Configuring display manager branding..."
    mkdir -p "$LFS/etc/lightdm"

    cat >"$LFS/etc/lightdm/lightdm-gtk-greeter.conf" <<EOF
[greeter]
background=${BRANDING_WALLPAPER_TARGET}
theme-name=${GTK_THEME}
icon-theme-name=${ICON_THEME}
EOF
}

configure_user_defaults() {
    log_info "Configuring user defaults..."
    mkdir -p "$LFS/etc/skel/.config"
    mkdir -p "$LFS/home/lfsuser/.config"
    mkdir -p "$LFS/root/.config"

    cat >"$LFS/etc/skel/.config/lfs-branding.conf" <<EOF
GTK_THEME=$GTK_THEME
ICON_THEME=$ICON_THEME
WALLPAPER=$BRANDING_WALLPAPER_TARGET
PRESET=$BRANDING_PRESET
EOF

    cp "$LFS/etc/skel/.config/lfs-branding.conf" "$LFS/home/lfsuser/.config/lfs-branding.conf" 2>/dev/null || true
    cp "$LFS/etc/skel/.config/lfs-branding.conf" "$LFS/root/.config/lfs-branding.conf" 2>/dev/null || true
}

install_branding_assets() {
    log_info "Installing branding assets..."
    mkdir -p "$LFS/usr/share/pixmaps/lfs"
    mkdir -p "$LFS/boot"

    if [ -d "$BRANDING_DIR/logo" ]; then
        cp "$BRANDING_DIR/logo"/* "$LFS/usr/share/pixmaps/lfs/" 2>/dev/null || true
    fi
}

generate_wallpapers_if_needed() {
    local repo_root="$SCRIPT_DIR/.."
    local generator="$repo_root/wblfs-wallpaper-generator.py"
    local output_dir="$BRANDING_DIR/wallpaper"

    if [ ! -f "$generator" ]; then
        log_warning "Wallpaper generator not found: $generator"
        return 0
    fi

    if is_true "${LFS_CONFIG_BRANDING_GENERATE_WALLPAPERS:-false}"; then
        log_info "Generating wallpapers with $generator..."
        if python3 "$generator" \
            --output "$output_dir" \
            --variants "${LFS_CONFIG_BRANDING_WALLPAPER_VARIANTS:-15}" \
            --include-logo \
            --include-branding 2>&1 | while read -r line; do
            log_info "  $line"
        done; then
            log_success "Wallpapers generated successfully"
        else
            log_warning "Wallpaper generation failed, continuing with existing wallpapers"
        fi
    fi
}

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
    ' >"$LFS/etc/lfs-builder-params.env"
    log_success "Builder parameters saved to /etc/lfs-builder-params.env"
}

write_branding_manifest() {
    log_info "Writing branding manifest..."
    local manifest="$LFS/etc/lfs-branding-manifest.txt"

    {
        echo "preset=$BRANDING_PRESET"
        echo "branding_dir=$BRANDING_DIR"
        echo "theme_variant=$BRANDING_THEME_VARIANT"
        echo "gtk_theme=$GTK_THEME"
        echo "icon_theme=$ICON_THEME"
        echo "wallpaper=$BRANDING_WALLPAPER_TARGET"
        echo "apply_desktops=$APPLY_DESKTOPS_RAW"
        echo "strict=$BRANDING_STRICT"
        echo ""
        echo "[files]"
        find "$LFS/usr/share/backgrounds/lfs" "$LFS/usr/share/themes" "$LFS/usr/share/pixmaps/lfs" -type f 2>/dev/null | LC_ALL=C sort
        echo ""
        echo "[checksums]"
        if command -v sha256sum >/dev/null 2>&1; then
            find "$LFS/usr/share/backgrounds/lfs" "$LFS/usr/share/themes" "$LFS/usr/share/pixmaps/lfs" -type f 2>/dev/null | LC_ALL=C sort | xargs -r sha256sum
        fi
    } >"$manifest"

    log_success "Branding manifest written to /etc/lfs-branding-manifest.txt"
}

log_info "Applying LFS branding and customizations"
resolve_branding_settings
generate_wallpapers_if_needed
resolve_wallpaper_path

log_info "LFS: $LFS"
log_info "Branding source: $BRANDING_DIR"
log_info "Theme variant: $BRANDING_THEME_VARIANT"
log_info "GTK theme: $GTK_THEME"
log_info "Icon theme: $ICON_THEME"
log_info "Wallpaper target: $BRANDING_WALLPAPER_TARGET"

install_gtk_themes
install_wallpapers
configure_xfce_branding
configure_gnome_branding
configure_kde_branding
configure_lxqt_branding
configure_phosh_branding
configure_display_manager
configure_user_defaults
install_branding_assets
write_builder_parameters_snapshot
write_branding_manifest

log_success "Branding applied successfully"
exit 0
