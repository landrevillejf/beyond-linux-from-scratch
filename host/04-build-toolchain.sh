#!/usr/bin/env bash
# Build cross-toolchain - Compatible with Docker and native
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

KERNEL_TYPE=${KERNEL_TYPE:-linux}

detect_distro() {
	if [ -f /etc/os-release ]; then
		# shellcheck source=/dev/null
		. /etc/os-release
		echo "$ID"
	elif [ -f /etc/debian_version ]; then
		echo "debian"
	elif [ -f /etc/redhat-release ]; then
		echo "rhel"
	elif [ -f /etc/alpine-release ]; then
		echo "alpine"
	else
		echo "unknown"
	fi
}

install_packages() {
	local distro="$1"
	shift
	local packages=("$@")
	log_info "Installing packages: ${packages[*]}"
	case "$distro" in
	debian | ubuntu)
		sudo apt-get update -qq
		sudo apt-get install -y -qq "${packages[@]}"
		;;
	fedora | rhel | centos | rocky)
		if command -v dnf &>/dev/null; then
			sudo dnf install -y "${packages[@]}"
		else
			sudo yum install -y "${packages[@]}"
		fi
		;;
	opensuse* | sles)
		sudo zypper install -y "${packages[@]}"
		;;
	arch | manjaro)
		sudo pacman -Syu --noconfirm "${packages[@]}"
		;;
	alpine)
		sudo apk add "${packages[@]}"
		;;
	*)
		log_error "Unknown distribution. Please install: ${packages[*]}"
		exit 1
		;;
	esac
}

ensure_compiler() {
	if command -v gcc &>/dev/null; then
		log_info "GCC installed: $(gcc --version | head -1)"
		return 0
	fi
	log_warning "GCC not found, installing..."
	local distro
	distro=$(detect_distro)
	case "$distro" in
	debian | ubuntu) install_packages "$distro" gcc ;;
	fedora | rhel | centos | rocky) install_packages "$distro" gcc ;;
	arch | manjaro) install_packages "$distro" gcc ;;
	opensuse* | sles) install_packages "$distro" gcc ;;
	*)
		log_error "Install GCC manually."
		exit 1
		;;
	esac
	if ! command -v gcc &>/dev/null; then
		log_error "GCC installation failed"
		exit 1
	fi
	log_success "GCC installed"
}

IN_DOCKER=false
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
	IN_DOCKER=true
fi

if [ "$IN_DOCKER" = true ]; then
	LFS=${LFS:-/output/image}
else
	LFS=${LFS:-/mnt/lfs}
fi

if [ -z "$LFS" ]; then
	log_error "LFS not set"
	exit 1
fi

LFS_TGT=${LFS_TGT:-$(uname -m)-lfs-linux-gnu}
NUM_JOBS=${NUM_JOBS:-$(nproc 2>/dev/null || echo 4)}
PATH="$LFS/tools/bin:/usr/bin:/bin"
export LFS LFS_TGT LC_ALL=POSIX PATH

log_info "LFS=$LFS, TARGET=$LFS_TGT, JOBS=$NUM_JOBS"

mkdir -pv "$LFS"/tools "$LFS"/sources

# Ensure lfs user exists
if ! id -u lfs &>/dev/null; then
	groupadd lfs
	useradd -s /bin/bash -g lfs -m -k /dev/null lfs
fi

# Set up environment for lfs user
LFS_HOME="/home/lfs"
mkdir -p "$LFS_HOME"
{
	echo "set +h"
	echo "umask 022"
	printf 'LFS=%q\n' "$LFS"
	echo "LC_ALL=POSIX"
	# shellcheck disable=SC2016
	echo 'LFS_TGT=$(uname -m)-lfs-linux-gnu'
	# shellcheck disable=SC2016
	echo 'PATH=$LFS/tools/bin:/usr/bin:/bin'
	echo "export LFS LC_ALL LFS_TGT PATH"
} >"$LFS_HOME/.bashrc"
cat >"$LFS_HOME/.bash_profile" <<'EOF'
if [ -f ~/.bashrc ]; then . ~/.bashrc; fi
EOF
chown -R lfs:lfs "$LFS_HOME"

chown -v lfs:lfs "$LFS"/tools "$LFS"/sources

check_toolchain() {
	if [ -x "$LFS/tools/bin/$LFS_TGT-gcc" ] &&
		[ -x "$LFS/tools/bin/$LFS_TGT-ld" ] &&
		[ -x "$LFS/tools/bin/$LFS_TGT-as" ]; then
		if echo 'int main(){}' | "$LFS/tools/bin/$LFS_TGT-gcc" -x c - -o /dev/null 2>/dev/null; then
			return 0
		fi
	fi
	return 1
}

if check_toolchain; then
	log_success "Toolchain already exists and works. Skipping build."
	exit 0
fi

# -------------------------------------------------------------------
# Build logic (to be run as lfs)
# -------------------------------------------------------------------
build_toolchain() {
	cd "$LFS/sources" || {
		log_error "Sources directory missing"
		exit 1
	}

	for pkg in binutils gcc linux glibc; do
		if ! find . -maxdepth 1 -name "${pkg}-*.tar.*" -print -quit | grep -q .; then
			log_error "Source for $pkg not found"
			exit 1
		fi
	done

	log_info "Building binutils (pass 1)"
	BINUTILS_TAR=$(find . -maxdepth 1 -name "binutils-*.tar.xz" -print -quit)
	tar -xf "$BINUTILS_TAR"
	BINUTILS_DIR=$(find . -maxdepth 1 -type d -name "binutils-*" -print -quit | sed 's|^\./||')
	cd "$BINUTILS_DIR"
	mkdir -v build
	cd build
	../configure --prefix="$LFS/tools" \
		--with-sysroot="$LFS" \
		--target="$LFS_TGT" \
		--disable-nls \
		--enable-gprofng=no \
		--disable-werror
	make -j"$NUM_JOBS"
	make install
	cd "$LFS/sources"
	rm -rf "$BINUTILS_DIR"
	log_success "binutils (pass 1) done"

	log_info "Building GCC (pass 1)"
	GCC_TAR=$(find . -maxdepth 1 -name "gcc-*.tar.xz" -print -quit)
	tar -xf "$GCC_TAR"
	GCC_DIR=$(find . -maxdepth 1 -type d -name "gcc-*" -print -quit | sed 's|^\./||')
	# Embed GMP, MPFR, MPC into GCC source tree
	for lib in gmp mpfr mpc; do
		LIB_TAR=$(find . -maxdepth 1 -name "${lib}-*.tar.*" -print | head -1)
		if [ -n "$LIB_TAR" ]; then
			tar -xf "$LIB_TAR"
			LIB_DIR=$(tar -tf "$LIB_TAR" | head -1 | cut -d/ -f1)
			if [ -d "$LIB_DIR" ]; then
				mv -v "$LIB_DIR" "$GCC_DIR/$lib"
			else
				echo "ERROR: Could not find extracted directory for $lib"
				exit 1
			fi
		else
			echo "ERROR: Tarball for $lib not found"
			exit 1
		fi
	done
	cd "$GCC_DIR"
	mkdir -v build
	cd build
	../configure --target="$LFS_TGT" \
		--prefix="$LFS/tools" \
		--with-glibc-version=2.38 \
		--with-sysroot="$LFS" \
		--with-newlib \
		--without-headers \
		--enable-default-pie \
		--enable-default-ssp \
		--disable-nls \
		--disable-shared \
		--disable-multilib \
		--disable-threads \
		--disable-libatomic \
		--disable-libgomp \
		--disable-libquadmath \
		--disable-libssp \
		--disable-libvtv \
		--disable-libstdcxx \
		--enable-languages=c,c++
	make -j"$NUM_JOBS"
	make install
	if [ ! -f "$LFS/tools/bin/cc" ]; then
		ln -sfv "$LFS_TGT-gcc" "$LFS/tools/bin/cc"
	fi
	cd "$LFS/sources"
	rm -rf "$GCC_DIR"
	log_success "GCC (pass 1) done"

	log_info "Installing Linux API headers"
	LINUX_TAR=$(find . -maxdepth 1 -type f -printf '%f\n' | grep -E "^${KERNEL_TYPE}-[0-9].*\\.tar\\.xz$" | head -n1)
	if [ -z "$LINUX_TAR" ]; then
		log_error "No kernel source found for type '$KERNEL_TYPE'"
		exit 1
	fi
	tar -xf "$LINUX_TAR"
	LINUX_DIR=$(tar -tf "$LINUX_TAR" | head -1 | cut -d/ -f1)
	cd "$LINUX_DIR"
	make mrproper
	make headers
	find usr/include -name '.*' -delete
	rm -f usr/include/Makefile
	mkdir -p "$LFS/usr"
	cp -rv usr/include "$LFS/usr"
	cd "$LFS/sources"
	rm -rf "$LINUX_DIR"
	log_success "Linux headers installed"

	log_info "Building glibc"
	GLIBC_TAR=$(find . -maxdepth 1 -name "glibc-*.tar.xz" -print -quit)
	tar -xf "$GLIBC_TAR"
	GLIBC_DIR=$(find . -maxdepth 1 -type d -name "glibc-*" -print -quit | sed 's|^\./||')
	cd "$GLIBC_DIR"
	mkdir -v build
	cd build
	../configure --prefix=/usr \
		--host="$LFS_TGT" \
		--build="$(../scripts/config.guess)" \
		--enable-kernel=4.14 \
		--with-headers="$LFS/usr/include" \
		--disable-nscd \
		libc_cv_slibdir=/usr/lib \
		libc_cv_forced_unwind=yes
	make -j"$NUM_JOBS"
	make DESTDIR="$LFS" install
	sed '/RTLDLIST=/s@/usr@@g' -i "$LFS/usr/bin/ldd"
	cd "$LFS/sources"
	rm -rf "$GLIBC_DIR"
	log_success "glibc done"

	log_info "Building libstdc++"
	tar -xf "$GCC_TAR" # re-extract GCC

	GCC_DIR=$(find . -maxdepth 1 -type d -name "gcc-*" -print -quit | sed 's|^\./||')
	cd "$GCC_DIR"
	mkdir -v build-libstdc++
	cd build-libstdc++
	../libstdc++-v3/configure --host="$LFS_TGT" \
		--build="$(../config.guess)" \
		--prefix="$LFS/tools" \
		--disable-multilib \
		--disable-nls \
		--disable-libstdcxx-pch \
		--with-gxx-include-dir="$LFS/tools/$LFS_TGT/include/c++/$(cat ../gcc/BASE-VER)"
	make -j"$NUM_JOBS"
	make install
	cd "$LFS/sources"
	rm -rf "$GCC_DIR"
	log_success "libstdc++ done"

	# ----- Cross-compile configure cache -----
	# Pre-answers gnulib/autoconf runtime tests that cannot execute when
	# cross-compiling. Prevents "cannot run test program while cross compiling"
	# failures introduced by newer package versions (e.g. diffutils-3.12,
	# patch-2.8) that bundle updated gnulib with stricter runtime checks.
	# Each package gets its own copy of the cache to avoid cross-contamination.
	CROSS_CACHE_TMPL="$LFS/sources/.cross-compile-cache"
	cat >"$CROSS_CACHE_TMPL" <<'CROSS_CACHE_EOF'
# Autoconf/gnulib cache values for cross-compilation
# String functions
ac_cv_func_strcasecmp=yes
ac_cv_func_strncasecmp=yes
gl_cv_func_strcasecmp_works=yes
gl_cv_func_strncasecmp_works=yes
ac_cv_func_strnlen_works=yes
gl_cv_func_strnlen_works=yes
# Memory / file operations
gl_cv_func_mknod_works=yes
gl_cv_func_lstat_dereferences_slashed_symlink=yes
gl_cv_func_stat_dir_slash=yes
gl_cv_func_stat_file_slash=yes
# Time
gl_cv_func_working_mktime=yes
gl_cv_func_utimes_works=yes
# I/O
gl_cv_func_fflush_stdin=yes
gl_cv_func_printf_directive_n=yes
# Misc
gl_cv_func_getgroups_works=yes
gl_cv_func_memmem_works=yes
CROSS_CACHE_EOF

	# ----- Build essential host tools for the temporary system -----
	log_info "Building essential tools for /tools"
	for pkg in m4 xz coreutils bash make grep sed gawk findutils tar gzip bzip2 diffutils patch; do
		# Avoid picking up make-ca instead of make
		if [ "$pkg" = "make" ]; then
			archive=$(find . -maxdepth 1 -name "make-[0-9]*.tar.*" -print -quit)
		else
			archive=$(find . -maxdepth 1 -name "${pkg}-*.tar.*" -print -quit)
		fi
		if [ -z "$archive" ]; then
			log_warning "Source for $pkg not found, skipping"
			continue
		fi
		dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
		log_info "Building $dir"
		tar -xf "$archive"
		cd "$dir"

		# Correctif pour findutils : _POSIX_ARG_MAX manquant avec glibc récente
		# Use sed instead of a patch file to avoid brittle line-number/context matching
		if [ "$pkg" = "findutils" ]; then
			if grep -q "ctl->posix_arg_size_min = _POSIX_ARG_MAX;" lib/buildcmd.c 2>/dev/null &&
				! grep -q "#ifdef _POSIX_ARG_MAX" lib/buildcmd.c 2>/dev/null; then
				sed -i 's/  ctl->posix_arg_size_min = _POSIX_ARG_MAX;/#ifdef _POSIX_ARG_MAX\n  ctl->posix_arg_size_min = _POSIX_ARG_MAX;\n#else\n  ctl->posix_arg_size_min = 4096;\n#endif/' lib/buildcmd.c
			fi
		fi

		# Correctif pour m4 : PATH_MAX non déclaré dans stackvma.c avec glibc récente
		# Use sed instead of a patch file to avoid brittle line-number/context matching
		if [ "$pkg" = "m4" ]; then
			if grep -q "PATH_MAX" lib/stackvma.c 2>/dev/null &&
				! grep -q "#include <limits.h>" lib/stackvma.c 2>/dev/null; then
				sed -i '1s/^/#include <limits.h>\n/' lib/stackvma.c
			fi
		fi

		CFLAGS=""
		if [ "$pkg" = "coreutils" ]; then
			CFLAGS="-DMB_LEN_MAX=16 -D_GNU_SOURCE -DPATH_MAX=4096"
		elif [ "$pkg" = "grep" ] || [ "$pkg" = "sed" ] || [ "$pkg" = "findutils" ] || [ "$pkg" = "m4" ]; then
			CFLAGS="-D_GNU_SOURCE -DPATH_MAX=4096"
		fi

		# bzip2 has no autoconf configure script; build it directly with make
		if [ "$pkg" = "bzip2" ]; then
			make CC="$LFS_TGT-gcc" AR="$LFS_TGT-ar" RANLIB="$LFS_TGT-ranlib" \
				-j"$NUM_JOBS"
			make CC="$LFS_TGT-gcc" AR="$LFS_TGT-ar" RANLIB="$LFS_TGT-ranlib" \
				PREFIX="$LFS/tools" install
		else
			# Per-package configure cache (copy from template to prevent cross-contamination)
			PKG_CACHE="$LFS/sources/.cc-${pkg}.cache"
			cp "$CROSS_CACHE_TMPL" "$PKG_CACHE"

			# Configure with error checking; use the cross-compile cache so that
			# runtime tests which cannot execute when cross-compiling are pre-answered.
			if ! CC="$LFS_TGT-gcc" \
				CXX="$LFS_TGT-g++" \
				AR="$LFS_TGT-ar" \
				RANLIB="$LFS_TGT-ranlib" \
				CFLAGS="$CFLAGS" \
				./configure --prefix="$LFS/tools" --host="$LFS_TGT" \
				--build="$(uname -m)-linux-gnu" \
				--cache-file="$PKG_CACHE" \
				--disable-nls; then
				log_error "Configure failed for $pkg"
				exit 1
			fi
			rm -f "$PKG_CACHE"

			# Remove gnulib-tests from SUBDIRS to avoid PATH_MAX and related errors
			if [ "$pkg" = "coreutils" ] || [ "$pkg" = "grep" ] || [ "$pkg" = "sed" ] || [ "$pkg" = "findutils" ] || [ "$pkg" = "m4" ]; then
				sed -i '/^SUBDIRS =/ s/ gnulib-tests//' Makefile 2>/dev/null || true
			fi

			make -j"$NUM_JOBS"
			make install
		fi
		cd "$LFS/sources"
		rm -rf "$dir"
	done
	rm -f "$CROSS_CACHE_TMPL"

	mkdir -p "$LFS/var/log"
	touch "$LFS/var/log/toolchain-ready"
	log_success "Temporary toolchain built successfully."
}

# -------------------------------------------------------------------
# Main execution
# -------------------------------------------------------------------
main() {
	ensure_compiler

	# If we are not lfs, re‑execute as lfs using sudo
	if [ "$(whoami)" != "lfs" ]; then
		log_info "Re‑executing as lfs user"
		exec sudo -n -u lfs env LFS="$LFS" LFS_TGT="$LFS_TGT" KERNEL_TYPE="$KERNEL_TYPE" NUM_JOBS="$NUM_JOBS" bash "$0" --force
	fi

	# Now running as lfs
	build_toolchain

	# Verify
	if check_toolchain; then
		log_success "Toolchain verified after build."
	else
		log_error "Toolchain verification failed after build."
		exit 1
	fi
}

# Handle --force flag to skip user checks (used for re‑execution)
if [ "$1" = "--force" ]; then
	shift
	# We are already lfs; skip the re‑execution
	if [ "$(whoami)" != "lfs" ]; then
		log_error "Cannot use --force without sudo; not lfs user"
		exit 1
	fi
	build_toolchain
	if check_toolchain; then
		log_success "Toolchain verified after build."
	else
		log_error "Toolchain verification failed."
		exit 1
	fi
else
	main "$@"
fi
