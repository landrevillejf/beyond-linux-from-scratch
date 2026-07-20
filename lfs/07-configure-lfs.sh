#!/bin/bash
# Configure LFS system – copie des binaires et configuration minimale
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

copy_binaries() {
    local dest="$1"
    shift
    for tool in "$@"; do
        src=$(which "$tool" 2>/dev/null || echo "/bin/$tool")
        if [ -f "$src" ]; then
            run_privileged cp -L -v "$src" "$dest/bin/"
            # Copier les bibliothèques
            ldd "$src" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read lib; do
                lib_dir="$dest/lib"
                [[ "$lib" == *"/lib64/"* ]] && lib_dir="$dest/lib64"
                run_privileged mkdir -p "$lib_dir"
                run_privileged cp -v "$lib" "$lib_dir/"
            done
        else
            log_warning "Command not found: $tool"
        fi
    done
}

log_info "========================================="
log_info "Configuring LFS system"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – minimal config inside $LFS"
    run_privileged mkdir -pv "$LFS"/etc/X11/xorg.conf.d
    run_privileged mkdir -pv "$LFS"/usr/local/bin

    cat > "$LFS/configure-system.sh" << 'INNEREOF'
#!/bin/bash
set -e
echo "Configuring LFS system (Docker mode)..."
if ! chroot . id lfsuser &>/dev/null; then
    chroot . groupadd -g 1000 lfsuser 2>/dev/null || true
    chroot . useradd -u 1000 -g 1000 -G wheel,audio,video,storage -m lfsuser 2>/dev/null || true
    chroot . sh -c 'echo "lfsuser:password123" | chpasswd' 2>/dev/null || true
fi
echo "lfsuser ALL=(ALL) ALL" >> ./etc/sudoers 2>/dev/null || true
cat > ./etc/X11/xorg.conf.d/00-keyboard.conf << "XORG"
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us"
EndSection
XORG
cat > ./usr/local/bin/start-desktop << "START"
#!/bin/bash
exec startx
START
chmod +x ./usr/local/bin/start-desktop
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
log_info "Native mode – full configuration"

# Monter les systèmes de fichiers virtuels
run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t devpts devpts "$LFS"/dev/pts 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true
run_privileged mount -t tmpfs tmpfs "$LFS"/run 2>/dev/null || true

# Copier les binaires essentiels dans le chroot
log_info "Copying essential binaries to chroot"
run_privileged mkdir -p "$LFS/bin" "$LFS/usr/bin" "$LFS/sbin"
copy_binaries "$LFS" mkdir chmod chown ln cat echo cp mv rm sed grep which
# Copier aussi les outils de gestion d'utilisateurs si présents (optionnel)
for tool in groupadd useradd chpasswd; do
    src=$(which "$tool" 2>/dev/null || echo "/usr/sbin/$tool")
    if [ -f "$src" ]; then
        run_privileged cp -L -v "$src" "$LFS/usr/sbin/"
        ldd "$src" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read lib; do
            lib_dir="$LFS/lib"
            [[ "$lib" == *"/lib64/"* ]] && lib_dir="$LFS/lib64"
            run_privileged mkdir -p "$lib_dir"
            run_privileged cp -v "$lib" "$lib_dir/"
        done
    fi
done

# Créer un script de configuration simplifié (sans dépendre de grub, systemd, etc.)
cat > "$LFS/configure-system.sh" << 'INNEREOF'
#!/bin/bash
set -e
echo "========================================="
echo "Configuring LFS System (minimal)"
echo "========================================="

# Fichiers de base
mkdir -pv /etc
mkdir -pv /usr/local/bin
mkdir -pv /etc/X11/xorg.conf.d

# Créer les utilisateurs si absents
if ! grep -q lfsuser /etc/passwd; then
    echo "lfsuser:x:1000:1000::/home/lfsuser:/bin/bash" >> /etc/passwd
    echo "lfsuser:x:1000:" >> /etc/group
    echo "lfsuser:password123" | chpasswd 2>/dev/null || echo "Warning: chpasswd failed"
    mkdir -pv /home/lfsuser
    chown -R lfsuser:lfsuser /home/lfsuser
fi

# Sudoers
echo "lfsuser ALL=(ALL) ALL" >> /etc/sudoers 2>/dev/null || echo "Warning: sudoers not updated"

# Clavier
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << "XORG"
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us"
EndSection
XORG

# Lanceur de bureau
cat > /usr/local/bin/start-desktop << "START"
#!/bin/bash
exec startx
START
chmod +x /usr/local/bin/start-desktop

# Hostname
echo "lfs-desktop" > /etc/hostname
cat > /etc/hosts << "HOSTS"
127.0.0.1   localhost.localdomain localhost
::1         localhost ip6-localhost ip6-loopback
127.0.1.1   lfs-desktop
HOSTS

# Fuseau horaire
ln -sfv /usr/share/zoneinfo/UTC /etc/localtime

# Locale
cat > /etc/locale.conf << "LOCALE"
LANG=en_US.UTF-8
LOCALE

# Console
cat > /etc/vconsole.conf << "VCONSOLE"
KEYMAP=us
FONT=Lat2-Terminus16
VCONSOLE

echo "========================================="
echo "System configuration complete!"
echo "========================================="
INNEREOF

run_privileged chmod +x "$LFS/configure-system.sh"

# Exécuter la configuration dans le chroot
log_info "Running configuration in chroot..."
run_privileged chroot "$LFS" /bin/bash /configure-system.sh

# Démontage
run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true
run_privileged umount "$LFS"/run 2>/dev/null || true

log_success "LFS configuration complete!"