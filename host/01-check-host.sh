#!/bin/bash
# 01-check-host.sh
# Complete host system verification for LFS / BLFS
# Author : Jean-Francois Landreville
# Date   : 2026

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/utils.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warning() { echo "[WARNING] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
}

# ---------- Environment detection ----------
IN_DOCKER=false
[ -f /.dockerenv ] || [ -f /run/.containerenv ] || [ -f /var/run/docker.sock ] || grep -q docker /proc/1/cgroup 2>/dev/null && IN_DOCKER=true

IN_LIMA=false
[ -f /etc/lima-version ] && IN_LIMA=true

if [ "$IN_DOCKER" = true ]; then
    log_info "Running inside Docker container (some checks are relaxed)"
fi
if [ "$IN_LIMA" = true ]; then
    log_info "Running inside Lima VM"
fi

# ---------- Distribution detection ----------
detect_distro() {
    if [ -f /etc/os-release ]; then
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
DISTRO=$(detect_distro)
log_info "Detected distribution: $DISTRO"
[ -f /etc/os-release ] && . /etc/os-release && log_info "Version: $VERSION"

# ---------- Privilege handling ----------
USE_SUDO=false
if [ "$EUID" -ne 0 ] && [ "$IN_DOCKER" = false ] && [ "$IN_LIMA" = false ]; then
    if sudo -n true 2>/dev/null; then
        log_warning "Not running as root, but sudo is available."
        USE_SUDO=true
    else
        log_error "Please run as root or with sudo."
        exit 1
    fi
fi

# ---------- Architecture ----------
ARCH=$(uname -m)
log_info "Architecture: $ARCH"
if [[ ! "$ARCH" =~ ^(x86_64|aarch64|arm64)$ ]]; then
    log_warning "Architecture $ARCH – LFS recommends x86_64 or ARM64."
fi

# ---------- Package installation functions ----------
install_packages() {
    local distro="$1"
    shift
    local packages=("$@")
    [ ${#packages[@]} -eq 0 ] && return 0
    log_info "Installing missing packages: ${packages[*]}"
    case "$distro" in
        debian|ubuntu)
            $USE_SUDO apt-get update -qq
            $USE_SUDO apt-get install -y -qq "${packages[@]}"
            ;;
        fedora|rhel|centos|rocky|almalinux)
            if command -v dnf &>/dev/null; then
                $USE_SUDO dnf install -y "${packages[@]}"
            else
                $USE_SUDO yum install -y "${packages[@]}"
            fi
            ;;
        opensuse*|sles)
            $USE_SUDO zypper install -y "${packages[@]}"
            ;;
        arch|manjaro)
            $USE_SUDO pacman -Syu --noconfirm "${packages[@]}"
            ;;
        alpine)
            $USE_SUDO apk add "${packages[@]}"
            ;;
        gentoo)
            log_error "Gentoo detected – please install manually using emerge: ${packages[*]}"
            exit 1
            ;;
        *)
            log_error "Unknown distribution – please install manually: ${packages[*]}"
            exit 1
            ;;
    esac
}

# Mapping from command to package name (generic)
declare -A PKG_MAP
PKG_MAP["bash"]="bash"
PKG_MAP["binutils"]="binutils"
PKG_MAP["bison"]="bison"
PKG_MAP["coreutils"]="coreutils"
PKG_MAP["diffutils"]="diffutils"
PKG_MAP["findutils"]="findutils"
PKG_MAP["gawk"]="gawk"
PKG_MAP["gcc"]="gcc"
PKG_MAP["g++"]="g++"
PKG_MAP["glibc"]="glibc"
PKG_MAP["grep"]="grep"
PKG_MAP["gzip"]="gzip"
PKG_MAP["m4"]="m4"
PKG_MAP["make"]="make"
PKG_MAP["patch"]="patch"
PKG_MAP["perl"]="perl"
PKG_MAP["python3"]="python3"
PKG_MAP["sed"]="sed"
PKG_MAP["tar"]="tar"
PKG_MAP["texinfo"]="texinfo"
PKG_MAP["xz"]="xz-utils"

# ---------- Version and symlink checks ----------
check_cmd_version() {
    local cmd=$1
    local min_version=$2
    local version_opt=${3:---version}
    local version=""
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Command '$cmd' not found."
        return 1
    fi
    # Extract version
    version=$($cmd $version_opt 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+\.?[0-9]*' | head -n1)
    if [ -z "$version" ]; then
        version=$($cmd -V 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+\.?[0-9]*' | head -n1)
    fi
    if [ -z "$version" ]; then
        log_warning "Could not determine version for $cmd"
        return 0
    fi
    if [ "$(printf '%s\n' "$version" "$min_version" | sort -V | head -n1)" != "$min_version" ] && [ "$version" != "$min_version" ]; then
        log_error "$cmd version $version < $min_version (minimum required)"
        return 1
    fi
    log_info "$cmd version $version OK (>= $min_version)"
    return 0
}

check_glibc_version() {
    local min_version="2.5.1"
    local version=""
    if command -v getconf &>/dev/null; then
        version=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $NF}')
    fi
    if [ -z "$version" ] && [ -f /lib/libc.so.6 ]; then
        version=$(/lib/libc.so.6 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+\.?[0-9]*' | head -n1)
    fi
    if [ -z "$version" ] && command -v ldd &>/dev/null; then
        version=$(ldd --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+\.?[0-9]*' | head -n1)
    fi
    if [ -z "$version" ]; then
        log_warning "Could not determine glibc version"
        return 0
    fi
    if [ "$(printf '%s\n' "$version" "$min_version" | sort -V | head -n1)" != "$min_version" ] && [ "$version" != "$min_version" ]; then
        log_error "glibc version $version < $min_version"
        return 1
    fi
    log_info "glibc version $version OK (>= $min_version)"
    return 0
}

check_symlink() {
    local link=$1
    local expected_target=$2
    local target=""
    if [ -L "$link" ]; then
        target=$(readlink "$link")
        if [ "$target" = "$expected_target" ]; then
            log_info "Symbolic link $link -> $target OK"
        else
            log_warning "Symbolic link $link -> $target (expected: $expected_target)"
            return 1
        fi
    else
        log_warning "$link is not a symbolic link (expected $expected_target)"
        return 1
    fi
    return 0
}

# ---------- LFS required tools (command:minimum_version) ----------
declare -A REQUIRED_TOOLS=(
    ["bash"]="3.2"
    ["binutils"]="2.13.1"    # checked via 'ld'
    ["bison"]="2.7"
    ["coreutils"]="6.9"      # via 'ls'
    ["diffutils"]="2.8.1"    # via 'diff'
    ["findutils"]="4.2.31"   # via 'find'
    ["gawk"]="4.0.1"
    ["gcc"]="12.0"
    ["g++"]="12.0"           # C++ compiler
    ["grep"]="2.5.1a"
    ["gzip"]="1.3.12"
    ["m4"]="1.4.10"
    ["make"]="4.0"
    ["patch"]="2.5.4"
    ["perl"]="5.8.8"
    ["python3"]="3.4"
    ["sed"]="4.1.5"
    ["tar"]="1.22"
    ["texinfo"]="4.7"        # via makeinfo
    ["xz"]="5.0.0"           # via xz
)

# Additional required commands (no explicit version)
ADDITIONAL_COMMANDS=(
    "ld" "as" "awk" "sh" "install" "cp" "mv" "rm" "mkdir" "ln" "chmod" "chown"
)

# ---------- Verification (Docker gets a lighter check) ----------
if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – minimal verification"
    DOCKER_REQUIRED=("bash" "gcc" "make" "bison" "flex" "gawk" "m4" "wget" "python3" "git" "tar" "gzip")
    for cmd in "${DOCKER_REQUIRED[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_warning "$cmd missing in Docker, attempting to install..."
            install_packages "$DISTRO" "${PKG_MAP[$cmd]}"
        fi
    done
    log_success "Docker environment OK"
    exit 0
fi

# ----- Check tools with version requirements -----
missing_packages=()
for cmd in "${!REQUIRED_TOOLS[@]}"; do
    min_ver="${REQUIRED_TOOLS[$cmd]}"
    # Special cases: some tools use a different command name
    case $cmd in
        binutils)   cmd_to_check="ld" ;;
        coreutils)  cmd_to_check="ls" ;;
        diffutils)  cmd_to_check="diff" ;;
        findutils)  cmd_to_check="find" ;;
        texinfo)    cmd_to_check="makeinfo" ;;
        xz)         cmd_to_check="xz" ;;
        *)          cmd_to_check="$cmd" ;;
    esac
    if ! check_cmd_version "$cmd_to_check" "$min_ver"; then
        pkg="${PKG_MAP[$cmd]}"
        [ -n "$pkg" ] && missing_packages+=("$pkg")
    fi
done

# ----- Check glibc -----
if ! check_glibc_version; then
    missing_packages+=("glibc" "glibc-devel")
fi

# ----- Check critical symlinks (LFS recommendations) -----
check_symlink "/bin/sh" "bash" || log_warning "/bin/sh is not linked to bash (recommended)"
check_symlink "/usr/bin/awk" "gawk" || log_warning "/usr/bin/awk is not linked to gawk (recommended)"
check_symlink "/usr/bin/yacc" "bison" || log_warning "/usr/bin/yacc is not linked to bison (recommended)"

# ----- Check additional commands (existence) -----
for cmd in "${ADDITIONAL_COMMANDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        log_warning "Command $cmd not found (may be provided by coreutils or others)"
    fi
done

# ----- Kernel -----
kernel_version=$(uname -r)
kernel_major=$(echo "$kernel_version" | cut -d. -f1)
kernel_minor=$(echo "$kernel_version" | cut -d. -f2)
log_info "Kernel: $kernel_version"
if [ "$kernel_major" -lt 5 ] || { [ "$kernel_major" -eq 5 ] && [ "$kernel_minor" -lt 10 ]; }; then
    log_warning "Kernel $kernel_version (< 5.10) – LFS recommends 5.10+"
fi

# ----- Disk space -----
available_space=$(df -BG / 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//')
[ -z "$available_space" ] && available_space=0
if [ "$available_space" -lt 50 ]; then
    log_warning "Disk space: ${available_space}GB available (recommended 50GB+)"
else
    log_info "Disk space: ${available_space}GB available"
fi

# ----- Memory -----
total_mem=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')
if [ -n "$total_mem" ]; then
    if [ "$total_mem" -lt 8 ]; then
        log_warning "Memory: ${total_mem}GB (recommended 8GB+)"
        [ "$total_mem" -lt 4 ] && log_warning "Very low memory, build may fail"
    else
        log_info "Memory: ${total_mem}GB"
    fi
fi

# ----- CPU -----
cpu_cores=$(nproc 2>/dev/null || echo 1)
log_info "CPU cores: $cpu_cores"

# ----- Environment (WSL, VM) -----
if grep -q Microsoft /proc/version 2>/dev/null; then
    log_info "WSL detected – I/O performance may be reduced"
fi
if [ -f /proc/1/environ ] && grep -q container /proc/1/environ 2>/dev/null; then
    log_info "Containerized environment detected"
fi

# ----- Optional LFS variable check -----
if [ -n "$LFS" ]; then
    log_warning "LFS variable is set ($LFS) – this script checks the host, not the build."
fi

# ----- Automatic installation of missing packages -----
if [ ${#missing_packages[@]} -ne 0 ]; then
    # Remove duplicates
    IFS=" " read -r -a unique_pkgs <<< "$(printf '%s\n' "${missing_packages[@]}" | sort -u)"
    log_info "Packages to install: ${unique_pkgs[*]}"
    install_packages "$DISTRO" "${unique_pkgs[@]}"
    # Re-check after installation
    all_good=true
    for cmd in "${!REQUIRED_TOOLS[@]}"; do
        case $cmd in
            binutils)   cmd_to_check="ld" ;;
            coreutils)  cmd_to_check="ls" ;;
            diffutils)  cmd_to_check="diff" ;;
            findutils)  cmd_to_check="find" ;;
            texinfo)    cmd_to_check="makeinfo" ;;
            xz)         cmd_to_check="xz" ;;
            *)          cmd_to_check="$cmd" ;;
        esac
        if ! check_cmd_version "$cmd_to_check" "${REQUIRED_TOOLS[$cmd]}"; then
            log_error "Check failed for $cmd even after installation."
            all_good=false
        fi
    done
    if ! $all_good; then
        log_error "Please install missing packages manually and re-run the script."
        exit 1
    fi
    log_success "All packages are now up-to-date."
fi

# ----- Final summary -----
echo ""
echo "==================  SYSTEM SUMMARY  =================="
echo "  OS               : ${PRETTY_NAME:-$DISTRO}"
echo "  Architecture     : $ARCH"
echo "  Kernel           : $kernel_version"
echo "  CPU cores        : $cpu_cores"
echo "  Memory           : ${total_mem:-?} GB"
echo "  Disk space       : ${available_space:-?} GB available"
if [ "$IN_DOCKER" = true ]; then
    echo "  Environment      : Docker"
elif [ "$IN_LIMA" = true ]; then
    echo "  Environment      : Lima VM"
fi
echo "======================================================"
log_success "Host system verification completed successfully!"
echo "You may now proceed with the LFS build."
exit 0