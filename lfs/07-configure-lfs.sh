#!/bin/bash
# Configure LFS system – LFS 12.4 chapter 9 configuration files
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
# 07-configure-lfs.sh – Write the book chapter 9 configuration files inside
#                        the already built system.  No host binary is ever
#                        copied into the target: every command runs inside the
#                        chroot using the programs built in chapter 8.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/../common/utils.sh" ]; then
    # shellcheck source=/dev/null
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

INIT_SYSTEM=${INIT_SYSTEM:-sysvinit}
HOSTNAME_LFS=${LFS_CONFIG_HOSTNAME:-lfs-desktop}

run_privileged() {
    if [ "$(whoami)" = "root" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

log_info "========================================="
log_info "Configuring LFS system"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – minimal config inside $LFS"
    run_privileged mkdir -pv "$LFS"/etc/X11/xorg.conf.d
    run_privileged mkdir -pv "$LFS"/usr/bin

    cat >"$LFS/configure-system.sh" <<'INNEREOF'
#!/bin/bash
set -e
echo "Configuring LFS system (Docker mode)..."
if ! chroot . id lfsuser &>/dev/null; then
    chroot . groupadd -g 1000 lfsuser 2>/dev/null || true
    chroot . useradd -u 1000 -g 1000 -G wheel,audio,video,storage -m lfsuser 2>/dev/null || true
    # Lock the lfsuser account – password must be set during installation or first boot
    chroot . passwd -l lfsuser 2>/dev/null || true
fi
echo "lfsuser ALL=(ALL) ALL" >> ./etc/sudoers 2>/dev/null || true
cat > ./etc/X11/xorg.conf.d/00-keyboard.conf << "XORG"
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us"
EndSection
XORG
cat > ./usr/bin/start-desktop << "START"
#!/bin/bash
exec startx
START
chmod +x ./usr/bin/start-desktop
echo "lfs-desktop" > ./etc/hostname
cat > ./etc/hosts << "HOSTS"
127.0.0.1   localhost.localdomain localhost
::1         localhost ip6-localhost ip6-loopback
127.0.1.1   lfs-desktop
HOSTS
echo "System configuration complete (Docker mode)!"
INNEREOF
    run_privileged chmod +x "$LFS/configure-system.sh"
    cd "$LFS" && run_privileged ./configure-system.sh
    log_success "LFS configuration complete (Docker mode)"
    exit 0
fi

# Native mode
log_info "Native mode – book chapter 9 configuration"

# Mount virtual filesystems
cleanup_mounts() {
    run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
    run_privileged umount "$LFS"/dev 2>/dev/null || true
    run_privileged umount "$LFS"/proc 2>/dev/null || true
    run_privileged umount "$LFS"/sys 2>/dev/null || true
    run_privileged umount "$LFS"/run 2>/dev/null || true
}
trap cleanup_mounts EXIT

run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t devpts devpts "$LFS"/dev/pts 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true
run_privileged mount -t tmpfs tmpfs "$LFS"/run 2>/dev/null || true

# -----------------------------------------------------------------
# Configuration script following LFS 12.4 chapter 9 plus the
# project-specific additions (locked accounts, desktop launcher).
# Runs entirely inside the chroot with the chapter 8 userland.
# -----------------------------------------------------------------
cat >"$LFS/configure-system.sh" <<INNEREOF
#!/bin/bash
set -e
export INIT_SYSTEM="$INIT_SYSTEM"
export HOSTNAME_LFS="$HOSTNAME_LFS"

echo "========================================="
echo "Configuring LFS System (LFS 12.4 ch 9)"
echo "========================================="

# --- 10.2 /etc/fstab (placeholders replaced by the installer) ---
if [ ! -f /etc/fstab ]; then
cat > /etc/fstab << "EOF"
# Begin /etc/fstab

# file system  mount-point  type     options             dump  fsck
#                                                              order

/dev/<xxx>     /            <fff>    defaults            1     1
/dev/<yyy>     swap         swap     pri=1               0     0
proc           /proc        proc     nosuid,noexec,nodev 0     0
sysfs          /sys         sysfs    nosuid,noexec,nodev 0     0
devpts         /dev/pts     devpts   gid=5,mode=620      0     0
tmpfs          /run         tmpfs    defaults            0     0
devtmpfs       /dev         devtmpfs mode=0755,nosuid    0     0
tmpfs          /dev/shm     tmpfs    nosuid,nodev        0     0
cgroup2        /sys/fs/cgroup cgroup2 nosuid,noexec,nodev 0    0

# End /etc/fstab
EOF
fi

# --- 9.4 Hostname and 9.5 hosts file ---
echo "\$HOSTNAME_LFS" > /etc/hostname
cat > /etc/hosts << EOF
# Begin /etc/hosts

127.0.0.1 localhost.localdomain localhost
127.0.1.1 \$HOSTNAME_LFS
::1       localhost ip6-localhost ip6-loopback

# End /etc/hosts
EOF

# --- 9.3 Network configuration ---
if [ "\$INIT_SYSTEM" = "sysvinit" ]; then
    cat > /etc/sysconfig/network << EOF
# Begin /etc/sysconfig/network

HOSTNAME=\$HOSTNAME_LFS

# End /etc/sysconfig/network
EOF
    cat > /etc/sysconfig/ifconfig.eth0 << "EOF"
# Begin /etc/sysconfig/ifconfig.eth0

ONBOOT=yes
IFACE=eth0
SERVICE=ipv4-static
IP=192.168.1.2
GATEWAY=192.168.1.1
PREFIX=24
BROADCAST=192.168.1.255

# End /etc/sysconfig/ifconfig.eth0
EOF
elif [ "\$INIT_SYSTEM" = "systemd" ]; then
    mkdir -pv /etc/systemd/network
    cat > /etc/systemd/network/10-eth-static.network << EOF
# Begin /etc/systemd/network/10-eth-static.network

[Match]
Name=eth0

[Network]
Address=192.168.1.2/24
Gateway=192.168.1.1

# End /etc/systemd/network/10-eth-static.network
EOF
fi

# --- 9.6 System locale (locales installed by glibc 8.5) ---
cat > /etc/locale.conf << "EOF"
# Begin /etc/locale.conf

LANG=en_US.UTF-8

# End /etc/locale.conf
EOF

# --- 9.7 /etc/profile ---
cat > /etc/profile << "EOF"
# Begin /etc/profile

for i in \$(locale); do
    unset \${i%=*}
done

if [[ "\$TERM" = linux ]]; then
    export LANG=C.UTF-8
else
    export LANG=en_US.UTF-8
fi

# End /etc/profile
EOF

# --- 9.8 /etc/inputrc ---
cat > /etc/inputrc << "EOF"
# Begin /etc/inputrc
# Modified by Chris Lynn <roryo@roryo.dynup.net>

# Allow the command prompt to wrap to the next line
set horizontal-scroll-mode Off

# Enable 8-bit input
set meta-flag On
set input-meta On

# Turns off 8th bit stripping
set convert-meta Off

# Keep the 8th bit for display
set output-meta On

# none, visible or audible
set bell-style none

# All of the following map the escape sequence of the value
# contained in the 1st argument to the readline specific functions
"\eOd": backward-word
"\eOc": forward-word

# for linux console
"\e[1~": beginning-of-line
"\e[4~": end-of-line
"\e[5~": beginning-of-history
"\e[6~": end-of-history
"\e[3~": delete-char
"\e[2~": quoted-insert

# for xterm
"\eOH": beginning-of-line
"\eOF": end-of-line

# for Konsole
"\e[H": beginning-of-line
"\e[F": end-of-line

# End /etc/inputrc
EOF

# --- 9.9 /etc/shells ---
cat > /etc/shells << "EOF"
# Begin /etc/shells

/bin/sh
/bin/bash

# End /etc/shells
EOF

# --- Console configuration ---
cat > /etc/vconsole.conf << "EOF"
# Begin /etc/vconsole.conf

KEYMAP=us
FONT=Lat2-Terminus16

# End /etc/vconsole.conf
EOF

# --- Dynamic linker configuration ---
if [ ! -s /etc/ld.so.conf ]; then
cat > /etc/ld.so.conf << "EOF"
# Begin /etc/ld.so.conf

/usr/local/lib
/opt/lib

# End /etc/ld.so.conf
EOF
fi

# --- Timezone (UTC default, installer adjusts) ---
ln -sfv /usr/share/zoneinfo/UTC /etc/localtime

# --- Project additions on top of the book baseline ---

# Users: lfsuser + locked accounts, passwords set at install/first boot
if ! grep -q '^lfsuser:' /etc/passwd; then
    useradd -u 1000 -g users -G wheel,audio,video -m lfsuser 2>/dev/null || true
    passwd -l lfsuser 2>/dev/null || true
fi
passwd -l root 2>/dev/null || true

# Sudoers (sudo is provided by BLFS, guard against its absence)
if [ -f /etc/sudoers ] && ! grep -q '^lfsuser' /etc/sudoers; then
    echo "lfsuser ALL=(ALL) ALL" >> /etc/sudoers
fi

# Keyboard layout for X11
mkdir -pv /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << "XORG"
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us"
EndSection
XORG

# Desktop launcher
cat > /usr/bin/start-desktop << "START"
#!/bin/bash
exec startx
START
chmod +x /usr/bin/start-desktop

# Basic udev rules directory for local rules
mkdir -pv /etc/udev/rules.d
cat > /etc/udev/rules.d/10-local.rules << "UDEV"
# Local udev rules
KERNEL=="sd[a-z]", NAME="%k", GROUP="disk"
KERNEL=="sd[a-z][0-9]", NAME="%k", GROUP="disk"
UDEV

# Skeleton directories for new users
mkdir -pv /etc/skel
for dir in Desktop Documents Downloads Music Pictures Public Templates Videos; do
    mkdir -pv "/etc/skel/\$dir"
done

# Extra profile fragments
cat > /etc/profile.d/umask.sh << "UMASK"
# Set default umask
umask 022
UMASK

cat > /etc/profile.d/dircolors.sh << "DIRCOLORS"
# Color support for ls and grep
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "\$(dircolors -b ~/.dircolors)" || eval "\$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
fi
DIRCOLORS

echo "========================================="
echo "System configuration complete!"
echo "========================================="
INNEREOF

run_privileged chmod +x "$LFS/configure-system.sh"

# Run configuration inside chroot with a book-style clean environment;
# PATH=/usr/bin:/usr/sbin only, the system is standalone at this point.
log_info "Running configuration in chroot..."
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /configure-system.sh

# Unmount
run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true
run_privileged umount "$LFS"/run 2>/dev/null || true

log_success "LFS configuration complete!"
