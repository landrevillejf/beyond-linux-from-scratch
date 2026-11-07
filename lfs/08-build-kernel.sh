#!/bin/bash
# Build and install the Linux kernel in the LFS system.
# Author : Jean-Francois Landreville, landrevvillejf@protonmail.com, 2026.
# 08-build-kernel.sh – LFS 12.4 section 10.3: the kernel is compiled inside
#                       the chroot with the system toolchain using the curated
#                       repository configuration (config/kernel-config*).
#                       Cross-compile profiles (CROSS_COMPILE set) still build
#                       on the host, but with the same repository config.
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[INFO] Relaunching with sudo..."
    # `sudo -E` is not reliable: the Ubuntu 26.04 runner's sudo refuses it
    # ("preserving the entire environment is not supported, '-E' is
    # ignored"), which stripped $LFS and every flattened LFS_CONFIG_* /
    # LFS_PROFILE_* knob the builder exported.  This stage then fell back to
    # its compiled-in /mnt/lfs default and died with "Sources directory not
    # found: /mnt/lfs/sources" while the real tree lives under the builder's
    # output dir (lg3d Nightly #45).  Re-feed the whole current environment
    # through `sudo env`; that never relies on sudo's env_reset whitelist.
    _sudo_env=()
    while IFS= read -r -d '' _kv; do
        _sudo_env+=("$_kv")
    done < <(env -0)
    exec sudo env "${_sudo_env[@]}" "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LFS=${LFS:-/mnt/lfs}
KERNEL_TYPE=${KERNEL_TYPE:-linux}
ARCH=${ARCH:-$(uname -m)}
PROFILE=${PROFILE:-minimal}
CROSS_COMPILE=${CROSS_COMPILE:-}

# Normalise ARCH for make
case "$ARCH" in
x86_64 | amd64) MAKE_ARCH="x86_64" ;;
aarch64 | arm64) MAKE_ARCH="arm64" ;;
armv7l | armhf) MAKE_ARCH="arm" ;;
riscv64) MAKE_ARCH="riscv" ;;
*) MAKE_ARCH="$ARCH" ;;
esac

log_info() { echo "[INFO] $*"; }
# The helper is defined here, with its siblings, on purpose: this stage runs
# under `set -e', so calling a log function this script never defines is not a
# cosmetic miss -- bash returns 127 and the kernel stage dies with it, which
# costs the whole image.  Every log_* name used below must exist.
log_warning() { echo "[WARNING] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_success() { echo "[SUCCESS] $*"; }

if [ -d "$LFS/image/tools" ] && [ -d "$LFS/image/usr" ] && [ ! -d "$LFS/tools" ]; then
    LFS="$LFS/image"
fi

# ---------------------------------------------------------------------------
# Select the curated kernel configuration from the repository.  Explicit
# KERNEL_CONFIG_FILE wins, then per-profile variants, then the default.
# ---------------------------------------------------------------------------
CONFIG_DIR="$SCRIPT_DIR/../config"
if [ -n "${KERNEL_CONFIG_FILE:-}" ] && [ -f "$KERNEL_CONFIG_FILE" ]; then
    KERNEL_CONFIG_SRC="$KERNEL_CONFIG_FILE"
elif [ -f "$CONFIG_DIR/kernel-config-$PROFILE" ]; then
    KERNEL_CONFIG_SRC="$CONFIG_DIR/kernel-config-$PROFILE"
elif [ "$MAKE_ARCH" = "arm64" ] && [ -f "$CONFIG_DIR/kernel-config-arm64" ]; then
    KERNEL_CONFIG_SRC="$CONFIG_DIR/kernel-config-arm64"
else
    KERNEL_CONFIG_SRC="$CONFIG_DIR/kernel-config"
fi
if [ ! -f "$KERNEL_CONFIG_SRC" ]; then
    log_error "Kernel configuration not found: $KERNEL_CONFIG_SRC"
    exit 1
fi
log_info "Using kernel configuration: $KERNEL_CONFIG_SRC"

# ---------------------------------------------------------------------------
# Security knobs (Phase 1 kernel hardening).  The curated fragments already
# carry the hardened baseline, but two settings are tunable at build time from
# the flattened security.kernel_hardening.* config keys so they can be changed
# without editing all six variants:
#   LFS_CONFIG_SECURITY_KERNEL_HARDENING_LOCKDOWN         integrity|confidentiality|off
#   LFS_CONFIG_SECURITY_KERNEL_HARDENING_MODULE_SIG_FORCE true|false
# They are re-applied with the kernel's own scripts/config helper AFTER the
# fragment is copied to .config and BEFORE `make olddefconfig`, so the choice
# symbols resolve cleanly.  Module signing itself needs no extra step: with
# CONFIG_MODULE_SIG(_ALL)=y `make` signs every .ko using certs/signing_key.pem,
# which the build auto-generates (openssl is installed by 05b before this
# stage); only the public key is embedded in vmlinuz, the private key is not
# shipped.
# ---------------------------------------------------------------------------
LOCKDOWN_MODE="${LFS_CONFIG_SECURITY_KERNEL_HARDENING_LOCKDOWN:-integrity}"
MODULE_SIG_FORCE="${LFS_CONFIG_SECURITY_KERNEL_HARDENING_MODULE_SIG_FORCE:-true}"

resolve_hardening_cmds() {
    case "$LOCKDOWN_MODE" in
    confidentiality)
        printf '%s\n' './scripts/config --enable SECURITY_LOCKDOWN_LSM --enable LOCKDOWN_KERNEL_FORCE_CONFIDENTIALITY'
        ;;
    off | none | disabled)
        printf '%s\n' './scripts/config --enable SECURITY_LOCKDOWN_LSM --disable LOCKDOWN_KERNEL_FORCE_INTEGRITY --disable LOCKDOWN_KERNEL_FORCE_CONFIDENTIALITY'
        ;;
    *)
        printf '%s\n' './scripts/config --enable SECURITY_LOCKDOWN_LSM --enable LOCKDOWN_KERNEL_FORCE_INTEGRITY'
        ;;
    esac
    if [ "$MODULE_SIG_FORCE" = "true" ]; then
        printf '%s\n' './scripts/config --enable MODULE_SIG --enable MODULE_SIG_FORCE'
    else
        printf '%s\n' './scripts/config --disable MODULE_SIG_FORCE'
    fi
}
HARDEN_CMDS="$(resolve_hardening_cmds)"
log_info "Kernel hardening knobs: lockdown=$LOCKDOWN_MODE module_sig_force=$MODULE_SIG_FORCE"

# The cgroup/namespace chain, verified against the resolved .config after
# olddefconfig on both build paths below.  Only symbols the fragment itself
# names are checked, so a fragment that does not ask for one is never judged
# for it - the guard catches the silent drop, it does not impose a policy.
# The gated set is exactly the chain the boot needs: BLFS 13.0
# general/elogind states that "elogind strictly needs a kernel with
# CONFIG_CGROUPS enabled at runtime", and rcS.d/S00mountvirtfs mounts
# cgroup2 for the sysvinit side of the same book.  Nothing else belongs here;
# an unrelated symbol must never be able to fail the kernel stage.
#
# CONFIG_NET is part of that set for the same reason, not as policy: with no
# net/ built, the kernel does not register the socket() syscall at all, so
# every socket() call returns ENOSYS.  systemd as PID 1 then cannot open its
# uevent netlink monitor and aborts on its own assertion in
# src/core/device.c:device_unset_sysfs() ("Freezing execution") -- lg3d
# nightly #102, where build-kernel.log compiled zero net/ objects.  A dead
# PID 1 is not a bootable image, whatever else the kernel does.
CGUARD_SYMBOLS="CONFIG_CGROUPS CONFIG_CGROUP_SCHED CONFIG_FAIR_GROUP_SCHED \
    CONFIG_MEMCG CONFIG_CGROUP_PIDS CONFIG_CGROUP_DEVICE \
    CONFIG_CGROUP_FREEZER CONFIG_NAMESPACES CONFIG_PID_NS \
    CONFIG_NET CONFIG_UNIX CONFIG_INET"

# ---------------------------------------------------------------------------
# Locate the kernel sources.  The chroot mirror ($LFS/sources) is the
# canonical copy: lfs-basic populates it for every profile, whatever
# the builder's host output layout (nightly #185 died on the old
# "$(dirname $LFS)/sources" guess because CI keeps its sources in
# build-release/sources, not next to $LFS).
# ---------------------------------------------------------------------------
SOURCES_HOST="$LFS/sources"
if [ ! -d "$SOURCES_HOST" ]; then
    log_error "Sources directory not found: $SOURCES_HOST"
    exit 1
fi

cd "$SOURCES_HOST"
KERNEL_TARBALL=$(find . -maxdepth 1 -name "${KERNEL_TYPE}-*.tar.*" -print -quit 2>/dev/null | head -n1)
if [ -z "$KERNEL_TARBALL" ]; then
    log_error "No kernel source found for type '$KERNEL_TYPE'"
    exit 1
fi
KERNEL_TARBALL=${KERNEL_TARBALL#./}

KERNEL_VERSION=$(echo "$KERNEL_TARBALL" | sed -E 's/^[^-]+(-libre)?-([0-9]+\.[0-9]+\.[0-9]+)\.tar\..*$/\2/')
KERNEL_DIR=$(tar -tf "$KERNEL_TARBALL" | head -1 | cut -d/ -f1)
log_info "Using kernel source: $KERNEL_TARBALL (version $KERNEL_VERSION)"

# Skip if already installed
if [ -f "$LFS/boot/vmlinuz" ]; then
    log_info "Kernel already installed – skipping"
    exit 0
fi

# ---------------------------------------------------------------------------
# Cross-compile path: the chroot cannot execute host-foreign binaries, so
# ARM-style profiles compile on the host with the cross toolchain but still
# use the curated repository configuration instead of defconfig.
# ---------------------------------------------------------------------------
if [ -n "$CROSS_COMPILE" ]; then
    WORKDIR=$(mktemp -d)
    trap 'rm -rf "$WORKDIR"' EXIT
    cd "$WORKDIR"
    log_info "Extracting kernel source (cross-compile on host)"
    tar -xf "$SOURCES_HOST/$KERNEL_TARBALL"
    cd "$KERNEL_DIR"

    MAKE_CMD="make ARCH=$MAKE_ARCH CROSS_COMPILE=$CROSS_COMPILE"

    log_info "Cleaning source tree (make mrproper)"
    $MAKE_CMD mrproper
    log_info "Configuring kernel from $KERNEL_CONFIG_SRC"
    cp "$KERNEL_CONFIG_SRC" .config
    log_info "Applying security hardening knobs (scripts/config)"
    eval "$HARDEN_CMDS"
    $MAKE_CMD olddefconfig
    # `make olddefconfig' silently drops any symbol whose dependency is not
    # named, which is how CONFIG_CGROUPS disappeared from a fragment that
    # asked for it and shipped a kernel that cannot mount cgroup2 at all --
    # rcS.d/S00mountvirtfs then aborts sysinit and systemd freezes as PID 1.
    #
    # Repair before judging.  A build that dies here produces no image at all,
    # which is worse than the dead image we had: the pipeline must keep
    # producing an artifact, so every symbol the fragment asks for and the
    # resolution lost is re-asserted through the kernel's own `scripts/config'
    # and resolved once more.  Only a symbol that still cannot be enabled -- a
    # dependency that genuinely does not exist in this source -- stops the
    # stage, because at that point the kernel cannot boot anything anyway.
    cguard_missing=()
    for sym in $CGUARD_SYMBOLS; do
        if grep -q "^${sym}=y" "$KERNEL_CONFIG_SRC" && ! grep -q "^${sym}=y" .config; then
            cguard_missing+=("${sym#CONFIG_}")
        fi
    done
    if [ ${#cguard_missing[@]} -gt 0 ]; then
        cguard_args=()
        for sym in "${cguard_missing[@]}"; do
            cguard_args+=(--enable "$sym")
        done
        cguard_msg="olddefconfig left ${#cguard_missing[@]} boot-critical symbol(s) unset:"
        log_warning "$cguard_msg ${cguard_missing[*]}; forcing and resolving again"
        # The repair itself may not be fatal: it runs under `set -e', and a
        # repair tool that errored would lose the build in a new place instead
        # of saving it.  If forcing or the second resolution fails, the config
        # simply keeps what it has and the judge below reports it.
        ./scripts/config "${cguard_args[@]}" ||
            log_warning "scripts/config could not force them; letting the guard judge"
        $MAKE_CMD olddefconfig ||
            log_warning "the second resolution failed; letting the guard judge"
    fi
    for sym in $CGUARD_SYMBOLS; do
        if grep -q "^${sym}=y" "$KERNEL_CONFIG_SRC" && ! grep -q "^${sym}=y" .config; then
            log_error "$sym=y is requested by $KERNEL_CONFIG_SRC but missing from the resolved .config"
            exit 1
        fi
    done
    log_info "Compiling kernel (using -j$(nproc))"
    $MAKE_CMD -j"$(nproc)"
    log_info "Installing modules to $LFS"
    $MAKE_CMD modules_install INSTALL_MOD_PATH="$LFS"

    KERNEL_IMAGE=""
    for candidate in "arch/$MAKE_ARCH/boot/bzImage" "arch/$MAKE_ARCH/boot/Image" \
        "arch/$MAKE_ARCH/boot/zImage" "vmlinuz"; do
        if [ -f "$candidate" ]; then
            KERNEL_IMAGE="$candidate"
            break
        fi
    done
    if [ -z "$KERNEL_IMAGE" ]; then
        log_error "No kernel image found"
        exit 1
    fi

    mkdir -p "$LFS/boot"
    cp -v "$KERNEL_IMAGE" "$LFS/boot/vmlinuz-${KERNEL_VERSION}"
    ln -sf "vmlinuz-${KERNEL_VERSION}" "$LFS/boot/vmlinuz"
    cp System.map "$LFS/boot/System.map"
    cp .config "$LFS/boot/config-${KERNEL_VERSION}"
    log_success "Kernel $KERNEL_TYPE cross-compiled and installed to $LFS/boot/vmlinuz"
    exit 0
fi

# ---------------------------------------------------------------------------
# Native path: build inside the chroot with the chapter 8 toolchain
# (LFS 12.4 section 10.3).  The source tarball is already present in the
# chroot's /sources directory; only the configuration file is injected.
# ---------------------------------------------------------------------------
if [ ! -f "$LFS/sources/$KERNEL_TARBALL" ]; then
    log_error "Kernel tarball missing from chroot: $LFS/sources/$KERNEL_TARBALL"
    exit 1
fi
cp "$KERNEL_CONFIG_SRC" "$LFS/sources/.kernel-config"

cleanup_mounts() {
    umount "$LFS"/dev/pts 2>/dev/null || true
    umount "$LFS"/dev 2>/dev/null || true
    umount "$LFS"/proc 2>/dev/null || true
    umount "$LFS"/sys 2>/dev/null || true
    umount "$LFS"/run 2>/dev/null || true
}
trap cleanup_mounts EXIT

mount --bind /dev "$LFS"/dev 2>/dev/null || true
mount -t devpts devpts "$LFS"/dev/pts 2>/dev/null || true
mount -t proc proc "$LFS"/proc 2>/dev/null || true
mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true
mount -t tmpfs tmpfs "$LFS"/run 2>/dev/null || true

cat >"$LFS/build-kernel.sh" <<EOF
#!/bin/bash
set -e
cd /sources
rm -rf "$KERNEL_DIR"
echo "=== Extracting $KERNEL_TARBALL ==="
tar -xf "$KERNEL_TARBALL"
cd "$KERNEL_DIR"

echo "=== make mrproper ==="
make mrproper

echo "=== Installing curated .config ==="
cp /sources/.kernel-config .config

echo "=== Applying security hardening knobs (lockdown=$LOCKDOWN_MODE module_sig_force=$MODULE_SIG_FORCE) ==="
$HARDEN_CMDS

make olddefconfig

# Same repair-then-judge rule as the cross-compile path above.  \${sym} is
# what makes the loop expand inside the chroot instead of while this heredoc
# is written; the list itself is expanded here, so both paths can never drift
# apart.  Dying here would cost the whole build, so the symbols the resolution
# lost are re-asserted through scripts/config first.
cguard_missing=()
for sym in ${CGUARD_SYMBOLS}; do
    if grep -q "^\${sym}=y" /sources/.kernel-config && ! grep -q "^\${sym}=y" .config; then
        cguard_missing+=("\${sym#CONFIG_}")
    fi
done
if [ \${#cguard_missing[@]} -gt 0 ]; then
    cguard_args=()
    for sym in "\${cguard_missing[@]}"; do
        cguard_args+=(--enable "\$sym")
    done
    cguard_msg="olddefconfig left \${#cguard_missing[@]} boot-critical symbol(s) unset:"
    echo "WARNING: \$cguard_msg \${cguard_missing[*]}; forcing and resolving again"
    ./scripts/config "\${cguard_args[@]}" ||
        echo "WARNING: scripts/config could not force them; letting the guard judge"
    make olddefconfig ||
        echo "WARNING: the second resolution failed; letting the guard judge"
fi
for sym in ${CGUARD_SYMBOLS}; do
    if grep -q "^\${sym}=y" /sources/.kernel-config && ! grep -q "^\${sym}=y" .config; then
        echo "ERROR: \${sym}=y requested by the fragment is missing from the resolved .config"
        exit 1
    fi
done

echo "=== Compiling kernel ==="
make -j"\$(nproc)"

echo "=== Installing modules ==="
make modules_install

KERNEL_IMAGE=""
for candidate in "arch/$MAKE_ARCH/boot/bzImage" "arch/$MAKE_ARCH/boot/Image" \\
                 "arch/$MAKE_ARCH/boot/zImage" "vmlinuz"; do
    if [ -f "\$candidate" ]; then
        KERNEL_IMAGE="\$candidate"
        break
    fi
done
if [ -z "\$KERNEL_IMAGE" ]; then
    echo "ERROR: no kernel image found"
    exit 1
fi

echo "=== Installing kernel image to /boot ==="
cp -v "\$KERNEL_IMAGE" "/boot/vmlinuz-$KERNEL_VERSION"
ln -sf "vmlinuz-$KERNEL_VERSION" /boot/vmlinuz
cp -v System.map /boot/System.map
cp -v .config "/boot/config-$KERNEL_VERSION"
echo "=== Kernel build complete ==="
EOF
chmod +x "$LFS/build-kernel.sh"

log_info "Building kernel inside the chroot"
chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-kernel.sh

rm -f "$LFS/sources/.kernel-config"

umount "$LFS"/dev/pts 2>/dev/null || true
umount "$LFS"/dev 2>/dev/null || true
umount "$LFS"/proc 2>/dev/null || true
umount "$LFS"/sys 2>/dev/null || true
umount "$LFS"/run 2>/dev/null || true

log_success "Kernel $KERNEL_TYPE compiled and installed to $LFS/boot/vmlinuz"
