#!/bin/bash
# Install init system – with host tool copying and explicit PATH
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
# 06a-init-system.sh is a modified version of the original 06-init-system.sh script from the LFS project.
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
        sudo -E "$@"
    fi
}

log_info "========================================="
log_info "Installing init system"
log_info "========================================="

INIT_SYSTEM="${INIT_SYSTEM:-sysvinit}"
log_info "Init system selected: $INIT_SYSTEM"

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – creating minimal init structure"
    mkdir -pv "$LFS"/{etc/init.d,bin,sbin,usr/sbin}
    cat >"$LFS/etc/init.d/rcS" <<'EOF'
#!/bin/sh
echo "Starting minimal init..."
exec /bin/bash
EOF
    chmod +x "$LFS/etc/init.d/rcS"
    ln -sf /etc/init.d/rcS "$LFS/sbin/init"
    log_success "Minimal init created for Docker"
    exit 0
fi

# ---- Dispatch to dedicated scripts for openrc, runit, or s6 ----
if [ "$INIT_SYSTEM" = "openrc" ]; then
    log_info "Dispatching to OpenRC build script"
    source "$SCRIPT_DIR/06c-init-openrc.sh"
    exit 0
elif [ "$INIT_SYSTEM" = "runit" ]; then
    log_info "Dispatching to runit build script"
    source "$SCRIPT_DIR/06d-init-runit.sh"
    exit 0
elif [ "$INIT_SYSTEM" = "s6" ]; then
    log_info "Dispatching to s6 build script"
    source "$SCRIPT_DIR/06e-init-s6.sh"
    exit 0
fi

# Only sysvinit and systemd are handled directly by this script.

if [ ! -f "$LFS/bin/bash" ]; then
    log_error "/bin/bash not found in $LFS/bin – run lfs-basic first"
    exit 1
fi
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
    log_error "chroot not working – run lfs-basic first"
    exit 1
fi

# Ensure /bin/sh resolves to a working shell inside chroot for make/autotools.
run_privileged ln -sfn /bin/bash "$LFS/bin/sh"

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
# Copy necessary host tools into the chroot (utilities ONLY, NOT the compiler)
# -----------------------------------------------------------------
copy_tool_with_libs() {
    local tool_path="$1"
    local tool_name
    tool_name="$(basename "$tool_path")"

    # Don't overwrite existing chroot tools (preserve those from chroot)
    if [ -x "$LFS/usr/bin/$tool_name" ]; then
        log_info "Keeping existing chroot tool: /usr/bin/$tool_name"
        return 0
    fi

    run_privileged cp -Lv "$tool_path" "$LFS/usr/bin/$tool_name"
    run_privileged chmod +x "$LFS/usr/bin/$tool_name"

    # Copy dynamic libraries required by the tool into the chroot.
    ldd "$tool_path" 2>/dev/null | awk '/=> \// {print $3} $1 ~ /^\/lib/ {print $1}' | while read -r lib; do
        [ -z "$lib" ] && continue
        local rel_dir
        rel_dir="$(dirname "$lib")"
        run_privileged mkdir -pv "$LFS$rel_dir"
        if [ ! -e "$LFS$lib" ]; then
            run_privileged cp -Lv "$lib" "$LFS$lib"
        fi
    done
}

# Only copy essential utilities; DO NOT copy gcc, cc, install, ln, chmod, etc.
for tool in tar head cut xz make nproc sed mktemp rm echo id getconf; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$tool_path" ] && [ -x "$tool_path" ] && [[ $tool_path == /* ]]; then
        copy_tool_with_libs "$tool_path"
    else
        log_warning "Host tool '$tool' not found, chroot may fail"
    fi
done

# GNU make may exec simple commands directly; ensure /bin/echo exists.
if [ ! -x "$LFS/bin/echo" ] && [ -x "$LFS/usr/bin/echo" ]; then
    run_privileged ln -sfn /usr/bin/echo "$LFS/bin/echo"
fi
# -----------------------------------------------------------------

# -----------------------------------------------------------------
# Check toolchain in chroot – if broken, abort with clear instruction.
# -----------------------------------------------------------------
log_info "Checking if gcc works in chroot..."
if ! run_privileged chroot "$LFS" /bin/bash -c "echo 'int main(){}' > /tmp/test.c && gcc /tmp/test.c -o /tmp/test 2>/dev/null && rm -f /tmp/test.c /tmp/test" 2>/dev/null; then
    log_error "gcc/cc1 missing or broken in chroot."
    log_error "The final toolchain (gcc, glibc, binutils) was not correctly installed."
    log_error "Please rebuild the LFS system stage (06-lfs-system) and then retry."
    exit 1
fi
log_success "Toolchain OK in chroot."
# -----------------------------------------------------------------

# Sources
SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    run_privileged chown -R lfs:lfs "$LFS/sources"
fi

# Internal script (no toolchain repair; assumes it works)
cat >"$LFS/build-init.sh" <<'INNEREOF'
#!/bin/bash
# Force PATH to include /usr/bin, /bin and the temporary toolchain
export PATH=/bin:/usr/bin:/sbin:/usr/sbin:/tools/bin
export SHELL=/bin/bash
export CONFIG_SHELL=/bin/bash

set -e
cd /sources

INIT_SYSTEM="${1:-sysvinit}"

MAKE_BIN="$(command -v make || true)"
if [ -z "$MAKE_BIN" ] && [ -x /tools/bin/make ]; then
    MAKE_BIN="/tools/bin/make"
fi
if [ -z "$MAKE_BIN" ]; then
    echo "ERROR: make command not found in chroot PATH=$PATH"
    exit 1
fi

NPROC_BIN="$(command -v nproc || true)"
if [ -z "$NPROC_BIN" ] && [ -x /usr/bin/nproc ]; then
    NPROC_BIN="/usr/bin/nproc"
fi
JOBS=1
if [ -n "$NPROC_BIN" ]; then
    JOBS="$("$NPROC_BIN" 2>/dev/null || echo 1)"
fi

mkdir -p /var/lib/lfs-builder/init-system

marker_for() { echo "/var/lib/lfs-builder/init-system/$1.done"; }

find_archive() {
    local pkg="$1"
    compgen -G "${pkg}-*.tar.*" 2>/dev/null | sort -V | tail -n 1
}

extract_archive() {
    local archive="$1" dir
    dir="$(tar -tf "$archive" | head -n 1 | cut -d/ -f1)"
    rm -rf "$dir"
    tar -xf "$archive"
    printf '%s\n' "$dir"
}

have_pc() { pkg-config --exists "$1" 2>/dev/null; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_installed() {
    local pkg="$1"
    [ -f "$(marker_for "$pkg")" ] && return 0
    case "$pkg" in
        sysvinit)        [ -x /sbin/init ] && ! readlink /sbin/init 2>/dev/null | grep -q systemd ;;
        libgpg-error)    have_pc gpg-error ;;
        libgcrypt)      have_pc libgcrypt ;;
        libseccomp)     have_pc libseccomp ;;
        kmod)           have_cmd kmod || have_cmd lsmod ;;
        systemd)         have_pc libsystemd || [ -x /usr/lib/systemd/systemd ] ;;
        *) return 1 ;;
    esac
}

build_pkg() {
    local pkg="$1" archive dir extra_opts=""
    shift
    extra_opts="$*"
    if is_installed "$pkg"; then echo "[INFO] $pkg already installed; skipping"; return 0; fi
    archive="$(find_archive "$pkg")"
    if [ -z "$archive" ]; then echo "[WARNING] Source archive missing for $pkg; skipping"; return 0; fi
    echo "=== Building $pkg from $archive ==="
    dir="$(extract_archive "$archive")"
    pushd "$dir" >/dev/null
    if [ -f meson.build ]; then
        rm -rf builddir
        # shellcheck disable=SC2086
        meson setup builddir --prefix=/usr --buildtype=release --sysconfdir=/etc --localstatedir=/var $extra_opts
        ninja -C builddir
        ninja -C builddir install
    elif [ -x ./configure ] || [ -f configure ]; then
        # shellcheck disable=SC2086
        ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static $extra_opts
        make -j"$JOBS"
        make install
    elif [ -f Makefile ]; then
        make -j"$JOBS"
        make install
    else
        echo "[ERROR] $pkg has no recognised build system"; popd >/dev/null; return 1
    fi
    popd >/dev/null
    rm -rf "$dir"
    touch "$(marker_for "$pkg")"
    echo "=== $pkg done ==="
}

# -----------------------------------------------------------------------
# sysvinit
# -----------------------------------------------------------------------
if [ "$INIT_SYSTEM" = "sysvinit" ]; then
    echo "Building sysvinit..."
    build_pkg sysvinit || echo "WARNING: sysvinit build failed"

    # Create /etc/inittab
    cat > /etc/inittab <<'INITTAB'
id:3:initdefault:
si::sysinit:/etc/init.d/rcS
l1:1:wait:/etc/init.d/rc 1
l2:2:wait:/etc/init.d/rc 2
l3:3:wait:/etc/init.d/rc 3
l4:4:wait:/etc/init.d/rc 4
l5:5:wait:/etc/init.d/rc 5
l6:6:wait:/etc/init.d/rc 6
ca:12345:ctrlaltdel:/sbin/shutdown -t1 -a -r now
1:2345:respawn:/sbin/agetty --noclear tty1 9600 linux
2:2345:respawn:/sbin/agetty --noclear tty2 9600 linux
3:2345:respawn:/sbin/agetty --noclear tty3 9600 linux
4:2345:respawn:/sbin/agetty --noclear tty4 9600 linux
5:2345:respawn:/sbin/agetty --noclear tty5 9600 linux
6:2345:respawn:/sbin/agetty --noclear tty6 9600 linux
INITTAB

# -----------------------------------------------------------------------
# systemd
# -----------------------------------------------------------------------
elif [ "$INIT_SYSTEM" = "systemd" ]; then
    echo "Building systemd dependencies..."

    # Build systemd dependencies if not already in the LFS base
    build_pkg libgpg-error  || echo "WARNING: libgpg-error build failed"
    build_pkg libgcrypt     || echo "WARNING: libgcrypt build failed"
    build_pkg libseccomp    || echo "WARNING: libseccomp build failed"
    build_pkg kmod          || echo "WARNING: kmod build failed (may already be in LFS)"

    echo "Building systemd..."
    if ! is_installed systemd; then
        archive="$(find_archive systemd)"
        if [ -n "$archive" ]; then
            dir="$(extract_archive "systemd")"
            pushd "$dir" >/dev/null
            rm -rf builddir
            meson setup builddir \
                --prefix=/usr \
                --buildtype=release \
                --sysconfdir=/etc \
                --localstatedir=/var \
                -Ddefault-hierarchy=unified \
                -Dcgroup-controller=systemd \
                -Db_lto=false \
                -Dsysvinit-path= \
                -Dsysvrcnd-path= \
                -Dadmin-group=wheel \
                -Dwheel-group=wheel \
                -Dbacklight=true \
                -Dbinfmt=true \
                -Dcoredump=true \
                -Dfirstboot=true \
                -Dhostnamed=true \
                -Dhwdb=true \
                -Dlocaled=true \
                -Dlogind=true \
                -Dmachined=true \
                -Dnetworkd=true \
                -Dportabled=false \
                -Dresolve=true \
                -Dtimedated=true \
                -Dtimesyncd=true \
                -Dtmpfiles=true \
                -Duserdb=true \
                -Dhomed=false \
                -Dpolkit=true \
                -Dman=true \
                -Dhtml=disabled \
                -Dlz4=enabled \
                -Dzstd=enabled
            ninja -C builddir
            ninja -C builddir install
            popd >/dev/null
            rm -rf "$dir"
            touch "$(marker_for systemd)"
            echo "=== systemd done ==="
        else
            echo "WARNING: No source found for systemd"
        fi
    else
        echo "[INFO] systemd already installed; skipping"
    fi

    # ---- Post-install configuration ----
    echo "Configuring systemd..."

    # Create /etc/machine-id
    if [ ! -f /etc/machine-id ] || [ ! -s /etc/machine-id ]; then
        if have_cmd systemd-machine-id-setup; then
            systemd-machine-id-setup
        else
            head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > /etc/machine-id
        fi
    fi

    # Create /etc/os-release if not present
    if [ ! -f /etc/os-release ]; then
        cat > /etc/os-release <<'OSREL'
NAME="LFS"
VERSION="13.0"
ID=lfs
PRETTY_NAME="Linux From Scratch 13.0"
OSREL
    fi

    # Link systemd as /sbin/init
    ln -sf /usr/lib/systemd/systemd /sbin/init
    ln -sf /usr/bin/systemctl /sbin/service 2>/dev/null || true

    # Set default target
    if have_cmd systemctl; then
        systemctl set-default multi-user.target 2>/dev/null || true
    else
        mkdir -p /etc/systemd/system
        ln -sf /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target
    fi

    # Enable essential services
    systemctl enable getty@tty1.service 2>/dev/null || true
    systemctl enable getty@tty2.service 2>/dev/null || true
    systemctl enable systemd-networkd.service 2>/dev/null || true
    systemctl enable systemd-resolved.service 2>/dev/null || true
    systemctl enable systemd-timesyncd.service 2>/dev/null || true

    # Basic network configuration
    mkdir -p /etc/systemd/network
    cat > /etc/systemd/network/20-wired.network <<'NETCONF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
NETCONF

    # Journald configuration
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/lfs-defaults.conf <<'JCONF'
[Journal]
Storage=persistent
Compress=yes
RateLimitIntervalSec=30s
RateLimitBurst=1000
JCONF

    # Logind configuration
    mkdir -p /etc/systemd/logind.conf.d
    cat > /etc/systemd/logind.conf.d/lfs-defaults.conf <<'LCONF'
[Login]
KillUserProcesses=no
LCONF

    # Resolved configuration
    mkdir -p /etc/systemd/resolved.conf.d
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true

    echo "systemd configuration complete."

else
    echo "ERROR: Unknown init system $INIT_SYSTEM"
    exit 1
fi

echo "Init system installation complete."
INNEREOF

run_privileged chmod +x "$LFS/build-init.sh"

# Execute with explicit PATH
log_info "Entering chroot and building init system with argument: $INIT_SYSTEM"
run_privileged chroot "$LFS" /bin/bash -c "export PATH=/bin:/usr/bin:/sbin:/usr/sbin:/tools/bin; /build-init.sh $INIT_SYSTEM"

run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true
run_privileged umount "$LFS"/run 2>/dev/null || true

log_success "Init system ($INIT_SYSTEM) installed successfully"
