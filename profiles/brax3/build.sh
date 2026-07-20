#!/bin/bash
# Brax3 Profile Builder - Build LFS for Brax3 Linux smartphone
# Target: Qualcomm Snapdragon-based mobile phone with 4G/5G

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../common/utils.sh"

log_info "========================================="
log_info "Brax3 Profile Builder"
log_info "Target: Brax3 Linux Smartphone (Qualcomm)"
log_info "========================================="

# Configuration
OUTPUT_DIR="${OUTPUT_DIR:-./lfs-brax3}"
IMAGE_SIZE="${IMAGE_SIZE:-4096}"  # 4GB minimum
BRAX3_VERSION="${BRAX3_VERSION:-1}"  # Hardware revision

log_info "Building for Brax3 v$BRAX3_VERSION"

# ============================================================================
# 1. Build LFS for ARM64
# ============================================================================
build_lfs() {
    log_info "Building LFS for Brax3..."

    cd "$SCRIPT_DIR/../.."

    python3 builder.py \
        --profile minimal \
        --config config/build-brax3.conf \
        --output "$OUTPUT_DIR/lfs-system" \
        --no-live

    log_success "LFS system built for Brax3"
}

# ============================================================================
# 2. Install Brax3 packages
# ============================================================================
install_brax3_packages() {
    log_info "Installing Brax3 smartphone packages..."

    cd "$OUTPUT_DIR/lfs-system"

    # Créer les répertoires
    mkdir -p etc/ModemManager
    mkdir -p etc/ofono
    mkdir -p etc/systemd/system
    mkdir -p etc/NetworkManager/conf.d
    mkdir -p etc/NetworkManager/dispatcher.d
    mkdir -p usr/local/bin
    mkdir -p etc/udev/rules.d

    # Configuration ModemManager pour Brax3
    cat > etc/ModemManager/ModemManager.conf << 'EOF'
[General]
LogLevel=INFO

[Modem]
FilterPolicy=STRICT
AllowedDrivers=qmi,mbim

[QMI]
QmiDeviceOpenFlags=none
EOF

    # Configuration NetworkManager pour données mobiles
    cat > etc/NetworkManager/conf.d/99-mobile.conf << 'EOF'
[connection]
wifi.mac-address-randomization=1

[device-wifi]
wifi.scan-rand-mac-address=no

[device-modem]
modem.mtu=1500
EOF

    # Script de gestion du modem
    cat > usr/local/bin/brax3-modem << 'EOF'
#!/bin/bash
# Brax3 modem control script

case "$1" in
    status)
        mmcli -L
        ;;
    enable)
        mmcli -m 0 --enable
        ;;
    disable)
        mmcli -m 0 --disable
        ;;
    sms)
        if [ -n "$2" ] && [ -n "$3" ]; then
            mmcli -m 0 --messaging-create-sms="text='$3',number='$2'"
        else
            echo "Usage: $0 sms <number> <message>"
        fi
        ;;
    call)
        if [ -n "$2" ]; then
            mmcli -m 0 --voice-create-call="tel:$2"
        else
            echo "Usage: $0 call <number>"
        fi
        ;;
    *)
        echo "Usage: $0 {status|enable|disable|sms|call}"
        exit 1
        ;;
esac
EOF
    chmod +x usr/local/bin/brax3-modem

    # Service systemd pour le modem
    cat > etc/systemd/system/brax3-modem.service << 'EOF'
[Unit]
Description=Brax3 Modem Manager
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/brax3-modem status
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

    # udev rules pour Brax3
    cat > etc/udev/rules.d/99-brax3.rules << 'EOF'
# Brax3 Modem
SUBSYSTEM=="usb", ATTR{idVendor}=="05c6", ATTR{idProduct}=="9001", MODE="0666", GROUP="dialout"
SUBSYSTEM=="usb", ATTR{idVendor}=="05c6", ATTR{idProduct}=="9025", MODE="0666", GROUP="dialout"

# Brax3 Touchscreen
SUBSYSTEM=="input", ATTRS{name}=="Goodix Touchscreen", MODE="0666", SYMLINK+="input/touchscreen"

# Brax3 Buttons
SUBSYSTEM=="input", ATTRS{name}=="gpio-keys", MODE="0666", ENV{LIBINPUT_IGNORE_DEVICE}="1"

# Brax3 Sensors
SUBSYSTEM=="iio", ATTRS{name}=="accelerometer", MODE="0666"
SUBSYSTEM=="iio", ATTRS{name}=="proximity", MODE="0666"
EOF

    log_success "Brax3 packages installed"
}

# ============================================================================
# 3. Créer les scripts spécifiques Brax3
# ============================================================================
create_brax3_scripts() {
    log_info "Creating Brax3 smartphone scripts..."

    # Script de contrôle batterie
    cat > "$OUTPUT_DIR/lfs-system/usr/local/bin/brax3-battery" << 'EOF'
#!/bin/bash
# Battery information for Brax3

BATTERY_PATH="/sys/class/power_supply/battery"

if [ -d "$BATTERY_PATH" ]; then
    echo "Battery Status:"
    echo "  Capacity: $(cat $BATTERY_PATH/capacity)%"
    echo "  Status: $(cat $BATTERY_PATH/status)"
    echo "  Temperature: $(($(cat $BATTERY_PATH/temp) / 1000))°C"

    if [ -f "$BATTERY_PATH/current_now" ]; then
        echo "  Current: $(($(cat $BATTERY_PATH/current_now) / 1000)) mA"
    fi
    if [ -f "$BATTERY_PATH/voltage_now" ]; then
        echo "  Voltage: $(($(cat $BATTERY_PATH/voltage_now) / 1000)) mV"
    fi
else
    echo "Battery information not available"
fi
EOF
    chmod +x "$OUTPUT_DIR/lfs-system/usr/local/bin/brax3-battery"

    # Script pour l'écran
    cat > "$OUTPUT_DIR/lfs-system/usr/local/bin/brax3-display" << 'EOF'
#!/bin/bash
# Display control for Brax3

BACKLIGHT_PATH="/sys/class/backlight/panel0-backlight"

case "$1" in
    up)
        CURRENT=$(cat $BACKLIGHT_PATH/brightness 2>/dev/null || echo 0)
        MAX=$(cat $BACKLIGHT_PATH/max_brightness 2>/dev/null || echo 255)
        NEW=$((CURRENT + 10))
        [ $NEW -gt $MAX ] && NEW=$MAX
        echo $NEW > $BACKLIGHT_PATH/brightness
        ;;
    down)
        CURRENT=$(cat $BACKLIGHT_PATH/brightness 2>/dev/null || echo 0)
        NEW=$((CURRENT - 10))
        [ $NEW -lt 0 ] && NEW=0
        echo $NEW > $BACKLIGHT_PATH/brightness
        ;;
    off)
        echo 0 > $BACKLIGHT_PATH/brightness
        ;;
    on)
        MAX=$(cat $BACKLIGHT_PATH/max_brightness 2>/dev/null || echo 255)
        echo $MAX > $BACKLIGHT_PATH/brightness
        ;;
    status)
        CURRENT=$(cat $BACKLIGHT_PATH/brightness 2>/dev/null || echo 0)
        MAX=$(cat $BACKLIGHT_PATH/max_brightness 2>/dev/null || echo 255)
        echo "Brightness: $CURRENT / $MAX ($((CURRENT * 100 / MAX))%)"
        ;;
    *)
        echo "Usage: $0 {up|down|on|off|status}"
        ;;
esac
EOF
    chmod +x "$OUTPUT_DIR/lfs-system/usr/local/bin/brax3-display"

    # Script pour les notifications (vibration)
    cat > "$OUTPUT_DIR/lfs-system/usr/local/bin/brax3-vibrate" << 'EOF'
#!/bin/bash
# Haptic feedback for Brax3

VIBE_PATH="/sys/class/leds/vibrator"

if [ ! -d "$VIBE_PATH" ]; then
    echo "Vibrator not found"
    exit 1
fi

duration=${1:-100}  # milliseconds

echo $duration > $VIBE_PATH/duration
echo 1 > $VIBE_PATH/activate
sleep 0.1
echo 0 > $VIBE_PATH/activate
EOF
    chmod +x "$OUTPUT_DIR/lfs-system/usr/local/bin/brax3-vibrate"

    log_success "Brax3 scripts created"
}

# ============================================================================
# 4. Créer la configuration Phosh (interface mobile)
# ============================================================================
create_phosh_config() {
    log_info "Creating Phosh mobile interface configuration..."

    mkdir -p "$OUTPUT_DIR/lfs-system/etc/phosh"
    mkdir -p "$OUTPUT_DIR/lfs-system/etc/dconf/db/local.d"

    # Configuration Phosh
    cat > "$OUTPUT_DIR/lfs-system/etc/phosh/config.ini" << 'EOF'
[shell]
layout=default
favorite-apps=org.gnome.Calls,org.gnome.Contacts,chatty,org.gnome.Evolution,librem.css

[ui]
scale-factor=2
dark-mode=true
show-date=true
show-battery-percentage=true

[lock-screen]
show-clock=true
show-date=true
show-notifications=true
EOF

    # Dconf settings pour Phosh
    cat > "$OUTPUT_DIR/lfs-system/etc/dconf/db/local.d/00-phosh" << 'EOF'
[org/gnome/desktop/interface]
gtk-theme='Adwaita-dark'
icon-theme='Adwaita'
cursor-theme='Adwaita'
font-name='Cantarell 11'

[org/gnome/desktop/wm/preferences]
button-layout='close,minimize,maximize:'
theme='Adwaita-dark'

[org/gnome/shell]
favorite-apps=['org.gnome.Calls.desktop', 'org.gnome.Contacts.desktop', 'chatty.desktop', 'org.gnome.Evolution.desktop', 'org.gnome.Settings.desktop']

[org/gnome/mutter]
experimental-features=['scale-monitor-framebuffer']
EOF

    log_success "Phosh configuration created"
}

# ============================================================================
# 5. Créer le script d'installation pour Brax3
# ============================================================================
create_installation_script() {
    log_info "Creating Brax3 installation script..."

    cat > "$OUTPUT_DIR/install-brax3.sh" << 'EOF'
#!/bin/bash
# Brax3 LFS Installation Script

set -e

echo "========================================="
echo "Brax3 LFS Installation"
echo "========================================="

# Détection du périphérique
if [ -b "/dev/disk/by-partlabel/boot_a" ]; then
    BOOT_DEV="/dev/disk/by-partlabel/boot_a"
    SYSTEM_DEV="/dev/disk/by-partlabel/system_a"
    DATA_DEV="/dev/disk/by-partlabel/userdata"
elif [ -b "/dev/mmcblk0" ]; then
    BOOT_DEV="/dev/mmcblk0p1"
    SYSTEM_DEV="/dev/mmcblk0p2"
    DATA_DEV="/dev/mmcblk0p3"
else
    echo "No Brax3 partitions found!"
    exit 1
fi

echo "Installing to:"
echo "  Boot: $BOOT_DEV"
echo "  System: $SYSTEM_DEV"
echo "  Data: $DATA_DEV"

# Monter les partitions
mkdir -p /mnt/{boot,system,data}
mount $BOOT_DEV /mnt/boot
mount $SYSTEM_DEV /mnt/system
mount $DATA_DEV /mnt/data

# Copier le système
echo "Copying system files..."
cp -rp /lfs-system/* /mnt/system/

# Copier le noyau
echo "Installing kernel..."
cp /mnt/system/boot/vmlinuz-lfs /mnt/boot/
cp /mnt/system/boot/initrd.img /mnt/boot/

# Nettoyer
umount /mnt/boot
umount /mnt/system
umount /mnt/data

echo "Installation complete!"
echo "Reboot your Brax3 to start LFS"
EOF

    chmod +x "$OUTPUT_DIR/install-brax3.sh"

    log_success "Installation script created"
}

# ============================================================================
# 6. Créer l'image flashable pour Brax3
# ============================================================================
create_flash_image() {
    log_info "Creating Brax3 flashable image ($IMAGE_SIZE MB)..."

    cd "$OUTPUT_DIR"

    # Créer l'image avec les partitions Qualcomm
    dd if=/dev/zero of=brax3-lfs.img bs=1M count="$IMAGE_SIZE"

    # Partitionner selon le schéma Qualcomm
    parted -s brax3-lfs.img mklabel gpt

    # Partitions Qualcomm standard pour Brax3
    # boot_a: 64MB, system_a: 3GB, vendor_a: 512MB, userdata: reste
    parted -s brax3-lfs.img mkpart boot_a fat32 1MiB 65MiB
    parted -s brax3-lfs.img mkpart system_a ext4 65MiB 3137MiB
    parted -s brax3-lfs.img mkpart vendor_a ext4 3137MiB 3649MiB
    parted -s brax3-lfs.img mkpart userdata ext4 3649MiB 100%

    # Configurer les flags
    parted -s brax3-lfs.img set 1 boot on
    parted -s brax3-lfs.img set 2 msftdata on

    # Monter et copier
    LOOP_DEV=$(sudo losetup -f --show brax3-lfs.img)
    sudo kpartx -a "$LOOP_DEV"

    # Formater
    sudo mkfs.vfat /dev/mapper/$(basename "$LOOP_DEV")p1
    sudo mkfs.ext4 /dev/mapper/$(basename "$LOOP_DEV")p2
    sudo mkfs.ext4 /dev/mapper/$(basename "$LOOP_DEV")p3
    sudo mkfs.ext4 /dev/mapper/$(basename "$LOOP_DEV")p4

    # Monter et copier
    sudo mount /dev/mapper/$(basename "$LOOP_DEV")p1 /mnt/boot
    sudo mount /dev/mapper/$(basename "$LOOP_DEV")p2 /mnt/system
    sudo mount /dev/mapper/$(basename "$LOOP_DEV")p3 /mnt/vendor

    sudo cp -rp lfs-system/boot/vmlinuz-lfs /mnt/boot/
    sudo cp -rp lfs-system/boot/initrd.img /mnt/boot/
    sudo cp -rp lfs-system/* /mnt/system/

    # Cleanup
    sudo umount /mnt/boot /mnt/system /mnt/vendor
    sudo kpartx -d "$LOOP_DEV"
    sudo losetup -d "$LOOP_DEV"

    log_success "Flashable image created: $OUTPUT_DIR/brax3-lfs.img"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    build_lfs
    install_brax3_packages
    create_brax3_scripts
    create_phosh_config
    create_installation_script
    create_flash_image

    log_success "========================================="
    log_success "Brax3 Profile Build Complete!"
    log_success "========================================="
    echo ""
    echo "📱 Output files:"
    echo "   - Flash image:  $OUTPUT_DIR/brax3-lfs.img"
    echo "   - Installer:    $OUTPUT_DIR/install-brax3.sh"
    echo ""
    echo "📱 Installation on Brax3:"
    echo ""
    echo "   METHOD 1 - Fastboot:"
    echo "     fastboot flash boot $OUTPUT_DIR/brax3-lfs.img"
    echo ""
    echo "   METHOD 2 - Recovery:"
    echo "     adb push $OUTPUT_DIR/install-brax3.sh /sdcard/"
    echo "     adb shell sh /sdcard/install-brax3.sh"
    echo ""
    echo "   METHOD 3 - SD Card (if supported):"
    echo "     dd if=brax3-lfs.img of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "   Default login: lfsuser / lfsuser123"
    echo ""
    echo "   Post-installation on phone:"
    echo "   - Modem: sudo brax3-modem enable"
    echo "   - Battery: brax3-battery"
    echo "   - Display: brax3-display up/down"
    echo ""
}

main "$@"