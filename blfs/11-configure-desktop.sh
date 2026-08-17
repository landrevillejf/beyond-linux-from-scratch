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
    # Default panel layout
    cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml <<'XFCEPANEL'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <value type="int" value="2"/>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="whiskermenu"/>
    <property name="plugin-2" type="string" value="tasklist"/>
    <property name="plugin-3" type="string" value="systray"/>
  </property>
</channel>
XFCEPANEL
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
