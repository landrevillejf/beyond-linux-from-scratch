#!/bin/bash
# first-boot.sh - Run once at first boot.
# Uses resources from packages/custom-scripts/

set -e

FIRST_BOOT_FLAG="/var/lib/.first-boot-done"

if [ -f "$FIRST_BOOT_FLAG" ]; then
    exit 0
fi

log_info()    { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;34m[SUCCESS]\033[0m $1"; }
log_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }
log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; exit 1; }

# ============================================================================
# LOAD CUSTOM CONFIGURATION
# ============================================================================
CUSTOM_CONF="/packages/custom-scripts/custom-settings.conf"
if [ -f "$CUSTOM_CONF" ]; then
    source "$CUSTOM_CONF"
fi

# Default values (can be overridden by custom.conf or environment)
DEFAULT_USER="${DEFAULT_USER:-lfsuser}"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-lfsuser123}"
HOSTNAME="${HOSTNAME:-lfs-desktop}"

# Try to read builder configuration from JSON (if present)
CONFIG_FILE="/etc/lfs-build.json"
if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
    # Override with values from the builder config
    HOSTNAME=$(jq -r '.hostname // "'"$HOSTNAME"'"' "$CONFIG_FILE")
    # Users: get first user from list, fallback to DEFAULT_USER
    USER_FROM_JSON=$(jq -r '.users[0].name // ""' "$CONFIG_FILE")
    if [ -n "$USER_FROM_JSON" ]; then
        DEFAULT_USER="$USER_FROM_JSON"
    fi
    # Init system detection: we can get it from config
    INIT_SYSTEM=$(jq -r '.init_system // "sysvinit"' "$CONFIG_FILE")
    DESKTOP=$(jq -r '.desktop.type // "xfce"' "$CONFIG_FILE")
else
    # Fallback: detect init system from running processes
    if pidof systemd >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    else
        INIT_SYSTEM="sysvinit"
    fi
    # Desktop: try to detect from installed packages (simple heuristic)
    if command -v startxfce4 >/dev/null 2>&1; then
        DESKTOP="xfce"
    elif command -v gnome-session >/dev/null 2>&1; then
        DESKTOP="gnome"
    elif command -v startplasma-x11 >/dev/null 2>&1; then
        DESKTOP="kde"
    elif command -v lxqt-session >/dev/null 2>&1; then
        DESKTOP="lxqt"
    else
        DESKTOP="none"
    fi
fi

# Export for welcome script
export DESKTOP INIT_SYSTEM

# ============================================================================
# HARDWARE DETECTION
# ============================================================================
detect_hardware() {
    log_info "Detecting hardware..."

    CPU_VENDOR=$(lscpu | grep "Vendor ID" | cut -d: -f2 | xargs 2>/dev/null || echo "unknown")
    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    RAM_GB=$(free -g | awk '/^Mem:/{print $2}' 2>/dev/null || echo 1)

    if lspci 2>/dev/null | grep -i vga | grep -qi nvidia; then
        GPU="nvidia"
    elif lspci 2>/dev/null | grep -i vga | grep -qi amd; then
        GPU="amd"
    elif lspci 2>/dev/null | grep -i vga | grep -qi intel; then
        GPU="intel"
    else
        GPU="unknown"
    fi

    cat > /etc/hardware-profile << EOF
CPU_VENDOR="$CPU_VENDOR"
CPU_CORES="$CPU_CORES"
RAM_GB="$RAM_GB"
GPU="$GPU"
HOSTNAME="$HOSTNAME"
EOF

    log_success "Hardware detected: $GPU, $CPU_CORES cores, ${RAM_GB}GB RAM"
}

# ============================================================================
# NETWORK CONFIGURATION
# ============================================================================
configure_network() {
    log_info "Configuring network..."

    # Set hostname
    echo "$HOSTNAME" > /etc/hostname
    hostname "$HOSTNAME"

    # Try DHCP on all Ethernet interfaces
    for iface in $(ip link show | grep -E '^[0-9]+: e' | cut -d: -f2 | xargs); do
        log_info "Configuring $iface with DHCP..."
        dhcpcd "$iface" 2>/dev/null || dhclient "$iface" 2>/dev/null || true
    done

    # Test connectivity
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        log_success "Network connected!"
    else
        log_warning "Network connection failed. Manual configuration may be needed."
    fi
}

# ============================================================================
# USER CREATION
# ============================================================================
create_user() {
    log_info "Creating user $DEFAULT_USER..."

    if ! id "$DEFAULT_USER" &>/dev/null; then
        useradd -m -G wheel,audio,video,storage,docker,plugdev -s /bin/bash "$DEFAULT_USER"
        echo "$DEFAULT_USER:$DEFAULT_PASSWORD" | chpasswd
        echo "$DEFAULT_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/"$DEFAULT_USER"
        log_success "User created"
    else
        log_info "User already exists"
    fi
}

# ============================================================================
# BASH CONFIGURATION
# ============================================================================
configure_bash() {
    log_info "Configuring Bash..."

    cat >> /etc/bash.bashrc << 'BASH'
# Custom prompt
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# Aliases
alias ls='ls --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'

# History
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth
HISTTIMEFORMAT="%F %T "

# PATH
export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
BASH

    # Copy to user home
    if [ -d "/home/$DEFAULT_USER" ]; then
        cp /etc/bash.bashrc "/home/$DEFAULT_USER/.bashrc"
        chown "$DEFAULT_USER:$DEFAULT_USER" "/home/$DEFAULT_USER/.bashrc"
    fi
}

# ============================================================================
# SERVICE ACTIVATION (systemd or sysvinit)
# ============================================================================
enable_services() {
    log_info "Activating services for $INIT_SYSTEM..."

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        # System services
        for svc in systemd-networkd systemd-resolved dbus; do
            systemctl enable "$svc" 2>/dev/null || true
        done

        # Bluetooth if present
        if command -v bluetoothd >/dev/null 2>&1; then
            systemctl enable bluetooth 2>/dev/null || true
        fi

        # CUPS if present
        if command -v cupsd >/dev/null 2>&1; then
            systemctl enable cups 2>/dev/null || true
        fi

        # Display manager (DM)
        if systemctl list-unit-files | grep -q lightdm; then
            systemctl enable lightdm 2>/dev/null || true
            systemctl set-default graphical.target 2>/dev/null || true
        elif systemctl list-unit-files | grep -q gdm; then
            systemctl enable gdm 2>/dev/null || true
            systemctl set-default graphical.target 2>/dev/null || true
        elif systemctl list-unit-files | grep -q sddm; then
            systemctl enable sddm 2>/dev/null || true
            systemctl set-default graphical.target 2>/dev/null || true
        fi
    else
        # sysvinit: enable common services via /etc/rc.d/rc.conf
        if [ -f /etc/rc.d/rc.conf ]; then
            sed -i 's/^#SERVICES=.*/SERVICES="network dhcpcd sshd"/' /etc/rc.d/rc.conf 2>/dev/null || true
        fi
        # (Additional sysvinit service links can be added here)
    fi

    log_success "Services activated"
}

# ============================================================================
# LIVE PERSISTENCE SETUP (if in live mode)
# ============================================================================
setup_persistence() {
    log_info "Setting up live persistence..."

    PERSIST_PART=$(blkid -L "LFS-PERSIST" 2>/dev/null)
    if [ -n "$PERSIST_PART" ]; then
        mkdir -p /mnt/persist
        mount "$PERSIST_PART" /mnt/persist 2>/dev/null || true

        if [ -d /mnt/persist ]; then
            mkdir -p /mnt/persist/{upper,work}
            touch /var/lib/live-persistence-enabled
            log_success "Live persistence enabled on $PERSIST_PART"
        fi
    else
        log_info "No persistence partition found"
    fi
}

# ============================================================================
# WELCOME MESSAGE
# ============================================================================
create_welcome() {
    log_info "Creating welcome message..."

    cat > /etc/profile.d/welcome.sh << 'WELCOME'
#!/bin/bash
if [ "$PS1" ]; then
    echo "=================================================="
    echo "  Welcome to LFS Linux $(cat /etc/lfs-release 2>/dev/null)"
    echo "=================================================="
    echo "  Kernel : $(uname -r)"
    echo "  CPU    : $(nproc) cores"
    echo "  RAM    : $(free -h | awk '/^Mem:/{print $2}')"
    echo "  Desktop: ${DESKTOP:-unknown}"
    echo "  Init   : ${INIT_SYSTEM:-unknown}"
    echo "=================================================="
    echo ""
fi
WELCOME

    chmod +x /etc/profile.d/welcome.sh

    # Add system logo if available
    if [ -f /usr/share/icons/hicolor/256x256/apps/lfs-logo.png ]; then
        echo "  Logo : LFS Linux" >> /etc/issue
    fi
}

# ============================================================================
# CLEANUP
# ============================================================================
cleanup() {
    log_info "Cleaning up..."

    rm -rf /tmp/* 2>/dev/null || true
    rm -rf /var/tmp/* 2>/dev/null || true
    find /var/log -name "*.log" -mtime +30 -delete 2>/dev/null || true

    log_success "Cleanup completed"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    log_info "=== FIRST BOOT CONFIGURATION ==="

    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root."
    fi

    detect_hardware
    configure_network
    create_user
    configure_bash
    enable_services
    setup_persistence
    create_welcome
    cleanup

    touch "$FIRST_BOOT_FLAG"

    log_success "=== SYSTEM READY ==="
    echo ""
    echo "=================================================="
    echo "  LFS LINUX IS NOW READY TO USE"
    echo "=================================================="
    echo "  User     : $DEFAULT_USER"
    echo "  Password : $DEFAULT_PASSWORD"
    echo ""
    echo "  Please change your password!"
    echo "=================================================="
}

main "$@"