#!/bin/bash
# Install init system – avec copie des outils et PATH explicite
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
    cat > "$LFS/etc/init.d/rcS" << 'EOF'
#!/bin/sh
echo "Starting minimal init..."
exec /bin/bash
EOF
    chmod +x "$LFS/etc/init.d/rcS"
    ln -sf /etc/init.d/rcS "$LFS/sbin/init"
    log_success "Minimal init created for Docker"
    exit 0
fi

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

run_privileged mount --bind /dev $LFS/dev 2>/dev/null || true
run_privileged mount -t devpts devpts $LFS/dev/pts 2>/dev/null || true
run_privileged mount -t proc proc $LFS/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs $LFS/sys 2>/dev/null || true
run_privileged mount -t tmpfs tmpfs $LFS/run 2>/dev/null || true

# Copie des outils manquants
copy_tool() {
    local tool="$1"
    local src="$(which "$tool" 2>/dev/null || echo "/bin/$tool")"
    [ -f "$src" ] || { log_warning "Source not found for $tool"; return 0; }
    run_privileged cp -L -v "$src" "$LFS/usr/bin/" 2>/dev/null || true
    ldd "$src" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read lib; do
        local dest_dir="$LFS/lib"
        [[ "$lib" == *"/lib64/"* ]] && dest_dir="$LFS/lib64"
        run_privileged mkdir -p "$dest_dir"
        run_privileged cp -v "$lib" "$dest_dir/" 2>/dev/null || true
    done
}

for tool in tar head cut xz make nproc sed mktemp rm; do
    copy_tool "$tool"
done

# Sources
SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    run_privileged chown -R lfs:lfs "$LFS/sources"
fi

# Script interne
cat > "$LFS/build-init.sh" << 'INNEREOF'
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

compile_package() {
    local archive=$1
    if [ ! -f "$archive" ]; then
        echo "WARNING: No source found for $archive"
        return 1
    fi
    local dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
    echo "=== Building $dir ==="
    tar -xf "$archive"
    cd "$dir"
    if [ -f "configure" ]; then
        ./configure --prefix=/usr --sysconfdir=/etc
    elif [ -f "Makefile" ]; then
        true
    fi
    "$MAKE_BIN" -j"$JOBS"
    "$MAKE_BIN" install
    cd /sources
    rm -rf "$dir"
    echo "=== $dir done ==="
}

if [ "$INIT_SYSTEM" = "sysvinit" ]; then
    echo "Building sysvinit..."
    found=0
    for archive in sysvinit-*.tar.*; do
        if [ -f "$archive" ]; then
            compile_package "$archive"
            found=1
            break
        fi
    done
    if [ $found -eq 0 ]; then
        echo "WARNING: No source found for sysvinit"
    fi
elif [ "$INIT_SYSTEM" = "systemd" ]; then
    echo "Building systemd..."
    found=0
    for archive in systemd-*.tar.*; do
        if [ -f "$archive" ]; then
            compile_package "$archive"
            found=1
            break
        fi
    done
    if [ $found -eq 0 ]; then
        echo "WARNING: No source found for systemd"
    fi
else
    echo "ERROR: Unknown init system $INIT_SYSTEM"
    exit 1
fi

echo "Init system installation complete."
INNEREOF

run_privileged chmod +x "$LFS/build-init.sh"

# Exécution avec PATH explicite
log_info "Entering chroot and building init system with argument: $INIT_SYSTEM"
run_privileged chroot "$LFS" /bin/bash -c "export PATH=/bin:/usr/bin:/sbin:/usr/sbin:/tools/bin; /build-init.sh $INIT_SYSTEM"

run_privileged umount $LFS/dev/pts 2>/dev/null || true
run_privileged umount $LFS/dev 2>/dev/null || true
run_privileged umount $LFS/proc 2>/dev/null || true
run_privileged umount $LFS/sys 2>/dev/null || true
run_privileged umount $LFS/run 2>/dev/null || true

log_success "Init system ($INIT_SYSTEM) installed successfully"