#!/bin/bash
# Build LFS basic – prepare chroot environment for system compilation
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
# 05a-build-lfs-basic.sh – Set up the bootstrap chroot, mount filesystems,
#                           and copy sources so the next stage can compile.
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

KERNEL_TYPE="${KERNEL_TYPE:-linux}"
export KERNEL_TYPE
log_info "Kernel type: $KERNEL_TYPE"

LFS_TGT="${LFS_TGT:-$(uname -m)-lfs-linux-gnu}"

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

if [ -d "$LFS/image/tools" ] && [ -d "$LFS/image/usr" ] && [ ! -d "$LFS/tools" ]; then
    log_warning "Detected image-root layout at $LFS/image, switching LFS root"
    LFS="$LFS/image"
fi

run_privileged() {
    if [ "$(whoami)" = "root" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

ensure_bootstrap_chroot_shell() {
    local tool
    local required_tools=(
        bash bison m4 xz bzip2 expr grep sed awk find xargs cut head tail wc
        tr sort uniq dirname basename tar uname make rm mkdir cp mv ln rmdir chmod
    )

    for tool in "${required_tools[@]}"; do
        if [ ! -x "$LFS/tools/bin/$tool" ]; then
            log_error "Missing bootstrap tool: $LFS/tools/bin/$tool"
            log_error "The toolchain stage must build it; host binaries are never copied into LFS."
            exit 1
        fi
    done

    # /tools is the self-contained temporary userspace. Only expose its shell
    # through conventional paths required by chroot; the inner build uses
    # PATH=/tools/bin and never imports host programs or libraries.
    run_privileged mkdir -p "$LFS/bin"
    run_privileged ln -sfn /tools/bin/bash "$LFS/bin/bash"
    run_privileged ln -sfn bash "$LFS/bin/sh"

    # ------------------------------------------------------------------
    # Ensure the dynamic linker is reachable at the path the cross-compiled
    # /tools/bin/bash expects.
    #
    # The toolchain gcc was built with --with-sysroot=$LFS and embeds the
    # interpreter path /tools/lib/ld-linux-*.so* in every ELF binary it
    # produces.  However, glibc's "make install" (configured with
    # --prefix=/usr, libc_cv_slibdir=/usr/lib) places the actual dynamic
    # linker under /lib64 (the default rtlddir on x86_64) or /usr/lib,
    # NOT under /tools/lib.  Without a symlink the kernel cannot find the
    # interpreter and the chroot execve() fails with ENOENT.
    # ------------------------------------------------------------------
    local expected_linker="$LFS/tools/lib/ld-linux-x86-64.so.2"
    if [ ! -e "$expected_linker" ]; then
        local actual_linker=""
        for candidate in "$LFS/lib64/ld-linux-x86-64.so.2" \
                         "$LFS/usr/lib/ld-linux-x86-64.so.2" \
                         "$LFS/lib/ld-linux-x86-64.so.2"; do
            if [ -f "$candidate" ]; then
                actual_linker="$candidate"
                break
            fi
        done

        if [ -n "$actual_linker" ]; then
            log_info "Dynamic linker found at $actual_linker"
            # Strip the $LFS prefix to get the chroot-relative path.
            # The symlink target MUST be relative to the chroot root,
            # NOT the host-absolute path (which doesn't exist inside chroot).
            local linker_in_chroot="${actual_linker#"$LFS"}"
            log_info "Creating symlink /tools/lib/ld-linux-x86-64.so.2 -> $linker_in_chroot"
            run_privileged mkdir -p "$LFS/tools/lib"
            run_privileged ln -sf "$linker_in_chroot" "$expected_linker"
        else
            log_warning "Dynamic linker ld-linux-x86-64.so.2 not found in /lib64, /usr/lib, or /lib"
            log_warning "Chroot may fail – check that glibc was installed correctly"
        fi
    fi

    # ------------------------------------------------------------------
    # Also ensure libc.so.6 is reachable at /tools/lib/ inside the chroot.
    # Cross-compiled /tools/bin/bash needs both the dynamic linker AND libc.
    # ------------------------------------------------------------------
    local expected_libc="$LFS/tools/lib/libc.so.6"
    if [ ! -e "$expected_libc" ]; then
        local actual_libc=""
        for candidate in "$LFS/lib64/libc.so.6" \
                         "$LFS/usr/lib/libc.so.6" \
                         "$LFS/lib/libc.so.6"; do
            if [ -f "$candidate" ]; then
                actual_libc="$candidate"
                break
            fi
        done

        if [ -n "$actual_libc" ]; then
            local libc_in_chroot="${actual_libc#"$LFS"}"
            log_info "libc.so.6 found at $actual_libc, linking $libc_in_chroot"
            run_privileged mkdir -p "$LFS/tools/lib"
            run_privileged ln -sf "$libc_in_chroot" "$expected_libc"
        fi
    fi
}

log_info "========================================="
log_info "Building LFS basic environment"
log_info "========================================="

INIT_SYSTEM=${INIT_SYSTEM:-sysvinit}
log_info "Init system: $INIT_SYSTEM"

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – skipping chroot setup"
    exit 0
fi

# -----------------------------------------------------------------
# Bootstrap chroot shell + dynamic linker symlink
# -----------------------------------------------------------------
ensure_bootstrap_chroot_shell

if [ ! -x "$LFS/tools/bin/bash" ]; then
    log_error "/tools/bin/bash not found – run toolchain first"
    exit 1
fi
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>&1; then
    log_error "chroot test failed – the cross-compiled /tools/bin/bash cannot run inside the chroot"
    log_error "Check that the dynamic linker (/tools/lib/ld-linux-x86-64.so.2) and libc.so.6 are accessible"
    exit 1
fi
log_success "Bootstrap chroot shell is working"

# Check for temporary toolchain
if [ ! -x "$LFS/tools/bin/${LFS_TGT}-gcc" ] || [ ! -x "$LFS/tools/bin/${LFS_TGT}-ld" ] || [ ! -x "$LFS/tools/bin/${LFS_TGT}-as" ]; then
    log_error "Missing temporary toolchain in $LFS/tools/bin (${LFS_TGT}-gcc/${LFS_TGT}-ld/${LFS_TGT}-as)"
    log_error "Cannot proceed – the toolchain stage must complete first"
    exit 1
fi
log_success "Temporary toolchain verified"

if [ ! -x "$LFS/bin/sh" ]; then
    log_info "Creating /bin/sh symlink"
    run_privileged ln -sf bash "$LFS/bin/sh"
fi

# -----------------------------------------------------------------
# Create essential directories inside chroot
# -----------------------------------------------------------------
log_info "Creating essential directories"
run_privileged mkdir -p "$LFS"/{boot,home,mnt,opt,srv}
run_privileged mkdir -p "$LFS"/etc/{opt,sysconfig}
run_privileged mkdir -p "$LFS"/lib/firmware
run_privileged mkdir -p "$LFS"/media/{floppy,cdrom}
run_privileged mkdir -p "$LFS"/usr/{local,share}
run_privileged mkdir -p "$LFS"/usr/local/{bin,include,lib,sbin,src}
run_privileged mkdir -p "$LFS"/usr/local/etc
run_privileged mkdir -p "$LFS"/var/{cache,lib,local,log,opt,spool}
run_privileged mkdir -p "$LFS"/var/lib/{color,misc,locate}
run_privileged mkdir -p "$LFS"/dev/{pts,shm}
run_privileged mkdir -p "$LFS"/proc
run_privileged mkdir -p "$LFS"/sys
run_privileged mkdir -p "$LFS"/run
run_privileged mkdir -p "$LFS"/sources
run_privileged mkdir -p "$LFS"/tmp

# -----------------------------------------------------------------
# Mount filesystems for chroot
# -----------------------------------------------------------------
cleanup_mounts() {
    run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
    run_privileged umount "$LFS"/dev 2>/dev/null || true
    run_privileged umount "$LFS"/proc 2>/dev/null || true
    run_privileged umount "$LFS"/sys 2>/dev/null || true
    run_privileged umount "$LFS"/run 2>/dev/null || true
}
trap cleanup_mounts EXIT

log_info "Mounting virtual filesystems"
run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t devpts devpts "$LFS"/dev/pts 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true
run_privileged mount -t tmpfs tmpfs "$LFS"/run 2>/dev/null || true

# -----------------------------------------------------------------
# Copy sources into chroot
# -----------------------------------------------------------------
SOURCES_DIR="$LFS/sources"

if [ -d "$SOURCES_DIR" ] && [ "$(ls -A "$SOURCES_DIR" 2>/dev/null)" ]; then
    log_info "Sources already present in $SOURCES_DIR"
else
    PARENT_SOURCES="$(dirname "$LFS")/sources"
    if [ -d "$PARENT_SOURCES" ] && [ "$(ls -A "$PARENT_SOURCES" 2>/dev/null)" ]; then
        log_info "Copying sources from $PARENT_SOURCES to $SOURCES_DIR"
        run_privileged mkdir -p "$SOURCES_DIR"
        run_privileged cp -r "$PARENT_SOURCES"/. "$SOURCES_DIR"/
        run_privileged chown -R lfs:lfs "$SOURCES_DIR"
    else
        log_error "No sources found in $SOURCES_DIR or $PARENT_SOURCES – cannot compile"
        exit 1
    fi
fi

ls -la "$SOURCES_DIR" | head -20

log_success "LFS basic environment ready"
