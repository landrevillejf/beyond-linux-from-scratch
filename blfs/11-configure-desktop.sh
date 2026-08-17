#!/bin/bash
# Configure desktop environment – supports XFCE, GNOME, KDE, LXQt
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/../common/utils.sh" ]; then
    source "$SCRIPT_DIR/../common/utils.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warning() { echo "[WARNING] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
fi

IN_DOCKER=false
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
    IN_DOCKER=true
    log_info "Running in Docker container"
fi

if [ "$IN_DOCKER" = true ]; then
    LFS=${LFS:-/output/image}
else
    LFS=${LFS:-/mnt/lfs}
fi

if [ -z "$LFS" ]; then
    log_error "LFS variable not set"
    exit 1
fi

run_privileged() {
    if [ "$(whoami)" = "root" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

DESKTOP_TYPE="${LFS_CONFIG_DESKTOP_TYPE:-xfce}"
INIT_SYSTEM="${INIT_SYSTEM:-sysvinit}"

log_info "========================================="
log_info "Configuring desktop environment"
log_info "Desktop type: $DESKTOP_TYPE"
log_info "========================================="

[ "$DESKTOP_TYPE" = "none" ] && { log_info "No desktop requested; skipping configuration"; exit 0; }

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – minimal desktop config inside $LFS"
    run_privileged mkdir -pv "$LFS"/etc/X11/xorg.conf.d "$LFS"/usr/share/xsessions
    run_privileged tee "$LFS/usr/share/xsessions/${DESKTOP_TYPE}.desktop" >/dev/null <<EOF
[Desktop Entry]
Name=${DESKTOP_TYPE}
Exec=start${DESKTOP_TYPE}4
Type=Application
EOF
    log_success "Desktop configuration created (Docker mode)"
    exit 0
fi

if [ ! -f "$LFS/bin/bash" ]; then
    log_error "/bin/bash not found in $LFS/bin"
    exit 1
fi

cleanup_mounts() {
    run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
    run_privileged umount "$LFS"/dev 2>/dev/null || true
    run_privileged umount "$LFS"/proc 2>/dev/null || true
    run_privileged umount "$LFS"/sys 2>/dev/null || true
    run_privileged umount "$LFS"/run 2>/dev/null || true
}
trap cleanup_mounts EXIT

run_privileged mkdir -p "$LFS"/dev/pts "$LFS"/run
run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t devpts devpts "$LFS"/dev/pts 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true
run_privileged mount -t tmpfs tmpfs "$LFS"/run 2>/dev/null || true

cat >"$LFS/configure-desktop.sh" <<INNEREOF
#!/bin/bash
set -e
export DESKTOP_TYPE="$DESKTOP_TYPE"
export INIT_SYSTEM="$INIT_SYSTEM"

log_info() { echo "[INFO] \$*"; }
log_error() { echo "[ERROR] \$*" >&2; }
log_warning() { echo "[WARNING] \$*"; }
log_success() { echo "[SUCCESS] \$*"; }

have_cmd() { command -v "\$1" >/dev/null 2>&1; }

echo "Configuring desktop: \$DESKTOP_TYPE"

# Common directories
mkdir -pv /etc/X11/xorg.conf.d /usr/share/xsessions /usr/share/wayland-sessions
mkdir -pv /etc/skel/.config /etc/skel/.local/share

# ---- Xorg configuration ----
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<'XORGKB'
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us"
    Option "XkbModel" "pc104"
EndSection
XORGKB

cat > /etc/X11/xorg.conf.d/10-evdev.conf <<'XORGEV'
Section "InputClass"
    Identifier "evdev-all"
    MatchIsKeyboard "on"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
EndSection
XORGEV

# ---- XFCE configuration ----
if [ "\$DESKTOP_TYPE" = "xfce" ]; then
    log_info "Configuring XFCE"
    cat > /usr/share/xsessions/xfce.desktop <<'XFCE'
[Desktop Entry]
Name=Xfce Session
Comment=Use this session to run Xfce as your desktop environment
Exec=startxfce4
Icon=xfce4
Type=Application
DesktopNames=XFCE
XFCE
    # XFCE default config in /etc/skel
    mkdir -p /etc/skel/.config/xfce4/panel
    mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml

    # ------------------------------------------------------------------
    # Panel 1 = thin top bar (menu, clock, systray) – semi-transparent
    # Panel 2 = bottom dock (macOS-style) – translucent with blur
    #
    # The compositor (xfwm4 built-in) must be enabled for alpha/blur.
    # Icon size on the dock is 40px; panel height 48px.
    # ------------------------------------------------------------------
    cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml <<'XFCEPANEL'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <!-- Two panels: top bar (1) and bottom dock (2) -->
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <value type="int" value="2"/>
  </property>

  <!-- ============== PANEL 1 – TOP BAR ============== -->
  <property name="panel-1" type="empty">
    <property name="position" type="string" value="p=8;x=960;y=14"/>
    <property name="length" type="uint" value="100"/>
    <property name="length-adjust" type="bool" value="true"/>
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

  <!-- ============== PANEL 2 – BOTTOM DOCK ============== -->
  <property name="panel-2" type="empty">
    <!-- p=2 = bottom-center -->
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

  <!-- ============== TOP BAR PLUGINS ============== -->
  <property name="plugin-1" type="string" value="whiskermenu">
    <property name="button-icon" type="string" value="start-here"/>
    <property name="button-title" type="string" value="Applications"/>
    <property name="show-button-title" type="bool" value="true"/>
  </property>
  <property name="plugin-2" type="string" value="clock">
    <property name="digital-format" type="string" value="%a %d %b  %H:%M"/>
    <property name="mode" type="uint" value="2"/>
  </property>
  <property name="plugin-3" type="string" value="separator">
    <property name="expand" type="bool" value="true"/>
  </property>
  <property name="plugin-4" type="string" value="systray">
    <property name="known-items" type="array">
      <value type="string" value="nm-applet"/>
      <value type="string" value="blueman"/>
      <value type="string" value="xfce4-power-manager"/>
    </property>
  </property>

  <!-- ============== DOCK PLUGINS ============== -->
  <!-- Launcher: File Manager (Thunar) -->
  <property name="plugin-10" type="string" value="launcher">
    <property name="items" type="array">
      <value type="string" value="thunar.desktop"/>
    </property>
    <property name="show-label" type="bool" value="false"/>
    <property name="disable-tooltips" type="bool" value="false"/>
  </property>
  <!-- Launcher: Terminal -->
  <property name="plugin-11" type="string" value="launcher">
    <property name="items" type="array">
      <value type="string" value="xfce4-terminal.desktop"/>
    </property>
    <property name="show-label" type="bool" value="false"/>
  </property>
  <!-- Launcher: Web Browser (Firefox) -->
  <property name="plugin-12" type="string" value="launcher">
    <property name="items" type="array">
      <value type="string" value="firefox.desktop"/>
    </property>
    <property name="show-label" type="bool" value="false"/>
  </property>
  <!-- Launcher: Text Editor -->
  <property name="plugin-13" type="string" value="launcher">
    <property name="items" type="array">
      <value type="string" value="mousepad.desktop"/>
    </property>
    <property name="show-label" type="bool" value="false"/>
  </property>
  <!-- Separator (visual spacer) -->
  <property name="plugin-14" type="string" value="separator"/>
  <!-- Launcher: Media Player -->
  <property name="plugin-15" type="string" value="launcher">
    <property name="items" type="array">
      <value type="string" value="parole.desktop"/>
    </property>
    <property name="show-label" type="bool" value="false"/>
  </property>
  <!-- Launcher: Image Viewer -->
  <property name="plugin-16" type="string" value="launcher">
    <property name="items" type="array">
      <value type="string" value="ristretto.desktop"/>
    </property>
    <property name="show-label" type="bool" value="false"/>
  </property>
  <!-- Launcher: Settings -->
  <property name="plugin-17" type="string" value="launcher">
    <property name="items" type="array">
      <value type="string" value="xfce-settings-manager.desktop"/>
    </property>
    <property name="show-label" type="bool" value="false"/>
  </property>
  <!-- Separator before tasklist -->
  <property name="plugin-18" type="string" value="separator"/>
  <!-- Tasklist (running apps, like macOS active indicators) -->
  <property name="plugin-19" type="string" value="tasklist">
    <property name="show-labels" type="bool" value="false"/>
    <property name="flat-buttons" type="bool" value="true"/>
    <property name="show-handle" type="bool" value="false"/>
    <property name="sort-order" type="uint" value="1"/>
    <property name="window-scrolling" type="bool" value="false"/>
    <property name="include-all-workspaces" type="bool" value="false"/>
    <property name="middle-click" type="uint" value="1"/>
  </property>
</channel>
XFCEPANEL

    # ------------------------------------------------------------------
    # XFCE compositor settings
    # Disable xfwm4 built-in compositor – picom provides blur/alpha
    # ------------------------------------------------------------------
    cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<'XFWM4'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Default"/>
    <property name="title_font" type="string" value="Sans Bold 9"/>
    <property name="button_layout" type="string" value="O|SHMC"/>
    <property name="easy_click" type="string" value="Alt"/>
    <property name="raise_on_focus" type="bool" value="false"/>
    <property name="click_to_focus" type="bool" value="true"/>
    <!-- Compositor OFF – picom handles compositing with blur -->
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
XFWM4

    # ------------------------------------------------------------------
    # Picom configuration – macOS-style blur behind transparent panels
    # Uses dual_kawase blur for a smooth frosted-glass dock effect.
    # ------------------------------------------------------------------
    mkdir -p /etc/skel/.config/picom
    cat > /etc/skel/.config/picom/picom.conf <<'PICOM'
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
PICOM

    # ------------------------------------------------------------------
    # Picom autostart – XDG autostart .desktop file
    # ------------------------------------------------------------------
    mkdir -p /etc/skel/.config/autostart
    cat > /etc/skel/.config/autostart/picom.desktop <<'AUTOSTART'
[Desktop Entry]
Type=Application
Name=Picom Compositor
Comment=X11 compositor for blur, transparency and shadows
Exec=picom --daemon
X-GNOME-Autostart-enabled=true
AUTOSTART

    # Also install system-wide autostart so it works for all users
    mkdir -p /etc/xdg/autostart
    cp /etc/skel/.config/autostart/picom.desktop /etc/xdg/autostart/picom.desktop 2>/dev/null || true

    # Copy picom.conf system-wide as well
    mkdir -p /etc/xdg/picom
    cp /etc/skel/.config/picom/picom.conf /etc/xdg/picom/picom.conf 2>/dev/null || true
    # Configure LightDM for XFCE
    if [ -f /etc/lightdm/lightdm.conf ]; then
        sed -i 's/^user-session=.*/user-session=xfce/' /etc/lightdm/lightdm.conf 2>/dev/null || true
        sed -i 's/^autologin-session=.*/autologin-session=xfce/' /etc/lightdm/lightdm.conf 2>/dev/null || true
    fi

# ---- GNOME configuration ----
elif [ "\$DESKTOP_TYPE" = "gnome" ]; then
    log_info "Configuring GNOME"
    cat > /usr/share/xsessions/gnome.desktop <<'GNOME'
[Desktop Entry]
Name=GNOME
Comment=GNOME Desktop
Exec=gnome-session
Type=Application
DesktopNames=GNOME
GNOME
    cat > /usr/share/wayland-sessions/gnome.desktop <<'GNOMEWL'
[Desktop Entry]
Name=GNOME on Wayland
Comment=GNOME Desktop (Wayland)
Exec=gnome-session --session=gnome
Type=Application
DesktopNames=GNOME
GNOMEWL
    # GDM configuration
    if [ -d /etc/gdm ]; then
        mkdir -p /etc/gdm
        cat > /etc/gdm/custom.conf <<'GDMCONF'
[daemon]
WaylandEnable=false
AutomaticLogin=lfsuser
AutomaticLoginEnable=true
GDMCONF
    fi
    # GNOME default settings
    mkdir -p /etc/dconf/db/local.d
    cat > /etc/dconf/db/local.d/00-gnome-defaults <<'GCONF'
[org/gnome/desktop/interface]
gtk-theme='Adwaita'
icon-theme='Adwaita'
font-name='Cantarell 11'

[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/gnome/default.jpg'

[org/gnome/desktop/screensaver]
lock-enabled=false
GCONF
    # Compile dconf database
    if have_cmd dconf; then
        dconf update 2>/dev/null || true
    fi

# ---- KDE Plasma configuration ----
elif [ "\$DESKTOP_TYPE" = "kde" ]; then
    log_info "Configuring KDE Plasma"
    cat > /usr/share/xsessions/plasma.desktop <<'KDE'
[Desktop Entry]
Name=Plasma
Comment=KDE Plasma Desktop
Exec=startplasma-x11
Type=Application
DesktopNames=KDE
KDE
    cat > /usr/share/wayland-sessions/plasma.desktop <<'KDEWL'
[Desktop Entry]
Name=Plasma (Wayland)
Comment=KDE Plasma Desktop (Wayland)
Exec=startplasma-wayland
Type=Application
DesktopNames=KDE
KDEWL
    # SDDM configuration
    if have_cmd sddm; then
        mkdir -p /etc/sddm.conf.d
        cat > /etc/sddm.conf.d/kde-settings.conf <<'SDDMCONF'
[Theme]
Current=breeze

[Autologin]
User=lfsuser
Session=plasma
SDDMCONF
    fi
    # KDE environment variables
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/kde.sh <<'KDEENV'
export XDG_CURRENT_DESKTOP=KDE
export KDE_FULL_SESSION=true
KDEENV

# ---- LXQt configuration ----
elif [ "\$DESKTOP_TYPE" = "lxqt" ]; then
    log_info "Configuring LXQt"
    cat > /usr/share/xsessions/lxqt.desktop <<'LXQT'
[Desktop Entry]
Name=LXQt
Comment=LXQt Desktop
Exec=lxqt-session
Type=Application
DesktopNames=LXQt
LXQT
    # LXQt session config
    mkdir -p /etc/xdg/lxqt
    cat > /etc/xdg/lxqt/session.conf <<'LXCONF'
[General]
window_manager=openbox
LXCONF
    # Openbox autostart
    mkdir -p /etc/xdg/lxqt/autostart
    cat > /etc/xdg/lxqt/autostart/openbox.desktop <<'OB'
[Desktop Entry]
Name=Openbox
Comment=Start Openbox window manager
Exec=openbox
Type=Application
OB
    # Configure LightDM for LXQt
    if [ -f /etc/lightdm/lightdm.conf ]; then
        sed -i 's/^user-session=.*/user-session=lxqt/' /etc/lightdm/lightdm.conf 2>/dev/null || true
        sed -i 's/^autologin-session=.*/autologin-session=lxqt/' /etc/lightdm/lightdm.conf 2>/dev/null || true
    fi
    # LXQt environment variables
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/lxqt.sh <<'LXENV'
export XDG_CURRENT_DESKTOP=LXQt
export XDG_SESSION_DESKTOP=lxqt
LXENV
fi

# ---- Common desktop configuration ----

# Create default xinitrc based on desktop type
case "\$DESKTOP_TYPE" in
    xfce)  XINIT_CMD="exec startxfce4" ;;
    gnome) XINIT_CMD="exec gnome-session" ;;
    kde)   XINIT_CMD="exec startplasma-x11" ;;
    lxqt)  XINIT_CMD="exec lxqt-session" ;;
    *)     XINIT_CMD="# No default session configured" ;;
esac
cat > /etc/X11/xinitrc <<XINIT
#!/bin/sh
\$XINIT_CMD
XINIT
chmod 0755 /etc/X11/xinitrc

# Create lfsuser home if it does not exist
if ! have_cmd getent; then
    : # getent not available, skip
elif ! getent passwd lfsuser >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G audio,video,lp,sys,wheel lfsuser 2>/dev/null || true
fi

# Copy skel to lfsuser home if lfsuser exists
if id lfsuser >/dev/null 2>&1; then
    cp -r /etc/skel/. /home/lfsuser/ 2>/dev/null || true
    chown -R lfsuser:lfsuser /home/lfsuser 2>/dev/null || true
fi

# Font configuration
if have_cmd fc-cache; then
    fc-cache -fv /usr/share/fonts 2>/dev/null || true
fi

# Desktop file for default applications
mkdir -p /usr/share/applications
cat > /usr/share/applications/default-browser.desktop <<'DEFAPP'
[Desktop Entry]
Name=Web Browser
Comment=Default web browser
Exec=firefox %u
Type=Application
Categories=Network;WebBrowser;
DEFAPP

# Create Xresources defaults
cat > /etc/skel/.Xresources <<'XRES'
Xft.dpi: 96
Xft.antialias: true
Xft.hinting: true
Xft.hintstyle: hintfull
Xft.rgba: none
XRES

echo "Desktop configuration complete."
INNEREOF

run_privileged chmod +x "$LFS/configure-desktop.sh"
run_privileged chroot "$LFS" /bin/bash /configure-desktop.sh

cleanup_mounts

log_success "Desktop configuration complete for $DESKTOP_TYPE"
