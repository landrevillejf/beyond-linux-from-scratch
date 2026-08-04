#!/bin/bash
# Create disk image for USB installation - Compatible with Docker and native
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fallback functions if utils.sh doesn't exist
if [ -f "$SCRIPT_DIR/../common/utils.sh" ]; then
    source "$SCRIPT_DIR/../common/utils.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warning() { echo "[WARNING] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
fi

# Detect if running in Docker
IN_DOCKER=false
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
    IN_DOCKER=true
    log_info "Running in Docker container"
fi

# Detect if running in Lima VM
IN_LIMA=false
if [ -f /etc/lima-version ]; then
    IN_LIMA=true
    log_info "Running in Lima VM"
fi

# Configuration
IMAGE_SIZE_MB=${IMAGE_SIZE_MB:-8192}
BOOT_SIZE_MB=${BOOT_SIZE_MB:-512}
SWAP_SIZE_MB=${SWAP_SIZE_MB:-2048}
ROOT_SIZE_MB=$((IMAGE_SIZE_MB - BOOT_SIZE_MB - SWAP_SIZE_MB))

log_info "Root partition size: ${ROOT_SIZE_MB}MB"

# Set LFS directory
if [ "$IN_DOCKER" = true ]; then
    LFS=${LFS:-/output}
    IMAGE_FILE="${LFS}/lfs.img"
else
    LFS=${LFS:-/mnt/lfs}
    IMAGE_FILE="${LFS}.img"
fi

log_info "Creating disk image of ${IMAGE_SIZE_MB}MB"
log_info "Image file: $IMAGE_FILE"

# Function to create image without loop device (for Docker)
create_image_docker() {
    log_info "Creating disk image in Docker mode (using file only)"

    # Create a sparse file
    dd if=/dev/zero of="$IMAGE_FILE" bs=1M count=0 seek="$IMAGE_SIZE_MB" status=progress 2>/dev/null || {
        # Fallback: create with actual size
        dd if=/dev/zero of="$IMAGE_FILE" bs=1M count="$IMAGE_SIZE_MB" status=progress 2>/dev/null
    }

    # Format as ext4 (no loop device needed)
    if command -v mkfs.ext4 &>/dev/null; then
        mkfs.ext4 -F "$IMAGE_FILE" 2>/dev/null || {
            log_warning "Could not format $IMAGE_FILE as ext4"
        }
    else
        log_warning "mkfs.ext4 not available, skipping format"
    fi

    # Create mount point
    mkdir -pv "$LFS" 2>/dev/null || true

    log_success "Docker image created at: $IMAGE_FILE"
    log_info "Size: $(du -h "$IMAGE_FILE" 2>/dev/null | cut -f1 || echo "unknown")"

    # In Docker, we can't mount loop devices, so just create directories
    mkdir -pv "$LFS"/{boot,etc,home,root,usr,var,bin,lib,lib64,sbin,opt,srv,media,mnt}
    mkdir -pv "$LFS/usr"/{bin,include,lib,lib64,sbin,share,src}
    mkdir -pv "$LFS/var"/{cache,lib,local,lock,log,opt,run,spool,tmp}
    mkdir -pv "$LFS/etc"/{profile.d,sysconfig,skel}

    log_success "Directory structure created at: $LFS"

    # Save the image path for later use
    echo "$IMAGE_FILE" >/tmp/lfs_image_file
    echo "file" >/tmp/lfs_mount_type

    return 0
}

# Function to create image with loop device (for native/Lima)
create_image_native() {
    log_info "Creating disk image with loop device"

    # Check if running as root (needed for loop devices)
    if [ "$EUID" -ne 0 ] && [ "$IN_DOCKER" = false ] && [ "$IN_LIMA" = false ]; then
        if sudo -n true 2>/dev/null; then
            log_info "Using sudo for privileged operations"
            USE_SUDO="sudo"
        else
            log_error "Root privileges required for loop device setup"
            log_info "Run with sudo or use Docker mode"
            exit 1
        fi
    else
        USE_SUDO=""
    fi

    # Check if losetup is available
    if ! command -v losetup &>/dev/null; then
        log_error "losetup not found. Installing required package..."
        if command -v apt-get &>/dev/null; then
            $USE_SUDO apt-get install -y util-linux 2>/dev/null || {
                log_warning "Could not install util-linux, falling back to file-only mode"
                create_image_docker
                return $?
            }
        elif command -v yum &>/dev/null; then
            $USE_SUDO yum install -y util-linux 2>/dev/null || {
                log_warning "Could not install util-linux, falling back to file-only mode"
                create_image_docker
                return $?
            }
        else
            log_warning "Could not install util-linux, falling back to file-only mode"
            create_image_docker
            return $?
        fi
    fi

    # Check if partprobe is available
    if ! command -v parted &>/dev/null; then
        log_error "parted not found"
        create_image_docker
        return $?
    fi

    # Check if mkfs tools are available
    for tool in mkfs.vfat mkfs.ext4 mkswap; do
        if ! command -v $tool &>/dev/null; then
            log_error "$tool not found"
            create_image_docker
            return $?
        fi
    done

    # Create empty image file
    log_info "Creating empty image file..."
    $USE_SUDO dd if=/dev/zero of="$IMAGE_FILE" bs=1M count="$IMAGE_SIZE_MB" status=progress 2>/dev/null || {
        log_warning "dd failed, falling back to file-only mode"
        create_image_docker
        return $?
    }

    # Setup loop device
    log_info "Setting up loop device..."
    LOOP_DEV=$($USE_SUDO losetup --find --show --partscan "$IMAGE_FILE" 2>/dev/null || {
        log_warning "losetup failed, falling back to file-only mode"
        create_image_docker
        return $?
    })

    if [ -z "$LOOP_DEV" ]; then
        log_warning "Failed to get loop device, falling back to file-only mode"
        create_image_docker
        return $?
    fi

    log_info "Loop device: $LOOP_DEV"

    # Create partition table
    log_info "Creating partition table..."
    $USE_SUDO parted -s "$LOOP_DEV" mklabel gpt 2>/dev/null || {
        log_warning "parted failed, falling back to file-only mode"
        $USE_SUDO losetup -d "$LOOP_DEV" 2>/dev/null || true
        create_image_docker
        return $?
    }

    $USE_SUDO parted -s "$LOOP_DEV" mkpart primary fat32 1MiB "${BOOT_SIZE_MB}MiB" 2>/dev/null || true
    $USE_SUDO parted -s "$LOOP_DEV" mkpart primary linux-swap "${BOOT_SIZE_MB}MiB" "$((BOOT_SIZE_MB + SWAP_SIZE_MB))MiB" 2>/dev/null || true
    $USE_SUDO parted -s "$LOOP_DEV" mkpart primary ext4 "$((BOOT_SIZE_MB + SWAP_SIZE_MB))MiB" 100% 2>/dev/null || true
    $USE_SUDO parted -s "$LOOP_DEV" set 1 esp on 2>/dev/null || true

    # Wait for partitions to appear
    log_info "Waiting for partitions..."
    sleep 2
    $USE_SUDO partprobe "$LOOP_DEV" 2>/dev/null || true
    sleep 2

    # Format partitions
    log_info "Formatting partitions..."
    $USE_SUDO mkfs.vfat -F32 "${LOOP_DEV}p1" 2>/dev/null || {
        log_warning "Failed to format boot partition, continuing..."
    }
    $USE_SUDO mkswap "${LOOP_DEV}p2" 2>/dev/null || {
        log_warning "Failed to format swap partition, continuing..."
    }
    $USE_SUDO mkfs.ext4 -F "${LOOP_DEV}p3" 2>/dev/null || {
        log_warning "Failed to format root partition, continuing..."
    }

    # Mount partitions
    log_info "Mounting partitions..."
    mkdir -pv "$LFS" 2>/dev/null || true
    $USE_SUDO mount "${LOOP_DEV}p3" "$LFS" 2>/dev/null || {
        log_warning "Failed to mount root partition"
    }
    mkdir -pv "$LFS/boot" 2>/dev/null || true
    $USE_SUDO mount "${LOOP_DEV}p1" "$LFS/boot" 2>/dev/null || {
        log_warning "Failed to mount boot partition"
    }
    $USE_SUDO swapon "${LOOP_DEV}p2" 2>/dev/null || {
        log_warning "Failed to enable swap"
    }

    log_success "Disk image created and mounted at $LFS"
    log_info "Loop device: $LOOP_DEV"
    echo "$LOOP_DEV" >/tmp/lfs_loop_device
    echo "loop" >/tmp/lfs_mount_type

    return 0
}

# Function to display information
show_info() {
    echo ""
    echo "========================================"
    echo "📊 Disk Image Information"
    echo "========================================"
    echo "Image file: $IMAGE_FILE"

    if [ -f "$IMAGE_FILE" ]; then
        echo "Size: $(du -h "$IMAGE_FILE" 2>/dev/null | cut -f1 || echo "unknown")"
        echo "Type: $(file "$IMAGE_FILE" 2>/dev/null | cut -d: -f2 || echo "unknown")"
    fi

    echo "Mount point: $LFS"

    if [ -d "$LFS" ]; then
        echo "Content: $(ls -la "$LFS" 2>/dev/null | wc -l) items"
    fi

    if [ -f /tmp/lfs_loop_device ]; then
        echo "Loop device: $(cat /tmp/lfs_loop_device 2>/dev/null || echo "none")"
    fi

    echo "========================================"
    echo ""
}

# Main execution
main() {
    if [ "$IN_DOCKER" = true ]; then
        log_info "Docker environment detected - using file-only mode"
        create_image_docker
        show_info
        exit 0
    fi

    # Try native mode first
    if create_image_native; then
        show_info
        log_success "Disk image created successfully with loop device!"
    else
        log_warning "Native mode failed, falling back to Docker mode"
        create_image_docker
        show_info
    fi
}

# Cleanup function (for when the script is interrupted)
cleanup() {
    log_info "Cleaning up..."
    if [ -f /tmp/lfs_loop_device ]; then
        LOOP_DEV=$(cat /tmp/lfs_loop_device 2>/dev/null)
        if [ -n "$LOOP_DEV" ]; then
            $USE_SUDO umount "${LOOP_DEV}p3" 2>/dev/null || true
            $USE_SUDO umount "${LOOP_DEV}p1" 2>/dev/null || true
            $USE_SUDO swapoff "${LOOP_DEV}p2" 2>/dev/null || true
            $USE_SUDO losetup -d "$LOOP_DEV" 2>/dev/null || true
            rm -f /tmp/lfs_loop_device
        fi
    fi
    rm -f /tmp/lfs_mount_type
    rm -f /tmp/lfs_image_file
}

trap cleanup EXIT INT TERM

main "$@"
