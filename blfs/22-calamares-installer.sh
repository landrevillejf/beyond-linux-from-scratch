#!/bin/bash
# blfs/22-calamares-installer.sh – Calamares installer framework setup
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# This script installs and configures the Calamares installer framework
# for graphical system installation. It creates the necessary modules,
# branding, and configuration for an LFS-specific installer experience.
set -euo pipefail

LFS="${LFS:-/mnt/lfs}"
if [ -z "$LFS" ] || [ ! -d "$LFS" ]; then
    echo "[ERROR] LFS directory '$LFS' not found"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Branding version comes from the repo VERSION file so the installer's About
# dialog never shows a stale hardcoded number again (it was pinned at 0.52.4
# long after the project had moved on).
WBLFS_VERSION="$(tr -d '[:space:]' <"$SCRIPT_DIR/../VERSION" 2>/dev/null || echo 0.0.0)"
[ -n "$WBLFS_VERSION" ] || WBLFS_VERSION="0.0.0"

run_privileged() {
    if [ "$(whoami)" = "root" ]; then "$@"; else sudo "$@"; fi
}

write_file() {
    local path="$1" mode="$2"
    run_privileged mkdir -p "$(dirname "$LFS$path")"
    run_privileged tee "$LFS$path" >/dev/null
    run_privileged chmod "$mode" "$LFS$path"
}

echo "[INFO] Configuring Calamares installer framework..."

# --------------------------------------------------------------------------
# 1. Verify Calamares is installed
# --------------------------------------------------------------------------
if [ ! -x "$LFS/usr/bin/calamares" ] && [ ! -x "$LFS/usr/sbin/calamares" ]; then
    echo "[WARN] Calamares binary not found in target system"
    echo "[INFO] Calamares must be built as a BLFS package before this stage"
    echo "[INFO] Creating configuration only – binary will be provided by package"
fi

# --------------------------------------------------------------------------
# 2. Create Calamares directory structure
# --------------------------------------------------------------------------
run_privileged mkdir -p \
    "$LFS/etc/calamares" \
    "$LFS/etc/calamares/modules" \
    "$LFS/usr/share/calamares" \
    "$LFS/usr/share/calamares/modules" \
    "$LFS/usr/share/calamares/branding/lfs" \
    "$LFS/usr/share/calamares/branding/lfs/logo" \
    "$LFS/usr/lib/calamares/modules"

# --------------------------------------------------------------------------
# 3. Main Calamares configuration (settings.conf)
# --------------------------------------------------------------------------
write_file /etc/calamares/settings.conf 0644 <<'SETTINGS'
---
# Calamares settings for Way Beyond LFS
# Managed by 22-calamares-installer.sh

modules-search: [ local, /usr/lib/calamares/modules ]

# Installer sequence – ordered modules executed during installation
sequence:
  # Phase 1: Welcome and language selection
  - show:
    - welcome       # Language, locale, keyboard
    - locale        # Timezone, locale settings
    - keyboard      # Keyboard layout detection

  # Phase 2: Partitioning
  - show:
    - partition     # Disk selection and partitioning
    - mount         # Mount point assignment

  # Phase 3: User configuration
  - show:
    - users         # Create user account
    - hostname      # Set machine hostname

  # Phase 4: Summary and confirmation
  - show:
    - summary       # Review all choices before applying

  # Phase 5: Installation (exec)
  - exec:
    - partition     # Apply partitioning
    - mount         # Mount target partitions
    - unpackfs      # Unpack rootfs squashfs to target
    - fstab         # Generate /etc/fstab
    - locale        # Apply locale settings
    - keyboard      # Apply keyboard settings
    - localecfg     # Configure /etc/locale.conf
    - networkcfg    # Configure NetworkManager
    - hwclock       # Set hardware clock
    - services      # Enable systemd services
    - grubcfg       # Install and configure GRUB
    - bootloader    # Final bootloader configuration
    - luksbootkeyfile  # LUKS keyfile setup (if encryption)
    - plymouthcfg   # Plymouth boot splash config
    - initramfscfg  # Initramfs configuration
    - initramfs     # Generate initramfs
    - shellprocess  # Remove live-ISO-only artifacts from the target
    - umount        # Unmount target partitions

  # Phase 6: Completion
  - show:
    - finished      # Installation complete, reboot option
SETTINGS

# --------------------------------------------------------------------------
# 4. Branding configuration
# --------------------------------------------------------------------------
write_file /usr/share/calamares/branding/lfs/branding.desc 0644 <<BRANDING
---
# Calamares branding descriptor for LFS
componentName: lfs
strings:
  productName: "Way Beyond Linux From Scratch"
  shortProductName: "WBLFS"
  version: "$WBLFS_VERSION"
  shortVersion: "$WBLFS_VERSION"
  versionedName: "Way Beyond LFS $WBLFS_VERSION"
  shortVersionedName: "WBLFS $WBLFS_VERSION"
  bootloaderEntryName: "WBLFS"
  productUrl: https://github.com/landrevillejf/beyond-linux-from-scratch
  supportUrl: https://github.com/landrevillejf/beyond-linux-from-scratch/issues
  knownIssuesUrl: https://github.com/landrevillejf/beyond-linux-from-scratch/issues
  releaseNotesUrl: https://github.com/landrevillejf/beyond-linux-from-scratch/blob/main/CHANGELOG.md
  donateUrl: ""

images:
  productLogo: "logo/logo.png"
  productIcon: "logo/logo.png"
  productWelcome: "logo/welcome.png"

style:
  sidebarBackground: "#2d2d2d"
  sidebarText: "#ffffff"
  sidebarTextSelect: "#4eab5c"
  sidebarTextHighlight: "#3d3d3d"
BRANDING

# --------------------------------------------------------------------------
# 5. Module configurations
# --------------------------------------------------------------------------

# Welcome module – language selection
write_file /etc/calamares/modules/welcome.conf 0644 <<'WELCOME'
---
showSupportUrl: true
showKnownIssuesUrl: true
showReleaseNotesUrl: true
showDonateUrl: false
WELCOME

# Partition module – disk selection
write_file /etc/calamares/modules/partition.conf 0644 <<'PARTITION'
---
# Partitioning configuration
efiSystemPartition: "/boot/efi"
enableLuksAutomatedPartitioning: true
userSwapChoices:
  - none
  - reuse
  - small
  - suspend
  - file
defaultPartitionTableType: gpt
initialSwapChoice: none
PARTITION

# Users module – account creation (MANDATORY)
write_file /etc/calamares/modules/users.conf 0644 <<'USERS'
---
# User and root account configuration
# Both root password and user creation are MANDATORY during installation.

defaultGroups:
  - users
  - wheel
  - audio
  - video
  - storage
  - network
  - docker

autologinGroup: autologin
doAutologin: false

# Root password is mandatory – user MUST set it during installation
setRootPassword: true
doReusePassword: true

# Enforce strong passwords
requireStrongPasswords: true

passwordRequirements:
  minLength: 12
  maxLength: 128

# User creation is mandatory – cannot skip this step
# The users module will not allow proceeding without creating at least one user
userShell: /bin/bash

# Ensure the created user gets sudo access
defaultGroups:
  - users
  - wheel
  - audio
  - video
  - storage
  - network
  - docker
USERS

# Unpackfs module – rootfs extraction
write_file /etc/calamares/modules/unpackfs.conf 0644 <<'UNPACKFS'
---
# Source: squashfs image from the live media
unpack:
  - source: "/run/media/live/rootfs.squashfs"
    sourcefs: "squashfs"
    destination: ""
    weight: 100
UNPACKFS

# GRUB bootloader configuration module
write_file /etc/calamares/modules/grubcfg.conf 0644 <<'GRUBCFG'
---
# GRUB configuration
kernel: "/boot/vmlinuz"
img: "/boot/initramfs.img"
timeout: 5
default: "0"
GRUBCFG

# Fstab module
write_file /etc/calamares/modules/fstab.conf 0644 <<'FSTAB'
---
mountOptions:
  default: "defaults,noatime"
  btrfs: "defaults,noatime,compress=zstd"
  xfs: "defaults,noatime"
  ext4: "defaults,noatime"
FSTAB

# Shellprocess module – install-time cleanup of live-ISO-only artifacts.
# The lg3d live image carries a passwordless `live` user (wheel+autologin,
# created by blfs/30) so its greeter is usable without credentials, plus the
# Calamares XDG-autostart and applications launchers below.  None of those
# belong on the installed system, so this step – wired into the settings.conf
# exec sequence just before umount – strips them from the target.  Commands run
# inside the target root (dontChroot defaults to false); a leading '-' marks a
# command non-fatal so a missing account or file never aborts the finish phase.
write_file /etc/calamares/modules/shellprocess.conf 0644 <<'SHELLPROC'
---
dontChroot: false
timeout: 60
commands:
  # Remove the passwordless live login account and its home directory.
  - -userdel -r live
  # Remove the live-session installer launchers.
  - -rm -f /etc/xdg/autostart/calamares-autostart.desktop
  - -rm -f /usr/share/applications/calamares.desktop
SHELLPROC

# --------------------------------------------------------------------------
# 6. Desktop entry for launching Calamares
# --------------------------------------------------------------------------
write_file /usr/share/applications/calamares.desktop 0644 <<'DESKTOP'
[Desktop Entry]
Type=Application
Version=1.0
Name=Install WBLFS Linux
GenericName=System Installer
Comment=Install Way Beyond Linux From Scratch to your computer
Exec=sudo calamares
Icon=calamares
Terminal=false
Categories=System;
DESKTOP

# --------------------------------------------------------------------------
# 7. Polkit rule for passwordless installer launch
# --------------------------------------------------------------------------
write_file /etc/polkit-1/rules.d/10-calamares.rules 0644 <<'POLKIT'
// Allow users in the wheel group to run Calamares without authentication
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program") == "/usr/bin/calamares" &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
POLKIT

# --------------------------------------------------------------------------
# 8. Autostart for live session (optional)
# --------------------------------------------------------------------------
write_file /etc/xdg/autostart/calamares-autostart.desktop 0644 <<'AUTOSTART'
[Desktop Entry]
Type=Application
Name=Calamares Installer
Comment=Launch installer on live session
Exec=calamares --debug
Terminal=false
X-GNOME-Autostart-enabled=true
AUTOSTART

# --------------------------------------------------------------------------
# 9. LFS-specific helper scripts
# --------------------------------------------------------------------------
write_file /usr/lib/calamares/modules/lfs-setup/main.sh 0755 <<'HELPER'
#!/bin/bash
# LFS-specific installer helper
# Called by Calamares during the exec phase

ROOT="${INSTALL_ROOT:-/mnt/lfs-target}"

# Ensure essential mount points
for dir in proc sys dev run; do
    mount --bind "/$dir" "$ROOT/$dir" 2>/dev/null || true
done

# Copy resolv.conf for network access in chroot
cp /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true

echo "[LFS-SETUP] Target root prepared at $ROOT"
HELPER

write_file /usr/lib/calamares/modules/lfs-cleanup/main.sh 0755 <<'CLEANUP'
#!/bin/bash
# LFS cleanup and verification after installation
ROOT="${INSTALL_ROOT:-/mnt/lfs-target}"

# Remove live-system artifacts from installed system
rm -f "$ROOT/etc/xdg/autostart/calamares-autostart.desktop" 2>/dev/null || true
rm -f "$ROOT/usr/share/applications/calamares.desktop" 2>/dev/null || true

# Remove live user and session files.  The lg3d live ISO's `live` account is
# passwordless and in wheel+autologin, so it must not survive onto the target;
# drop the account (not just its home) via userdel in the target root.
if [ -x "$ROOT/usr/sbin/userdel" ]; then
    chroot "$ROOT" /usr/sbin/userdel -r live 2>/dev/null || true
fi
rm -rf "$ROOT/home/live" 2>/dev/null || true

# Verify root password was set
if [ -f "$ROOT/etc/shadow" ]; then
    root_pass=$(grep '^root:' "$ROOT/etc/shadow" 2>/dev/null | cut -d: -f2)
    if [ -z "$root_pass" ] || [ "$root_pass" = "!" ] || [ "$root_pass" = "*" ]; then
        echo "[LFS-CLEANUP] WARNING: Root password was not set during installation!"
        echo "[LFS-CLEANUP] The first-boot wizard will require setting it."
    else
        echo "[LFS-CLEANUP] Root password is configured."
    fi
fi

# Verify at least one regular user exists
user_found=false
if [ -f "$ROOT/etc/passwd" ]; then
    while IFS=: read -r uname _ uid _ _ _ _; do
        if [ "$uid" -ge 1000 ] 2>/dev/null && [ "$uid" -lt 65000 ] 2>/dev/null && [ "$uname" != "nobody" ]; then
            user_found=true
            echo "[LFS-CLEANUP] Regular user '$uname' exists."
            break
        fi
    done < "$ROOT/etc/passwd"
fi
if ! $user_found; then
    echo "[LFS-CLEANUP] WARNING: No regular user account found!"
    echo "[LFS-CLEANUP] The first-boot wizard will require creating one."
fi

# Regenerate initramfs for installed system
if [ -x "$ROOT/usr/sbin/dracut" ]; then
    chroot "$ROOT" /usr/sbin/dracut --force /boot/initramfs.img 2>/dev/null || true
fi

echo "[LFS-CLEANUP] Installation artifacts cleaned"
CLEANUP

# --------------------------------------------------------------------------
# 10. LG3D start menu: "Install WBLFS (LG3D)" launcher
# --------------------------------------------------------------------------
# The lg3d profile boots straight into Project Looking Glass, whose start menu
# is data-driven from startmenu.lgcfg.  blfs/30 extracts that file to /opt/lg3d
# before this stage runs.  Inject a System-group item that launches the
# installer via pkexec (section 7's polkit rule makes it passwordless for the
# wheel group, which the live user is in).  Desktop2DAppRegistry runs the
# command's first token through a `which` lookup, so the item posts only where
# pkexec/calamares exist (the live ISO) and self-hides once they are gone.
#
# This is the single-repo fallback for the ProjectLookingGlass startmenu.lgcfg
# change: the guard below makes it idempotent, so an archive that already
# carries the entry (PLG main) is left untouched and no duplicate is written.
# A missing file (Docker scaffolding leaves /opt/lg3d empty) is a no-op.
LG_STARTMENU="$LFS/opt/lg3d/lg3d-core/src/etc/lg3d/startmenu.lgcfg"
if [ -f "$LG_STARTMENU" ] && ! grep -q 'Install WBLFS (LG3D)' "$LG_STARTMENU"; then
    LG_ITEM="$(mktemp)"
    LG_OUT="$(mktemp)"
    cat >"$LG_ITEM" <<'LGITEM'
 <!-- System Menu: Install WBLFS (injected by 22-calamares-installer.sh) -->
 <object class="org.jdesktop.lg3d.scenemanager.utils.startmenu.StartMenuItemConfig">
  <void property="command">
   <string>pkexec calamares</string>
  </void>
  <void property="desc">
   <string>Install WBLFS (LG3D)</string>
  </void>
  <void property="displayResourceType">
   <string>ICON</string>
  </void>
  <void property="displayResourceUrlName">
   <string>resource:///resources/images/icon/system.png</string>
  </void>
  <void property="menuGroup">
   <string>System</string>
  </void>
  <void property="name">
   <string>Install WBLFS (LG3D)</string>
  </void>
 </object>
LGITEM
    # Insert the item immediately before the closing </java> tag.  awk writes to
    # a temp file (the unprivileged build user cannot redirect into root-owned
    # $LFS), then run_privileged tee streams it back over the original.
    awk -v ins="$LG_ITEM" '
        /<\/java>/ && !inserted {
            while ((getline line < ins) > 0) print line
            close(ins)
            inserted = 1
        }
        { print }
    ' "$LG_STARTMENU" >"$LG_OUT"
    run_privileged tee "$LG_STARTMENU" >/dev/null <"$LG_OUT"
    rm -f "$LG_ITEM" "$LG_OUT"
    echo "[INFO] Injected 'Install WBLFS (LG3D)' into the LG3D start menu"
elif [ ! -f "$LG_STARTMENU" ]; then
    echo "[INFO] LG3D start menu absent; skipping the 'Install WBLFS' entry"
else
    echo "[INFO] LG3D start menu already lists 'Install WBLFS (LG3D)'; skipping"
fi

echo "[SUCCESS] Calamares installer framework configured"
echo "  - Main config:   /etc/calamares/settings.conf"
echo "  - Branding:      /usr/share/calamares/branding/lfs/"
echo "  - Modules:       /etc/calamares/modules/"
echo "  - Desktop entry: /usr/share/applications/calamares.desktop"
exit 0
