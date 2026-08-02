#!/bin/bash
# Build LFS system – official LFS compilation with cross-toolchain
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
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

copy_tool_with_libs() {
	local source_path="$1"
	local dest_path="$2"

	if [ ! -x "$source_path" ]; then
		return 1
	fi

	run_privileged mkdir -p "$(dirname "$dest_path")"
	run_privileged cp -Lv "$source_path" "$dest_path"
	run_privileged chmod +x "$dest_path"

	ldd "$source_path" 2>/dev/null | awk '/=> \// {print $3} $1 ~ /^\/lib/ {print $1}' | while read -r lib; do
		[ -z "$lib" ] && continue
		run_privileged mkdir -p "$LFS$(dirname "$lib")"
		if [ ! -e "$LFS$lib" ]; then
			run_privileged cp -Lv "$lib" "$LFS$lib"
		fi
	done
}

ensure_bootstrap_chroot_shell() {
	if [ ! -x "$LFS/bin/bash" ]; then
		log_info "Bootstrapping /bin/bash into chroot"
		if [ -x "$LFS/usr/bin/bash" ]; then
			run_privileged mkdir -p "$LFS/bin"
			run_privileged ln -sfn /usr/bin/bash "$LFS/bin/bash"
		else
			local host_bash
			host_bash="$(command -v bash 2>/dev/null || true)"
			if [ -z "$host_bash" ] || [ ! -x "$host_bash" ]; then
				log_error "Unable to locate a host bash binary for chroot bootstrap"
				exit 1
			fi
			copy_tool_with_libs "$host_bash" "$LFS/bin/bash"
		fi
	fi

	if [ ! -e "$LFS/bin/sh" ]; then
		run_privileged ln -sfn bash "$LFS/bin/sh"
	fi

	for tool in env xz bzip2 expr grep sed awk find xargs cut head tail wc tr sort uniq dirname basename tar uname make rm mkdir cp mv ln rmdir chmod gcc ld; do
		if [ ! -x "$LFS/usr/bin/$tool" ]; then
			log_info "Bootstrapping /usr/bin/$tool into chroot"
			local host_tool
			host_tool="$(command -v "$tool" 2>/dev/null || true)"
			if [ -n "$host_tool" ] && [ -x "$host_tool" ]; then
				copy_tool_with_libs "$host_tool" "$LFS/usr/bin/$tool"
			else
				log_warning "Host tool '$tool' not found, chroot may fail"
			fi
		fi
	done

	# Ensure /bin/awk exists
	if [ ! -x "$LFS/bin/awk" ]; then
		if [ -x "$LFS/usr/bin/awk" ]; then
			run_privileged cp -v "$LFS/usr/bin/awk" "$LFS/bin/awk"
			run_privileged chmod +x "$LFS/bin/awk"
		else
			log_warning "/usr/bin/awk not found in chroot, awk may be missing"
		fi
	fi

	# Copy libtinfo.so.6 to /lib (instead of symlink) to ensure it's found
	if [ -f "$LFS/lib/x86_64-linux-gnu/libtinfo.so.6" ] && [ ! -e "$LFS/lib/libtinfo.so.6" ]; then
		run_privileged cp -v "$LFS/lib/x86_64-linux-gnu/libtinfo.so.6" "$LFS/lib/libtinfo.so.6"
	fi

	# If the toolchain built a newer liblzma (e.g. xz-5.6+), prefer it over the
	# host version.  The host liblzma may be an older rollback package that does
	# not export the XZ_5.6.0 version symbol required by the cross-compiled xz
	# binary placed in /tools/bin by the toolchain stage.
	if [ -f "$LFS/tools/lib/liblzma.so.5" ] && [ -f "$LFS/lib/x86_64-linux-gnu/liblzma.so.5" ]; then
		run_privileged cp -Lv "$LFS/tools/lib/liblzma.so.5" "$LFS/lib/x86_64-linux-gnu/liblzma.so.5"
		log_info "Updated /lib/x86_64-linux-gnu/liblzma.so.5 from toolchain"
	fi
}

log_info "========================================="
log_info "Building LFS system"
log_info "========================================="

INIT_SYSTEM=${INIT_SYSTEM:-sysvinit}
log_info "Init system: $INIT_SYSTEM"

if [ "$IN_DOCKER" = true ]; then
	log_info "Docker mode – skipping compilation"
	exit 0
fi

ensure_bootstrap_chroot_shell

if [ ! -f "$LFS/bin/bash" ]; then
	log_error "/bin/bash not found in $LFS/bin – run lfs-basic first"
	exit 1
fi
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
	log_error "chroot not working – run lfs-basic first"
	exit 1
fi

# Check for temporary toolchain
if [ ! -x "$LFS/tools/bin/${LFS_TGT}-gcc" ] || [ ! -x "$LFS/tools/bin/${LFS_TGT}-ld" ] || [ ! -x "$LFS/tools/bin/${LFS_TGT}-as" ]; then
	log_error "Missing temporary toolchain in $LFS/tools/bin (${LFS_TGT}-gcc/${LFS_TGT}-ld/${LFS_TGT}-as)"
	log_error "Cannot proceed – run lfs-basic first"
	exit 1
fi

if [ ! -x "$LFS/bin/sh" ]; then
	log_info "Creating /bin/sh symlink"
	run_privileged ln -sf bash "$LFS/bin/sh"
fi

# -----------------------------------------------------------------
# Mount filesystems
# -----------------------------------------------------------------
run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t devpts devpts "$LFS"/dev/pts 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true
run_privileged mount -t tmpfs tmpfs "$LFS"/run 2>/dev/null || true
run_privileged mount --bind /usr "$LFS"/usr 2>/dev/null || true

# -----------------------------------------------------------------
# Copy sources into chroot
# -----------------------------------------------------------------
SOURCES_DIR="$LFS/sources"
LEGACY_SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_DIR" ] && [ "$(ls -A "$SOURCES_DIR" 2>/dev/null)" ]; then
	log_info "Using existing sources in $SOURCES_DIR"
elif [ -d "$LEGACY_SOURCES_HOST" ] && [ "$(ls -A "$LEGACY_SOURCES_HOST" 2>/dev/null)" ]; then
	log_info "Copying sources from $LEGACY_SOURCES_HOST to $SOURCES_DIR"
	run_privileged mkdir -p "$SOURCES_DIR"
	run_privileged cp -r "$LEGACY_SOURCES_HOST"/. "$SOURCES_DIR"/
	run_privileged chown -R lfs:lfs "$SOURCES_DIR"
else
	log_error "No sources found in $SOURCES_DIR or $LEGACY_SOURCES_HOST – cannot compile"
	exit 1
fi

# -----------------------------------------------------------------
# Internal compilation script (official LFS steps with cross-toolchain)
# -----------------------------------------------------------------
log_info "Creating internal compilation script"
cat >"$LFS/build-lfs-system.sh" <<'INNEREOF'
#!/bin/bash
set -e

export PATH=/tools/bin:/bin:/usr/bin:/sbin
export LD_LIBRARY_PATH=/tools/lib
export SHELL=/bin/bash
export CONFIG_SHELL=/bin/bash

cd /sources

# ----- Helper: extract and cd -----
extract() {
    local archive=$1
    local dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
    echo "Extracting $archive -> $dir"
    tar -xf "$archive"
    cd "$dir"
}

# ----- Helper: find archive (supports .tar.xz, .tar.gz, .tgz, etc.) -----
find_archive() {
    local base=$1
    local archive=""
    for f in "${base}"*.tar.* "${base}"*.tgz; do
        if [ -f "$f" ]; then
            archive="$f"
            break
        fi
    done
    echo "$archive"
}

# ---- Install Linux API headers into /usr/include ----
echo "Installing Linux API headers"
LINUX_ARCHIVE=$(find_archive linux)
if [ -z "$LINUX_ARCHIVE" ]; then
    echo "ERROR: linux source not found"
    echo "Available source archives:"
    ls -la
    exit 1
fi
echo "Extracting $LINUX_ARCHIVE"
tar -xf "$LINUX_ARCHIVE"
LINUX_DIR=$(echo "$LINUX_ARCHIVE" | sed -E 's/\.tar\.[a-z0-9]+$//' | sed -E 's/\.tgz$//')
if [ ! -d "$LINUX_DIR" ]; then
    echo "ERROR: extracted directory $LINUX_DIR not found"
    exit 1
fi
cd "$LINUX_DIR"
make mrproper
make headers
find usr/include -name '.*' -delete
rm -f usr/include/Makefile
cp -rv usr/include/. /usr/include
cd /sources
rm -rf "$LINUX_DIR"
echo "Linux headers installed"

# ---- Set cross-compiler variables ----
CC="${LFS_TGT}-gcc"
CXX="${LFS_TGT}-g++"
LD="${LFS_TGT}-ld"
AS="${LFS_TGT}-as"
export CC CXX LD AS

# ============================================================
# 1. BUILD GLIBC (official LFS)
# ============================================================
echo "=== Building glibc ==="
GLIBC_ARCHIVE=$(find_archive glibc)
if [ -z "$GLIBC_ARCHIVE" ]; then
    echo "ERROR: glibc source not found"
    exit 1
fi
extract "$GLIBC_ARCHIVE"
mkdir -v build
cd build
../configure --prefix=/usr \
             --host=$LFS_TGT \
             --build=$(uname -m)-linux-gnu \
             --disable-werror \
             --enable-kernel=4.14 \
             --enable-stack-protector=strong \
             --with-headers=/usr/include \
             --libdir=/usr/lib \
             --enable-cet \
             --enable-multi-arch
make -j$(nproc)
# Use LD_LIBRARY_PATH and SHELL to ensure /bin/sh can find libtinfo
LD_LIBRARY_PATH=/lib:/lib/x86_64-linux-gnu make RM=/tools/bin/rm SHELL=/bin/bash install
cd /sources
rm -rf "$(basename "$GLIBC_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
echo "glibc done"

# ============================================================
# 2. BUILD BINUTILS (official LFS)
# ============================================================
echo "=== Building binutils ==="
BINUTILS_ARCHIVE=$(find_archive binutils)
if [ -z "$BINUTILS_ARCHIVE" ]; then
    echo "ERROR: binutils source not found"
    exit 1
fi
extract "$BINUTILS_ARCHIVE"
mkdir -v build
cd build
../configure --prefix=/usr \
             --host=$LFS_TGT \
             --build=$(uname -m)-linux-gnu \
             --sysconfdir=/etc \
             --enable-gold \
             --enable-ld=default \
             --enable-plugins \
             --enable-shared \
             --disable-werror \
             --enable-64-bit-bfd \
             --with-system-zlib
make -j$(nproc) tooldir=/usr
make tooldir=/usr install
cd /sources
rm -rf "$(basename "$BINUTILS_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
echo "binutils done"

# ============================================================
# 3. BUILD GCC (official LFS) – with GMP, MPFR, MPC integrated
# ============================================================
echo "=== Building gcc ==="
GCC_ARCHIVE=$(find_archive gcc)
if [ -z "$GCC_ARCHIVE" ]; then
    echo "ERROR: gcc source not found"
    exit 1
fi
extract "$GCC_ARCHIVE"

# Integrate GMP, MPFR, MPC
echo "Integrating GMP, MPFR, MPC into GCC source tree"
GMP_ARCHIVE=$(find_archive gmp)
if [ -n "$GMP_ARCHIVE" ]; then
    tar -xf "$GMP_ARCHIVE"
    GMP_DIR=$(echo "$GMP_ARCHIVE" | sed -E 's/\.tar\.[a-z0-9]+$//' | sed -E 's/\.tgz$//')
    mv -v "$GMP_DIR" gmp
else
    echo "WARNING: GMP source not found – GCC may fail"
fi

MPFR_ARCHIVE=$(find_archive mpfr)
if [ -n "$MPFR_ARCHIVE" ]; then
    tar -xf "$MPFR_ARCHIVE"
    MPFR_DIR=$(echo "$MPFR_ARCHIVE" | sed -E 's/\.tar\.[a-z0-9]+$//' | sed -E 's/\.tgz$//')
    mv -v "$MPFR_DIR" mpfr
else
    echo "WARNING: MPFR source not found – GCC may fail"
fi

MPC_ARCHIVE=$(find_archive mpc)
if [ -n "$MPC_ARCHIVE" ]; then
    tar -xf "$MPC_ARCHIVE"
    MPC_DIR=$(echo "$MPC_ARCHIVE" | sed -E 's/\.tar\.[a-z0-9]+$//' | sed -E 's/\.tgz$//')
    mv -v "$MPC_DIR" mpc
else
    echo "WARNING: MPC source not found – GCC may fail"
fi

mkdir -v build
cd build
../configure --prefix=/usr \
             --host=$LFS_TGT \
             --build=$(uname -m)-linux-gnu \
             --enable-languages=c,c++ \
             --disable-multilib \
             --disable-bootstrap \
             --with-system-zlib \
             --enable-default-pie \
             --enable-default-ssp \
             --enable-cet=auto \
             --enable-linker-build-id
make -j$(nproc)
make install
ln -sf gcc /usr/bin/cc
ln -sf g++ /usr/bin/c++
cd /sources
rm -rf "$(basename "$GCC_ARCHIVE" .tar.* 2>/dev/null | sed 's/\.tar\.[a-z0-9]*$//')"
echo "gcc done"

# ============================================================
# 4. BUILD BASE PACKAGES (coreutils, bash, etc.) – now using native compiler
# ============================================================
# After gcc is installed, we switch to the native compiler
unset CC CXX LD AS

build_simple() {
    local pkg=$1
    local cflags=""
    local archive=$(find_archive "$pkg")
    if [ -z "$archive" ]; then
        echo "WARNING: $pkg source not found, skipping"
        return 0
    fi
    local dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
    echo "=== Building $dir ==="
    tar -xf "$archive"
    cd "$dir"
    if [ "$pkg" = "diffutils" ]; then
        if grep -q "PATH_MAX" lib/stackvma.c 2>/dev/null &&
           ! grep -q "#include <limits.h>" lib/stackvma.c 2>/dev/null; then
            sed -i '1s/^/#include <limits.h>\n/' lib/stackvma.c
        fi
        cflags="-D_GNU_SOURCE -DPATH_MAX=4096"
    fi
    if [ -f "configure" ]; then
        CFLAGS="$cflags" ./configure --prefix=/usr --sysconfdir=/etc
    elif [ -f "Makefile" ]; then
        true
    fi
    CFLAGS="$cflags" make -j$(nproc)
    CFLAGS="$cflags" make install
    cd /sources
    rm -rf "$dir"
    echo "=== $dir done ==="
}

for pkg in coreutils bash make grep sed gawk findutils tar gzip bzip2 diffutils patch; do
    build_simple "$pkg"
done

echo "=== Base system compilation complete ==="
INNEREOF

run_privileged chmod +x "$LFS/build-lfs-system.sh"

log_info "Entering chroot and compiling..."
run_privileged chroot "$LFS" /bin/bash -c "export INIT_SYSTEM=$INIT_SYSTEM; export KERNEL_TYPE=$KERNEL_TYPE; export LFS_TGT=$LFS_TGT; /build-lfs-system.sh"

if [ -x "$LFS/usr/bin/bash" ]; then
	run_privileged ln -sfn /usr/bin/bash "$LFS/bin/bash"
	run_privileged ln -sfn bash "$LFS/bin/sh"
fi

run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true
run_privileged umount "$LFS"/run 2>/dev/null || true
run_privileged umount "$LFS"/usr 2>/dev/null || true

log_success "LFS system build complete"
