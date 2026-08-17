#!/bin/bash
# XFCE Desktop Profile for LFS
# Lightweight XFCE 4.20 desktop environment setup

set -e

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;34m[SUCCESS]\033[0m $1"; }
log_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

# ============================================================================
# XFCE SPECIFIC CONFIGURATION
# ============================================================================

XFCE_VERSION="4.20"
NUM_JOBS=${NUM_JOBS:-$(nproc)}
PACKAGE_LIST="profiles/xfce/packages.list"

# ============================================================================
# INSTALL XFCE COMPONENTS
# ============================================================================
install_xfce() {
    log_info "Installing XFCE ${XFCE_VERSION} desktop environment..."

    cd /sources

    # Core XFCE packages
    local core_packages=(
        "libxfce4util"
        "xfconf"
        "libxfce4ui"
        "exo"
        "garcon"
        "xfce4-panel"
        "xfce4-session"
        "xfce4-settings"
        "xfwm4"
        "xfdesktop"
        "thunar"
        "xfce4-appfinder"
    )

    for pkg in "${core_packages[@]}"; do
        if [ -f "${pkg}-*.tar.bz2" ]; then
            log_info "Building $pkg..."
            tar -xf ${pkg}-*.tar.bz2
            cd ${pkg}-*

            ./configure --prefix=/usr
            make -j$NUM_JOBS
            make install

            cd ..
        fi
    done

    log_success "XFCE core components installed"
}

# ============================================================================
# INSTALL XFCE APPLICATIONS
# ============================================================================
install_xfce_apps() {
    log_info "Installing XFCE applications..."

    cd /sources

    local applications=(
        "xfce4-terminal"
        "xfce4-taskmanager"
        "xfce4-screenshooter"
        "xfce4-power-manager"
        "xfce4-notifyd"
        "ristretto"
        "mousepad"
        "orage"
        "parole"
        "gigolo"
    )

    for app in "${applications[@]}"; do
        if [ -f "${app}-*.tar.bz2" ]; then
            log_info "Building $app..."
            tar -xf ${app}-*.tar.bz2
            cd ${app}-*

            ./configure --prefix=/usr
            make -j$NUM_JOBS
            make install

            cd ..
        fi
    done

    log_success "XFCE applications installed"
}

# ============================================================================
# INSTALL XFCE PLUGINS
# ============================================================================
install_xfce_plugins() {
    log_info "Installing XFCE panel plugins..."

    cd /sources

    local plugins=(
        "xfce4-whiskermenu-plugin"
        "xfce4-docklike-plugin"
        "xfce4-statusnotifier-plugin"
        "xfce4-cpugraph-plugin"
        "xfce4-netload-plugin"
        "xfce4-systemload-plugin"
        "xfce4-weather-plugin"
        "xfce4-clipman-plugin"
        "thunar-archive-plugin"
    )

    for plugin in "${plugins[@]}"; do
        if [ -f "${plugin}-*.tar.bz2" ]; then
            log_info "Building $plugin..."
            tar -xf ${plugin}-*.tar.bz2
            cd ${plugin}-*

            ./configure --prefix=/usr
            make -j$NUM_JOBS
            make install

            cd ..
        fi
    done

    log_success "XFCE plugins installed"
}

# ============================================================================
# CONFIGURE LIGHTDM (Display Manager)
# ============================================================================
configure_lightdm() {
    log_info "Configuring LightDM for XFCE..."

    # Create LightDM configuration directory
    mkdir -p /etc/lightdm

    # Main LightDM configuration
    cat > /etc/lightdm/lightdm.conf << 'EOF'
[LightDM]
greeter-session=lightdm-gtk-greeter
user-session=xfce

[Seat:*]
autologin-user=lfsuser
autologin-user-timeout=0
session-wrapper=/etc/X11/Xsession
user-session=xfce
greeter-session=lightdm-gtk-greeter

[XDMCPServer]
enabled=false

[VNCServer]
enabled=false
EOF

    # GTK Greeter configuration
    cat > /etc/lightdm/lightdm-gtk-greeter.conf << 'EOF'
[greeter]
background=/usr/share/backgrounds/xfce/xfce-stripes.png
theme-name=Adwaita
icon-theme-name=Adwaita
font-name=Sans 10
clock-format=%H:%M
indicators=~host;~spacer;~clock;~spacer;~session;~language;~a11y;~power
show-indicators=~session;~language;~a11y
EOF

    # Enable LightDM service
    if command -v systemctl &> /dev/null; then
        systemctl enable lightdm
        systemctl set-default graphical.target
    fi

    log_success "LightDM configured"
}

# ============================================================================
# CONFIGURE XFCE SETTINGS
# ============================================================================
configure_xfce() {
    log_info "Configuring XFCE desktop settings..."

    # Create configuration directories for default user
    mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/

    # Panel configuration – two panels:
    #   Panel 1 = thin top bar (whiskermenu, clock, systray) – semi-transparent
    #   Panel 2 = bottom dock (macOS-style launchers + tasklist) – translucent
    cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <value type="int" value="2"/>
  </property>

  <!-- Panel 1: top bar -->
  <property name="panel-1" type="empty">
    <property name="position" type="string" value="p=8;x=960;y=14"/>
    <property name="length" type="uint" value="100"/>
    <property name="size" type="uint" value="28"/>
    <property name="position-locked" type="bool" value="true"/>
    <property name="mode" type="uint" value="0"/>
    <property name="icon-size" type="uint" value="16"/>
    <property name="background-style" type="uint" value="1"/>
    <property name="background-rgba" type="array">
      <value type="double" value="0.08"/>
      <value type="double" value="0.08"/>
      <value type="double" value="0.16"/>
      <value type="double" value="0.55"/>
    </property>
    <property name="plugin-ids" type="array">
      <value type="int" value="1"/>
      <value type="int" value="2"/>
      <value type="int" value="3"/>
      <value type="int" value="4"/>
    </property>
  </property>

  <!-- Panel 2: bottom dock (macOS-style) -->
  <property name="panel-2" type="empty">
    <property name="position" type="string" value="p=2;x=960;y=1010"/>
    <property name="length" type="uint" value="60"/>
    <property name="length-adjust" type="bool" value="false"/>
    <property name="size" type="uint" value="56"/>
    <property name="position-locked" type="bool" value="true"/>
    <property name="mode" type="uint" value="0"/>
    <property name="icon-size" type="uint" value="40"/>
    <property name="background-style" type="uint" value="1"/>
    <property name="background-rgba" type="array">
      <value type="double" value="0.10"/>
      <value type="double" value="0.10"/>
      <value type="double" value="0.18"/>
      <value type="double" value="0.50"/>
    </property>
    <property name="enter-opacity" type="uint" value="100"/>
    <property name="leave-opacity" type="uint" value="70"/>
    <property name="plugin-ids" type="array">
      <value type="int" value="10"/>
      <value type="int" value="11"/>
      <value type="int" value="12"/>
      <value type="int" value="13"/>
      <value type="int" value="14"/>
      <value type="int" value="15"/>
      <value type="int" value="16"/>
      <value type="int" value="17"/>
      <value type="int" value="18"/>
      <value type="int" value="19"/>
    </property>
  </property>

  <!-- Top bar plugins -->
  <property name="plugin-1" type="string" value="whiskermenu"/>
  <property name="plugin-2" type="string" value="clock">
    <property name="digital-format" type="string" value="%a %d %b  %H:%M"/>
    <property name="mode" type="uint" value="2"/>
  </property>
  <property name="plugin-3" type="string" value="separator">
    <property name="expand" type="bool" value="true"/>
  </property>
  <property name="plugin-4" type="string" value="systray"/>

  <!-- Dock plugins: launchers + tasklist -->
  <property name="plugin-10" type="string" value="launcher">
    <property name="items" type="array">
      <value type="string" value="thunar.desktop"/>
    </property>
    <property name="show-label" type="bool" value="false"/>
  </property>
  <property name="plugin-11" type="string" value="launcher">
    <property name="items" type="array">
      <value type="string" value="xfce4-terminal.desktop"/>
    </property>
    <property name="show-label" type="bool" value="false"/>
  </property>
  <property name="plugin-12" type="string" value="launcher">
    <property name="items" type="array">
      <value type="string" value="firefox.desktop"/>
    </property>
    <property name="show-label" type="bool" value="false"/>
  </property>
  <property name="plugin-13" type="string" value="launcher">
    <property name="items" type="array">
      <value type="string" value="mousepad.desktop"/>
    </property>
    <property name="show-label" type="bool" value="false"/>
  </property>
  <property name="plugin-14" type="string" value="separator"/>
  <property name="plugin-15" type="string" value="launcher">
    <property name="items" type="array">
      <value type="string" value="parole.desktop"/>
    </property>
    <property name="show-label" type="bool" value="false"/>
  </property>
  <property name="plugin-16" type="string" value="launcher">
    <property name="items" type="array">
      <value type="string" value="ristretto.desktop"/>
    </property>
    <property name="show-label" type="bool" value="false"/>
  </property>
  <property name="plugin-17" type="string" value="launcher">
    <property name="items" type="array">
      <value type="string" value="xfce-settings-manager.desktop"/>
    </property>
    <property name="show-label" type="bool" value="false"/>
  </property>
  <property name="plugin-18" type="string" value="separator"/>
  <property name="plugin-19" type="string" value="tasklist">
    <property name="show-labels" type="bool" value="false"/>
    <property name="flat-buttons" type="bool" value="true"/>
    <property name="show-handle" type="bool" value="false"/>
    <property name="sort-order" type="uint" value="1"/>
  </property>
</channel>
EOF

    # Desktop settings
    cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="image-path" type="string" value="/usr/share/backgrounds/xfce/xfce-stripes.png"/>
        <property name="image-style" type="int" value="5"/>
        <property name="image-show" type="bool" value="true"/>
      </property>
    </property>
  </property>
</channel>
EOF

    # Window manager settings – compositor OFF (picom handles it)
    cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Default"/>
    <property name="title_font" type="string" value="Sans Bold 9"/>
    <property name="button_layout" type="string" value="O|SHMC"/>
    <property name="button_offset" type="int" value="0"/>
    <property name="easy_click" type="string" value="Alt"/>
    <property name="focus_delay" type="int" value="250"/>
    <property name="focus_hint" type="bool" value="true"/>
    <property name="placement_ratio" type="int" value="20"/>
    <property name="raise_on_focus" type="bool" value="false"/>
    <property name="wrap_windows" type="bool" value="false"/>
    <property name="wrap_workspaces" type="bool" value="false"/>
    <property name="click_to_focus" type="bool" value="true"/>
    <!-- Compositor OFF – picom provides blur/alpha instead -->
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF

    # Picom compositor – macOS-style frosted glass dock
    mkdir -p /etc/skel/.config/picom
    cat > /etc/skel/.config/picom/picom.conf << 'EOF'
# Picom compositor – macOS-style frosted glass dock
backend = "glx";
vsync = true;

# Blur settings – dual_kawase gives the best frosted-glass look
blur:
{
    method = "dual_kawase";
    strength = 8;
    background = true;
    background-frame = true;
    background-fixed = true;
};

# Shadows
shadow = true;
shadow-radius = 12;
shadow-opacity = 0.6;
shadow-offset-x = 0;
shadow-offset-y = 4;
shadow-color = "#000000";
no-dock-shadow = false;
no-dnd-shadow = true;
clear-shadow = true;

# Window opacity rules
opacity-rules = [
    "95:class_g = 'Xfce4-panel'"
];

# Fading (smooth transitions)
fading = true;
fade-in-step = 0.04;
fade-out-step = 0.04;
fade-exclude = [];

# Rounded corners for panels and dialogs
corner-radius = 12;
rounded-corners-exclude = [];

# Exclude conditions
blur-background-exclude = [
    "window_type = 'dock'",
    "window_type = 'desktop'",
    "_GTK_FRAME_EXTENTS@:c"
];

# GLX specific settings
glx-no-stencil = true;
glx-copy-from-front = false;
use-damage = true;
EOF

    # Picom autostart
    mkdir -p /etc/skel/.config/autostart
    cat > /etc/skel/.config/autostart/picom.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Picom Compositor
Comment=X11 compositor for blur, transparency and shadows
Exec=picom --daemon
X-GNOME-Autostart-enabled=true
EOF

    # GTK settings
    mkdir -p /etc/skel/.config/gtk-3.0
    cat > /etc/skel/.config/gtk-3.0/settings.ini << 'EOF'
[Settings]
gtk-theme-name=Adwaita
gtk-icon-theme-name=Adwaita
gtk-font-name=Sans 10
gtk-cursor-theme-name=Adwaita
gtk-toolbar-style=GTK_TOOLBAR_ICONS
gtk-enable-event-sounds=0
gtk-enable-input-feedback-sounds=0
EOF

    # XFCE keyboard shortcuts
    cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-keyboard-shortcuts" version="1.0">
  <property name="commands" type="empty">
    <property name="default" type="empty">
      <property name="&lt;Primary&gt;&lt;Alt&gt;t" type="string" value="xfce4-terminal"/>
      <property name="&lt;Primary&gt;&lt;Alt&gt;Delete" type="string" value="xfce4-session-logout"/>
      <property name="&lt;Super&gt;e" type="string" value="thunar"/>
      <property name="&lt;Super&gt;f" type="string" value="firefox"/>
      <property name="&lt;Super&gt;r" type="string" value="xfce4-appfinder"/>
    </property>
  </property>
</channel>
EOF

    log_success "XFCE settings configured"
}

# ============================================================================
# SETUP XFCE BACKGROUNDS
# ============================================================================
setup_backgrounds() {
    log_info "Setting up XFCE backgrounds..."

    mkdir -p /usr/share/backgrounds/xfce

    cd /usr/share/backgrounds/xfce
    if [ ! -f "xfce-stripes.png" ]; then
        # Create simple gradient background
        convert -size 1920x1080 gradient:blue-grey xfce-stripes.png 2>/dev/null || true
    fi

    log_success "Backgrounds configured"
}

# ============================================================================
# CLEANUP
# ============================================================================
cleanup() {
    log_info "Cleaning up temporary files..."

    cd /sources
    rm -rf libxfce4util-* xfconf-* libxfce4ui-* exo-* garcon-*
    rm -rf xfce4-panel-* xfce4-session-* xfce4-settings-* xfwm4-* xfdesktop-* thunar-*
    rm -rf xfce4-* mousepad-* ristretto-* parole-*

    log_success "Cleanup complete"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    log_info "========================================="
    log_info "XFCE Desktop Installation"
    log_info "========================================="

    install_xfce
    install_xfce_apps
    install_xfce_plugins
    configure_lightdm
    configure_xfce
    setup_backgrounds
    cleanup

    log_success "========================================="
    log_success "XFCE Desktop Installation Complete!"
    log_success "========================================="
    echo ""
    echo "XFCE $XFCE_VERSION has been installed successfully."
    echo ""
    echo "To start XFCE:"
    echo "  1. Reboot your system"
    echo "  2. Login with your user account"
    echo "  3. XFCE will start automatically"
    echo ""
    echo "Default login: lfsuser / lfsuser123"
    echo "========================================="
}

# Run main function
main "$@"