#!/bin/bash
# blfs/30-install-lg3d.sh
# Project Looking Glass (lg3d): install the desktop tree and wire the X11
# session that lfs-x11-contract.md mandates.
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -euo pipefail
#
# lg3d is NOT compiled here.  The stage installs the upstream source tree
# (run-lg3d.sh + the Gradle wrapper) into /opt/lg3d and writes the systemd
# session unit from lfs-x11-contract.md section 3.6, which hands off to
# Xorg on :0 with lg3d as the sole window manager / compositor.  The JDK it
# runs on is the one the java-dev stage installs, so this stage must run
# AFTER java-dev and after the xorg stage that provides xinit/Xorg.
#
# The launch mode comes from the profile (LFS_PROFILE_LG3D_MODE), matching
# the run-lg3d.sh flags:
#   iso        -> run-lg3d.sh --iso -x  (lfs-iso-contract.md default: the
#                 composited 2D desktop AND the X11 WM/compositor in one JVM,
#                 so external X clients are hosted as process-isolated MDI
#                 windows; both --iso and -x are required, see iso contract 5.1)
#   compositor -> run-lg3d.sh -x  (lfs-x11-contract.md: WM + compositor)
#   2d         -> run-lg3d.sh -2  (conventional Swing 2D desktop)
#   swing      -> run-lg3d.sh -w  (Swing desktop, Metal look and feel)
#   dev        -> run-lg3d.sh     (3D desktop in an ordinary window)
# An unknown value warns and falls back to iso, the contract target.

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

# --- Launch mode (from the profile) ----------------------------------------
# builder.py exports the lg3d profile's lg3d_mode key as LFS_PROFILE_LG3D_MODE.
LG3D_MODE="${LFS_PROFILE_LG3D_MODE:-iso}"
case "$LG3D_MODE" in
iso)
    LG3D_FLAG="--iso -x"
    LG3D_DESC="--iso composited 2D desktop + WM/compositor"
    UNIT_BASE="compositor"
    ;;
compositor)
    LG3D_FLAG="-x"
    LG3D_DESC="window manager + compositor"
    UNIT_BASE="compositor"
    ;;
2d)
    LG3D_FLAG="-2"
    LG3D_DESC="2D Swing desktop"
    UNIT_BASE="2d"
    ;;
swing)
    LG3D_FLAG="-w"
    LG3D_DESC="Swing desktop (Metal look and feel)"
    UNIT_BASE="swing"
    ;;
dev)
    LG3D_FLAG=""
    LG3D_DESC="3D desktop (development mode)"
    UNIT_BASE="dev"
    ;;
*)
    log_warning "Unknown lg3d_mode '$LG3D_MODE'; falling back to iso"
    LG3D_MODE="iso"
    LG3D_FLAG="--iso -x"
    LG3D_DESC="--iso composited 2D desktop + WM/compositor"
    UNIT_BASE="compositor"
    ;;
esac
# lfs-x11-contract.md 3.6 names the compositor session unit
# lg3d-compositor.service.  --iso is that same compositor session with the
# composited 2D desktop layered on top (lfs-iso-contract.md 3 keeps the
# lg3d-compositor.service name), so iso and compositor both map to it, while
# the other modes stay self-documenting (lg3d-2d.service, ...).
UNIT_NAME="lg3d-${UNIT_BASE}.service"
# run-lg3d.sh portion of ExecStart (dev mode passes no flag).
LG3D_RUN="/opt/lg3d/run-lg3d.sh"
if [ -n "$LG3D_FLAG" ]; then
    LG3D_RUN="/opt/lg3d/run-lg3d.sh ${LG3D_FLAG}"
fi

# --- Init system ------------------------------------------------------------
# builder.py exports INIT_SYSTEM as the effective init: the --init override
# wins over the profile's pinned systemd, so the very same stage wires either
# a systemd unit or a sysvinit inittab respawn depending on what the build
# selected.  lfs-x11-contract.md only mandates the bare Xorg :0 session, not
# the init flavour that starts it.
INIT="${INIT_SYSTEM:-systemd}"

# --- Display manager ownership of :0 ----------------------------------------
# When the profile enables a display manager (lg3d now does), LightDM owns Xorg
# :0, shows the login greeter and launches lg3d through the
# /usr/share/xsessions/lg3d-*.desktop entries written below.  In that case the
# standalone session unit (systemd) and the inittab respawn (sysvinit) must NOT
# also claim :0, or two sessions fight for the display.  The unit/launcher files
# are still written so a DM-less boot keeps working; only their boot-graph enable
# is gated.  lfs-x11-contract.md 74-75 allows a DM precisely because it hands off
# to a bare Xorg session whose sole WM is lg3d.
DM_OWNS_DISPLAY=false
if [ "${LFS_PROFILE_DISPLAY_MANAGER:-false}" = "true" ]; then
    DM_OWNS_DISPLAY=true
fi

log_info "========================================="
log_info "Project Looking Glass (lg3d) session"
log_info "  mode : ${LG3D_MODE} (${LG3D_DESC})"
log_info "  init : ${INIT}"
log_info "  dm   : ${DM_OWNS_DISPLAY} (display manager owns :0)"
if [ "$INIT" = "systemd" ]; then
    log_info "  unit : ${UNIT_NAME}"
fi
log_info "========================================="

# Write the systemd session unit from lfs-x11-contract.md section 3.6.  It is
# written host-side into $LFS/etc/systemd/system (the contract's location and
# the admin-writable unit path) so it lands in both Docker and native trees.
write_session_unit() {
    run_privileged mkdir -p "$LFS/etc/systemd/system"
    # tee (not `cat >`) so the write runs with the same privileges as the
    # mkdir above: $LFS/etc/systemd/system is root-owned, and the build runs
    # as the unprivileged lfs user, so an unprivileged redirect fails with
    # "Permission denied".
    run_privileged tee "$LFS/etc/systemd/system/${UNIT_NAME}" >/dev/null <<UNIT
[Unit]
Description=Project Looking Glass as the X11 session (${LG3D_DESC})
After=systemd-user-sessions.service

[Service]
Environment=JAVA_HOME=/opt/jdk-21
ExecStart=/usr/bin/xinit ${LG3D_RUN} -- /usr/bin/Xorg :0 vt1 -nolisten tcp
Restart=on-failure

[Install]
WantedBy=graphical.target
UNIT
    run_privileged chmod 0644 "$LFS/etc/systemd/system/${UNIT_NAME}"
    log_info "systemd ${UNIT_NAME} installed"
}

# Write the sysvinit equivalent of the systemd unit.  BLFS starts a display
# manager straight from inittab with a respawn entry that runs a tiny
# foreground launcher (bootscripts .../blfs/init.d/xdm, sourced by
# /etc/sysconfig/xdm).  lg3d is the sole session on a bare X server, so it is
# wired the same way: an init.d launcher that execs the contract's xinit
# command, plus a runlevel-5 respawn line -- the sysvinit analogue of
# WantedBy=graphical.target and Restart=on-failure.  Everything is a plain
# file write, so it works host-side in an offline chroot with no systemctl.
write_sysv_session() {
    run_privileged mkdir -p "$LFS/etc/rc.d/init.d"
    run_privileged tee "$LFS/etc/rc.d/init.d/lg3d" >/dev/null <<INITD
#!/bin/sh
# Project Looking Glass X11 session (${LG3D_DESC}).
# Run directly from inittab:
#   lg3d:5:respawn:/etc/rc.d/init.d/lg3d
# A bare Xorg :0 with lg3d as the sole window manager / compositor, matching
# the systemd lg3d-<mode>.service unit's ExecStart.
export JAVA_HOME=/opt/jdk-21
exec /usr/bin/xinit ${LG3D_RUN} -- /usr/bin/Xorg :0 vt1 -nolisten tcp
INITD
    run_privileged chmod 0755 "$LFS/etc/rc.d/init.d/lg3d"
    log_info "sysvinit /etc/rc.d/init.d/lg3d installed"

    # A getty on runlevel 5 would fight lg3d for the console, so register the
    # respawn entry and boot straight into runlevel 5 (the sysvinit equivalent
    # of `systemctl set-default graphical.target`).  inittab is written by the
    # lfs configure stage, so it is present in any native tree; guard anyway so
    # Docker scaffolding never aborts on a missing file.
    if [ ! -f "$LFS/etc/inittab" ]; then
        log_warning "$LFS/etc/inittab missing; lg3d session not wired into boot"
        return 0
    fi
    # Still boot into runlevel 5 so a session starts, but when a display manager
    # owns :0 it is LightDM that blfs/08d respawns from rc5; adding an lg3d
    # respawn here would put a second client on :0, so skip it.
    if [ "$DM_OWNS_DISPLAY" = "true" ]; then
        run_privileged sed -i 's/^id:[0-9]*:initdefault:/id:5:initdefault:/' \
            "$LFS/etc/inittab"
        log_info "Default runlevel set to 5 (display manager owns the session)"
        return 0
    fi
    if ! grep -q '^lg3d:5:respawn:' "$LFS/etc/inittab"; then
        echo 'lg3d:5:respawn:/etc/rc.d/init.d/lg3d' |
            run_privileged tee -a "$LFS/etc/inittab" >/dev/null
        log_info "inittab respawn entry added for lg3d"
    fi
    run_privileged sed -i 's/^id:[0-9]*:initdefault:/id:5:initdefault:/' \
        "$LFS/etc/inittab"
    log_info "Default runlevel set to 5"
}

# Write the session artifact for whichever init the build selected.
write_session() {
    if [ "$INIT" = "systemd" ]; then
        write_session_unit
    else
        write_sysv_session
    fi
}

# --- Docker mode: scaffold only --------------------------------------------
# The Docker rootfs carries no JDK (java-dev skips there) and no Xorg, so the
# session cannot run; install the init artifact and the /opt/lg3d directory and
# leave populating the tree to a native build.
if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode - scaffolding lg3d session in $LFS"
    run_privileged mkdir -p "$LFS/opt/lg3d"
    write_session
    log_warning "Docker mode - /opt/lg3d left empty (no JDK/Xorg in this rootfs)"
    log_success "lg3d session artifact created (Docker mode)"
    exit 0
fi

# --- Native mode -----------------------------------------------------------
log_info "Native mode - installing lg3d inside chroot"

if [ ! -f "$LFS/bin/bash" ]; then
    log_error "/bin/bash not found in $LFS/bin - run lfs-basic first"
    exit 1
fi
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
    log_error "chroot not working - run lfs-basic first"
    exit 1
fi

run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t devpts devpts "$LFS"/dev/pts 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true
run_privileged mount -t tmpfs tmpfs "$LFS"/run 2>/dev/null || true

# /sources must exist so the inner script's `cd /sources` never fails and a
# missing archive surfaces as require_file's fail-fast message instead.
run_privileged mkdir -p "$LFS/sources"
SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    run_privileged chown -R lfs:lfs "$LFS/sources" 2>/dev/null ||
        log_warning "Could not chown $LFS/sources to lfs:lfs"
fi

# Written host-side so it is present before the chroot enables it below.
write_session

# --- XSession entries for Display Manager selection ---
# .desktop entries in /usr/share/xsessions let the display manager's greeter
# offer every LG3D mode at the login screen.  The lg3d profile now enables
# LightDM (blfs/08d), which owns :0 and runs the chosen entry's Exec as the
# sole WM/compositor, so all five modes below are selectable at login.  They
# also stay usable by any other DM a user installs later.
run_privileged mkdir -p "$LFS/usr/share/xsessions"

# --iso composited desktop (process-isolated MDI apps) - the contract default
run_privileged tee "$LFS/usr/share/xsessions/lg3d-iso.desktop" >/dev/null <<EOF
[Desktop Entry]
Name=Project Looking Glass (ISO)
Comment=LG3D --iso composited 2D desktop + WM/compositor
Exec=/opt/lg3d/run-lg3d.sh --iso -x
Type=Application
EOF

# 3D Desktop (Compositor / WM)
run_privileged tee "$LFS/usr/share/xsessions/lg3d-compositor.desktop" >/dev/null <<EOF
[Desktop Entry]
Name=Project Looking Glass (3D)
Comment=LG3D as Window Manager and Compositor
Exec=/opt/lg3d/run-lg3d.sh -x
Type=Application
EOF

# 2D Desktop
run_privileged tee "$LFS/usr/share/xsessions/lg3d-2d.desktop" >/dev/null <<EOF
[Desktop Entry]
Name=Project Looking Glass (2D)
Comment=LG3D conventional Swing 2D desktop
Exec=/opt/lg3d/run-lg3d.sh -2
Type=Application
EOF

# Swing Desktop (Metal)
run_privileged tee "$LFS/usr/share/xsessions/lg3d-swing.desktop" >/dev/null <<EOF
[Desktop Entry]
Name=Project Looking Glass (Swing)
Comment=LG3D Swing desktop (Metal Look & Feel)
Exec=/opt/lg3d/run-lg3d.sh -w
Type=Application
EOF

# 3D desktop in an ordinary window (development mode; run-lg3d.sh takes no flag)
run_privileged tee "$LFS/usr/share/xsessions/lg3d-dev.desktop" >/dev/null <<EOF
[Desktop Entry]
Name=Project Looking Glass (Dev)
Comment=LG3D 3D desktop in an ordinary window (development mode)
Exec=/opt/lg3d/run-lg3d.sh
Type=Application
EOF

run_privileged tee "$LFS/install-lg3d.sh" >/dev/null <<'INNEREOF'
#!/bin/bash
set -euo pipefail
cd /sources

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }

fail() {
    log_error "$*"
    exit 1
}

# Resolve a required source archive; abort the stage when missing.
require_file() {
    local pattern="$1" f
    # shellcheck disable=SC2086
    f="$(ls $pattern 2>/dev/null | head -n1 || true)"
    [ -n "$f" ] || fail "required source archive missing: $pattern"
    printf '%s\n' "$f"
}

# Project Looking Glass source tree (GitHub archive of the main branch,
# pinned in packages/custom-sources.list; downloaded as
# ProjectLookingGlass-main.tar.gz).
lg3d_archive="$(require_file 'ProjectLookingGlass-*.tar.gz')"
log_info "Installing $(basename "$lg3d_archive") to /opt/lg3d"
rm -rf /opt/lg3d
mkdir -p /opt/lg3d
# The /archive/refs/heads/main tarball wraps everything in a top-level
# ProjectLookingGlass-main/ directory; strip it.
tar -xf "$lg3d_archive" --strip-components=1 -C /opt/lg3d

[ -f /opt/lg3d/run-lg3d.sh ] || fail "lg3d install incomplete: run-lg3d.sh missing"
[ -d /opt/lg3d/lg3d-core ] || fail "lg3d install incomplete: lg3d-core missing"
chmod 0755 /opt/lg3d/run-lg3d.sh /opt/lg3d/gradlew 2>/dev/null || true

# The contract's session unit sets JAVA_HOME=/opt/jdk-21; point it at the JDK
# the java-dev stage installed so run-lg3d.sh's JDK-21 probe resolves.
if [ -d /usr/lib/java/jdk ]; then
    ln -sfn /usr/lib/java/jdk /opt/jdk-21
    log_info "/opt/jdk-21 -> /usr/lib/java/jdk"
else
    log_warning "/usr/lib/java/jdk missing (java-dev stage did not run?); /opt/jdk-21 not linked"
fi

# Convenience launcher on PATH.
ln -sf /opt/lg3d/run-lg3d.sh /usr/bin/lg3d

    [ -x /usr/bin/xinit ] || \
    log_warning "/usr/bin/xinit missing; the lg3d session unit needs it (xorg stage)"

    # Add a simple selector script for console login / .xinitrc usage
    cat > /usr/bin/lg3d-session-select <<'SELECTOR'
#!/bin/bash
# If we have a terminal, allow selection. Otherwise fall back to profile default.
if [ -t 0 ]; then
    echo "Select Project Looking Glass mode:"
    echo "1) ISO Desktop (composited 2D + WM/compositor, process-isolated)"
    echo "2) 3D Desktop (Compositor/WM)"
    echo "3) 2D Desktop (Swing)"
    echo "4) Swing Desktop (Metal)"
    echo "5) Dev Desktop (3D desktop in an ordinary window)"
    read -t 10 -p "Choice [1-5] (default in 10s): " choice || choice=""
    case $choice in
        1) exec /opt/lg3d/run-lg3d.sh --iso -x ;;
        2) exec /opt/lg3d/run-lg3d.sh -x ;;
        3) exec /opt/lg3d/run-lg3d.sh -2 ;;
        4) exec /opt/lg3d/run-lg3d.sh -w ;;
        5) exec /opt/lg3d/run-lg3d.sh ;;
        *) # Fallback to exported mode or iso
           MODE="${LFS_PROFILE_LG3D_MODE:-iso}"
           case "$MODE" in
               compositor) exec /opt/lg3d/run-lg3d.sh -x ;;
               2d) exec /opt/lg3d/run-lg3d.sh -2 ;;
               swing) exec /opt/lg3d/run-lg3d.sh -w ;;
               dev) exec /opt/lg3d/run-lg3d.sh ;;
               *) exec /opt/lg3d/run-lg3d.sh --iso -x ;;
           esac
           ;;
    esac
else
    # Non-interactive: use profile default
    MODE="${LFS_PROFILE_LG3D_MODE:-iso}"
    case "$MODE" in
        compositor) exec /opt/lg3d/run-lg3d.sh -x ;;
        2d) exec /opt/lg3d/run-lg3d.sh -2 ;;
        swing) exec /opt/lg3d/run-lg3d.sh -w ;;
        dev) exec /opt/lg3d/run-lg3d.sh ;;
        *) exec /opt/lg3d/run-lg3d.sh --iso -x ;;
    esac
fi
SELECTOR
    chmod +x /usr/bin/lg3d-session-select

    # Convenience .xinitrc so a human typing `startx` at a text console lands
    # in the selector.  This is NOT how the lg3d session is wired at boot --
    # that is the systemd lg3d-compositor.service unit or the sysvinit inittab
    # respawn written host-side -- so it must never be able to abort the stage.
    # The base-cache resume tree never creates /home/lfs, and the unguarded
    # `cat > /home/lfs/.xinitrc` died with "No such file or directory" under
    # set -e (nightly lg3d-20261023 and lg3d-20260930).  Guard the write.
    if [ -d /home/lfs ]; then
        cat > /home/lfs/.xinitrc <<'EOF'
exec lg3d-session-select
EOF
        chown lfs:lfs /home/lfs/.xinitrc 2>/dev/null || true
        chmod 0644 /home/lfs/.xinitrc
    else
        log_warning "/home/lfs absent; skipping the convenience .xinitrc (the boot session is wired via the init unit, not .xinitrc)"
    fi

    log_info "lg3d installed to /opt/lg3d."
INNEREOF

run_privileged chmod +x "$LFS/install-lg3d.sh"
run_privileged chroot "$LFS" /bin/bash /install-lg3d.sh

# Wire the session into the boot graph.  The systemd path creates the wants
# symlink directly so it survives an offline chroot where systemctl refuses to
# run; systemctl enable/set-default are then attempted best-effort.  The
# sysvinit path needs nothing here: write_sysv_session already wrote the init.d
# launcher, the inittab respawn entry and the runlevel-5 default host-side.
# When a display manager owns :0, the standalone lg3d unit is left installed but
# NOT enabled, so LightDM (blfs/08d) is the only client on :0 and launches lg3d
# through the xsessions entries; the default target stays graphical so the DM
# starts.
if [ "$INIT" = "systemd" ]; then
    if [ "$DM_OWNS_DISPLAY" = "true" ]; then
        log_info "Display manager owns :0; ${UNIT_NAME} installed but not enabled"
    else
        run_privileged mkdir -p "$LFS/etc/systemd/system/graphical.target.wants"
        run_privileged ln -sf "/etc/systemd/system/${UNIT_NAME}" \
            "$LFS/etc/systemd/system/graphical.target.wants/${UNIT_NAME}"
        run_privileged chroot "$LFS" systemctl enable "$UNIT_NAME" 2>/dev/null ||
            log_warning "Could not enable ${UNIT_NAME} via systemctl (offline chroot)"
    fi

    if run_privileged chroot "$LFS" systemctl set-default graphical.target 2>/dev/null; then
        log_info "Default boot target set to graphical.target"
    else
        for target in "$LFS/usr/lib/systemd/system/graphical.target" \
            "$LFS/lib/systemd/system/graphical.target"; do
            if [ -e "$target" ]; then
                run_privileged ln -sf "${target#"$LFS"}" "$LFS/etc/systemd/system/default.target"
                log_info "default.target -> ${target#"$LFS"} (symlink fallback)"
                break
            fi
        done
    fi
else
    if [ "$DM_OWNS_DISPLAY" = "true" ]; then
        log_info "Display manager owns :0; sysvinit lg3d respawn skipped (LightDM starts from rc5)"
    else
        log_info "sysvinit session wired via inittab respawn (runlevel 5)"
    fi
fi

run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true
run_privileged umount "$LFS"/run 2>/dev/null || true

log_success "Project Looking Glass installed and lg3d session wired (${INIT})"
