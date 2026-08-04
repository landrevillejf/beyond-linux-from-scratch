#!/bin/bash
# blfs/16-privacy-tools.sh – with dynamic source path
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
log_info "Installing privacy tools"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – skipping privacy tools installation"
    exit 0
fi

log_info "Native mode – installing privacy tools inside chroot"

if [ ! -f "$LFS/bin/bash" ]; then
    log_error "/bin/bash not found in $LFS/bin – run lfs-basic first"
    exit 1
fi
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
    log_error "chroot not working – run lfs-basic first"
    exit 1
fi

run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t devpts devpts "$LFS"/dev/pts 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true
run_privileged mount -t tmpfs tmpfs "$LFS"/run 2>/dev/null || true

# --- DYNAMIC SOURCE PATH ---
SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    run_privileged chown -R lfs:lfs "$LFS/sources"
fi

cat >"$LFS/install-privacy-tools.sh" <<'INNEREOF'
#!/bin/bash
set -e

cd /sources

echo "=== Installing privacy tools ==="

# Tor
if ls tor-*.tar.gz 1>/dev/null 2>&1; then
    echo "Building Tor..."
    tar -xf $(ls tor-*.tar.gz | head -n1)
    cd tor-*
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-system-torrc
    make -j$(nproc)
    make install
    groupadd -r tor 2>/dev/null || true
    useradd -r -g tor -d /var/lib/tor tor 2>/dev/null || true
    mkdir -p /var/lib/tor /var/log/tor
    chown -R tor:tor /var/lib/tor /var/log/tor
    chmod 700 /var/lib/tor
    cat > /etc/tor/torrc << 'EOF'
DataDirectory /var/lib/tor
Log notice file /var/log/tor/notices.log
SocksPort 9050
ControlPort 9051
EOF
    cd /sources
fi

# WireGuard-tools
if ls wireguard-tools-*.tar.xz 1>/dev/null 2>&1; then
    echo "Building WireGuard-tools..."
    tar -xf $(ls wireguard-tools-*.tar.xz | head -n1)
    cd wireguard-tools-*/src
    make -j$(nproc)
    make install
    cd /sources
fi

# DNSCrypt-proxy
if ls dnscrypt-proxy-*.tar.gz 1>/dev/null 2>&1; then
    echo "Building DNSCrypt-proxy..."
    tar -xf $(ls dnscrypt-proxy-*.tar.gz | head -n1)
    cd dnscrypt-proxy-*
    make -j$(nproc)
    make install
    mkdir -p /etc/dnscrypt-proxy
    groupadd -r dnscrypt 2>/dev/null || true
    useradd -r -g dnscrypt -d /var/empty dnscrypt 2>/dev/null || true
    cd /sources
fi

# Mat2
if ls mat2-*.tar.gz 1>/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    echo "Building Mat2..."
    tar -xf $(ls mat2-*.tar.gz | head -n1)
    cd mat2-*
    python3 setup.py install
    cd /sources
fi

echo "Privacy tools installed."
INNEREOF

run_privileged chmod +x "$LFS/install-privacy-tools.sh"
run_privileged chroot "$LFS" /bin/bash /install-privacy-tools.sh

run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true
run_privileged umount "$LFS"/run 2>/dev/null || true

log_success "Privacy tools installed"
