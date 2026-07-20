#!/bin/bash
# Pinebook Profile Builder - Build LFS for Pinebook/Pinebook Pro
# Target: ARM64 RK3399 laptop

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../common/utils.sh"

log_info "========================================="
log_info "Pinebook Profile Builder"
log_info "Target: Pinebook / Pinebook Pro (ARM64)"
log_info "========================================="

# Configuration
OUTPUT_DIR="${OUTPUT_DIR:-./lfs-pinebook}"
IMAGE_SIZE="${IMAGE_SIZE:-8192}"  # 8GB
PINEBOOK_MODEL="${PINEBOOK_MODEL:-pro}"  # pro, original

log_info "Building for Pinebook $PINEBOOK_MODEL"

# ============================================================================
# 1. Build LFS for ARM64 (cross-compilation)
# ============================================================================
build_lfs() {
    log_info "Building LFS for Pinebook..."

    cd "$SCRIPT_DIR/../.."

    # Utiliser la configuration spécifique Pinebook
    python3 builder.py \
        --profile minimal \
        --config config/build-pinebook.conf \
        --output "$OUTPUT_DIR/lfs-system" \
        --no-live

    log_success "LFS system built for Pinebook"
}

# ============================================================================
# 2. Install Pinebook-specific packages
# ============================================================================
install_pinebook_packages() {
    log_info "Installing Pinebook hardware support..."

    cd "$OUTPUT_DIR/lfs-system"

    # Créer les répertoires
    mkdir -p etc/modules-load.d
    mkdir -p etc/udev/rules.d
    mkdir -p usr/local/bin
    mkdir -p etc/acpi/events

    # Configurer les modules noyau à charger
    cat > etc/modules-load.d/pinebook.conf << 'EOF'
# Pinebook kernel modules
brcmfmac
brcmutil
es8316
panfrost
rockchipdrm
gpio_keys
EOF

    # Configurer udev pour les périphériques Pinebook
    cat > etc/udev/rules.d/99-pinebook.rules << 'EOF'
# Pinebook hardware detection
SUBSYSTEM=="power_supply", ATTR{manufacturer}=="Pine64", SYMLINK+="pinebook_battery"
SUBSYSTEM=="backlight", ATTR{type}=="firmware", SYMLINK+="pinebook_backlight"

# WiFi module
SUBSYSTEM=="mmc", ATTR{device}=="brcmfmac", SYMLINK+="pinebook_wifi"

# Keyboard backlight
SUBSYSTEM=="leds", ATTRS{function}=="kbd_backlight", SYMLINK+="pinebook_kbd_led"
EOF

    log_success "Pinebook packages installed"
}

# ============================================================================
# 3. Créer les scripts Pinebook spécifiques
# ============================================================================
create_pinebook_scripts() {
    log_info "Creating Pinebook utility scripts..."

    # Script de contrôle du rétroéclairage clavier (Pinebook Pro)
    cat > "$OUTPUT_DIR/lfs-system/usr/local/bin/kbd-backlight" << 'EOF'
#!/bin/bash
# Keyboard backlight control for Pinebook Pro

KBD_LED="/sys/class/leds/chromeos::kbd_backlight/brightness"
MAX_BRIGHT=100

if [ -z "$1" ]; then
    echo "Usage: kbd-backlight {up|down|0-100|off|on}"
    exit 1
fi

case "$1" in
    up)
        CURRENT=$(cat $KBD_LED 2>/dev/null || echo 0)
        NEW=$((CURRENT + 20))
        [ $NEW -gt $MAX_BRIGHT ] && NEW=$MAX_BRIGHT
        echo $NEW > $KBD_LED
        ;;
    down)
        CURRENT=$(cat $KBD_LED 2>/dev/null || echo 0)
        NEW=$((CURRENT - 20))
        [ $NEW -lt 0 ] && NEW=0
        echo $NEW > $KBD_LED
        ;;
    off|0)
        echo 0 > $KBD_LED
        ;;
    on|100)
        echo $MAX_BRIGHT > $KBD_LED
        ;;
    *)
        echo "$1" > $KBD_LED 2>/dev/null && echo "Set to $1%" || echo "Invalid value"
        ;;
esac
EOF
    chmod +x "$OUTPUT_DIR/lfs-system/usr/local/bin/kbd-backlight"

    # Script de contrôle du ventilateur (Pinebook Pro)
    cat > "$OUTPUT_DIR/lfs-system/usr/local/bin/fan-control" << 'EOF'
#!/bin/bash
# Fan control for Pinebook Pro
# Uses thermal zones to control fan speed

THERMAL_ZONE="/sys/class/thermal/thermal_zone0/temp"
FAN_CONTROL="/sys/class/hwmon/hwmon0/pwm1"

if [ ! -f "$THERMAL_ZONE" ]; then
    echo "No thermal zone found"
    exit 1
fi

TEMP=$(cat $THERMAL_ZONE)
TEMP=$((TEMP / 1000))

if [ $TEMP -lt 50 ]; then
    # Fan off
    echo 0 > $FAN_CONTROL 2>/dev/null
elif [ $TEMP -lt 60 ]; then
    # Low speed
    echo 85 > $FAN_CONTROL 2>/dev/null
elif [ $TEMP -lt 75 ]; then
    # Medium speed
    echo 170 > $FAN_CONTROL 2>/dev/null
else
    # Max speed
    echo 255 > $FAN_CONTROL 2>/dev/null
fi
EOF
    chmod +x "$OUTPUT_DIR/lfs-system/usr/local/bin/fan-control"

    # Script de gestion batterie (charge limit)
    cat > "$OUTPUT_DIR/lfs-system/usr/local/bin/battery-care" << 'EOF'
#!/bin/bash
# Battery charging limiter for Pinebook
# Stops charging at 80% to extend battery life

BATTERY_PATH="/sys/class/power_supply/cw2015-battery"

if [ ! -d "$BATTERY_PATH" ]; then
    echo "Battery not found"
    exit 1
fi

CAPACITY=$(cat $BATTERY_PATH/capacity 2>/dev/null)

if [ -n "$CAPACITY" ] && [ $CAPACITY -gt 80 ]; then
    # Disable charging
    echo 0 > $BATTERY_PATH/charging_enabled 2>/dev/null
    echo "Battery at $CAPACITY% - charging stopped"
elif [ -n "$CAPACITY" ] && [ $CAPACITY -lt 75 ]; then
    # Re-enable charging
    echo 1 > $BATTERY_PATH/charging_enabled 2>/dev/null
    echo "Battery at $CAPACITY% - charging resumed"
fi
EOF
    chmod +x "$OUTPUT_DIR/lfs-system/usr/local/bin/battery-care"

    # Service cron pour batterie
    mkdir -p "$OUTPUT_DIR/lfs-system/etc/cron.d"
    cat > "$OUTPUT_DIR/lfs-system/etc/cron.d/battery-care" << 'EOF'
# Battery care - check every 10 minutes
*/10 * * * * root /usr/local/bin/battery-care
EOF

    log_success "Pinebook scripts created"
}

# ============================================================================
# 4. Créer la configuration Xorg pour Pinebook
# ============================================================================
create_xorg_config() {
    log_info "Creating Xorg configuration for Pinebook..."

    mkdir -p "$OUTPUT_DIR/lfs-system/etc/X11/xorg.conf.d"

    # Configuration écran (1080p)
    cat > "$OUTPUT_DIR/lfs-system/etc/X11/xorg.conf.d/10-pinebook.conf" << 'EOF'
Section "Device"
    Identifier  "Mali"
    Driver      "panfrost"
    Option      "AccelMethod"   "gallium"
    Option      "Debug"         "false"
EndSection

Section "Monitor"
    Identifier  "eDP-1"
    Option      "PreferredMode" "1920x1080"
    Option      "DPI"           "96 x 96"
EndSection

Section "Screen"
    Identifier  "Screen0"
    Device      "Mali"
    Monitor     "eDP-1"
    DefaultDepth 24
EndSection

Section "InputClass"
    Identifier  "Touchpad"
    Driver      "libinput"
    MatchIsTouchpad "on"
    Option      "Tapping"       "on"
    Option      "NaturalScrolling" "on"
    Option      "ScrollMethod"  "twofinger"
EndSection
EOF

    # Configuration pour l'accélération matérielle
    cat > "$OUTPUT_DIR/lfs-system/etc/X11/xorg.conf.d/20-modesetting.conf" << 'EOF'
Section "Device"
    Identifier  "GPU"
    Driver      "modesetting"
    Option      "AccelMethod"   "glamor"
    Option      "DRI"           "3"
EndSection
EOF

    log_success "Xorg configuration created"
}

# ============================================================================
# 5. Créer l'image SD card
# ============================================================================
create_sdcard_image() {
    log_info "Creating SD card image ($IMAGE_SIZE MB)..."

    cd "$OUTPUT_DIR"

    # Créer l'image
    dd if=/dev/zero of=lfs-pinebook.img bs=1M count="$IMAGE_SIZE"

    # Partitionner pour Pinebook (U-Boot + rootfs)
    parted -s lfs-pinebook.img mklabel gpt
    parted -s lfs-pinebook.img mkpart primary fat32 16MiB 528MiB
    parted -s lfs-pinebook.img mkpart primary ext4 528MiB 100%
    parted -s lfs-pinebook.img set 1 boot on

    # Monter et copier
    LOOP_DEV=$(sudo losetup -f --show lfs-pinebook.img)
    sudo kpartx -a "$LOOP_DEV"

    # Formater boot (FAT32) et root (ext4)
    sudo mkfs.vfat /dev/mapper/$(basename "$LOOP_DEV")p1
    sudo mkfs.ext4 /dev/mapper/$(basename "$LOOP_DEV")p2

    # Monter
    sudo mount /dev/mapper/$(basename "$LOOP_DEV")p1 /mnt/boot
    sudo mount /dev/mapper/$(basename "$LOOP_DEV")p2 /mnt/root

    # Copier le système
    sudo cp -rp lfs-system/* /mnt/root/

    # Copier le noyau et l'initrd sur la partition boot
    sudo cp /mnt/root/boot/vmlinuz-lfs /mnt/boot/
    sudo cp /mnt/root/boot/initrd.img /mnt/boot/

    # Installer U-Boot
    sudo dd if=/usr/lib/u-boot/pinebook-pro-rk3399/u-boot-rockchip.bin \
        of="$LOOP_DEV" seek=64 conv=notrunc

    # Nettoyer
    sudo umount /mnt/boot /mnt/root
    sudo kpartx -d "$LOOP_DEV"
    sudo losetup -d "$LOOP_DEV"

    log_success "SD card image created: $OUTPUT_DIR/lfs-pinebook.img"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    build_lfs
    install_pinebook_packages
    create_pinebook_scripts
    create_xorg_config
    create_sdcard_image

    log_success "========================================="
    log_success "Pinebook Profile Build Complete!"
    log_success "========================================="
    echo ""
    echo "📱 Output files:"
    echo "   - SD card image:  $OUTPUT_DIR/lfs-pinebook.img"
    echo ""
    echo "📱 Installation on Pinebook:"
    echo ""
    echo "   1. Flash image to SD card:"
    echo "      dd if=lfs-pinebook.img of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "   2. Insert SD card into Pinebook"
    echo "   3. Power on (boot from SD automatically or press ESC for boot menu)"
    echo "   4. Default login: lfsuser / lfsuser123"
    echo ""
    echo "   Post-installation:"
    echo "   - Keyboard backlight: kbd-backlight up/down"
    echo "   - Battery care: automatic at 80%"
    echo ""
}

main "$@"