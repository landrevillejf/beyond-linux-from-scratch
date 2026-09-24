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
#   compositor -> run-lg3d.sh -x  (contract default: WM + compositor)
#   2d         -> run-lg3d.sh -2  (conventional Swing 2D desktop)
#   swing      -> run-lg3d.sh -w  (Swing desktop, Metal look and feel)
#   dev        -> run-lg3d.sh     (3D desktop in an ordinary window)
# An unknown value warns and falls back to compositor, the contract target.

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
LG3D_MODE="${LFS_PROFILE_LG3D_MODE:-compositor}"
case "$LG3D_MODE" in
compositor)
    LG3D_FLAG="-x"
    LG3D_DESC="window manager + compositor"
    ;;
2d)
    LG3D_FLAG="-2"
    LG3D_DESC="2D Swing desktop"
    ;;
swing)
    LG3D_FLAG="-w"
    LG3D_DESC="Swing desktop (Metal look and feel)"
    ;;
dev)
    LG3D_FLAG=""
    LG3D_DESC="3D desktop (development mode)"
    ;;
*)
    log_warning "Unknown lg3d_mode '$LG3D_MODE'; falling back to compositor"
    LG3D_MODE="compositor"
    LG3D_FLAG="-x"
    LG3D_DESC="window manager + compositor"
    ;;
esac
# Contract section 3.6 names the compositor unit lg3d-compositor.service;
# deriving the name from the mode keeps that exact name for the default and
# stays self-documenting for the other modes (lg3d-2d.service, ...).
UNIT_NAME="lg3d-${LG3D_MODE}.service"
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

log_info "========================================="
log_info "Project Looking Glass (lg3d) session"
log_info "  mode : ${LG3D_MODE} (${LG3D_DESC})"
log_info "  init : ${INIT}"
if [ "$INIT" = "systemd" ]; then
    log_info "  unit : ${UNIT_NAME}"
fi
log_info "========================================="

# Write the systemd session unit from lfs-x11-contract.md section 3.6.  It is
# written host-side into $LFS/etc/systemd/system (the contract's location and
# the admin-writable unit path) so it lands in both Docker and native trees.
write_session_unit() {
    run_privileged mkdir -p "$LFS/etc/systemd/system"
    cat >"$LFS/etc/systemd/system/${UNIT_NAME}" <<UNIT
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
    cat >"$LFS/etc/rc.d/init.d/lg3d" <<INITD
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

cat >"$LFS/install-lg3d.sh" <<'INNEREOF'
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

log_info "lg3d installed to /opt/lg3d."
INNEREOF

run_privileged chmod +x "$LFS/install-lg3d.sh"
run_privileged chroot "$LFS" /bin/bash /install-lg3d.sh

# Wire the session into the boot graph.  The systemd path creates the wants
# symlink directly so it survives an offline chroot where systemctl refuses to
# run; systemctl enable/set-default are then attempted best-effort.  The
# sysvinit path needs nothing here: write_sysv_session already wrote the init.d
# launcher, the inittab respawn entry and the runlevel-5 default host-side.
if [ "$INIT" = "systemd" ]; then
    run_privileged mkdir -p "$LFS/etc/systemd/system/graphical.target.wants"
    run_privileged ln -sf "/etc/systemd/system/${UNIT_NAME}" \
        "$LFS/etc/systemd/system/graphical.target.wants/${UNIT_NAME}"
    run_privileged chroot "$LFS" systemctl enable "$UNIT_NAME" 2>/dev/null ||
        log_warning "Could not enable ${UNIT_NAME} via systemctl (offline chroot)"

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
    log_info "sysvinit session wired via inittab respawn (runlevel 5)"
fi

run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true
run_privileged umount "$LFS"/run 2>/dev/null || true

log_success "Project Looking Glass installed and lg3d session wired (${INIT})"
