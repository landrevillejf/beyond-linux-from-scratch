#!/bin/bash
# First-boot service – runs once on first boot to finalize system setup
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

log_info "========================================="
log_info "Setting up first-boot service"
log_info "========================================="

# -----------------------------------------------------------------------
# The first-boot script that will run inside the built system on first boot.
# Both Docker and native modes install the SAME inner script.
# -----------------------------------------------------------------------
read -r -d '' FIRST_BOOT_SCRIPT <<'INNEREOF' || true
#!/bin/bash
# first-boot.sh – runs once on the very first boot of the built system
# Regenerates unique system state, then disables itself.
set -e

LOG=/var/log/first-boot.log
exec > >(tee -a "$LOG") 2>&1
echo "=== LFS First-boot configuration started at $(date) ==="

# ------------------------------------------------------------------
# 1. Regenerate SSH host keys (unique per installation)
# ------------------------------------------------------------------
if [ -d /etc/ssh ]; then
    echo "Regenerating SSH host keys..."
    rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
    if command -v ssh-keygen >/dev/null 2>&1; then
        ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -q
        ssh-keygen -t rsa    -f /etc/ssh/ssh_host_rsa_key    -N "" -q -b 4096
        echo "SSH host keys regenerated"
    else
        echo "ssh-keygen not found – skipping SSH key regeneration"
    fi
fi

# ------------------------------------------------------------------
# 2. MANDATORY: Set root password and create user account
#    If not already configured by the installer, prompt interactively.
# ------------------------------------------------------------------
echo ""
echo "========================================"
echo "  LFS First-Boot Account Setup"
echo "========================================"
echo ""

# 2a. Root password – MUST be set
ROOT_LOCKED=false
if [ -f /etc/shadow ]; then
    root_entry=$(grep '^root:' /etc/shadow 2>/dev/null || true)
    # Check if root password is locked (! or * or empty)
    if echo "$root_entry" | grep -qE 'root:[!*]:' || echo "$root_entry" | grep -qE 'root::'; then
        ROOT_LOCKED=true
    fi
fi

if $ROOT_LOCKED || ! grep -q '^root:' /etc/shadow 2>/dev/null; then
    echo "Root account has no password set. You MUST set one now."
    echo ""
    while true; do
        read -rsp "Enter new root password: " ROOT_PASS
        echo ""
        if [ -z "$ROOT_PASS" ]; then
            echo "ERROR: Password cannot be empty. Try again."
            continue
        fi
        if [ ${#ROOT_PASS} -lt 8 ]; then
            echo "ERROR: Password must be at least 8 characters. Try again."
            continue
        fi
        read -rsp "Confirm root password: " ROOT_PASS2
        echo ""
        if [ "$ROOT_PASS" != "$ROOT_PASS2" ]; then
            echo "ERROR: Passwords do not match. Try again."
            continue
        fi
        break
    done
    echo "root:$ROOT_PASS" | chpasswd 2>/dev/null || \
        passwd root <<< "$ROOT_PASS" 2>/dev/null || true
    unset ROOT_PASS ROOT_PASS2
    # Set password expiry policy for root
    if command -v chage >/dev/null 2>&1; then
        chage -M 90 -W 14 root 2>/dev/null || true
    fi
    echo "Root password set successfully."
else
    echo "Root password is already configured."
fi
echo ""

# 2b. User account – MUST exist with a password
# Check if any regular user (UID >= 1000) exists with a valid password
REGULAR_USER_EXISTS=false
if [ -f /etc/passwd ] && [ -f /etc/shadow ]; then
    while IFS=: read -r uname _ uid _ _ _ _; do
        if [ "$uid" -ge 1000 ] && [ "$uid" -lt 65000 ] && [ "$uname" != "nobody" ]; then
            # Check if this user has a valid (non-locked) password
            shadow_entry=$(grep "^${uname}:" /etc/shadow 2>/dev/null || true)
            if [ -n "$shadow_entry" ]; then
                pass_field=$(echo "$shadow_entry" | cut -d: -f2)
                if [ -n "$pass_field" ] && [ "$pass_field" != "!" ] && [ "$pass_field" != "*" ] && [ "$pass_field" != "!!" ]; then
                    REGULAR_USER_EXISTS=true
                    echo "Regular user '$uname' exists with a valid password."
                    break
                fi
            fi
        fi
    done < /etc/passwd
fi

if ! $REGULAR_USER_EXISTS; then
    echo "No regular user account found. You MUST create one now."
    echo ""
    while true; do
        read -rp "Enter username for new account: " NEW_USER
        if [ -z "$NEW_USER" ]; then
            echo "ERROR: Username cannot be empty."
            continue
        fi
        if ! echo "$NEW_USER" | grep -qE '^[a-z_][a-z0-9_-]*$'; then
            echo "ERROR: Invalid username. Use lowercase letters, digits, hyphens, underscores."
            continue
        fi
        if id "$NEW_USER" >/dev/null 2>&1; then
            echo "ERROR: User '$NEW_USER' already exists. Choose another name."
            continue
        fi
        break
    done

    while true; do
        read -rsp "Enter password for $NEW_USER: " USER_PASS
        echo ""
        if [ -z "$USER_PASS" ]; then
            echo "ERROR: Password cannot be empty."
            continue
        fi
        if [ ${#USER_PASS} -lt 8 ]; then
            echo "ERROR: Password must be at least 8 characters."
            continue
        fi
        read -rsp "Confirm password for $NEW_USER: " USER_PASS2
        echo ""
        if [ "$USER_PASS" != "$USER_PASS2" ]; then
            echo "ERROR: Passwords do not match."
            continue
        fi
        break
    done

    # Create the user
    groupadd "$NEW_USER" 2>/dev/null || true
    useradd -m -g "$NEW_USER" -G wheel,audio,video,storage -s /bin/bash "$NEW_USER" 2>/dev/null || true
    echo "$NEW_USER:$USER_PASS" | chpasswd 2>/dev/null || \
        passwd "$NEW_USER" <<< "$USER_PASS" 2>/dev/null || true
    unset USER_PASS USER_PASS2

    # Add to sudoers
    echo "$NEW_USER ALL=(ALL) ALL" >> /etc/sudoers 2>/dev/null || true

    # Set password expiry policy for new user
    if command -v chage >/dev/null 2>&1; then
        chage -M 90 -W 14 "$NEW_USER" 2>/dev/null || true
    fi

    # Create home directory if not already done
    if [ ! -d "/home/$NEW_USER" ]; then
        mkdir -p "/home/$NEW_USER"
        chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER"
    fi

    echo "User '$NEW_USER' created successfully."
else
    echo "Regular user account is already configured."
fi
echo ""
echo "Account setup complete."
echo "========================================"
echo ""

# ------------------------------------------------------------------
# 3. Generate locale if locale-gen exists
# ------------------------------------------------------------------
if [ -f /etc/locale.conf ]; then
    LANG=$(grep '^LANG=' /etc/locale.conf 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "en_US.UTF-8")
else
    LANG="en_US.UTF-8"
fi

if command -v locale-gen >/dev/null 2>&1; then
    echo "Generating locale: $LANG"
    locale-gen "$LANG" 2>/dev/null || true
elif command -v localedef >/dev/null 2>&1; then
    echo "Generating locale with localedef: $LANG"
    localedef -i "${LANG%%.*}" -c -f UTF-8 -A /usr/share/locale/locale.alias "$LANG" 2>/dev/null || true
fi

# ------------------------------------------------------------------
# 4. Configure timezone
# ------------------------------------------------------------------
if [ -f /etc/timezone ]; then
    TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
elif [ -f /etc/localtime ] && [ -L /etc/localtime ]; then
    TZ=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
else
    TZ="UTC"
fi

if [ -f "/usr/share/zoneinfo/$TZ" ]; then
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "Timezone set to: $TZ"
else
    echo "Timezone zone file not found for: $TZ"
fi

# ------------------------------------------------------------------
# 5. Update dynamic linker cache
# ------------------------------------------------------------------
if [ -x /sbin/ldconfig ]; then
    echo "Running ldconfig..."
    /sbin/ldconfig 2>/dev/null || true
fi

# ------------------------------------------------------------------
# 6. Resize root partition for live USB (if running from overlay)
# ------------------------------------------------------------------
if [ -f /etc/lfs-live-usb ] && command -v growpart >/dev/null 2>&1; then
    ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    if [ -n "$ROOT_DEV" ]; then
        PARENT=$(echo "$ROOT_DEV" | sed 's/[0-9]*$//')
        PARTNUM=$(echo "$ROOT_DEV" | grep -o '[0-9]*$')
        if [ -n "$PARENT" ] && [ -n "$PARTNUM" ]; then
            echo "Resizing live USB partition $ROOT_DEV..."
            growpart "$PARENT" "$PARTNUM" 2>/dev/null || true
            if command -v resize2fs >/dev/null 2>&1; then
                resize2fs "$ROOT_DEV" 2>/dev/null || true
            fi
        fi
    fi
fi

# ------------------------------------------------------------------
# 7. Update machine-id (unique per installation)
# ------------------------------------------------------------------
if [ -f /etc/machine-id ] && [ "$(cat /etc/machine-id 2>/dev/null)" = "uninitialized" ]; then
    if command -v systemd-machine-id-setup >/dev/null 2>&1; then
        systemd-machine-id-setup 2>/dev/null || true
    else
        # Generate a random machine-id
        head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n' > /etc/machine-id
    fi
    echo "Machine ID regenerated"
fi

# ------------------------------------------------------------------
# 8. Clean up temporary build artifacts
# ------------------------------------------------------------------
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
rm -f /etc/.first-boot-password-change-required 2>/dev/null || true

# ------------------------------------------------------------------
# 9. Disable this service so it never runs again
# ------------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    systemctl disable first-boot.service 2>/dev/null || true
    echo "first-boot.service disabled"
elif command -v update-rc.d >/dev/null 2>&1; then
    update-rc.d -f first-boot remove 2>/dev/null || true
    echo "first-boot init script removed"
fi

echo "=== LFS First-boot configuration completed at $(date) ==="
INNEREOF

# -----------------------------------------------------------------------
# Install the first-boot script into the LFS tree
# -----------------------------------------------------------------------
install_first_boot_script() {
    run_privileged mkdir -p "$LFS/usr/sbin"
    run_privileged mkdir -p "$LFS/var/log"
    printf '%s\n' "$FIRST_BOOT_SCRIPT" > "$LFS/usr/sbin/first-boot.sh"
    run_privileged chmod 0755 "$LFS/usr/sbin/first-boot.sh"
}

install_service_unit() {
    # systemd
    if [ -d "$LFS/usr/lib/systemd/system" ] || [ -d "$LFS/lib/systemd/system" ]; then
        run_privileged mkdir -p "$LFS/usr/lib/systemd/system"
        cat > "$LFS/usr/lib/systemd/system/first-boot.service" <<'SERVICE'
[Unit]
Description=LFS First Boot Configuration
Documentation=man:first-boot.sh(8)
After=network.target local-fs.target
ConditionPathExists=!/var/log/first-boot-done

[Service]
Type=oneshot
ExecStart=/usr/sbin/first-boot.sh
ExecStopPost=/bin/touch /var/log/first-boot-done
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
SERVICE
        run_privileged chmod 0644 "$LFS/usr/lib/systemd/system/first-boot.service"
        log_info "systemd first-boot.service installed"
        return 0
    fi

    # sysvinit / openrc / runit
    if [ -d "$LFS/etc/init.d" ]; then
        cat > "$LFS/etc/init.d/first-boot" <<'INIT'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          first-boot
# Required-Start:    $local_fs $network
# Default-Start:     2 3 4 5
# Default-Stop:
# Short-Description: LFS First Boot Configuration
### END INIT INFO

case "$1" in
    start)
        if [ ! -f /var/log/first-boot-done ]; then
            /usr/sbin/first-boot.sh
            touch /var/log/first-boot-done
        fi
        ;;
    stop|status)
        exit 0
        ;;
    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac
INIT
        run_privileged chmod 0755 "$LFS/etc/init.d/first-boot"
        log_info "sysvinit first-boot script installed"
        return 0
    fi

    # runit
    if [ -d "$LFS/etc/sv" ] || [ -d "$LFS/service" ]; then
        run_privileged mkdir -p "$LFS/etc/sv/first-boot"
        cat > "$LFS/etc/sv/first-boot/run" <<'RUNIT'
#!/bin/sh
if [ ! -f /var/log/first-boot-done ]; then
    /usr/sbin/first-boot.sh
    touch /var/log/first-boot-done
fi
exec touch /var/log/first-boot-done
RUNIT
        run_privileged chmod 0755 "$LFS/etc/sv/first-boot/run"
        log_info "runit first-boot service installed"
        return 0
    fi

    log_warning "No supported init system found for first-boot service"
    return 1
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – installing first-boot script into $LFS"
    install_first_boot_script
    install_service_unit || true
    log_success "First-boot script created (Docker mode)"
    exit 0
fi

log_info "Native mode – installing first-boot service"

# Mount virtual filesystems
run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true

install_first_boot_script
install_service_unit || true

# Enable the service inside the chroot
if [ -d "$LFS/usr/lib/systemd/system" ]; then
    run_privileged chroot "$LFS" systemctl enable first-boot.service 2>/dev/null || true
elif [ -d "$LFS/etc/init.d" ]; then
    run_privileged chroot "$LFS" update-rc.d first-boot defaults 2>/dev/null || true
fi

run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true

log_success "First-boot service installed"
