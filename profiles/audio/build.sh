#!/bin/bash
# Unified audio profile builder - ONE SCRIPT TO RULE THEM ALL

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../common/utils.sh"

# Load configuration
source "$SCRIPT_DIR/../config/audio-profile.conf" 2>/dev/null || {
    log_warning "No audio profile configured, running selector first"
    ./profiles/select-audio-profile.sh
    source "$SCRIPT_DIR/../config/audio-profile.conf"
}

log_info "========================================="
log_info "Building audio profile: $AUDIO_PROFILE"
log_info "========================================="

# ============================================================================
# CORE FUNCTION: Install packages from a packages.list
# ============================================================================
install_from_list() {
    local list_file="$1"

    if [ ! -f "$list_file" ]; then
        log_error "Package list not found: $list_file"
        return 1
    fi

    log_info "Installing packages from: $(basename $(dirname $list_file))"

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue

        # Handle include directives
        if [[ "$line" =~ ^include: ]]; then
            local included="${line#include:}"
            local included_file="$SCRIPT_DIR/$included"
            if [ -f "$included_file" ]; then
                install_from_list "$included_file"
            fi
        else
            log_info "  Installing: $line"
            lpm install "$line" 2>/dev/null || log_warning "Failed to install $line"
        fi
    done < "$list_file"
}

# ============================================================================
# PROFILE-SPECIFIC CONFIGURATIONS
# ============================================================================
configure_cli_minimal() {
    log_info "Configuring CLI minimal environment..."

    cat > /etc/profile.d/audio-cli.sh << 'EOF'
# Audio CLI aliases
alias jack-start='jack_control start'
alias jack-stop='jack_control stop'
alias midi-ls='aconnect -l'
EOF

    cat > /usr/local/bin/start-audio << 'EOF'
#!/bin/bash
jack_control start
echo "Audio system started"
EOF
    chmod 755 /usr/local/bin/start-audio

    log_success "CLI minimal configured"
}

configure_desktop_xfce() {
    log_info "Configuring XFCE desktop for audio..."

    cat > /usr/share/applications/jack-control.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=JACK Control
Exec=qjackctl
Icon=audio-card
Categories=Audio;Music;
EOF

    log_success "XFCE desktop configured"
}

configure_desktop_gnome() {
    log_info "Configuring GNOME desktop for audio..."

    mkdir -p /etc/dconf/db/local.d
    cat > /etc/dconf/db/local.d/00-audio << 'EOF'
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'

[org/gnome/shell]
favorite-apps=['ardour.desktop', 'audacity.desktop', 'qjackctl.desktop']
EOF
    dconf compile /etc/dconf/db/local /etc/dconf/db/local.d 2>/dev/null || true

    log_success "GNOME desktop configured"
}

configure_studio_full() {
    log_info "Configuring full studio environment..."

    # Real-time kernel
    if [ -f /sources/linux-6.16.1-rt.tar.xz ]; then
        cd /sources
        tar -xf linux-6.16.1-rt.tar.xz
        cd linux-6.16.1-rt
        scripts/config --enable PREEMPT_RT
        make -j$(nproc)
        make modules_install
        cp arch/x86/boot/bzImage /boot/vmlinuz-lfs-rt
    fi

    # Real-time limits
    cat >> /etc/security/limits.conf << 'EOF'
@audio   -  rtprio     95
@audio   -  memlock    unlimited
EOF

    log_success "Full studio configured"
}

# ============================================================================
# MAIN
# ============================================================================

# 1. Install packages for the selected profile
install_from_list "$SCRIPT_DIR/$AUDIO_PROFILE/packages.list"

# 2. Apply profile-specific configuration
case "$AUDIO_PROFILE" in
    cli-minimal)      configure_cli_minimal ;;
    desktop-xfce)     configure_desktop_xfce ;;
    desktop-gnome)    configure_desktop_gnome ;;
    studio-full)      configure_studio_full ;;
    custom)           log_info "Custom profile - no extra configuration" ;;
esac

log_success "========================================="
log_success "Audio profile $AUDIO_PROFILE build complete!"
log_success "========================================="