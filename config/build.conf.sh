# ============================================================================
# LFS/BLFS MAIN BUILD CONFIGURATION
# ============================================================================

# ============================================================================
# BUILD ENVIRONMENT
# ============================================================================
# Number of parallel jobs for make (auto-detected if not set)
NUM_JOBS="${NUM_JOBS:-$(nproc)}"

# LFS mount point
LFS="/mnt/lfs"

# Target architecture
# Options: x86_64, i686, aarch64, armv7hl
ARCH="x86_64"

# Target triplet (auto-detected from ARCH)
case "$ARCH" in
    x86_64)   TARGET="x86_64-lfs-linux" ;;
    i686)     TARGET="i686-lfs-linux" ;;
    aarch64)  TARGET="aarch64-lfs-linux" ;;
    armv7hl)  TARGET="armv7hl-lfs-linux" ;;
esac

# ============================================================================
# BUILD TYPE
# ============================================================================
# Options: lfs-only, blfs-base, blfs-full, custom
BUILD_TYPE="blfs-full"

# Build stage (for partial builds)
# Options: all, toolchain, lfs, blfs, desktop, applications, audio, security
BUILD_STAGE="all"

# ============================================================================
# SOURCES & PACKAGES
# ============================================================================
# Sources directory (where packages/sources.list is located)
SOURCES_DIR="/sources"

# Packages database directory
LPM_DB="/var/lib/lpm/db.json"

# Repository configuration directory
LPM_REPOS="/etc/lpm/repos.d"

# Custom package list file (for BUILD_TYPE=custom)
CUSTOM_PACKAGE_LIST="profiles/minimal/packages.list"

# ============================================================================
# COMPILATION OPTIONS
# ============================================================================
# Compiler optimizations
# Options: -O2, -O3, -Os (size), -Ofast (fast but unsafe)
CFLAGS="-O2 -pipe"
CXXFLAGS="-O2 -pipe"

# Link time optimization (LTO)
# true/false - improves performance but increases build time
USE_LTO="false"

# Strip binaries (reduces size, recommended for production)
# true/false
STRIP_BINARIES="true"

# Keep build directories (for debugging)
# true/false
KEEP_BUILD_DIRS="false"

# ============================================================================
# INSTALLATION OPTIONS
# ============================================================================
# Installation prefix (usually /usr)
PREFIX="/usr"

# System configuration directory
SYSCONFDIR="/etc"

# Local state directory
LOCALSTATEDIR="/var"

# Run state directory
RUNDIR="/run"

# ============================================================================
# TEST SUITES
# ============================================================================
# Run package test suites (significantly increases build time)
# Options: none, basic, full
RUN_TESTS="basic"

# Stop build on test failure (for RUN_TESTS != none)
STOP_ON_TEST_FAILURE="false"

# ============================================================================
# DOCUMENTATION
# ============================================================================
# Install documentation
INSTALL_DOCS="true"

# Install man pages
INSTALL_MAN_PAGES="true"

# Install info pages
INSTALL_INFO_PAGES="true"

# ============================================================================
# LOGGING
# ============================================================================
# Build log directory
LOG_DIR="/var/log/lfs-build"

# Log level: DEBUG, INFO, WARNING, ERROR
LOG_LEVEL="INFO"

# Save all build output to logs
SAVE_BUILD_LOGS="true"

# ============================================================================
# NETWORK (for downloading sources)
# ============================================================================
# Number of retries for failed downloads
DOWNLOAD_RETRIES="3"

# Concurrent downloads
DOWNLOAD_PARALLEL="4"

# Use wget2 if available (faster)
USE_WGET2="true"

# ============================================================================
# CACHE
# ============================================================================
# Enable ccache (speeds up recompilation)
USE_CCACHE="false"
CCACHE_DIR="/var/cache/ccache"
CCACHE_SIZE="10G"

# Package source cache (avoid re-downloading)
SOURCE_CACHE_DIR="/var/cache/lfs-sources"
USE_SOURCE_CACHE="true"

# ============================================================================
# END OF CONFIGURATION
# ============================================================================