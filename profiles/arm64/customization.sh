#!/bin/bash
# Configuration spécifique ARM64 (aarch64)
# Exécuté dans le chroot final, après le stage BLFS de base.
# Utilise les variables d'environnement définies par le builder :
#   LFS, KERNEL_VERSION, BOARD, U_BOOT_BOARD, KERNEL_DTB, CREATE_SD_IMAGE, etc.

set -e

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;34m[SUCCESS]\033[0m $1"; }
log_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; exit 1; }

# ============================================================================
# VARIABLES PAR DÉFAUT (surchargeables par l'environnement)
# ============================================================================
BOARD="${BOARD:-rpi_4}"               # rpi_4, rpi_5, orangepi_pc, pine64, generic
U_BOOT_BOARD="${U_BOOT_BOARD:-rpi_4}"
KERNEL_DTB="${KERNEL_DTB:-bcm2711-rpi-4-b.dtb}"
CREATE_SD_IMAGE="${CREATE_SD_IMAGE:-yes}"
SD_IMAGE_PATH="${LFS}/../lfs-arm64.img"
SD_SIZE_MB="${SD_SIZE_MB:-2048}"
NUM_JOBS="${NUM_JOBS:-$(nproc 2>/dev/null || echo 4)}"

# Chemins
SOURCES_DIR="${LFS}/sources"
BOOT_DIR="${LFS}/boot"
ROOTFS_DIR="${LFS}"

# Vérification que LFS est défini
if [ -z "$LFS" ]; then
    log_error "La variable LFS n'est pas définie. Assurez-vous d'exécuter ce script dans le chroot ou avec l'environnement du builder."
fi

# ============================================================================
# DÉTECTION DE LA CARTE
# ============================================================================
detect_board() {
    case "$BOARD" in
        rpi_4|rpi4|raspberrypi4)
            BOARD="rpi_4"
            U_BOOT_BOARD="rpi_4"
            KERNEL_DTB="bcm2711-rpi-4-b.dtb"
            log_info "Configuring for Raspberry Pi 4"
            ;;
        rpi_5|rpi5|raspberrypi5)
            BOARD="rpi_5"
            U_BOOT_BOARD="rpi_5"
            KERNEL_DTB="bcm2712-rpi-5-b.dtb"
            log_info "Configuring for Raspberry Pi 5"
            ;;
        orangepi_pc|orangepi)
            BOARD="orangepi_pc"
            U_BOOT_BOARD="orangepi_pc"
            KERNEL_DTB="sun8i-h3-orangepi-pc.dtb"
            log_info "Configuring for Orange Pi PC"
            ;;
        pine64)
            BOARD="pine64"
            U_BOOT_BOARD="pine64_plus"
            KERNEL_DTB="sun50i-a64-pine64-plus.dtb"
            log_info "Configuring for Pine64"
            ;;
        *)
            BOARD="generic"
            U_BOOT_BOARD="generic"
            KERNEL_DTB="generic-arm64.dtb"
            log_warning "Unknown board: $BOARD, using generic configuration"
            ;;
    esac
    # Exporter pour les sous‑scripts éventuels
    export BOARD U_BOOT_BOARD KERNEL_DTB
}

# ============================================================================
# INSTALLATION DU NOYAU ARM64
# ============================================================================
install_arm64_kernel() {
    log_info "Building and installing ARM64 kernel (version ${KERNEL_VERSION:-6.16.1})..."

    cd "$SOURCES_DIR" || log_error "Sources directory not found"

    # Trouver l'archive du noyau
    KERNEL_TAR=$(ls linux-*.tar.xz 2>/dev/null | head -1)
    if [ -z "$KERNEL_TAR" ]; then
        log_error "No Linux kernel tarball found in $SOURCES_DIR"
    fi

    tar -xf "$KERNEL_TAR"
    KERNEL_DIR=$(tar -tf "$KERNEL_TAR" | head -1 | cut -d/ -f1)
    cd "$KERNEL_DIR" || log_error "Failed to enter kernel source directory"

    # Nettoyer et utiliser une config de base arm64
    make ARCH=arm64 CROSS_COMPILE=aarch64-lfs-linux-gnu- mrproper

    # Utiliser la config fournie par le builder ou une defconfig
    if [ -f "/config/kernel-config-arm64" ]; then
        cp "/config/kernel-config-arm64" .config
    else
        make ARCH=arm64 CROSS_COMPILE=aarch64-lfs-linux-gnu- defconfig
    fi

    # Personnaliser pour la carte
    if [ "$BOARD" = "rpi_4" ] || [ "$BOARD" = "rpi_5" ]; then
        scripts/config --enable ARCH_BCM2835
        scripts/config --enable ARCH_BCM2711
    fi

    make ARCH=arm64 CROSS_COMPILE=aarch64-lfs-linux-gnu- olddefconfig

    # Construire
    make ARCH=arm64 CROSS_COMPILE=aarch64-lfs-linux-gnu- -j"$NUM_JOBS" Image modules dtbs

    # Installer les modules
    make ARCH=arm64 CROSS_COMPILE=aarch64-lfs-linux-gnu- INSTALL_MOD_PATH="$ROOTFS_DIR" modules_install

    # Installer l'image du noyau et les DTBs
    mkdir -p "$BOOT_DIR"
    cp arch/arm64/boot/Image "$BOOT_DIR/vmlinuz-lfs"
    cp arch/arm64/boot/dts/*/$KERNEL_DTB "$BOOT_DIR/" 2>/dev/null || true
    # Copier toutes les DTBs utiles
    find arch/arm64/boot/dts -name "*.dtb" -exec cp {} "$BOOT_DIR/" \;

    cd "$SOURCES_DIR"
    log_success "ARM64 kernel installed"
}

# ============================================================================
# INSTALLATION DE U-BOOT
# ============================================================================
install_uboot() {
    log_info "Building and installing U-Boot for $U_BOOT_BOARD..."

    cd "$SOURCES_DIR" || log_error "Sources directory not found"

    UBOOT_TAR=$(ls u-boot-*.tar.bz2 2>/dev/null | head -1)
    if [ -z "$UBOOT_TAR" ]; then
        log_info "U-Boot tarball not found. Downloading default version..."
        wget -q https://ftp.denx.de/pub/u-boot/u-boot-2024.01.tar.bz2 -O u-boot-2024.01.tar.bz2
        UBOOT_TAR="u-boot-2024.01.tar.bz2"
    fi

    tar -xjf "$UBOOT_TAR"
    UBOOT_DIR=$(tar -tf "$UBOOT_TAR" | head -1 | cut -d/ -f1)
    cd "$UBOOT_DIR" || log_error "Failed to enter U-Boot directory"

    make ${U_BOOT_BOARD}_defconfig
    make ARCH=arm CROSS_COMPILE=aarch64-lfs-linux-gnu- -j"$NUM_JOBS"

    # Installer les fichiers U-Boot
    cp u-boot.bin "$BOOT_DIR/"
    cp u-boot.img "$BOOT_DIR/" 2>/dev/null || true
    if [ -f "u-boot-dtb.bin" ]; then
        cp u-boot-dtb.bin "$BOOT_DIR/"
    fi

    # Créer config.txt pour Raspberry Pi
    if [ "$BOARD" = "rpi_4" ] || [ "$BOARD" = "rpi_5" ]; then
        cat > "$BOOT_DIR/config.txt" << 'EOF'
# LFS ARM64 configuration for Raspberry Pi
arm_64bit=1
kernel=u-boot.bin
enable_uart=1
uart_2ndstage=1
force_turbo=1
boot_delay=0
gpu_mem=64
disable_splash=1
EOF
        if [ "$BOARD" = "rpi_5" ]; then
            echo "device_tree=bcm2712-rpi-5-b.dtb" >> "$BOOT_DIR/config.txt"
        else
            echo "device_tree=bcm2711-rpi-4-b.dtb" >> "$BOOT_DIR/config.txt"
        fi
    fi

    cd "$SOURCES_DIR"
    log_success "U-Boot installed"
}

# ============================================================================
# CRÉATION DU SCRIPT DE DÉMARRAGE U-BOOT
# ============================================================================
create_boot_script() {
    log_info "Creating U-Boot boot script..."

    cat > "$BOOT_DIR/boot.cmd" << 'EOF'
# U-Boot script for LFS ARM64
setenv bootargs console=ttyAMA0,115200 root=/dev/mmcblk0p2 rootwait rw
load mmc 0:1 ${kernel_addr_r} /vmlinuz-lfs
load mmc 0:1 ${fdt_addr_r} /${KERNEL_DTB}
booti ${kernel_addr_r} - ${fdt_addr_r}
EOF

    # Remplacer KERNEL_DTB dans le script
    sed -i "s|\${KERNEL_DTB}|$KERNEL_DTB|g" "$BOOT_DIR/boot.cmd"

    if command -v mkimage >/dev/null; then
        mkimage -A arm64 -O linux -T script -C none -a 0 -e 0 -n "LFS Boot Script" -d "$BOOT_DIR/boot.cmd" "$BOOT_DIR/boot.scr"
        log_success "Boot script created"
    else
        log_warning "mkimage not found, boot script not compiled. Install u-boot-tools."
    fi
}

# ============================================================================
# CONFIGURATION FSTAB
# ============================================================================
configure_fstab() {
    log_info "Configuring fstab for ARM64..."

    cat > "$ROOTFS_DIR/etc/fstab" << 'EOF'
# /etc/fstab for ARM64 LFS
# <file system> <mount point> <type> <options> <dump> <pass>

/dev/mmcblk0p2  /           ext4    defaults,noatime  0   1
/dev/mmcblk0p1  /boot       vfat    defaults          0   2
proc            /proc       proc    defaults          0   0
sysfs           /sys        sysfs   defaults          0   0
devtmpfs        /dev        devtmpfs mode=0755,nosuid 0   0
tmpfs           /dev/shm    tmpfs   defaults          0   0
EOF

    log_success "fstab configured"
}

# ============================================================================
# CRÉATION DE L'IMAGE SD
# ============================================================================
create_sd_image() {
    if [ "$CREATE_SD_IMAGE" != "yes" ]; then
        log_info "SD card image creation disabled (CREATE_SD_IMAGE=$CREATE_SD_IMAGE)"
        return
    fi

    log_info "Creating SD card image ($SD_IMAGE_PATH) of size $SD_SIZE_MB MB..."

    # Créer une image vide
    dd if=/dev/zero of="$SD_IMAGE_PATH" bs=1M count="$SD_SIZE_MB" status=progress

    # Partitions
    parted -s "$SD_IMAGE_PATH" mklabel msdos
    parted -s "$SD_IMAGE_PATH" mkpart primary fat32 1MiB 256MiB
    parted -s "$SD_IMAGE_PATH" mkpart primary ext4 256MiB 100%

    # Boucle
    LOOP_DEV=$(losetup --find --show --partscan "$SD_IMAGE_PATH")
    if [ -z "$LOOP_DEV" ]; then
        log_error "Failed to set up loop device for $SD_IMAGE_PATH"
    fi

    # Formater
    mkfs.vfat -F32 "${LOOP_DEV}p1"
    mkfs.ext4 -F "${LOOP_DEV}p2"

    # Monter
    mkdir -p /mnt/boot /mnt/root
    mount "${LOOP_DEV}p1" /mnt/boot
    mount "${LOOP_DEV}p2" /mnt/root

    # Copier le système
    rsync -a --exclude={/dev/*,/proc/*,/sys/*,/tmp/*,/run/*,/mnt/*,/media/*} "$ROOTFS_DIR/" /mnt/root/
    cp -r "$BOOT_DIR"/* /mnt/boot/

    # Nettoyer
    umount /mnt/boot
    umount /mnt/root
    losetup -d "$LOOP_DEV"

    log_success "SD card image created: $SD_IMAGE_PATH"
    echo ""
    echo "To flash to SD card:"
    echo "  dd if=$SD_IMAGE_PATH of=/dev/sdX bs=4M status=progress"
}

# ============================================================================
# INSTALLATION D'OUTILS SPÉCIFIQUES ARM64 (optionnel)
# ============================================================================
install_arm64_tools() {
    log_info "Installing ARM64-specific utilities (qemu-user-static, etc.)..."

    # Ces outils doivent être compilés avant, mais on peut ajouter des scripts
    # pour les installer depuis les sources déjà présentes.
    # Par exemple, qemu-user-static peut être construit plus tôt.
    # On laisse vide ici, car le builder gère déjà les paquets BLFS.
    log_info "ARM64 tools installation handled by BLFS stage if enabled."
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    log_info "=== ARM64 Profile Configuration ==="
    detect_board

    # S'assurer que les répertoires existent
    mkdir -p "$BOOT_DIR"

    # Étapes principales
    install_arm64_kernel
    install_uboot
    create_boot_script
    configure_fstab
    install_arm64_tools

    # Créer l'image SD si demandé
    create_sd_image

    log_success "ARM64 profile configuration complete!"
    echo ""
    echo "=========================================="
    echo "ARM64 LFS System Ready"
    echo "=========================================="
    echo "Board      : $BOARD"
    echo "U-Boot     : $U_BOOT_BOARD"
    echo "DTB        : $KERNEL_DTB"
    echo "Kernel     : $BOOT_DIR/vmlinuz-lfs"
    if [ "$CREATE_SD_IMAGE" = "yes" ]; then
        echo "SD Image   : $SD_IMAGE_PATH"
    fi
    echo "=========================================="
}

# Exécuter si le script n'est pas sourcé
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi