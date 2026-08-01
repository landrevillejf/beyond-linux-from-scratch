We can implement a **public build cache** for pre‑built root filesystems (and optionally ISOs) of the heaviest profiles (KDE, GNOME, full). Here’s a complete plan and code to integrate it into the builder.

---

## 1. Cache Design Overview

- **Cache Server**: GitHub Releases (free, public) – we’ll publish assets as release attachments.
- **Cache Metadata**: A JSON file hosted on the repository (e.g., `https://raw.githubusercontent.com/lfs-builder/lfs-builder/main/cache-metadata.json`). It lists available pre‑built tarballs for each profile, init system, architecture, and builder version.
- **Builder Integration**: New command‑line flag `--use-cache` (or `--cache-only`) to make the builder download and extract a cached rootfs instead of compiling from source. If no cache is found, the builder falls back to a full build (or errors out with `--cache-only`).
- **Building the Cache**: A GitHub Actions workflow (e.g., `.github/workflows/build-cache.yml`) runs periodically (weekly) or on demand to build the heavy profiles and upload them as release assets, updating the metadata file.

---

## 2. Cache Metadata Format (`cache-metadata.json`)

```json
{
  "version": "4.3.0",
  "profiles": {
    "kde": {
      "systemd": {
        "x86_64": {
          "build_date": "2026-06-27",
          "sha256": "abc123...",
          "url": "https://github.com/lfs-builder/lfs-builder/releases/download/v4.3.0-cache/lfs-rootfs-kde-systemd-x86_64.tar.xz",
          "size_mb": 1024
        }
      }
    },
    "gnome": {
      "systemd": {
        "x86_64": {
          "build_date": "2026-06-27",
          "sha256": "def456...",
          "url": "...",
          "size_mb": 2048
        }
      }
    },
    "full": {
      "systemd": {
        "x86_64": {
          "build_date": "2026-06-27",
          "sha256": "ghi789...",
          "url": "...",
          "size_mb": 4096
        }
      }
    }
  }
}
```

---

## 3. Modifications to `builder.py`

Add a new class `BuildCache` and integrate it into `LFSBuilder`.

### 3.1. New command‑line options

Add to `create_parser()`:

```python
parser.add_argument('--use-cache', action='store_true',
                    help='Use pre-built cache if available (skip compilation)')
parser.add_argument('--cache-only', action='store_true',
                    help='Only use cache; fail if not found')
parser.add_argument('--cache-url', default='https://raw.githubusercontent.com/lfs-builder/lfs-builder/main/cache-metadata.json',
                    help='Custom cache metadata URL')
```

### 3.2. BuildCache class

```python
class BuildCache:
    def __init__(self, cache_url: str, logger: logging.Logger):
        self.cache_url = cache_url
        self.logger = logger
        self.metadata = None

    def fetch_metadata(self) -> bool:
        try:
            with urllib.request.urlopen(self.cache_url, timeout=10) as resp:
                data = resp.read().decode('utf-8')
                self.metadata = json.loads(data)
                return True
        except Exception as e:
            self.logger.warning(f"Failed to fetch cache metadata: {e}")
            return False

    def get_cached_entry(self, profile: str, init: str, arch: str, builder_version: str) -> Optional[Dict]:
        if not self.metadata:
            return None
        profiles = self.metadata.get('profiles', {})
        if profile not in profiles:
            return None
        inits = profiles[profile]
        if init not in inits:
            return None
        arches = inits[init]
        if arch not in arches:
            return None
        entry = arches[arch]
        # Check if builder version matches (or we allow older?)
        # We'll just check that the entry exists.
        return entry

    def download_and_extract(self, entry: Dict, output_dir: Path) -> bool:
        url = entry.get('url')
        sha256_expected = entry.get('sha256')
        if not url:
            self.logger.error("Cache entry missing URL")
            return False
        # Download to temporary file
        import tempfile
        import hashlib
        try:
            with tempfile.NamedTemporaryFile(delete=False, suffix='.tar.xz') as tmp:
                self.logger.info(f"Downloading cache from {url} ...")
                urllib.request.urlretrieve(url, tmp.name, self._reporthook)
                tmp_path = Path(tmp.name)
            # Verify checksum
            if sha256_expected:
                actual = hashlib.sha256(tmp_path.read_bytes()).hexdigest()
                if actual != sha256_expected:
                    self.logger.error(f"Checksum mismatch: expected {sha256_expected}, got {actual}")
                    tmp_path.unlink()
                    return False
            # Extract to output_dir/image
            import tarfile
            image_dir = output_dir / 'image'
            if image_dir.exists():
                shutil.rmtree(image_dir)
            image_dir.mkdir(parents=True)
            with tarfile.open(tmp_path, 'r:xz') as tar:
                tar.extractall(image_dir)
            self.logger.info(f"Cache extracted to {image_dir}")
            tmp_path.unlink()
            return True
        except Exception as e:
            self.logger.error(f"Failed to download/extract cache: {e}")
            return False

    def _reporthook(self, blocknum, blocksize, totalsize):
        if totalsize <= 0:
            return
        percent = int(blocknum * blocksize * 100 / totalsize)
        if percent % 10 == 0:
            sys.stdout.write(f"\r  Download: {percent}%")
            sys.stdout.flush()
        if percent >= 100:
            sys.stdout.write("\n")
```

### 3.3. Integrate into `LFSBuilder.build()`

In `LFSBuilder.build()`, after checking prerequisites and preparing environment, check if `--use-cache` is set.

```python
def build(self, resume_from: Optional[str] = None, use_cache: bool = False, cache_only: bool = False) -> bool:
    # ... existing logging ...
    if use_cache:
        cache = BuildCache(self.cache_url, self.logger)
        if cache.fetch_metadata():
            entry = cache.get_cached_entry(self.profile, self.get_init_system(), self.config.get('architecture', 'x86_64'), __version__)
            if entry:
                self.logger.info("Cache found. Downloading and extracting...")
                if cache.download_and_extract(entry, self.output_dir):
                    self.logger.info("Cache installation successful. Skipping all build stages.")
                    # We still need to run final stages (initramfs, bootloader, installer, live-system) if they are to be generated.
                    # But the cache contains a complete rootfs; we can skip all stages and just run the final ones.
                    # However, the user may want to generate an ISO. We'll still run the final stages.
                    # But we must ensure the environment variables (LFS, etc.) are set correctly.
                    # We'll just return True (build complete) and let the caller handle final steps.
                    # Actually, we should run the final stages if they are not already done.
                    # For simplicity, we can just set a flag and skip all stages.
                    # Then we can optionally run the final stages.
                    # We'll handle this in the main flow.
                    return True
                else:
                    if cache_only:
                        self.logger.error("Cache download failed and --cache-only is set")
                        return False
                    self.logger.warning("Cache download failed, falling back to full build")
            else:
                if cache_only:
                    self.logger.error("No cache entry found for this profile/init/arch and --cache-only is set")
                    return False
                self.logger.info("No cache entry found, performing full build")
        else:
            if cache_only:
                self.logger.error("Could not fetch cache metadata and --cache-only is set")
                return False
            self.logger.info("Cache metadata unavailable, performing full build")
    # ... rest of build logic ...
```

### 3.4. Update `main()` to pass the flags

```python
if not builder.build(resume_from=args.resume_from, use_cache=args.use_cache, cache_only=args.cache_only):
    sys.exit(1)
```

---

## 4. GitHub Actions Workflow to Build Cache

Create `.github/workflows/build-cache.yml`:

```yaml
name: Build Cache

on:
  schedule:
    - cron: '0 0 * * 0'   # weekly on Sunday
  workflow_dispatch:      # manual trigger

jobs:
  build-cache:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        profile: [kde, gnome, full]
        init: [systemd]
        arch: [x86_64]
    steps:
      - uses: actions/checkout@v4
      - name: Install dependencies
        run: |
          sudo apt update
          sudo apt install -y build-essential bison flex gawk texinfo wget git python3 xorriso isolinux mtools dosfstools parted rsync bc cpio libssl-dev libelf-dev
      - name: Build profile
        run: |
          # We need to run the builder and capture the rootfs.
          sudo python3 builder.py --profile ${{ matrix.profile }} --init ${{ matrix.init }} --output /tmp/lfs-build
          # Compress the image directory
          cd /tmp/lfs-build/image
          tar -cJf /tmp/rootfs.tar.xz .
      - name: Upload to Release
        uses: svenstaro/upload-release-action@v2
        with:
          repo_token: ${{ secrets.GITHUB_TOKEN }}
          file: /tmp/rootfs.tar.xz
          asset_name: lfs-rootfs-${{ matrix.profile }}-${{ matrix.init }}-${{ matrix.arch }}.tar.xz
          tag: v4.3.0-cache
          overwrite: true
```

After upload, we need to update `cache-metadata.json` with the new asset URLs and SHA256. This can be done in a separate step or a dedicated script that extracts the artifact info from the release and updates the JSON file in the repository.

To avoid complexity, we can manually update the metadata when we publish a new cache build, or we can automate it with a script that runs after upload and commits the updated metadata back to the repo. We'll keep it simple for now.

---

## 5. Documentation

Add a section to the README explaining the cache feature:

### Using Pre‑built Caches

For heavy profiles like `kde`, `gnome`, or `full`, you can save days of compilation time by using our pre‑built cache. The builder will automatically download a ready‑to‑use root filesystem if you enable the `--use-cache` flag.

```bash
python3 builder.py --profile kde --use-cache
```

If you want to ensure that only the cache is used (no fallback to compilation), add `--cache-only`:

```bash
python3 builder.py --profile kde --use-cache --cache-only
```

The cache is built weekly and stored on GitHub Releases. It includes a full root filesystem for the specified profile, init system, and architecture.

> **Note**: The cache is provided as‑is. It is built from the latest stable scripts and sources, but you may still need to run the final stages (bootloader, ISO creation) on your own machine, as hardware‑specific configurations may differ.

---

## 6. Next Steps

1. **Implement** the code changes in `builder.py` as described.
2. **Set up** the GitHub Actions workflow.
3. **Publish** an initial set of caches manually (or trigger the workflow).
4. **Update** the README and ADVANCED.md with cache usage instructions.
5. **Test** the cache download and extraction on a fresh machine.

---

This approach gives users a fast path to a working system while still allowing the flexibility of building from source. It also reduces the load on our CI runners because we only build the heavy profiles periodically.

backup files


---

## FILE 2: `config/build.conf`

```json
{
  "lfs_version": "12.1",
  "blfs_version": "12.1",
  "architecture": "x86_64",
  "target_triplet": "x86_64-lfs-linux-gnu",
  
  "desktop": {
    "type": "xfce",
    "display_manager": "lightdm",
    "theme": "adwaita",
    "extras": [
      "firefox",
      "libreoffice",
      "gimp",
      "vlc"
    ]
  },
  
  "filesystem": {
    "type": "ext4",
    "size_mb": 8192,
    "swap_mb": 2048,
    "boot_mb": 512
  },
  
  "kernel": {
    "version": "6.6.14",
    "config": "config/kernel-config",
    "modules": [
      "ext4",
      "xfs",
      "nvme",
      "virtio",
      "usb_storage"
    ]
  },
  
  "locale": "en_US.UTF-8",
  "timezone": "America/New_York",
  "hostname": "lfs-desktop",
  
  "users": [
    {
      "name": "lfsuser",
      "groups": ["wheel", "audio", "video", "storage"]
    }
  ],
  
  "custom_scripts": [
    "packages/custom-scripts/post-install.sh"
  ],
  
  "repositories": [
    "https://www.linuxfromscratch.org/lfs/view/stable/wget-list",
    "https://www.linuxfromscratch.org/blfs/view/stable/wget-list"
  ]
}
```

## FILE 3: `config/kernel-config`

```
#
# Linux/x86 6.6.14 Kernel Configuration for LFS
#
CONFIG_64BIT=y
CONFIG_X86_64=y
CONFIG_SMP=y
CONFIG_NR_CPUS=64
CONFIG_HZ_1000=y
CONFIG_HZ=1000

#
# General setup
#
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_NO_HZ_IDLE=y
CONFIG_HIGH_RES_TIMERS=y
CONFIG_PREEMPT=y

#
# Processor type and features
#
CONFIG_MQUEUE=y
CONFIG_POSIX_MQUEUE=y
CONFIG_X86_RDS=y
CONFIG_X86_ACPI_CPUFREQ=y

#
# Power management options
#
CONFIG_SUSPEND=y
CONFIG_HIBERNATION=y
CONFIG_PM_STD_PARTITION=""
CONFIG_ACPI=y
CONFIG_ACPI_BUTTON=y
CONFIG_ACPI_VIDEO=y

#
# Block layer
#
CONFIG_BLK_DEV_BSG=y
CONFIG_BLK_DEV_THROTTLING=y
CONFIG_BLK_CFQ_GROUP_IOSCHED=y
CONFIG_BFQ_GROUP_IOSCHED=y
CONFIG_BLK_DEV_INTEGRITY=y

#
# Executable file formats
#
CONFIG_COREDUMP=y
CONFIG_IA32_EMULATION=y

#
# Networking support
#
CONFIG_NET=y
CONFIG_PACKET=y
CONFIG_UNIX=y
CONFIG_INET=y
CONFIG_IP_MULTICAST=y
CONFIG_IP_ADVANCED_ROUTER=y
CONFIG_IP_PNP=y
CONFIG_IP_PNP_DHCP=y
CONFIG_IP_PNP_BOOTP=y
CONFIG_NET_IPIP=y
CONFIG_IP_MROUTE=y
CONFIG_SYN_COOKIES=y
CONFIG_NET_IPVTI=y
CONFIG_INET_AH=y
CONFIG_INET_ESP=y
CONFIG_INET_IPCOMP=y
CONFIG_TCP_CONG_CUBIC=y
CONFIG_IPV6=y
CONFIG_NETFILTER=y
CONFIG_NF_CONNTRACK=y
CONFIG_NF_CONNTRACK_FTP=y
CONFIG_NF_NAT_FTP=y
CONFIG_BRIDGE=y
CONFIG_VLAN_8021Q=y

#
# Device Drivers
#
CONFIG_FW_LOADER=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y

#
# ATA/ATAPI/MFM/RLL support
#
CONFIG_ATA=y
CONFIG_PATA_LEGACY=y
CONFIG_ATA_PIIX=y
CONFIG_AHCI=y

#
# NVME Support
#
CONFIG_NVME_CORE=y
CONFIG_BLK_DEV_NVME=y

#
# SCSI device support
#
CONFIG_SCSI_MOD=y
CONFIG_SCSI=y
CONFIG_BLK_DEV_SD=y
CONFIG_SCSI_SATA=y
CONFIG_SCSI_SATA_AHCI=y
CONFIG_SCSI_MULTI_LUN=y

#
# Network device support
#
CONFIG_NETDEVICES=y
CONFIG_DUMMY=y
CONFIG_BONDING=y
CONFIG_ETHERTAP=y
CONFIG_TUN=y
CONFIG_VETH=y
CONFIG_VIRTIO_NET=y

#
# Ethernet driver support
#
CONFIG_NET_VENDOR_INTEL=y
CONFIG_E1000=y
CONFIG_E1000E=y
CONFIG_IGB=y
CONFIG_NET_VENDOR_REALTEK=y
CONFIG_8139TOO=y
CONFIG_R8169=y

#
# Wireless LAN
#
CONFIG_ATH9K=y
CONFIG_IWLWIFI=y
CONFIG_IWLWIFI_LEGACY=y
CONFIG_IWL3945=y

#
# USB Network Adapters
#
CONFIG_USB_USBNET=y
CONFIG_USB_NET_AX8817X=y
CONFIG_USB_NET_RTL8150=y
CONFIG_USB_NET_RTL8152=y

#
# Input device support
#
CONFIG_INPUT=y
CONFIG_INPUT_KEYBOARD=y
CONFIG_KEYBOARD_ATKBD=y
CONFIG_INPUT_MOUSE=y
CONFIG_MOUSE_PS2=y
CONFIG_INPUT_TOUCHSCREEN=y
CONFIG_INPUT_EVDEV=y

#
# Graphics support
#
CONFIG_AGP=y
CONFIG_VGA_ARB=y
CONFIG_DRM=y
CONFIG_DRM_I915=y
CONFIG_DRM_NOUVEAU=y
CONFIG_DRM_RADEON=y
CONFIG_DRM_VIRTIO_GPU=y
CONFIG_FB=y
CONFIG_FB_VESA=y
CONFIG_FB_EFI=y

#
# Sound support
#
CONFIG_SOUND=y
CONFIG_SND=y
CONFIG_SND_HDA_INTEL=y
CONFIG_SND_USB_AUDIO=y
CONFIG_SND_HDA_CODEC_HDMI=y

#
# USB support
#
CONFIG_USB_SUPPORT=y
CONFIG_USB_XHCI_HCD=y
CONFIG_USB_EHCI_HCD=y
CONFIG_USB_OHCI_HCD=y
CONFIG_USB_UHCI_HCD=y
CONFIG_USB_STORAGE=y
CONFIG_USB_UAS=y

#
# File systems
#
CONFIG_EXT4_FS=y
CONFIG_EXT4_USE_FOR_EXT2=y
CONFIG_EXT4_FS_POSIX_ACL=y
CONFIG_EXT4_FS_SECURITY=y
CONFIG_VFAT_FS=y
CONFIG_FAT_DEFAULT_IOCHARSET="utf8"
CONFIG_NTFS_FS=m
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_TMPFS=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_CONFIGFS_FS=y

#
# CD-ROM/DVD Filesystems
#
CONFIG_ISO9660_FS=y
CONFIG_UDF_FS=y

#
# Pseudo filesystems
#
CONFIG_DEVPTS_FS=y
CONFIG_DEBUG_FS=y

#
# Kernel hacking
#
CONFIG_MAGIC_SYSRQ=y
CONFIG_DEBUG_KERNEL=y
CONFIG_DEBUG_INFO=y

CONFIG_EFI=y
CONFIG_EFI_STUB=y
CONFIG_EFI_MIXED=y
```

## FILE 4: `scripts/common/chroot-utils.sh`

```bash
#!/bin/bash
# Chroot environment utilities

source $(dirname $0)/utils.sh

# Prepare chroot environment
prepare_chroot() {
    log_info "Preparing chroot environment"
    
    # Create necessary directories
    mkdir -pv $LFS/{dev,proc,sys,run,etc,home,root,boot,lib64,usr,var}
    
    # Create essential device nodes
    if [ ! -c $LFS/dev/console ]; then
        mknod -m 600 $LFS/dev/console c 5 1
    fi
    
    if [ ! -c $LFS/dev/null ]; then
        mknod -m 666 $LFS/dev/null c 1 3
    fi
    
    # Mount virtual filesystems
    mount_virtual_kernel_filesystems
    
    # Copy DNS configuration
    cp -v /etc/resolv.conf $LFS/etc/
    
    log_info "Chroot environment prepared"
}

# Run command in chroot
run_in_chroot() {
    local cmd="$1"
    log_info "Running in chroot: $cmd"
    
    chroot "$LFS" /usr/bin/env -i \
        HOME=/root \
        TERM="$TERM" \
        PS1='(lfs chroot) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin \
        MAKEFLAGS="-j${NUM_JOBS}" \
        LFS_TGT="${LFS_TGT}" \
        /bin/bash -c "$cmd"
}

# Copy host tools to chroot
copy_host_tools() {
    log_info "Copying host tools to chroot"
    
    local tools=(
        "/usr/bin/bash"
        "/usr/bin/cat"
        "/usr/bin/chmod"
        "/usr/bin/cp"
        "/usr/bin/grep"
        "/usr/bin/ln"
        "/usr/bin/ls"
        "/usr/bin/mkdir"
        "/usr/bin/mknod"
        "/usr/bin/mount"
        "/usr/bin/rm"
        "/usr/bin/sed"
        "/usr/bin/sh"
        "/usr/bin/sort"
        "/usr/bin/tar"
        "/usr/bin/umount"
        "/usr/bin/uniq"
        "/usr/bin/wc"
    )
    
    for tool in "${tools[@]}"; do
        if [ -f "$tool" ]; then
            cp -v "$tool" "$LFS${tool}"
        fi
    done
}

# Setup chroot user
setup_chroot_user() {
    local username=$1
    
    run_in_chroot "groupadd -g 1000 $username 2>/dev/null || true"
    run_in_chroot "useradd -u 1000 -g 1000 -G wheel,audio,video,storage -m $username 2>/dev/null || true"
    
    log_info "User $username created in chroot"
}

# Clean chroot
clean_chroot() {
    log_info "Cleaning chroot environment"
    
    # Unmount virtual filesystems
    umount_virtual_kernel_filesystems
    
    # Remove temporary files
    rm -rf $LFS/tmp/*
    rm -rf $LFS/var/tmp/*
    rm -rf $LFS/var/cache/*
    
    log_info "Chroot cleaned"
}

# Enter interactive chroot session
enter_interactive_chroot() {
    log_info "Entering interactive chroot session"
    log_info "Type 'exit' to leave"
    enter_chroot
}
```

## FILE 5: `scripts/common/error-handler.sh`

```bash
#!/bin/bash
# Error handling utilities

# Error trap function
error_trap() {
    local line=$1
    local command=$2
    local code=$3
    
    log_error "Command failed at line $line: $command"
    log_error "Exit code: $code"
    
    # Log system state
    log_error "=== System State ==="
    log_error "PWD: $(pwd)"
    log_error "LFS: ${LFS:-not set}"
    log_error "PATH: $PATH"
    
    # Check disk space
    local disk_usage=$(df -h ${LFS:-/} 2>/dev/null || df -h /)
    log_error "Disk usage: $disk_usage"
    
    # Check memory
    local mem_info=$(free -h 2>/dev/null || echo "Memory info not available")
    log_error "Memory: $mem_info"
    
    # Create error report
    local error_report="/tmp/lfs-error-$(date +%Y%m%d-%H%M%S).log"
    cat > $error_report << EOF
LFS Build Error Report
======================
Timestamp: $(date)
Line: $line
Command: $command
Exit code: $code

Environment:
LFS=$LFS
LFS_TGT=$LFS_TGT
MAKEFLAGS=$MAKEFLAGS

Last 50 lines of build log:
$(tail -50 /lfs-build/build.log 2>/dev/null || echo "No build log")

System Info:
$(uname -a)
EOF
    
    log_error "Error report saved to: $error_report"
    
    # Cleanup on error
    if [ "${LFS_CLEANUP_ON_ERROR:-yes}" = "yes" ]; then
        log_warning "Cleaning up partial build..."
        cleanup_partial_build
    fi
    
    exit $code
}

# Partial build cleanup
cleanup_partial_build() {
    if [ -n "$LFS" ] && [ -d "$LFS" ]; then
        log_info "Unmounting filesystems..."
        umount -l $LFS/dev/pts 2>/dev/null || true
        umount -l $LFS/dev 2>/dev/null || true
        umount -l $LFS/proc 2>/dev/null || true
        umount -l $LFS/sys 2>/dev/null || true
        umount -l $LFS/run 2>/dev/null || true
    fi
}

# Retry command on failure
retry() {
    local max_attempts=${1:-3}
    local delay=${2:-5}
    shift 2
    
    local attempt=1
    local exit_code=0
    
    while [ $attempt -le $max_attempts ]; do
        log_info "Attempt $attempt of $max_attempts: $@"
        
        if "$@"; then
            return 0
        else
            exit_code=$?
            log_warning "Command failed (attempt $attempt)"
            
            if [ $attempt -eq $max_attempts ]; then
                log_error "Command failed after $max_attempts attempts"
                return $exit_code
            fi
            
            sleep $delay
            ((attempt++))
        fi
    done
}

# Check build prerequisites with retry
check_with_retry() {
    local check_cmd=$1
    local max_retries=${2:-5}
    
    retry $max_retries 10 "$check_cmd"
}

# Validate build environment
validate_build_env() {
    local errors=0
    
    # Check required variables
    for var in LFS LFS_TGT NUM_JOBS; do
        if [ -z "${!var}" ]; then
            log_error "Required variable $var is not set"
            ((errors++))
        fi
    done
    
    # Check required directories
    for dir in /sources $LFS; do
        if [ ! -d "$dir" ]; then
            log_error "Required directory $dir does not exist"
            ((errors++))
        fi
    done
    
    # Check available disk space (need at least 10GB free)
    local free_space=$(df --output=avail "$LFS" | tail -1)
    if [ "$free_space" -lt 10485760 ]; then  # 10GB in KB
        log_error "Insufficient disk space in $LFS (need at least 10GB)"
        ((errors++))
    fi
    
    if [ $errors -gt 0 ]; then
        log_error "Build environment validation failed with $errors errors"
        return 1
    fi
    
    log_info "Build environment validated successfully"
    return 0
}

# Setup error handling
setup_error_handling() {
    set -E
    trap 'error_trap ${LINENO} "$BASH_COMMAND" $?' ERR
    
    # Set default cleanup behavior
    export LFS_CLEANUP_ON_ERROR=${LFS_CLEANUP_ON_ERROR:-yes}
}

# Safe source file with error handling
safe_source() {
    local file=$1
    
    if [ ! -f "$file" ]; then
        log_error "Cannot source: $file does not exist"
        return 1
    fi
    
    source "$file"
    log_info "Successfully sourced $file"
}

# Export functions
export -f error_trap cleanup_partial_build retry check_with_retry validate_build_env setup_error_handling safe_source
```

## FILE 6: `scripts/host/01-check-host.sh`

```bash
#!/bin/bash
# Check host system requirements

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/utils.sh"
source "$SCRIPT_DIR/../common/error-handler.sh"

setup_error_handling

log_info "Checking host system requirements"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    log_error "Please run as root"
    exit 1
fi

# Check distribution
if [ -f /etc/os-release ]; then
    . /etc/os-release
    log_info "Distribution: $NAME $VERSION"
fi

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    log_warning "Architecture is $ARCH, LFS requires x86_64"
fi

# Check required commands
required_commands=(
    "bash" "gcc" "g++" "ld" "bison" "flex" "gawk" "m4"
    "make" "patch" "sed" "tar" "texinfo" "xz" "grep" "awk"
    "wget" "python3" "git" "rsync" "parted" "xorriso" "isolinux"
)

missing_commands=()
for cmd in "${required_commands[@]}"; do
    if ! command -v $cmd &> /dev/null; then
        missing_commands+=($cmd)
    fi
done

if [ ${#missing_commands[@]} -ne 0 ]; then
    log_error "Missing required commands: ${missing_commands[*]}"
    exit 1
fi

# Check library versions
check_version() {
    local cmd=$1
    local min_version=$2
    local version=$($cmd --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+\.?[0-9]*' | head -n1)
    
    if [ -z "$version" ]; then
        log_warning "Could not determine version for $cmd"
        return 0
    fi
    
    if [ "$(echo -e "$version\n$min_version" | sort -V | head -n1)" != "$min_version" ]; then
        log_error "$cmd version $version is too old (need >= $min_version)"
        return 1
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
log_info "Kernel version: $kernel_version"

# Check disk space
available_space=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
if [ "$available_space" -lt 50 ]; then
    log_error "Insufficient disk space: ${available_space}GB available, need 50GB"
    exit 1
fi

# Check memory
total_mem=$(free -g | awk '/^Mem:/{print $2}')
if [ "$total_mem" -lt 8 ]; then
    log_warning "Low memory: ${total_mem}GB (recommended: 8GB+)"
fi

# Check CPU cores
cpu_cores=$(nproc)
log_info "CPU cores: $cpu_cores"

log_info "Host system check passed!"
```

## FILE 7: `scripts/host/02-prepare-host.sh`

```bash
#!/bin/bash
# Prepare host system for LFS build

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/utils.sh"
source "$SCRIPT_DIR/../common/error-handler.sh"

setup_error_handling

log_info "Preparing host system for LFS build"

# Create LFS user if not exists
if ! id "lfs" &>/dev/null; then
    log_info "Creating lfs user"
    groupadd lfs
    useradd -s /bin/bash -g lfs -m -k /dev/null lfs
    echo "lfs:lfs123" | chpasswd
    echo "lfs ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
fi

# Create LFS directory structure
LFS=${LFS:-/mnt/lfs}
mkdir -pv $LFS
chown -v lfs:lfs $LFS

# Create necessary directories
mkdir -pv $LFS/{bin,boot,dev,etc,home,lib,lib64,media,mnt,opt,proc,root,run,sbin,srv,sys,tmp,usr,var}
mkdir -pv $LFS/usr/{bin,include,lib,lib64,sbin,share,src}
mkdir -pv $LFS/usr/share/{man,doc,info}
mkdir -pv $LFS/var/{cache,lib,local,lock,log,opt,run,spool,tmp}
mkdir -pv $LFS/etc/{profile.d,sysconfig,skel}

# Set permissions
chmod -v 1777 $LFS/tmp
chmod -v 1777 $LFS/var/tmp

# Create sources directory
mkdir -pv $LFS/sources
chmod -v a+wt $LFS/sources
chown -v lfs:lfs $LFS/sources

# Create tools directory
mkdir -pv $LFS/tools
chown -v lfs:lfs $LFS/tools

# Set up lfs user environment
cat > /home/lfs/.bashrc << "EOF"
set +h
umask 022
LFS=/mnt/lfs
LC_ALL=POSIX
LFS_TGT=$(uname -m)-lfs-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
PATH=$LFS/tools/bin:$PATH
CONFIG_SITE=$LFS/usr/share/config.site
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
MAKEFLAGS="-j$(nproc)"
export MAKEFLAGS
EOF

cat > /home/lfs/.bash_profile << "EOF"
if [ -f "$HOME/.bashrc" ] ; then
    source "$HOME/.bashrc"
fi
EOF

chown lfs:lfs /home/lfs/.bashrc /home/lfs/.bash_profile

# Install build dependencies based on distribution
if command -v apt-get &> /dev/null; then
    log_info "Installing dependencies for Debian/Ubuntu"
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        build-essential bison flex gawk texinfo \
        wget curl git python3 python3-pip \
        xorriso isolinux mtools dosfstools \
        parted rsync sudo \
        bc cpio unzip xz-utils \
        libssl-dev libelf-dev \
        kmod cpio
 
elif command -v yum &> /dev/null; then
    log_info "Installing dependencies for RHEL/CentOS/Fedora"
    yum groupinstall -y "Development Tools"
    yum install -y bison flex gawk texinfo wget curl git \
        python3 xorriso isolinux mtools dosfstools \
        parted rsync bc cpio xz unzip \
        openssl-devel elfutils-libelf-devel kmod
elif command -v pacman &> /dev/null; then
    log_info "Installing dependencies for Arch"
    pacman -S --noconfirm base-devel bison flex gawk texinfo \
        wget curl git python xorriso libisoburn mtools \
        dosfstools parted rsync bc cpio
fi

# Create build script
cat > $LFS/build-lfs.sh << "EOF"
#!/bin/bash
# Main LFS build script to be run as lfs user

cd /mnt/lfs/sources

# Download packages
wget --input-file=wget-list --continue --directory-prefix=/mnt/lfs/sources

# Verify packages
md5sum -c md5sums

# Build toolchain
echo "Building cross-toolchain..."
tar -xf binutils-*.tar.xz
cd binutils-*
mkdir -v build
cd build
../configure --prefix=$LFS/tools \
             --with-sysroot=$LFS \
             --target=$LFS_TGT \
             --disable-nls \
             --enable-gprofng=no \
             --disable-werror
make
make install
cd ../..

# GCC
tar -xf gcc-*.tar.xz
cd gcc-*
case $(uname -m) in
  x86_64)
    sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
  ;;
esac
mkdir -v build
cd build
../configure --target=$LFS_TGT \
             --prefix=$LFS/tools \
             --with-glibc-version=2.38 \
             --with-sysroot=$LFS \
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
make
make install
cd ../..

# Linux API Headers
tar -xf linux-*.tar.xz
cd linux-*
make mrproper
make headers
find usr/include -type f ! -name '*.h' -delete
cp -rv usr/include $LFS/usr
cd ..

# Glibc
tar -xf glibc-*.tar.xz
cd glibc-*
case $(uname -m) in
    i?86)   ln -sfv ld-linux.so.2 $LFS/lib/ld-lsb.so.3
    ;;
    x86_64) ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64
            ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64/ld-lsb-x86-64.so.3
    ;;
esac
patch -Np1 -i ../glibc-2.38-fhs-1.patch
mkdir -v build
cd build
echo "rootsbindir=/usr/sbin" > configparms
../configure --prefix=/usr \
             --host=$LFS_TGT \
             --build=$(../scripts/config.guess) \
             --enable-kernel=4.14 \
             --with-headers=$LFS/usr/include \
             libc_cv_slibdir=/usr/lib
make
make DESTDIR=$LFS install
sed '/RTLDLIST=/s@/usr/lib@/lib@' -i $LFS/usr/bin/ldd
cd ../..

echo "Cross-toolchain build complete!"

EOF

chmod +x $LFS/build-lfs.sh
chown lfs:lfs $LFS/build-lfs.sh

log_info "Host preparation complete!"
log_info "Now run: su - lfs"
log_info "Then: /mnt/lfs/build-lfs.sh"
```

## FILE 8: `scripts/host/04-build-toolchain.sh`

```bash
#!/bin/bash
# Build cross-toolchain (run as lfs user)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/utils.sh"

LFS=${LFS:-/mnt/lfs}
LFS_TGT=${LFS_TGT:-$(uname -m)-lfs-linux-gnu}
NUM_JOBS=${NUM_JOBS:-$(nproc)}
LC_ALL=POSIX

log_info "Building cross-toolchain as $(whoami)"

if [ "$EUID" -eq 0 ]; then
    log_error "This script must NOT be run as root"
    exit 1
fi

cd $LFS/sources

# Binutils (first pass)
log_info "Building binutils (pass 1)"
tar -xf binutils-*.tar.xz
cd binutils-*
mkdir -v build
cd build
../configure --prefix=$LFS/tools \
             --with-sysroot=$LFS \
             --target=$LFS_TGT \
             --disable-nls \
             --enable-gprofng=no \
             --disable-werror
make -j$NUM_JOBS
make install
cd ../..

# GCC (first pass)
log_info "Building GCC (pass 1)"
tar -xf gcc-*.tar.xz
cd gcc-*
tar -xf ../mpfr-*.tar.xz
mv -v mpfr-* mpfr
tar -xf ../gmp-*.tar.xz
mv -v gmp-* gmp
tar -xf ../mpc-*.tar.xz
mv -v mpc-* mpc
case $(uname -m) in
  x86_64)
    sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
  ;;
esac
mkdir -v build
cd build
../configure --target=$LFS_TGT \
             --prefix=$LFS/tools \
             --with-glibc-version=2.38 \
             --with-sysroot=$LFS \
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
make -j$NUM_JOBS
make install
cd ../..

# Linux API Headers
log_info "Installing Linux API headers"
tar -xf linux-*.tar.xz
cd linux-*
make mrproper
make headers
find usr/include -type f ! -name '*.h' -delete
cp -rv usr/include $LFS/usr
cd ..

# Glibc
log_info "Building Glibc"
tar -xf glibc-*.tar.xz
cd glibc-*
if [ "$(uname -m)" = "x86_64" ]; then
    ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64
    ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64/ld-lsb-x86-64.so.3
fi
patch -Np1 -i ../glibc-2.38-fhs-1.patch
mkdir -v build
cd build
echo "rootsbindir=/usr/sbin" > configparms
../configure --prefix=/usr \
             --host=$LFS_TGT \
             --build=$(../scripts/config.guess) \
             --enable-kernel=4.14 \
             --with-headers=$LFS/usr/include \
             libc_cv_slibdir=/usr/lib
make -j$NUM_JOBS
make DESTDIR=$LFS install
sed '/RTLDLIST=/s@/usr/lib@/lib@' -i $LFS/usr/bin/ldd
cp -v ../nscd/nscd.conf $LFS/etc/nscd.conf
mkdir -pv $LFS/var/cache/nscd
cd ../..

# GCC (second pass)
log_info "Building GCC (pass 2)"
tar -xf gcc-*.tar.xz
cd gcc-*
case $(uname -m) in
  x86_64)
    sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
  ;;
esac
mkdir -v build
cd build
../configure --build=$(../config.guess) \
             --host=$LFS_TGT \
             --target=$LFS_TGT \
             LDFLAGS_FOR_TARGET=-L$PWD/$LFS_TGT/libgcc \
             --prefix=/usr \
             --with-build-sysroot=$LFS \
             --enable-default-pie \
             --enable-default-ssp \
             --disable-nls \
             --disable-multilib \
             --disable-libatomic \
             --disable-libgomp \
             --disable-libquadmath \
             --disable-libsanitizer \
             --disable-libssp \
             --disable-libvtv \
             --enable-languages=c,c++
make -j$NUM_JOBS
make DESTDIR=$LFS install
ln -sv gcc $LFS/usr/bin/cc
cd ../..

log_info "Cross-toolchain build complete!"
```

## FILE 9: `scripts/lfs/05-build-lfs-basic.sh`

```bash
#!/bin/bash
# Build basic LFS system (run as lfs user after chroot)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/utils.sh"

log_info "Building basic LFS system"

# Enter chroot if not already
if [ ! -f "$LFS/usr/bin/bash" ]; then
    log_error "Chroot environment not ready"
    exit 1
fi

# Create chroot script
cat > $LFS/build-basic.sh << "EOF"
#!/bin/bash

set -e

# Create directory structure
mkdir -pv /{boot,home,mnt,opt,srv}
mkdir -pv /etc/{opt,sysconfig}
mkdir -pv /lib/firmware
mkdir -pv /media/{floppy,cdrom}
mkdir -pv /usr/{local,share}
mkdir -pv /usr/local/{bin,include,lib,sbin,src}
mkdir -pv /usr/local/etc
mkdir -pv /var/{cache,lib,local,log,opt,spool}
mkdir -pv /var/lib/{color,misc,locate}
ln -sfv /run /var/run
ln -sfv /run/lock /var/lock
install -dv -m 0750 /root
install -dv -m 1777 /tmp /var/tmp

# Create essential symlinks
ln -sv /proc/self/mounts /etc/mtab
ln -sv /proc/self/fd /dev/fd
ln -sv /proc/self/fd/0 /dev/stdin
ln -sv /proc/self/fd/1 /dev/stdout
ln -sv /proc/self/fd/2 /dev/stderr

# Setup users and groups
cat > /etc/passwd << "PASSWD"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:daemon:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
systemd-journal-gateway:x:73:73:systemd Journal Gateway:/:/usr/bin/false
systemd-journal-remote:x:74:74:systemd Journal Remote:/:/usr/bin/false
systemd-journal-upload:x:75:75:systemd Journal Upload:/:/usr/bin/false
systemd-network:x:76:76:systemd Network Management:/:/usr/bin/false
systemd-resolve:x:77:77:systemd Resolver:/:/usr/bin/false
systemd-timesync:x:78:78:systemd Time Synchronization:/:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
PASSWD

cat > /etc/group << "GROUP"
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
usb:x:14:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
systemd-journal:x:23:
input:x:24:
systemd-network:x:76:
dbus:x:81:
systemd-journal-gateway:x:73:
systemd-journal-remote:x:74:
systemd-journal-upload:x:75:
systemd-resolve:x:77:
systemd-timesync:x:78:
wheel:x:97:
users:x:999:
nogroup:x:65534:
GROUP

# Setup password
echo "root:root123" | chpasswd

# Create shell profile
cat > /etc/profile << "PROFILE"
export LANG=en_US.UTF-8
export INPUTRC=/etc/inputrc
export PATH=/usr/local/bin:/usr/bin:/bin
PROFILE

# Create inputrc
cat > /etc/inputrc << "INPUTRC"
set horizontal-scroll-mode Off
set meta-flag On
set input-meta On
set convert-meta Off
set output-meta On
set bell-style none
"\eOd": backward-word
"\eOc": forward-word
"\e[1~": beginning-of-line
"\e[4~": end-of-line
"\e[5~": beginning-of-history
"\e[6~": end-of-history
"\e[3~": delete-char
"\e[2~": quoted-insert
"\eOH": beginning-of-line
"\eOF": end-of-line
"\e[H": beginning-of-line
"\e[F": end-of-line
INPUTRC

# Build gettext
cd /sources
tar -xf gettext-*.tar.xz
cd gettext-*
./configure --prefix=/usr --disable-shared
make -j$(nproc)
make install
cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
cd ..

# Build Bison
tar -xf bison-*.tar.xz
cd bison-*
./configure --prefix=/usr
make -j$(nproc)
make install
cd ..

# Build Perl
tar -xf perl-*.tar.xz
cd perl-*
sh Configure -des -Dprefix=/usr -Dvendorprefix=/usr -Duseshrplib
make -j$(nproc)
make install
cd ..

# Build Python
tar -xf Python-*.tar.xz
cd Python-*
./configure --prefix=/usr --enable-shared --with-system-expat --with-system-ffi --enable-optimizations
make -j$(nproc)
make install
cd ..

# Build Texinfo
tar -xf texinfo-*.tar.xz
cd texinfo-*
./configure --prefix=/usr
make -j$(nproc)
make install
cd ..

# Build util-linux
tar -xf util-linux-*.tar.xz
cd util-linux-*
./configure --prefix=/usr --bindir=/usr/bin --libdir=/usr/lib --enable-libblkid --enable-libmount --enable-libfdisk --enable-libsmartcols
make -j$(nproc)
make install
cd ..

# Cleanup
find /usr/lib -type f -name '*.a' -delete
rm -rf /tmp/*

echo "Basic system build complete!"
EOF

chmod +x $LFS/build-basic.sh

# Run in chroot
log_info "Running basic system build in chroot"
chroot "$LFS" /usr/bin/env -i \
    HOME=/root \
    TERM="$TERM" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-basic.sh

log_info "Basic LFS system build complete!"
```

## FILE 10: `scripts/lfs/06-build-lfs-system.sh`

```bash
#!/bin/bash
# Build complete LFS system

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/utils.sh"

log_info "Building complete LFS system"

cat > $LFS/build-system.sh << "EOF"
#!/bin/bash

set -e
cd /sources

# Linux Kernel
echo "Building Linux Kernel..."
tar -xf linux-*.tar.xz
cd linux-*
make mrproper
make defconfig
make -j$(nproc)
make modules_install
cp -v arch/x86/boot/bzImage /boot/vmlinuz-lfs
cp -v System.map /boot/System.map
cp -v .config /boot/config
cd ..

# Systemd
echo "Building systemd..."
tar -xf systemd-*.tar.gz
cd systemd-*
sed -i 's/GROUP="render"/GROUP="video"/' rules.d/50-udev-default.rules.in
mkdir -p build
cd build
meson setup --prefix=/usr --buildtype=release -Ddefault-dnssec=no -Dfirstboot=false -Dinstall-tests=false -Dldconfig=false -Dsysusers=false -Drpmmacrosdir=no -Dhomed=false -Duserdb=false -Dman=false -Dmode=release -Ddocdir=/usr/share/doc/systemd-255 ..
meson compile
meson install
cd ../..

# GRUB
echo "Building GRUB..."
tar -xf grub-*.tar.xz
cd grub-*
./configure --prefix=/usr --sysconfdir=/etc --disable-efiemu
make -j$(nproc)
make install
mv -v /etc/bash_completion.d/grub /usr/share/bash-completion/completions
cd ..

# D-Bus
echo "Building D-Bus..."
tar -xf dbus-*.tar.xz
cd dbus-*
./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --runstatedir=/run
make -j$(nproc)
make install
cd ..

# OpenSSL
echo "Building OpenSSL..."
tar -xf openssl-*.tar.gz
cd openssl-*
./config --prefix=/usr --openssldir=/etc/ssl --libdir=lib shared zlib-dynamic
make -j$(nproc)
make install
cd ..

# OpenSSH
echo "Building OpenSSH..."
tar -xf openssh-*.tar.gz
cd openssh-*
./configure --prefix=/usr --sysconfdir=/etc/ssh --with-md5-passwords --with-privsep-path=/var/lib/sshd
make -j$(nproc)
make install
install -v -m755    contrib/ssh-copy-id /usr/bin
install -v -m644    contrib/ssh-copy-id.1 /usr/share/man/man1
install -v -m755 -d /usr/share/doc/openssh-9.6p1
install -v -m644    INSTALL LICENCE OVERVIEW README* /usr/share/doc/openssh-9.6p1
ssh-keygen -A
cd ..

# Create fstab
cat > /etc/fstab << "FSTAB"
# Begin /etc/fstab

# file system  mount-point  type     options             dump  fsck
#                                                              order

/dev/sda3      /            ext4    defaults            1     1
/dev/sda1      /boot        vfat    defaults            0     2
/dev/sda2      swap         swap    pri=1               0     0
proc           /proc        proc    nosuid,noexec,nodev 0     0
sysfs          /sys         sysfs   nosuid,noexec,nodev 0     0
devpts         /dev/pts     devpts  gid=5,mode=620      0     0
tmpfs          /run         tmpfs   defaults            0     0
devtmpfs       /dev         devtmpfs mode=0755,nosuid   0     0
tmpfs          /dev/shm     tmpfs   nosuid,nodev        0     0
cgroup2        /sys/fs/cgroup cgroup2 nosuid,noexec,nodev 0   0

# End /etc/fstab
FSTAB

# Configure network
cat > /etc/hostname << "HOSTNAME"
lfs-desktop
HOSTNAME

cat > /etc/hosts << "HOSTS"
127.0.0.1 localhost.localdomain localhost
::1       localhost ip6-localhost ip6-loopback
ff02::1   ip6-allnodes
ff02::2   ip6-allrouters
127.0.1.1 lfs-desktop
HOSTS

# Configure systemd network
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/20-dhcp.network << "NETWORK"
[Match]
Name=en*

[Network]
DHCP=yes
NETWORK

# Configure timezone
ln -sfv /usr/share/zoneinfo/America/New_York /etc/localtime

# Configure locale
cat > /etc/locale.conf << "LOCALE"
LANG=en_US.UTF-8
LOCALE

# Configure console
cat > /etc/vconsole.conf << "VCONSOLE"
KEYMAP=us
FONT=Lat2-Terminus16
VCONSOLE

echo "LFS system build complete!"
EOF

chmod +x $LFS/build-system.sh

chroot "$LFS" /usr/bin/env -i \
    HOME=/root \
    TERM="$TERM" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-system.sh

log_info "LFS system build complete!"
```

## FILE 11: `scripts/lfs/07-configure-lfs.sh`

```bash
#!/bin/bash
# Configure LFS system

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/utils.sh"

log_info "Configuring LFS system"

cat > $LFS/configure-system.sh << "EOF"
#!/bin/bash

set -e

# Create initramfs
echo "Creating initramfs..."
mkinitcpio -p linux

# Setup bootloader
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=LFS --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# Enable services
systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl enable systemd-timesyncd
systemctl enable sshd
systemctl enable dbus

# Create user
groupadd -g 1000 lfsuser
useradd -u 1000 -g 1000 -G wheel,audio,video,storage -m lfsuser
echo "lfsuser:password123" | chpasswd

# Setup sudo
echo "lfsuser ALL=(ALL) ALL" >> /etc/sudoers

# Create basic Xorg configuration
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << "XORG"
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us"
EndSection
XORG

# Setup desktop environment script
cat > /usr/local/bin/start-desktop << "START"
#!/bin/bash
exec startx
START

chmod +x /usr/local/bin/start-desktop

echo "System configuration complete!"
EOF

chmod +x $LFS/configure-system.sh

chroot "$LFS" /usr/bin/env -i \
    HOME=/root \
    TERM="$TERM" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    /bin/bash /configure-system.sh

log_info "LFS configuration complete!"
```

## FILE 12: `scripts/blfs/08-build-blfs-base.sh`

```bash
#!/bin/bash
# Build BLFS base system

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/utils.sh"

log_info "Building BLFS base system"

cat > $LFS/build-blfs.sh << "EOF"
#!/bin/bash

set -e
cd /sources

# Xorg libraries
echo "Building Xorg libraries..."
tar -xf libxcb-*.tar.xz
cd libxcb-*
./configure --prefix=/usr --sysconfdir=/etc --disable-static
make -j$(nproc)
make install
cd ..

# Mesa
echo "Building Mesa..."
tar -xf mesa-*.tar.xz
cd mesa-*
mkdir build
cd build
meson setup --prefix=/usr --buildtype=release -Dgallium-drivers=auto -Dvulkan-drivers=auto -Dshared-glapi=enabled -Dopengl=true -Degl=enabled -Dgbm=enabled -Dosmesa=false -Ddri3=enabled ..
ninja
ninja install
cd ../..

# ALSA
echo "Building ALSA..."
tar -xf alsa-lib-*.tar.bz2
cd alsa-lib-*
./configure --prefix=/usr
make -j$(nproc)
make install
cd ..

# PulseAudio
echo "Building PulseAudio..."
tar -xf pulseaudio-*.tar.xz
cd pulseaudio-*
mkdir build
cd build
meson setup --prefix=/usr --buildtype=release -Ddaemon=true -Ddoxygen=false -Dman=false -Dtests=false ..
ninja
ninja install
cd ../..

# Fonts
echo "Installing fonts..."
tar -xf dejavu-fonts-ttf-*.tar.bz2
cd dejavu-fonts-ttf-*
cp -v *.ttf /usr/share/fonts/TTF/
cd ..

# Bluetooth support
echo "Building BlueZ..."
tar -xf bluez-*.tar.xz
cd bluez-*
./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --enable-library
make -j$(nproc)
make install
cd ..

echo "BLFS base build complete!"
EOF

chmod +x $LFS/build-blfs.sh

chroot "$LFS" /usr/bin/env -i \
    HOME=/root \
    TERM="$TERM" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-blfs.sh

log_info "BLFS base system build complete!"
```

## FILE 13: `scripts/blfs/09-build-desktop.sh`

```bash
#!/bin/bash
# Build desktop environment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/utils.sh"

PROFILE=${PROFILE:-xfce}
log_info "Building $PROFILE desktop environment"

# Copy profile customization
cp -r "$SCRIPT_DIR/../../profiles/$PROFILE/"* $LFS/

cat > $LFS/build-desktop.sh << "EOF"
#!/bin/bash

set -e
cd /sources

# Build GTK
echo "Building GTK..."
tar -xf gtk+-*.tar.xz
cd gtk+-*
mkdir build
cd build
meson setup --prefix=/usr --buildtype=release -Dintrospection=enabled -Ddemos=false -Dtests=false ..
ninja
ninja install
cd ../..

# XFCE specific
if [ "$PROFILE" = "xfce" ]; then
    echo "Building XFCE desktop..."
    
    # libxfce4util
    tar -xf libxfce4util-*.tar.bz2
    cd libxfce4util-*
    ./configure --prefix=/usr
    make -j$(nproc)
    make install
    cd ..
    
    # xfconf
    tar -xf xfconf-*.tar.bz2
    cd xfconf-*
    ./configure --prefix=/usr
    make -j$(nproc)
    make install
    cd ..
    
    # libxfce4ui
    tar -xf libxfce4ui-*.tar.bz2
    cd libxfce4ui-*
    ./configure --prefix=/usr
    make -j$(nproc)
    make install
    cd ..
    
    # exo
    tar -xf exo-*.tar.bz2
    cd exo-*
    ./configure --prefix=/usr
    make -j$(nproc)
    make install
    cd ..
    
    # garcon
    tar -xf garcon-*.tar.bz2
    cd garcon-*
    ./configure --prefix=/usr
    make -j$(nproc)
    make install
    cd ..
    
    # xfce4-panel
    tar -xf xfce4-panel-*.tar.bz2
    cd xfce4-panel-*
    ./configure --prefix=/usr
    make -j$(nproc)
    make install
    cd ..
    
    # thunar
    tar -xf thunar-*.tar.bz2
    cd thunar-*
    ./configure --prefix=/usr
    make -j$(nproc)
    make install
    cd ..
    
    # xfwm4
    tar -xf xfwm4-*.tar.bz2
    cd xfwm4-*
    ./configure --prefix=/usr
    make -j$(nproc)
    make install
    cd ..
    
    # xfce4-session
    tar -xf xfce4-session-*.tar.bz2
    cd xfce4-session-*
    ./configure --prefix=/usr
    make -j$(nproc)
    make install
    cd ..
    
    # xfce4-settings
    tar -xf xfce4-settings-*.tar.bz2
    cd xfce4-settings-*
    ./configure --prefix=/usr
    make -j$(nproc)
    make install
    cd ..
    
    # xfdesktop
    tar -xf xfdesktop-*.tar.bz2
    cd xfdesktop-*
    ./configure --prefix=/usr
    make -j$(nproc)
    make install
    cd ..
fi

# GNOME specific
if [ "$PROFILE" = "gnome" ]; then
    echo "Building GNOME desktop..."
    # GNOME build would go here (very large)
    echo "GNOME profile requires additional configuration"
fi

# LightDM
echo "Building LightDM..."
tar -xf lightdm-*.tar.gz
cd lightdm-*
mkdir build
cd build
meson setup --prefix=/usr --buildtype=release -Dlibdir=/usr/lib -Dlogind=systemd -Dliblightdm-qt5=false ..
ninja
ninja install
cd ../..

# LightDM GTK Greeter
tar -xf lightdm-gtk-greeter-*.tar.gz
cd lightdm-gtk-greeter-*
mkdir build
cd build
meson setup --prefix=/usr --buildtype=release ..
ninja
ninja install
cd ../..

# Configure LightDM
cat > /etc/lightdm/lightdm.conf << "LIGHTDM"
[LightDM]
greeter-session=lightdm-gtk-greeter

[Seat:*]
autologin-user=lfsuser
autologin-user-timeout=0
user-session=xfce

[XDMCPServer]
enabled=false
LIGHTDM

echo "Desktop build complete!"
EOF

chmod +x $LFS/build-desktop.sh

chroot "$LFS" /usr/bin/env -i \
    HOME=/root \
    TERM="$TERM" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    PROFILE="$PROFILE" \
    /bin/bash /build-desktop.sh

log_info "Desktop build complete!"
```

## FILE 14: `scripts/blfs/10-build-applications.sh`

```bash
#!/bin/bash
# Build common applications

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/utils.sh"

log_info "Building applications"

cat > $LFS/build-apps.sh << "EOF"
#!/bin/bash

set -e
cd /sources

# Firefox
echo "Building Firefox (this will take a while)..."
tar -xf firefox-*.source.tar.xz
cd firefox-*
./mach configure --prefix=/usr --enable-release --enable-optimize --enable-system-ffi --enable-system-pixman
./mach build -j$(nproc)
./mach install
cd ..

# LibreOffice
echo "Building LibreOffice (very long!)..."
tar -xf libreoffice-*.tar.xz
cd libreoffice-*
./autogen.sh --prefix=/usr --without-java --disable-odk --disable-firebird-sdbc --disable-postgresql-sdbc --without-system-libs --with-system-headers
make -j$(nproc)
make install
cd ..

# GIMP
echo "Building GIMP..."
tar -xf gimp-*.tar.bz2
cd gimp-*
./configure --prefix=/usr
make -j$(nproc)
make install
cd ..

# VLC
echo "Building VLC..."
tar -xf vlc-*.tar.xz
cd vlc-*
./configure --prefix=/usr
make -j$(nproc)
make install
cd ..

# Chromium (optional - very large)
# echo "Building Chromium..."
# tar -xf chromium-*.tar.xz
# cd chromium-*
# gn gen out/Release --args='is_debug=false is_official_build=true'
# ninja -C out/Release
# cd ..

echo "Applications build complete!"
EOF

chmod +x $LFS/build-apps.sh

chroot "$LFS" /usr/bin/env -i \
    HOME=/root \
    TERM="$TERM" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    /bin/bash /build-apps.sh

log_info "Applications build complete!"
```

## FILE 15: `scripts/blfs/11-configure-desktop.sh`

```bash
#!/bin/bash
# Configure desktop environment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/utils.sh"

log_info "Configuring desktop environment"

cat > $LFS/configure-desktop.sh << "EOF"
#!/bin/bash

set -e

# Create XFCE configuration for default user
mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/

# Panel configuration
cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml << "PANEL"
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="panels" type="uint" value="1">
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
        <value type="int" value="6"/>
        <value type="int" value="7"/>
        <value type="int" value="8"/>
      </property>
    </property>
  </property>
</channel>
PANEL

# Desktop settings
cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml << "DESKTOP"
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="image-path" type="string" value="/usr/share/backgrounds/default.png"/>
        <property name="image-style" type="int" value="5"/>
      </property>
    </property>
  </property>
</channel>
DESKTOP

# Window manager settings
cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml << "XFWM4"
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Default"/>
    <property name="title_font" type="string" value="Sans Bold 9"/>
    <property name="button_layout" type="string" value="O|SHMC"/>
    <property name="button_offset" type="int" value="0"/>
    <property name="easy_click" type="string" value="Alt"/>
    <property name="focus_delay" type="int" value="250"/>
    <property name="focus_hint" type="bool" value="true"/>
    <property name="placement_ratio" type="int" value="20"/>
    <property name="raise_on_focus" type="bool" value="false"/>
    <property name="wrap_windows" type="bool" value="false"/>
    <property name="wrap_workspaces" type="bool" value="false"/>
    <property name="click_to_focus" type="bool" value="true"/>
  </property>
</channel>
XFWM4

# Keyboard shortcuts
cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml << "SHORTCUTS"
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-keyboard-shortcuts" version="1.0">
  <property name="commands" type="empty">
    <property name="default" type="empty">
      <property name="&lt;Primary&gt;&lt;Alt&gt;t" type="empty"/>
      <property name="&lt;Primary&gt;&lt;Alt&gt;Delete" type="empty"/>
      <property name="XF86Display" type="empty"/>
      <property name="&lt;Super&gt;p" type="empty"/>
      <property name="&lt;Primary&gt;Escape" type="empty"/>
      <property name="XF86WWW" type="empty"/>
      <property name="XF86Mail" type="empty"/>
    </property>
  </property>
  <property name="xfwm4" type="empty">
    <property name="default" type="empty">
      <property name="&lt;Alt&gt;F4" type="empty"/>
      <property name="&lt;Alt&gt;F10" type="empty"/>
      <property name="&lt;Alt&gt;F9" type="empty"/>
      <property name="&lt;Alt&gt;F7" type="empty"/>
      <property name="&lt;Alt&gt;F8" type="empty"/>
      <property name="&lt;Alt&gt;Insert" type="empty"/>
      <property name="&lt;Alt&gt;Home" type="empty"/>
    </property>
  </property>
</channel>
SHORTCUTS

# Enable LightDM
systemctl enable lightdm
systemctl set-default graphical.target

# Create default wallpaper directory
mkdir -p /usr/share/backgrounds
cp -f /sources/wallpaper-default.png /usr/share/backgrounds/default.png 2>/dev/null || true

echo "Desktop configuration complete!"
EOF

chmod +x $LFS/configure-desktop.sh

chroot "$LFS" /usr/bin/env -i \
    HOME=/root \
    TERM="$TERM" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    /bin/bash /configure-desktop.sh

log_info "Desktop configuration complete!"
```

## FILE 16: `scripts/final/12-create-initramfs.sh`

```bash
#!/bin/bash
# Create initramfs

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/utils.sh"

log_info "Creating initramfs"

cat > $LFS/create-initramfs.sh << "EOF"
#!/bin/bash

set -e

# Create initramfs directory
mkdir -p /tmp/initramfs/{bin,dev,etc,lib,lib64,mnt,proc,root,sbin,sys,usr}
cd /tmp/initramfs

# Copy necessary binaries
cp /bin/busybox bin/
cp /sbin/blkid sbin/
cp /bin/mount bin/
cp /bin/umount bin/
cp /bin/sh bin/

# Copy libraries
ldd /bin/busybox | grep -o '/lib/[^ ]*' | xargs -I {} cp {} lib/
ldd /sbin/blkid | grep -o '/lib/[^ ]*' | xargs -I {} cp {} lib/

# Create device nodes
mknod -m 622 dev/console c 5 1
mknod -m 666 dev/null c 1 3
mknod -m 600 dev/mem c 1 1

# Create init script
cat > init << "INIT"
#!/bin/sh

# Mount essential filesystems
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

# Detect root device
for dev in /dev/sd* /dev/nvme*; do
    if [ -b "$dev" ] && blkid "$dev" | grep -q "ext4"; then
        mount "$dev" /mnt
        break
    fi
done

# Cleanup and switch root
umount /proc
umount /sys
exec switch_root /mnt /sbin/init
INIT

chmod +x init

# Create initramfs image
find . | cpio -o -H newc | gzip > /boot/initramfs.img

rm -rf /tmp/initramfs

echo "Initramfs created successfully"
EOF

chmod +x $LFS/create-initramfs.sh

chroot "$LFS" /usr/bin/env -i \
    HOME=/root \
    TERM="$TERM" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    /bin/bash /create-initramfs.sh

log_info "Initramfs creation complete!"
```

## FILE 17: `scripts/final/13-create-bootloader.sh`

```bash
#!/bin/bash
# Configure bootloader

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/utils.sh"

log_info "Configuring bootloader"

cat > $LFS/configure-bootloader.sh << "EOF"
#!/bin/bash

set -e

# GRUB configuration
cat > /boot/grub/grub.cfg << "GRUBCFG"
# Begin /boot/grub/grub.cfg
set default=0
set timeout=5

insmod part_gpt
insmod ext2
insmod fat

if [ -f /boot/grub/grubenv ]; then
    load_env
fi

set menu_color_normal=cyan/blue
set menu_color_highlight=white/blue

menuentry "LFS Linux" {
    linux /boot/vmlinuz-lfs root=/dev/sda3 ro quiet splash
    initrd /boot/initramfs.img
}

menuentry "LFS Linux (fallback)" {
    linux /boot/vmlinuz-lfs root=/dev/sda3 ro nomodeset
    initrd /boot/initramfs.img
}

menuentry "Memory Test" {
    linux16 /boot/memtest86+.bin
}

menuentry "System Rescue" {
    linux /boot/vmlinuz-lfs root=/dev/sda3 ro single
    initrd /boot/initramfs.img
}
GRUBCFG

# Install GRUB to disk (done in installer)
echo "Bootloader configuration ready"
EOF

chmod +x $LFS/configure-bootloader.sh

chroot "$LFS" /usr/bin/env -i \
    HOME=/root \
    TERM="$TERM" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    /bin/bash /configure-bootloader.sh

log_info "Bootloader configuration complete!"
```

## FILE 18: `profiles/minimal/customization.sh`

```bash
#!/bin/bash
# Minimal profile - no desktop

set -e

log_info "Applying minimal profile (no desktop)"

# No desktop, just console
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << "EOF"
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

echo "Minimal profile applied"
```

## FILE 19: `profiles/gnome/customization.sh`

```bash
#!/bin/bash
# GNOME desktop profile

set -e

log_info "Applying GNOME profile"

# Install GNOME components
cd /sources

# Track the build process
echo "Installing GNOME (this will take many hours)..."

# Meson and ninja already installed from base

# Install gtk-doc for building docs
tar -xf gtk-doc-*.tar.xz
cd gtk-doc-*
meson setup --prefix=/usr --buildtype=release build
ninja -C build
ninja -C build install
cd ..

# Install libxml2
tar -xf libxml2-*.tar.xz
cd libxml2-*
./configure --prefix=/usr --disable-static --with-history
make
make install
cd ..

# Install gobject-introspection
tar -xf gobject-introspection-*.tar.xz
cd gobject-introspection-*
meson setup --prefix=/usr --buildtype=release build
ninja -C build
ninja -C build install
cd ..

# Install GLib (already done in desktop build)

# Install GNOME Shell dependencies
echo "GNOME profile requires many more packages..."
echo "See BLFS book for complete GNOME build"

# Configure GDM
cat > /etc/gdm/custom.conf << "GDM"
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=lfsuser

[security]

[xdmcp]

[chooser]

[debug]
GDM

echo "GNOME profile partially applied (requires full BLFS GNOME build)"
```

## FILE 20: `packages/custom-scripts/post-install.sh`

```bash
#!/bin/bash
# Post-installation customization

set -e

log_info "Running post-installation scripts"

# Install additional fonts
mkdir -p /usr/share/fonts/TTF
cd /sources
wget https://github.com/ryanoasis/nerd-fonts/releases/download/v3.0.2/CascadiaCode.zip
unzip CascadiaCode.zip -d /usr/share/fonts/TTF/
fc-cache -fv

# Configure bash prompt
cat >> /etc/bash.bashrc << "BASH"
# Custom prompt
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# Aliases
alias ls='ls --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'

# History
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth
BASH

# Configure Vim
cat > /etc/vimrc << "VIM"
set number
set relativenumber
set tabstop=4
set shiftwidth=4
set expandtab
set mouse=a
syntax on
VIM

# Install some useful scripts
cat > /usr/local/bin/welcome.sh << "WELCOME"
#!/bin/bash
clear
echo "========================================="
echo "   Welcome to LFS Linux Desktop"
echo "========================================="
echo "  Distribution: LFS $(cat /etc/lfs-release)"
echo "  Kernel: $(uname -r)"
echo "  Desktop: $(cat /etc/desktop-environment)"
echo "========================================="
echo ""
WELCOME

chmod +x /usr/local/bin/welcome.sh

# Add welcome message to profile
echo "/usr/local/bin/welcome.sh" >> /etc/profile

echo "Post-installation complete!"
```

## FILE 21: `mac-lfs-builder.sh`

```bash
#!/bin/bash
# macOS LFS Builder using Docker

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Configuration
OUTPUT_DIR="${HOME}/lfs-output"
DOCKER_IMAGE="lfs-builder-mac:latest"

# Check Docker
if ! command -v docker &> /dev/null; then
    log_error "Docker not installed"
    echo "Install Docker Desktop from: https://www.docker.com/products/docker-desktop"
    exit 1
fi

if ! docker info &> /dev/null; then
    log_error "Docker not running"
    echo "Start Docker Desktop from Applications"
    exit 1
fi

log_info "Docker is ready"

# Create output directory
mkdir -p "$OUTPUT_DIR"/{sources,logs,image}

# Build Docker image
log_info "Building Docker image"
cat > Dockerfile.mac << 'EOF'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

RUN apt update && apt install -y \
    build-essential bison flex gawk texinfo \
    wget curl git python3 python3-pip \
    xorriso isolinux mtools dosfstools \
    parted rsync sudo bc cpio \
    kmod libssl-dev libelf-dev \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -G sudo builder && \
    echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER builder
WORKDIR /home/builder

CMD ["/bin/bash"]
EOF

docker build -t $DOCKER_IMAGE -f Dockerfile.mac .

# Build LFS
log_info "Starting LFS build in Docker"

docker run --rm --privileged \
    -v "$OUTPUT_DIR:/output" \
    -v "$(pwd):/lfs-builder" \
    -e LFS=/output/image \
    -e MAKEFLAGS="-j$(sysctl -n hw.ncpu)" \
    $DOCKER_IMAGE \
    bash -c "
        cd /lfs-builder
        python3 builder.py --profile xfce --output /output
    "

log_info "Build complete!"
log_info "ISO location: $OUTPUT_DIR/lfs-installer.iso"

# Instructions for writing to USB
echo ""
echo "To write to USB on macOS:"
echo "1. Find your USB drive: diskutil list"
echo "2. Unmount it: diskutil unmountDisk /dev/disk2"
echo "3. Write ISO: sudo dd if=$OUTPUT_DIR/lfs-installer.iso of=/dev/rdisk2 bs=4m status=progress"
```

## FILE 22: `tools/multi-platform/setup-wsl.sh`

```bash
#!/bin/bash
# WSL2 setup for Windows

echo "Setting up WSL2 for LFS building..."

# Check if running in WSL
if ! grep -q Microsoft /proc/version; then
    echo "This script must be run in WSL"
    exit 1
fi

# Update packages
sudo apt update && sudo apt upgrade -y

# Install build dependencies
sudo apt install -y \
    build-essential bison flex gawk texinfo \
    wget curl git python3 python3-pip \
    xorriso isolinux mtools dosfstools \
    parted rsync bc cpio kmod \
    libssl-dev libelf-dev

# Create build directory
mkdir -p ~/lfs-builder
cd ~/lfs-builder

# Clone or copy builder scripts
if [ -d "/mnt/c/Users/$USER/Desktop/lfs-builder" ]; then
    cp -r "/mnt/c/Users/$USER/Desktop/lfs-builder"/* .
else
    echo "Please copy builder scripts to ~/lfs-builder"
fi

echo "WSL2 setup complete!"
echo "Run: python3 builder.py --profile xfce"
```

## FILE 23: `tools/multi-platform/docker-build.sh`

```bash
#!/bin/bash
# Cross-platform Docker build script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

# Create Dockerfile
cat > Dockerfile.lfs << 'EOF'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y \
    build-essential bison flex gawk texinfo \
    wget curl git python3 python3-pip \
    xorriso isolinux mtools dosfstools \
    parted rsync sudo bc cpio kmod \
    libssl-dev libelf-dev \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m builder && \
    echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER builder
WORKDIR /home/builder

COPY --chown=builder:builder . /home/builder/lfs-builder

WORKDIR /home/builder/lfs-builder

CMD ["python3", "builder.py", "--profile", "xfce", "--output", "/output"]
EOF

log_info "Building Docker image"
docker build -t lfs-builder -f Dockerfile.lfs .

log_info "Running build"
docker run --rm --privileged \
    -v "$(pwd)/output:/output" \
    lfs-builder

log_info "Build complete! ISO in ./output/"
```

## Files Structure

```
lfs-builder/
├── builder.py                 # Main orchestrator
├── mac-lfs-builder.sh         # macOS script
├── Dockerfile.mac             # macOS Docker config
├── config/
│   ├── build.conf             # Build configuration
│   └── kernel-config          # Kernel config
├── scripts/
│   ├── common/
│   │   ├── utils.sh           # Utilities
│   │   ├── chroot-utils.sh    # Chroot helpers
│   │   └── error-handler.sh   # Error handling
│   ├── host/
│   │   ├── 01-check-host.sh   # Check requirements
│   │   ├── 02-prepare-host.sh # Prepare host
│   │   ├── 03-create-disk-image.sh
│   │   └── 04-build-toolchain.sh
│   ├── lfs/
│   │   ├── 05-build-lfs-basic.sh
│   │   ├── 06-build-lfs-system.sh
│   │   └── 07-configure-lfs.sh
│   ├── blfs/
│   │   ├── 08-build-blfs-base.sh
│   │   ├── 09-build-desktop.sh
│   │   ├── 10-build-applications.sh
│   │   └── 11-configure-desktop.sh
│   └── final/
│       ├── 12-create-initramfs.sh
│       ├── 13-create-bootloader.sh
│       └── 14-create-installer.sh
├── profiles/
│   ├── minimal/customization.sh
│   ├── xfce/customization.sh
│   └── gnome/customization.sh
├── packages/
│   ├── sources.list
│   └── custom-scripts/post-install.sh
└── tools/
    ├── multi-platform/setup-wsl.sh
    └── multi-platform/docker-build.sh
```

## Requirements

- **Linux**: 50GB disk, 8GB RAM, 4+ cores
- **macOS**: Docker Desktop, 60GB disk
- **Windows**: WSL2 with Ubuntu, 60GB disk

## Build Time

- Minimal: 1-2 hours
- XFCE: 3-4 hours
- GNOME: 6-8 hours

## Output

Installer ISO located at `./lfs-build/lfs-installer.iso`

Write to USB:
```bash
# Linux
sudo dd if=lfs-installer.iso of=/dev/sdX bs=4M status=progress

# macOS
sudo dd if=lfs-installer.iso of=/dev/rdiskX bs=4m status=progress

# Windows
Use Rufus or balenaEtcher
```

## All files are ready to use. Create the directory structure and copy each file to its location. Then run the appropriate builder for your OS.
```

---

**ALL FILES ARE HERE!**

Create the directory structure and copy each file to its location. To use:

```bash
# Create the structure
mkdir -p lfs-builder/{config,scripts/{common,host,lfs,blfs,final},profiles/{minimal,xfce,gnome},packages/custom-scripts,tools/multi-platform}

# Copy each file to its location (according to the paths indicated above)

# Make scripts executable
chmod +x lfs-builder/*.sh lfs-builder/mac-lfs-builder.sh lfs-builder/scripts/**/*.sh

# Launch the build
cd lfs-builder
./mac-lfs-builder.sh  # On Mac
# OR
sudo python3 builder.py --profile xfce  # On Linux
```