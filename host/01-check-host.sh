#!/bin/bash
# 01-check-host.sh
# Check host system requirements - Compatible with Docker and native
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/utils.sh" 2>/dev/null || {
    # Fallback if utils.sh doesn't exist
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warning() { echo "[WARNING] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
}

# Helper functions for distribution detection and package management
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

install_packages() {
    local distro="$1"
    shift
    local packages=("$@")

    log_info "Installing missing packages: ${packages[*]}"

    case "$distro" in
        debian|ubuntu)
            sudo apt-get update -qq
            sudo apt-get install -y -qq "${packages[@]}"
            ;;
        fedora|rhel|centos|rocky)
            if command -v dnf &>/dev/null; then
                sudo dnf install -y "${packages[@]}"
            else
                sudo yum install -y "${packages[@]}"
            fi
            ;;
        opensuse*|sles)
            sudo zypper install -y "${packages[@]}"
            ;;
        arch|manjaro)
            sudo pacman -Syu --noconfirm "${packages[@]}"
            ;;
        alpine)
            sudo apk add "${packages[@]}"
            ;;
        gentoo)
            log_error "Gentoo detected. Please install the following packages manually using emerge: ${packages[*]}"
            exit 1
            ;;
        *)
            log_error "Unknown distribution. Please install the following packages manually: ${packages[*]}"
            exit 1
            ;;
    esac
}

# Detect if running in Docker
IN_DOCKER=false
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || [ -f /var/run/docker.sock ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
    IN_DOCKER=true
    log_info "Running in Docker container - skipping root/sudo checks"
fi

# Detect if running in Lima VM
IN_LIMA=false
if [ -f /etc/lima-version ]; then
    IN_LIMA=true
    log_info "Running in Lima VM"
fi

# Check if running as root (skip for Docker and Lima)
if [ "$EUID" -ne 0 ] && [ "$IN_DOCKER" = false ] && [ "$IN_LIMA" = false ]; then
    # Check if user has sudo access
    if sudo -n true 2>/dev/null; then
        log_warning "Not running as root, but sudo is available"
        log_info "Will use sudo for privileged operations"
        USE_SUDO=true
    else
        log_error "Please run as root or with sudo"
        exit 1
    fi
else
    USE_SUDO=false
fi

# Distribution detection
DISTRO=$(detect_distro)
log_info "Distribution: $DISTRO"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    log_info "Version: $VERSION"
fi

# Check architecture
ARCH=$(uname -m)
log_info "Architecture: $ARCH"
if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
    log_warning "Architecture is $ARCH, LFS typically requires x86_64 or ARM64"
fi

# In Docker, we can skip some checks since the container should have everything
if [ "$IN_DOCKER" = true ]; then
    log_info "Docker container detected - checking only essential tools"

    # Minimal required commands for Docker
    required_commands=(
        "bash" "gcc" "make" "bison" "flex" "gawk" "m4"
        "wget" "python3" "git" "tar" "gzip"
    )

    missing_commands=()
    for cmd in "${required_commands[@]}"; do
        if ! command -v $cmd &> /dev/null; then
            missing_commands+=($cmd)
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then
        log_warning "Some commands missing in Docker: ${missing_commands[*]}"
        log_info "Attempting to install missing packages inside container"
        install_packages "$DISTRO" "${missing_commands[@]}"
    fi

    log_success "Docker environment check passed"
    exit 0
fi

# Check required commands (full check for native systems)
required_commands=(
    "bash" "gcc" "g++" "ld" "bison" "flex" "gawk" "m4"
    "make" "patch" "sed" "tar" "makeinfo" "xz" "grep" "awk"
    "wget" "python3" "git" "rsync" "parted" "xorriso"
)

missing_commands=()
for cmd in "${required_commands[@]}"; do
    if ! command -v $cmd &> /dev/null; then
        missing_commands+=($cmd)
    fi
done

if [ ${#missing_commands[@]} -ne 0 ]; then
    log_error "Missing required commands: ${missing_commands[*]}"
    log_info "Attempting automatic installation..."
    install_packages "$DISTRO" "${missing_commands[@]}"
    # Re-check after installation
    for cmd in "${missing_commands[@]}"; do
        if ! command -v $cmd &> /dev/null; then
            log_error "Command '$cmd' still missing after installation. Please install it manually."
            exit 1
        fi
    done
    log_success "All missing packages successfully installed."
fi

# Check library versions (unchanged)
check_version() {
    local cmd=$1
    local min_version=$2
    local version

    if ! command -v $cmd &> /dev/null; then
        return 0
    fi

    # Try different ways to get version
    version=$($cmd --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+\.?[0-9]*' | head -n1)
    if [ -z "$version" ]; then
        version=$($cmd -V 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+\.?[0-9]*' | head -n1)
    fi

    if [ -z "$version" ]; then
        log_warning "Could not determine version for $cmd"
        return 0
    fi

    # Simple version comparison
    if [ "$(printf '%s\n' "$version" "$min_version" | sort -V | head -n1)" != "$min_version" ]; then
        if [ "$version" != "$min_version" ]; then
            log_error "$cmd version $version is too old (need >= $min_version)"
            return 1
        fi
    fi

    log_info "$cmd version $version OK"
    return 0
}

# Check critical versions
critical_versions=(
    "gcc:12.0"
    "make:4.0"
    "bash:3.2"
    "bison:2.7"
)

for item in "${critical_versions[@]}"; do
    cmd="${item%:*}"
    min="${item#*:}"
    check_version "$cmd" "$min" || exit 1
done

# Check kernel version
kernel_version=$(uname -r)
kernel_major=$(echo $kernel_version | cut -d. -f1)
kernel_minor=$(echo $kernel_version | cut -d. -f2)

log_info "Kernel version: $kernel_version"
if [ "$kernel_major" -lt 5 ] || { [ "$kernel_major" -eq 5 ] && [ "$kernel_minor" -lt 10 ]; }; then
    log_warning "Kernel version $kernel_version is old (recommended: 5.10+)"
fi

# Check disk space
available_space=$(df -BG / 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//')
if [ -z "$available_space" ]; then
    available_space=0
fi

if [ "$available_space" -lt 50 ]; then
    log_warning "Low disk space: ${available_space}GB available (recommended: 50GB+)"
    log_info "You can use an external drive or increase disk space"
else
    log_info "Disk space: ${available_space}GB available"
fi

# Check memory
total_mem=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')
if [ -n "$total_mem" ]; then
    if [ "$total_mem" -lt 8 ]; then
        log_warning "Low memory: ${total_mem}GB (recommended: 8GB+)"
        if [ "$total_mem" -lt 4 ]; then
            log_warning "Very low memory: ${total_mem}GB - build may fail"
        fi
    else
        log_info "Memory: ${total_mem}GB"
    fi
fi

# Check CPU cores
cpu_cores=$(nproc 2>/dev/null || echo 1)
log_info "CPU cores: $cpu_cores"

# Check if we're in a VM or container
if [ -f /proc/1/environ ] && grep -q container /proc/1/environ 2>/dev/null; then
    log_info "Running in container environment"
fi

# Check for lima VM
if [ "$IN_LIMA" = true ]; then
    log_info "Lima VM detected - skipping some hardware checks"
    log_success "Host system check passed (Lima VM)"
    exit 0
fi

# Check if running on WSL
if grep -q Microsoft /proc/version 2>/dev/null; then
    log_info "Running on WSL (Windows Subsystem for Linux)"
    log_warning "WSL may have slower I/O performance"
fi

log_success "Host system check passed!"
log_info "System is ready for LFS build"

# Print summary
echo ""
echo "System Summary:"
echo "  OS: ${PRETTY_NAME:-$DISTRO}"
echo "  Architecture: $ARCH"
echo "  Kernel: $kernel_version"
echo "  CPU cores: $cpu_cores"
echo "  Memory: ${total_mem:-?}GB"
echo "  Disk space: ${available_space}GB available"
if [ "$IN_DOCKER" = true ]; then
    echo "  Environment: Docker"
elif [ "$IN_LIMA" = true ]; then
    echo "  Environment: Lima VM"
fi
echo ""

exit 0