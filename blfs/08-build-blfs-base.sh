#!/bin/bash
# Build BLFS base packages (minimal set) – BLFS book compliant
# Author : Jean-Francois Landreville, landrevvillejf@protonmail.com, 2026.
# 08-build-blfs-base.sh – Installs the BLFS base library chain (OpenSSL,
#                          cURL, expat, libxml2) and the blfs-bootscripts
#                          using the per-package commands from the BLFS
#                          book instead of a generic configure/make
#                          template.  A failed package fails the stage:
#                          no "|| true" error masking.
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

# ============================================================================
# INTÉGRATION DU TYPE DE NOYAU
# ============================================================================
KERNEL_TYPE="${KERNEL_TYPE:-linux}"
export KERNEL_TYPE
log_info "Kernel type: $KERNEL_TYPE"
# ============================================================================

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
log_info "Building BLFS base packages"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – creating minimal BLFS structure inside $LFS"
    run_privileged mkdir -pv "$LFS/usr/share/doc"
    run_privileged mkdir -pv "$LFS/usr/share/man"
    log_success "Minimal BLFS structure created"
    exit 0
fi

log_info "Native mode – building BLFS base packages"

if [ ! -f "$LFS/bin/bash" ]; then
    log_error "/bin/bash not found in $LFS/bin – run lfs-basic first"
    exit 1
fi
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
    log_error "chroot not working – run lfs-basic first"
    exit 1
fi

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

# --- DYNAMIC SOURCE PATH ---
SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    run_privileged chown -R lfs:lfs "$LFS/sources"
fi

# -----------------------------------------------------------------
# Internal build script – per-package BLFS book commands.
# Order follows the BLFS dependency chain: OpenSSL first (cURL
# links against it), then cURL, expat, libxml2, blfs-bootscripts.
# ICU support is omitted for libxml2 because icu4c is only built
# later by 08a-build-blfs-libs.sh (it is optional and only needed
# by QtWebEngine).
# -----------------------------------------------------------------
cat >"$LFS/build-blfs-base.sh" <<'INNEREOF'
#!/bin/bash
set -e

cd /sources

# Match package names case-insensitively (Python-3.13.7.tar.xz),
# treat underscores like dashes (flit_core), prefer name-<version>
# tarballs over documentation variants (python-3.13.7-docs-html),
# and fall back to oddball layouts (tcl8.6.16-src, expect5.45.4).
find_archive() {
    local base=$1 f name_lc prefix_lc
    local -a tier1=() tier2=() filtered=()
    prefix_lc=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

    for f in *.tar.* *.tgz; do
        [ -f "$f" ] || continue
        name_lc=$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        case "$name_lc" in
            "$prefix_lc"*) ;;
            *) continue ;;
        esac
        case "$name_lc" in
            "$prefix_lc"-[0-9]*) tier1+=("$f") ;;
            *) tier2+=("$f") ;;
        esac
    done

    # Prefer name-<version> tarballs, skipping documentation variants
    # such as python-3.13.7-docs-html.tar.bz2.
    if [ "${#tier1[@]}" -gt 0 ]; then
        for f in "${tier1[@]}"; do
            case "$f" in
                *-docs* | *-html* | *-apidoc*) ;;
                *) filtered+=("$f") ;;
            esac
        done
        [ "${#filtered[@]}" -gt 0 ] && tier1=("${filtered[@]}")
        # Newest version wins: stale duplicates restored from the CI
        # packages cache must never shadow the book version (glob
        # order silently picks the oldest name, nightly #174).
        printf '%s\n' "${tier1[@]}" | sort -V | tail -n 1
        return 0
    fi

    # Fallback: non-standard layouts such as tcl8.6.16-src.tar.gz or
    # expect5.45.4.tar.gz.  Prefer -src archives, then any archive
    # whose top level carries a configure script.
    if [ "${#tier2[@]}" -eq 0 ]; then
        echo "ERROR: no source archive found for $base" >&2
        return 0
    fi
    for f in "${tier2[@]}"; do
        case "$f" in
            *-src*)
                printf '%s\n' "$f"
                return 0
                ;;
        esac
    done
    filtered=()
    for f in "${tier2[@]}"; do
        case "$f" in
            *-docs* | *-html* | *-apidoc*) ;;
            *) filtered+=("$f") ;;
        esac
    done
    [ "${#filtered[@]}" -gt 0 ] && tier2=("${filtered[@]}")
    for f in "${tier2[@]}"; do
        if tar -tf "$f" 2>/dev/null | grep -Eq '(^|/)configure$'; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    printf '%s\n' "${tier2[0]}"
    return 0
}

extract() {
    local archive=$1
    local dir
    dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
    echo "=== Building $dir ==="
    rm -rf "$dir"
    tar -xf "$archive"
    cd "$dir"
}

# ---- OpenSSL (BLFS postlfs) ----
extract "$(find_archive openssl)"
./config --prefix=/usr \
    --openssldir=/etc/ssl \
    --libdir=lib \
    shared \
    zlib-dynamic
make -j"$(nproc)"
make install
rm -rvf /usr/bin/c_rehash
cd /sources

# ---- IDN stack for cURL (BLFS general + basicnet) ----
# curl 8.15 requires libpsl (BLFS basicnet/curl), which itself
# needs libidn2 and libunistring.  The 08a libs stage runs after
# this one, so the whole chain must land here before cURL.
extract "$(find_archive libunistring)"
./configure --prefix=/usr \
    --disable-static
make -j"$(nproc)"
make install
cd /sources

extract "$(find_archive libidn2)"
./configure --prefix=/usr \
    --disable-static
make -j"$(nproc)"
make install
cd /sources

psl_dir=$(tar -tf "$(find_archive libpsl)" | head -1 | cut -d/ -f1)
extract "$(find_archive libpsl)"
mkdir -p build
cd build
meson setup --prefix=/usr \
    --buildtype=release \
    ..
ninja
ninja install
install -v -dm755 \
    "/usr/share/doc/${psl_dir}/libpsl"
install -v -m644 ../doc/libpsl/* \
    "/usr/share/doc/${psl_dir}/libpsl"
cd /sources

# ---- cURL (BLFS basicnet – needs OpenSSL and libpsl first) ----
curl_dir=$(tar -tf "$(find_archive curl)" | head -1 | cut -d/ -f1)
extract "$(find_archive curl)"
./configure --prefix=/usr \
    --disable-static \
    --with-openssl \
    --with-ca-path=/etc/ssl/certs
make -j"$(nproc)"
make install
rm -rf docs/examples/.deps
find docs \( -name 'Makefile*' -o \
    -name '*.1' -o \
    -name '*.3' -o \
    -name 'CMakeLists.txt' \) -delete
mkdir -p "/usr/share/doc/${curl_dir}"
cp -v -R docs -T "/usr/share/doc/${curl_dir}"
cd /sources

# ---- expat (BLFS general) ----
expat_dir=$(tar -tf "$(find_archive expat)" | head -1 | cut -d/ -f1)
extract "$(find_archive expat)"
./configure --prefix=/usr \
    --disable-static \
    --docdir="/usr/share/doc/${expat_dir}"
make -j"$(nproc)"
make install
install -v -m644 doc/*.html doc/*.css "/usr/share/doc/${expat_dir}"
cd /sources

# ---- libxml2 (BLFS general) ----
libxml2_dir=$(tar -tf "$(find_archive libxml2)" | head -1 | cut -d/ -f1)
extract "$(find_archive libxml2)"
./configure --prefix=/usr \
    --sysconfdir=/etc \
    --disable-static \
    --with-history \
    PYTHON=/usr/bin/python3 \
    --docdir="/usr/share/doc/${libxml2_dir}"
make -j"$(nproc)"
make install
rm -vf /usr/lib/libxml2.la
sed '/libs=/s/xml2.*/xml2"/' -i /usr/bin/xml2-config
cd /sources

# ---- blfs-bootscripts (requires lfs-bootscripts from stage 06a) ----
archive=""
for f in blfs-bootscripts-*.tar.xz; do
    if [ -f "$f" ]; then
        archive=$f
    fi
done
if [ -z "$archive" ]; then
    echo "ERROR: blfs-bootscripts source not found" >&2
    exit 1
fi
extract "$archive"
make install
cd /sources

echo "BLFS base packages built."
INNEREOF

run_privileged chmod +x "$LFS/build-blfs-base.sh"

# --- Pass KERNEL_TYPE inside chroot ---
run_privileged chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" PATH=/usr/bin:/usr/sbin \
    KERNEL_TYPE="$KERNEL_TYPE" \
    /bin/bash /build-blfs-base.sh

log_success "BLFS base packages built successfully"
