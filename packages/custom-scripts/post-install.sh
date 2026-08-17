#!/bin/bash
# Post-installation script – adapts to the builder configuration.
# Run as root after first boot.
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.

set -e

# -------------------------------------------------------------------
# 1. Read configuration (JSON)
# -------------------------------------------------------------------
CONFIG_FILE="/etc/lfs-build.json"

# If the file does not exist, use defaults from environment or hardcoded values
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[WARN] Configuration file $CONFIG_FILE not found."
    echo "       Using default values."
    # Default values (used when the file is missing)
    DESKTOP_TYPE="xfce"
    INIT_SYSTEM="sysvinit"
    HOSTNAME="lfs-desktop"
    LOCALE="en_US.UTF-8"
    TIMEZONE="UTC"
    USERS='[{"name":"lfsuser","groups":["wheel","audio","video","storage"],"sudo":true,"autologin":true}]'
else
    # Extract values with jq if available, otherwise rely on environment variables
    if command -v jq >/dev/null 2>&1; then
        DESKTOP_TYPE=$(jq -r '.features.desktop // "xfce"' "$CONFIG_FILE")
        INIT_SYSTEM=$(jq -r '.init_system // "sysvinit"' "$CONFIG_FILE")
        HOSTNAME=$(jq -r '.hostname // "lfs-desktop"' "$CONFIG_FILE")
        LOCALE=$(jq -r '.locale // "en_US.UTF-8"' "$CONFIG_FILE")
        TIMEZONE=$(jq -r '.timezone // "UTC"' "$CONFIG_FILE")
        USERS_JSON=$(jq -c '.users // [{"name":"lfsuser","groups":["wheel"],"sudo":true}]' "$CONFIG_FILE")
    else
        # Fallback: use environment variables if defined
        DESKTOP_TYPE="${DESKTOP_TYPE:-xfce}"
        INIT_SYSTEM="${INIT_SYSTEM:-sysvinit}"
        HOSTNAME="${HOSTNAME:-lfs-desktop}"
        LOCALE="${LOCALE:-en_US.UTF-8}"
        TIMEZONE="${TIMEZONE:-UTC}"
        USERS_JSON='[{"name":"lfsuser","groups":["wheel","audio","video","storage"],"sudo":true}]'
    fi
fi

# -------------------------------------------------------------------
# 2. Common functions
# -------------------------------------------------------------------
log_info() {
    echo "[INFO] $(date +'%Y-%m-%d %H:%M:%S') - $*"
}
log_error() {
    echo "[ERROR] $(date +'%Y-%m-%d %H:%M:%S') - $*" >&2
    exit 1
}
check_cmd() {
    command -v "$1" >/dev/null 2>&1 || { log_error "Command $1 not found."; }
}

# -------------------------------------------------------------------
# 3. Basic system configuration
# -------------------------------------------------------------------
configure_base() {
    log_info "Configuring base system..."
    # Hostname
    echo "$HOSTNAME" > /etc/hostname

    # Locale
    if [ -f /etc/locale.conf ]; then
        echo "LANG=$LOCALE" > /etc/locale.conf
    fi

    # Timezone
    if [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
        cp "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    fi

    # Timezone for sysvinit/systemd
    if [ "$INIT_SYSTEM" = "sysvinit" ] && [ -f /etc/sysconfig/clock ]; then
        echo "UTC=1" > /etc/sysconfig/clock
        echo "ZONE=$TIMEZONE" >> /etc/sysconfig/clock
    fi
}

# -------------------------------------------------------------------
# 4. User creation
# -------------------------------------------------------------------
create_users() {
    log_info "Creating users..."
    # Parse user JSON (fallback if jq is missing)
    if command -v jq >/dev/null 2>&1; then
        echo "$USERS_JSON" | jq -c '.[]' | while read -r user; do
            USERNAME=$(echo "$user" | jq -r '.name')
            GROUPS=$(echo "$user" | jq -r '.groups | join(",")')
            SUDO=$(echo "$user" | jq -r '.sudo')
            AUTOLOGIN=$(echo "$user" | jq -r '.autologin // false')
            # Create user if it does not exist
            if ! id "$USERNAME" &>/dev/null; then
                useradd -m -G "$GROUPS" -s /bin/bash "$USERNAME"
                # Set a default password (change later)
                echo "$USERNAME:${USERNAME}123" | chpasswd
                if [ "$SUDO" = "true" ]; then
                    echo "$USERNAME ALL=(ALL) ALL" > "/etc/sudoers.d/$USERNAME"
                fi
            fi
            # Configure .bashrc
            cat > "/home/$USERNAME/.bashrc" << "BASHRC"
# Load system bashrc
source /etc/bash.bashrc
export PATH=$PATH:$HOME/.local/bin
BASHRC
            chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
        done
    else
        # Fallback: create default user
        USERNAME="lfsuser"
        if ! id "$USERNAME" &>/dev/null; then
            useradd -m -G wheel,audio,video,storage -s /bin/bash "$USERNAME"
            echo "$USERNAME:${USERNAME}123" | chpasswd
            echo "$USERNAME ALL=(ALL) ALL" > "/etc/sudoers.d/$USERNAME"
        fi
    fi
}

# -------------------------------------------------------------------
# 5. Desktop configuration (according to DESKTOP_TYPE)
# -------------------------------------------------------------------
configure_desktop() {
    log_info "Configuring desktop: $DESKTOP_TYPE"
    case "$DESKTOP_TYPE" in
        xfce)
            configure_xfce
            ;;
        gnome)
            configure_gnome
            ;;
        kde)
            configure_kde
            ;;
        lxqt)
            configure_lxqt
            ;;
        none|"")
            log_info "No desktop selected (CLI mode)."
            ;;
        *)
            log_info "Unknown desktop: $DESKTOP_TYPE – configuration skipped."
            ;;
    esac
}

# Sub-functions for each desktop
configure_xfce() {
    log_info "Configuring XFCE..."
    # Install wallpaper if present
    WALLPAPER_SRC="/usr/share/backgrounds/lfs-wallpaper.png"
    if [ -f "$WALLPAPER_SRC" ]; then
        mkdir -p /usr/share/xfce4/backdrops
        cp "$WALLPAPER_SRC" /usr/share/xfce4/backdrops/
    fi
    # Autostart script for XFCE settings
    cat > /etc/xdg/autostart/lfs-desktop-settings.desktop << "AUTOSTART"
[Desktop Entry]
Type=Application
Name=LFS Desktop Settings
Exec=/usr/local/bin/lfs-desktop-settings.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
AUTOSTART
    cat > /usr/local/bin/lfs-desktop-settings.sh << "SETTINGS"
#!/bin/bash
export DISPLAY=:0
sleep 2
xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/image-path -s /usr/share/xfce4/backdrops/lfs-wallpaper.png 2>/dev/null || true
xfconf-query -c xfwm4 -p /general/theme -s Adwaita 2>/dev/null || true
xfconf-query -c xsettings -p /Net/ThemeName -s Adwaita 2>/dev/null || true
xfconf-query -c xsettings -p /Net/IconThemeName -s Papirus 2>/dev/null || true

# ---- macOS-style dock panel (panel-2) ----
# Disable xfwm4 compositor – picom handles blur/alpha
xfconf-query -c xfwm4 -p /general/use_compositing -s false 2>/dev/null || true

# Start picom compositor for frosted-glass blur effect
if command -v picom >/dev/null 2>&1; then
    picom --daemon 2>/dev/null || true
fi

# Panel 2: bottom dock – translucent dark background
xfconf-query -c xfce4-panel -p /panels/panel-2/background-style -t int -s 1 2>/dev/null || true
xfconf-query -c xfce4-panel -p /panels/panel-2/background-rgba -t array -n 2>/dev/null || true
xfconf-query -c xfce4-panel -p /panels/panel-2/enter-opacity -t int -s 100 2>/dev/null || true
xfconf-query -c xfce4-panel -p /panels/panel-2/leave-opacity -t int -s 70 2>/dev/null || true

# Panel 1: top bar – semi-transparent
xfconf-query -c xfce4-panel -p /panels/panel-1/background-style -t int -s 1 2>/dev/null || true
xfconf-query -c xfce4-panel -p /panels/panel-1/enter-opacity -t int -s 100 2>/dev/null || true
xfconf-query -c xfce4-panel -p /panels/panel-1/leave-opacity -t int -s 80 2>/dev/null || true
SETTINGS
    chmod +x /usr/local/bin/lfs-desktop-settings.sh
}

configure_gnome() {
    log_info "Configuring GNOME..."
    # For GNOME, use gsettings (run as user)
    # Create an autostart script that applies settings
    cat > /etc/xdg/autostart/lfs-gnome-settings.desktop << "AUTOSTART"
[Desktop Entry]
Type=Application
Name=LFS GNOME Settings
Exec=/usr/local/bin/lfs-gnome-settings.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
AUTOSTART
    cat > /usr/local/bin/lfs-gnome-settings.sh << "SETTINGS"
#!/bin/bash
export DISPLAY=:0
sleep 2
# Wallpaper (if file exists)
if [ -f /usr/share/backgrounds/lfs-wallpaper.png ]; then
    gsettings set org.gnome.desktop.background picture-uri "file:///usr/share/backgrounds/lfs-wallpaper.png"
fi
# Theme (if Adwaita exists)
gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita' 2>/dev/null || true
gsettings set org.gnome.desktop.interface icon-theme 'Papirus' 2>/dev/null || true
SETTINGS
    chmod +x /usr/local/bin/lfs-gnome-settings.sh
}

configure_kde() {
    log_info "Configuring KDE Plasma..."
    # KDE uses configuration files in ~/.config
    # Create a script to apply themes via lookandfeeltool
    cat > /etc/xdg/autostart/lfs-kde-settings.desktop << "AUTOSTART"
[Desktop Entry]
Type=Application
Name=LFS KDE Settings
Exec=/usr/local/bin/lfs-kde-settings.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
AUTOSTART
    cat > /usr/local/bin/lfs-kde-settings.sh << "SETTINGS"
#!/bin/bash
export DISPLAY=:0
sleep 2
# Apply a global theme (e.g., Breeze)
lookandfeeltool --apply "org.kde.breeze.desktop" 2>/dev/null || true
# Wallpaper (if file exists)
if [ -f /usr/share/backgrounds/lfs-wallpaper.png ]; then
    # Use plasma-apply-wallpaperimage if available
    plasma-apply-wallpaperimage /usr/share/backgrounds/lfs-wallpaper.png 2>/dev/null || true
fi
SETTINGS
    chmod +x /usr/local/bin/lfs-kde-settings.sh
}

configure_lxqt() {
    log_info "Configuring LXQt..."
    # LXQt uses ~/.config/lxqt/lxqt.conf
    # Pre-configure wallpaper and theme
    cat > /etc/xdg/autostart/lfs-lxqt-settings.desktop << "AUTOSTART"
[Desktop Entry]
Type=Application
Name=LFS LXQt Settings
Exec=/usr/local/bin/lfs-lxqt-settings.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
AUTOSTART
    cat > /usr/local/bin/lfs-lxqt-settings.sh << "SETTINGS"
#!/bin/bash
export DISPLAY=:0
sleep 2
# Wallpaper (modify ~/.config/lxqt/lxqt.conf)
WALLPAPER="/usr/share/backgrounds/lfs-wallpaper.png"
if [ -f "$WALLPAPER" ]; then
    mkdir -p /home/$USER/.config/lxqt
    cat >> /home/$USER/.config/lxqt/lxqt.conf << LXQT_CONF
[General]
wallpaper=$WALLPAPER
theme=Adwaita
LXQT_CONF
    chown -R $USER:$USER /home/$USER/.config/lxqt
fi
SETTINGS
    chmod +x /usr/local/bin/lfs-lxqt-settings.sh
}

# -------------------------------------------------------------------
# 6. Shell (bash) and common tools configuration
# -------------------------------------------------------------------
configure_bash() {
    log_info "Configuring bash..."
    cat >> /etc/bash.bashrc << "BASH"
# System customization
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoreboth

alias ls='ls --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias df='df -h'
alias du='du -h'
mkcd() { mkdir -p "$1" && cd "$1"; }
BASH
}

configure_vim() {
    log_info "Configuring Vim..."
    cat > /etc/vim/vimrc << "VIM"
set number
set relativenumber
set tabstop=4
set shiftwidth=4
set expandtab
set mouse=a
syntax on
set autoindent
set smartindent
set background=dark
set showmatch
set ruler
VIM
}

# -------------------------------------------------------------------
# 7. Fonts and extra packages
# -------------------------------------------------------------------
install_fonts() {
    log_info "Installing Nerd Fonts..."
    mkdir -p /usr/share/fonts/TTF
    cd /sources || log_error "Directory /sources not found."
    FONT_ZIP="CascadiaCode.zip"
    if [ ! -f "$FONT_ZIP" ]; then
        URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.0.2/CascadiaCode.zip"
        if command -v wget >/dev/null; then
            wget "$URL" -O "$FONT_ZIP" || log_error "Failed to download fonts."
        elif command -v curl >/dev/null; then
            curl -L "$URL" -o "$FONT_ZIP" || log_error "Failed to download fonts."
        else
            log_error "wget or curl required for fonts."
        fi
    fi
    unzip -qo "$FONT_ZIP" -d /usr/share/fonts/TTF/
    fc-cache -fv
}

# -------------------------------------------------------------------
# 8. Welcome message
# -------------------------------------------------------------------
create_welcome() {
    log_info "Creating welcome message..."
    cat > /usr/local/bin/welcome.sh << "WELCOME"
#!/bin/bash
clear
echo "========================================="
echo "   Welcome to LFS Linux"
echo "========================================="
echo "  Distribution : LFS $(cat /etc/lfs-release 2>/dev/null || echo 'unknown')"
echo "  Kernel       : $(uname -r)"
echo "  Desktop      : $DESKTOP_TYPE"
echo "  Init System  : $INIT_SYSTEM"
echo "  User         : $(whoami)"
echo "========================================="
echo ""
WELCOME
    chmod +x /usr/local/bin/welcome.sh
    if ! grep -q "welcome.sh" /etc/profile; then
        echo "/usr/local/bin/welcome.sh" >> /etc/profile
    fi
}

# -------------------------------------------------------------------
# 9. Init-specific services
# -------------------------------------------------------------------
configure_services() {
    log_info "Configuring services for $INIT_SYSTEM..."
    if [ "$INIT_SYSTEM" = "sysvinit" ]; then
        # Enable services via /etc/rc.d/rc.conf
        if [ -f /etc/rc.d/rc.conf ]; then
            sed -i 's/^#SERVICES=.*/SERVICES="network dhcpcd sshd"/' /etc/rc.d/rc.conf 2>/dev/null || true
        fi
        # Additional services can be linked in /etc/rc.d/
    elif [ "$INIT_SYSTEM" = "systemd" ]; then
        # Enable systemd services
        systemctl enable NetworkManager 2>/dev/null || true
        systemctl enable sshd 2>/dev/null || true
    fi
}

# -------------------------------------------------------------------
# 10. Execute all steps
# -------------------------------------------------------------------
log_info "Starting post-installation."

configure_base
create_users
configure_bash
configure_vim
install_fonts
configure_desktop
create_welcome
configure_services

log_info "Post-installation completed successfully."
echo "Check the log: $LOG_FILE"