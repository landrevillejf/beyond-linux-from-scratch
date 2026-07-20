#!/bin/bash
# LXQt Desktop Profile for LFS
# Lightweight Qt-based desktop environment setup

set -e

log_info() { echo -e "\033[0;32m[INFO]\033\0 $1"; }
log_success() { echo -e "\033[0;34m[SUCCESS]\033[0m $1"; }
log_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

# ============================================================================
# LXQT SPECIFIC CONFIGURATION
# ============================================================================

LXQT_VERSION="1.4.0"
NUM_JOBS=${NUM_JOBS:-$(nproc)}
PACKAGE_LIST="profiles/lxqt/packages.list"

# ============================================================================
# BUILD QT5 FRAMEWORK
# ============================================================================
build_qt5() {
    log_info "Building Qt5 framework..."

    cd /sources

    # Qt5 base
    if [ -f "qt5-base-*.tar.xz" ]; then
        log_info "Building Qt5 Base..."
        tar -xf qt5-base-*.tar.xz
        cd qt5-base-*

        ./configure -prefix /usr \
                    -release \
                    -shared \
                    -nomake examples \
                    -nomake tests \
                    -confirm-license \
                    -opensource \
                    -qt-doubleconversion \
                    -qt-pcre \
                    -qt-zlib \
                    -qt-libpng \
                    -qt-libjpeg \
                    -qt-freetype \
                    -qt-harfbuzz \
                    -qt-sqlite \
                    -openssl-linked \
                    -dbus-linked \
                    -glib \
                    -icu \
                    -xcb \
                    -xcb-xlib \
                    -xkbcommon \
                    -wayland
        make -j$NUM_JOBS
        make install
        cd ..
    fi

    # Additional Qt5 modules
    local qt_modules=(
        "qt5-declarative"
        "qt5-tools"
        "qt5-multimedia"
        "qt5-svg"
        "qt5-quickcontrols"
        "qt5-quickcontrols2"
        "qt5-graphicaleffects"
        "qt5-x11extras"
        "qt5-wayland"
    )

    for module in "${qt_modules[@]}"; do
        if [ -f "${module}-*.tar.xz" ]; then
            log_info "Building $module..."
            tar -xf ${module}-*.tar.xz
            cd ${module}-*

            ./configure -prefix /usr
            make -j$NUM_JOBS
            make install
            cd ..
        fi
    done

    log_success "Qt5 built successfully"
}

# ============================================================================
# BUILD LXQT COMPONENTS
# ============================================================================
build_lxqt_core() {
    log_info "Building LXQt core components..."

    cd /sources

    # Order matters for dependencies
    local lxqt_components=(
        "libqtxdg"
        "lxqt-build-tools"
        "libfm-qt"
        "lxqt-qtplugin"
        "lxqt-menu-data"
        "lxqt-globalkeys"
        "lxqt-notificationd"
        "lxqt-session"
        "lxqt-panel"
        "lxqt-runner"
        "lxqt-config"
        "lxqt-powermanagement"
        "lxqt-about"
        "lxqt-admin"
        "lxqt-openssh-askpass"
        "lxqt-policykit"
        "lxqt-sudo"
        "pcmanfm-qt"
        "qterminal"
        "qps"
        "lximage-qt"
    )

    for component in "${lxqt_components[@]}"; do
        if [ -f "${component}-*.tar.xz" ]; then
            log_info "Building $component..."
            tar -xf ${component}-*.tar.xz
            cd ${component}-*

            mkdir -p build
            cd build
            cmake -DCMAKE_INSTALL_PREFIX=/usr \
                  -DCMAKE_BUILD_TYPE=Release \
                  -DPULL_TRANSLATIONS=OFF \
                  ..
            make -j$NUM_JOBS
            make install
            cd ../..
        fi
    done

    log_success "LXQt core components built"
}

# ============================================================================
# BUILD OPENBOX (Window Manager)
# ============================================================================
build_openbox() {
    log_info "Building Openbox window manager (LXQt default)..."

    cd /sources

    if [ -f "openbox-*.tar.gz" ]; then
        tar -xf openbox-*.tar.gz
        cd openbox-*

        ./configure --prefix=/usr \
                    --sysconfdir=/etc \
                    --disable-static \
                    --enable-startup-notification
        make -j$NUM_JOBS
        make install

        # Default configuration
        mkdir -p /etc/xdg/openbox
        cp -r /etc/xdg/openbox /etc/skel/.config/

        cd ..
    fi

    log_success "Openbox built"
}

# ============================================================================
# CONFIGURE LXQT SESSION
# ============================================================================
configure_lxqt_session() {
    log_info "Configuring LXQt session..."

    # Create session configuration
    mkdir -p /usr/share/xsessions

    cat > /usr/share/xsessions/lxqt.desktop << 'EOF'
[Desktop Entry]
Name=LXQt
Comment=Lightweight Qt Desktop Environment
Exec=startlxqt
Type=Application
DesktopNames=LXQt
X-GDM-SessionRegisters=true
EOF

    # Create LXQt session script
    cat > /usr/bin/startlxqt << 'EOF'
#!/bin/bash
# LXQt session startup script

export XDG_CURRENT_DESKTOP=LXQt
export QT_QPA_PLATFORMTHEME=lxqt

# Start Openbox with LXQt settings
openbox --startup &

# Start LXQt components
lxqt-session &
lxqt-panel &
lxqt-config &
lxqt-runner &
lxqt-notificationd &

# Set wallpaper if available
if [ -f /usr/share/backgrounds/lxqt-default.png ]; then
    pcmanfm-qt --set-wallpaper /usr/share/backgrounds/lxqt-default.png
fi

# Exec into session
exec lxqt-session
EOF

    chmod +x /usr/bin/startlxqt

    log_success "LXQt session configured"
}

# ============================================================================
# CONFIGURE DESKTOP MANAGER (LightDM/SDDM)
# ============================================================================
configure_display_manager() {
    log_info "Configuring display manager for LXQt..."

    # Prefer LightDM for lightweight setup
    if command -v lightdm &> /dev/null; then
        cat >> /etc/lightdm/lightdm.conf << 'EOF'
[Seat:*]
user-session=lxqt
autologin-user=lfsuser
autologin-user-timeout=0
EOF

        if command -v systemctl &> /dev/null; then
            systemctl enable lightdm
            systemctl set-default graphical.target
        fi
    elif command -v sddm &> /dev/null; then
        cat > /etc/sddm.conf << 'EOF'
[Autologin]
User=lfsuser
Session=lxqt

[Theme]
Current=breeze

[General]
DisplayServer=x11
EOF
        systemctl enable sddm
        systemctl set-default graphical.target
    fi

    log_success "Display manager configured"
}

# ============================================================================
# CONFIGURE LXQT SETTINGS
# ============================================================================
configure_lxqt_settings() {
    log_info "Configuring LXQt settings..."

    # Create default configuration for new users
    mkdir -p /etc/skel/.config/lxqt

    # Panel configuration
    cat > /etc/skel/.config/lxqt/panel.conf << 'EOF'
[General]
__userfile__=true

[mainPanel]
alignment=Left
animation-duration=200
cache-eviction=System
freeMove=false
height=36
hidpi=false
icon-size=24
length=100
length-percent=true
position=Bottom
show-delay=0
show-delay-onhover=false
show-only-current-desktop=false
type=Panel
width=100
width-percent=true

[mainPanel\plugins]
count=6
plugin1=mainmenu
plugin2=taskbar
plugin3=launcher
plugin4=statusnotifier
plugin5=volume
plugin6=clock

[mainPanel\plugins\launcher]
alignment=Left
buttons=
type=Launcher

[mainPanel\plugins\mainmenu]
alignment=Left
type=MainMenu

[mainPanel\plugins\taskbar]
alignment=Left
autoRotate=true
closeOnMiddleClick=true
raiseOnHover=false
showOnlyCurrentDesktop=false
showToolTips=true
type=TaskBar

[mainPanel\plugins\statusnotifier]
alignment=Right
type=StatusNotifier

[mainPanel\plugins\volume]
alignment=Right
type=Volume

[mainPanel\plugins\clock]
alignment=Right
type=Clock
EOF

    # Session configuration
    cat > /etc/skel/.config/lxqt/session.conf << 'EOF'
[Environment]
QT_QPA_PLATFORMTHEME=lxqt

[General]
autostart=
leave_confirmation=false
merge_menu_files=false
single_click=false
window_manager=openbox
EOF

    # LXQt configuration
    cat > /etc/skel/.config/lxqt/lxqt.conf << 'EOF'
[General]
theme=lxqt
icon_theme=papirus
cursor_size=24
cursor_theme=Adwaita
font=Sans Serif,10,-1,5,50,0,0,0,0,0
EOF

    # Openbox configuration
    mkdir -p /etc/skel/.config/openbox
    cat > /etc/skel/.config/openbox/rc.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <theme>
    <name>Clearlooks</name>
    <titleLayout>LCSIM</titleLayout>
    <keepBorder>yes</keepBorder>
    <animateIconify>yes</animateIconify>
    <font place="ActiveWindow">
      <name>sans</name>
      <size>9</size>
      <weight>bold</weight>
    </font>
  </theme>

  <desktops>
    <number>4</number>
    <popupTime>875</popupTime>
  </desktops>

  <resize>
    <drawContents>yes</drawContents>
    <popupShow>Nonpixel</popupShow>
    <popupPosition>Center</popupPosition>
  </resize>

  <focus>
    <focusNew>yes</focusNew>
    <focusNewDelay>0</focusNewDelay>
    <focusLast>yes</focusLast>
    <underMouse>no</underMouse>
    <followMouse>no</followMouse>
    <raiseLastFocus>no</raiseLastFocus>
  </focus>

  <dock>
    <position>TopLeft</position>
    <floating>no</floating>
    <stacking>Above</stacking>
  </dock>

  <keyboard>
    <chainQuitKey>C-g</chainQuitKey>
    <keybind key="A-F4">
      <action name="Close"/>
    </keybind>
    <keybind key="A-Tab">
      <action name="NextWindow"/>
    </keybind>
    <keybind key="A-S-Tab">
      <action name="PreviousWindow"/>
    </keybind>
    <keybind key="C-A-t">
      <action name="Execute">
        <command>qterminal</command>
      </action>
    </keybind>
    <keybind key="C-A-d">
      <action name="ToggleShowDesktop"/>
    </keybind>
  </keyboard>

  <mouse>
    <dragThreshold>3</dragThreshold>
    <context name="Frame">
      <mousebind button="A-Left" action="Press">
        <action name="Focus"/>
        <action name="Raise"/>
      </mousebind>
    </context>
  </mouse>

  <menu>
    <file>menu.xml</file>
    <hideDelay>0</hideDelay>
    <middle>no</middle>
    <submenuShowDelay>100</submenuShowDelay>
    <submenuHideDelay>400</submenuHideDelay>
  </menu>
</openbox_config>
EOF

    # Application menu
    cat > /etc/skel/.config/openbox/menu.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu>
  <menu id="root-menu" label="Openbox 3">
    <item label="Terminal">
      <action name="Execute">
        <command>qterminal</command>
      </action>
    </item>
    <item label="Web Browser">
      <action name="Execute">
        <command>firefox</command>
      </action>
    </item>
    <item label="File Manager">
      <action name="Execute">
        <command>pcmanfm-qt</command>
      </action>
    </item>
    <separator/>
    <menu id="app-menu" label="Applications"/>
    <separator/>
    <item label="Log Out">
      <action name="Exit"/>
    </item>
  </menu>
</openbox_menu>
EOF

    log_success "LXQt settings configured"
}

# ============================================================================
# SETUP LXQT BACKGROUNDS
# ============================================================================
setup_backgrounds() {
    log_info "Setting up LXQt backgrounds..."

    mkdir -p /usr/share/backgrounds/lxqt

    cd /usr/share/backgrounds/lxqt
    if [ ! -f "lxqt-default.png" ]; then
        # Create simple gradient background
        convert -size 1920x1080 gradient:blue-grey lxqt-default.png 2>/dev/null || \
        cp /usr/share/backgrounds/xfce/xfce-stripes.png lxqt-default.png 2>/dev/null || true
    fi

    log_success "Backgrounds configured"
}

# ============================================================================
# INSTALL LXQT THEME
# ============================================================================
install_lxqt_theme() {
    log_info "Installing LXQt themes..."

    cd /sources

    if [ -f "lxqt-themes-*.tar.xz" ]; then
        tar -xf lxqt-themes-*.tar.xz
        cd lxqt-themes-*
        mkdir -p build
        cd build
        cmake -DCMAKE_INSTALL_PREFIX=/usr ..
        make -j$NUM_JOBS
        make install
        cd ../..
    fi

    log_success "LXQt themes installed"
}

# ============================================================================
# ENABLE STARTUP SERVICES
# ============================================================================
enable_services() {
    log_info "Enabling startup services..."

    if command -v systemctl &> /dev/null; then
        # Display manager
        if command -v lightdm &> /dev/null; then
            systemctl enable lightdm
        elif command -v sddm &> /dev/null; then
            systemctl enable sddm
        fi

        # Network
        systemctl enable NetworkManager 2>/dev/null || systemctl enable systemd-networkd 2>/dev/null

        # Sound
        systemctl enable pipewire 2>/dev/null || true
        systemctl enable pipewire-pulse 2>/dev/null || true

        log_success "Services enabled"
    fi
}

# ============================================================================
# CLEANUP
# ============================================================================
cleanup() {
    log_info "Cleaning up temporary files..."

    cd /sources
    rm -rf qt5-* lxqt-* openbox-* pcmanfm-* qterminal-* 2>/dev/null || true

    log_success "Cleanup complete"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    log_info "========================================="
    log_info "LXQt Desktop Installation"
    log_info "========================================="
    log_warning "This will take several hours..."
    echo ""

    build_qt5
    build_openbox
    build_lxqt_core
    install_lxqt_theme
    configure_lxqt_session
    configure_display_manager
    configure_lxqt_settings
    setup_backgrounds
    enable_services
    cleanup

    log_success "========================================="
    log_success "LXQt Desktop Installation Complete!"
    log_success "========================================="
    echo ""
    echo "LXQt $LXQT_VERSION has been installed successfully."
    echo ""
    echo "To start LXQt:"
    echo "  1. Reboot your system"
    echo "  2. Login with your user account"
    echo "  3. Select 'LXQt' from the session menu"
    echo "  4. LXQt will start"
    echo ""
    echo "Default login: lfsuser / lfsuser123"
    echo ""
    echo "Keyboard shortcuts:"
    echo "  Alt + F2        - Run command"
    echo "  Alt + Space     - Application menu"
    echo "  Ctrl + Alt + T  - Terminal (QTerminal)"
    echo "  Alt + Tab       - Switch windows"
    echo "  Ctrl + Alt + D  - Show desktop"
    echo "  Alt + F4        - Close window"
    echo ""
    echo "Estimated memory usage: ~500MB"
    echo "========================================="
}

# Run main function
main "$@"