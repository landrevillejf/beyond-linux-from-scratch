#!/usr/bin/env python3
"""
LFS/BLFS Builder - Main orchestrator
Works on Linux, macOS, and Windows (WSL2)
Author: Jean-Francois Landreville, landrevillejf@protonmail.com, 2026
"""

import os
import re
import sys
import json
import argparse
import subprocess
import platform
import shutil
import hashlib
import socket
from pathlib import Path
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple
import logging
import tarfile
import tempfile
import pwd
import urllib.request
import urllib.error
from urllib.parse import urlparse
from concurrent.futures import ThreadPoolExecutor, as_completed

# ============================================================================
# VERSION INFO
# ============================================================================
__version__ = "0.50.9"
__build_date__ = datetime.now().strftime("%Y-%m-%d")

# ============================================================================
# CONSTANTS
# ============================================================================

# Script directories (based on your actual structure)
SCRIPT_DIRS = {
    'host': 'host',
    'lfs': 'lfs',
    'blfs': 'blfs',
    'final': 'final',
    'common': 'common'
}

# Build stages with correct paths
BUILD_STAGES = [
    ('host-check', 'host/01-check-host.sh'),
    ('host-prepare', 'host/02-prepare-host.sh'),
    ('disk-image', 'host/03-create-disk-image.sh'),
    ('toolchain', 'host/04-build-toolchain.sh'),
    ('qemu-setup', 'host/00-setup-qemu.sh'),
    ('uboot', 'host/05-build-uboot.sh'),
    ('lfs-system', 'lfs/05-build-lfs-system.sh'),
    ('init-system', 'lfs/06a-init-system.sh'),
    ('service-mgmt', 'lfs/06b-service-management.sh'),
    ('configure-lfs', 'lfs/07-configure-lfs.sh'),
    ('blfs-base', 'lfs/08-build-blfs-base.sh'),
    ('desktop', 'blfs/09-build-desktop.sh'),
    ('applications', 'blfs/10-build-applications.sh'),
    ('configure-desktop', 'blfs/11-configure-desktop.sh'),
    ('java-dev', 'blfs/12-install-java-dev.sh'),
    ('package-manager', 'blfs/13-create-package-manager.sh'),
    ('base-packages', 'blfs/14-create-base-packages.sh'),
    ('security', 'blfs/15-security-hardening.sh'),
    ('privacy', 'blfs/16-privacy-tools.sh'),
    ('branding', 'blfs/21-branding.sh'),
    ('first-boot', 'blfs/17-first-boot-service.sh'),
    ('system-updater', 'blfs/18-system-updater.sh'),
    ('package-updater', 'blfs/19-package-updater.sh'),
    ('lpm-advanced', 'blfs/20-lpm-advanced.sh'),
    ('initramfs', 'final/12-create-initramfs.sh'),
    ('bootloader', 'final/13-create-bootloader.sh'),
    ('installer', 'final/14-create-installer.sh'),
    ('live-system', 'final/15-create-live-system.sh'),
]

# ============================================================================
# CONFIGURATION CLASSES
# ============================================================================

class LFSConfig:
    """LFS Builder Configuration Manager - Updated for LFS 13.0"""

    def __init__(self, config_file: Path):
        if isinstance(config_file, str):
            config_file = Path(config_file)
        self.config_file = config_file
        self.data = self.load()

    def load(self) -> Dict:
        """Load configuration from JSON file"""
        if not self.config_file.exists():
            self.data = self.get_default_config()
            self.save()
        else:
            with open(self.config_file, 'r') as f:
                self.data = json.load(f)
        return self.data

    def save(self):
        """Save configuration to JSON file"""
        with open(self.config_file, 'w') as f:
            json.dump(self.data, f, indent=2)

    def get_default_config(self) -> Dict:
        """Return default configuration for LFS 13.0"""
        return {
            "lfs_version": "13.0",
            "blfs_version": "13.0",
            "architecture": "x86_64",
            "target_triplet": "x86_64-lfs-linux-gnu",
            "build_threads": os.cpu_count(),
            "cross_compile": False,
            "cross_prefix": "",
            "sysroot": "",
            "qemu_user": "",

            "init_system": {
                "choice": "sysvinit",
                "service_style": "lfs-classic",
                "parallel_startup": False,
                "auto_restart": True,
                "default_runlevel": 3,
                "service_timeout": 5,
                "max_parallel": 1
            },

            "package_manager": {
                "enabled": True,
                "name": "lpm",
                "version": "1.0.0",
                "repositories": ["official", "community"],
                "auto_clean": True,
                "dependency_resolution": True,
                "upgrade_check_daily": True
            },

            "system_updater": {
                "enabled": True,
                "auto_check": True,
                "backup_before_upgrade": True,
                "keep_backups": 5,
                "rollback_support": True
            },

            "live_system": {
                "enabled": True,
                "squashfs_compression": "xz",
                "persistence_support": True,
                "default_boot": "live"
            },

            "java_dev": {
                "enabled": False,
                "version": "21.0.10",
                "distribution": "temurin",
                "tools": ["maven", "gradle", "tomcat", "jenkins", "docker", "kubectl"],
                "optimizations": True,
                "demo_projects": True
            },

            "desktop": {
                "type": "xfce",
                "display_manager": "lightdm",
                "theme": "adwaita",
                "icon_theme": "Papirus",
                "font": "Noto Sans 10",
                "wallpaper": "/usr/share/backgrounds/default.jpg",
                "extras": ["firefox", "libreoffice", "gimp", "vlc", "thunar", "xfce4-terminal"]
            },

            "branding": {
                "preset": "default",
                "dir": "",
                "theme_variant": "dark",
                "gtk_theme": "",
                "icon_theme": "",
                "wallpaper": "lfs-wallpaper.png",
                "apply_desktops": "auto",
                "strict": False
            },

            "security": {
                "kernel_hardening": True,
                "firewall": {"enabled": True, "backend": "nftables", "allow_ssh": True, "allow_http": False},
                "privacy": {"disable_telemetry": True, "clear_tmp_on_boot": True, "disable_core_dumps": True},
                "fail2ban": {"enabled": True, "ban_time": 3600, "max_retry": 5},
                "audit": {"enabled": True, "monitor_files": ["/etc/passwd", "/etc/shadow", "/etc/sudoers"]},
                "user_hardening": {"password_min_length": 12, "disable_root_login": True, "max_login_attempts": 5},
                "encryption": {"encrypted_swap": True, "swap_size_mb": 2048},
                "hids": {"enabled": True, "daily_check": True, "tool": "aide"},
                "daily_scans": {"enabled": True, "rootkit_check": True, "port_scan": True}
            },

            "bootloader": {
                "type": "grub",
                "config": "config/grub.cfg",
                "uboot_config": "config/u-boot.config",
                "uboot_board": "rpi_4"
            },

            "filesystem": {
                "type": "ext4",
                "size_mb": 10240,
                "swap_mb": 2048,
                "boot_mb": 512,
                "compress": False,
                "noatime": True
            },

            "kernel": {
                "version": "6.16.1",
                "type": "linux",
                "config": "config/kernel-config",
                "modules": ["ext4", "xfs", "nvme", "virtio", "usb_storage", "overlay", "vfat", "ntfs"],
                "custom_patches": []
            },

            "locale": "en_US.UTF-8",
            "timezone": "UTC",
            "hostname": "lfs-desktop",
            "keyboard_layout": "us",

            "users": [
                {"name": "lfsuser", "groups": ["wheel", "audio", "video", "storage", "docker"], "sudo": True, "autologin": True}
            ],

            "network": {
                "dhcp": True,
                "dns_servers": ["8.8.8.8", "8.8.4.4", "1.1.1.1"],
                "enable_ipv6": True,
                "wireless": True,
                "bluetooth": True
            },

            "custom_scripts": {
                "post_install": ["packages/custom-scripts/post-install.sh"],
                "theme_setup": "packages/custom-scripts/theme-setup.sh",
                "first_boot": "packages/custom-scripts/first-boot.sh"
            },

            "repositories": [
                "https://www.linuxfromscratch.org/lfs/view/stable/wget-list",
                "https://www.linuxfromscratch.org/blfs/view/stable/wget-list"
            ],

            "build_options": {
                "parallel_build": True,
                "keep_build_dirs": False,
                "strip_binaries": True,
                "checksum_verification": True,
                "verbose_logging": False,
                "download_timeout": 300,
                "retry_downloads": 3
            },

            "logging": {
                "level": "INFO",
                "max_size_mb": 100,
                "max_files": 10,
                "log_build_output": True
            }
        }

    def get(self, key: str, default=None):
        """Get configuration value by dot notation key"""
        keys = key.split('.')
        value = self.data
        for k in keys:
            if isinstance(value, dict):
                value = value.get(k, default)
            else:
                return default
        return value

    def set(self, key: str, value):
        """Set configuration value by dot notation key"""
        keys = key.split('.')
        target = self.data
        for k in keys[:-1]:
            if k not in target:
                target[k] = {}
            target = target[k]
        target[keys[-1]] = value
        self.save()


# ============================================================================
# PROFILE MANAGER - Updated with LFS 13.0 compatibility
# ============================================================================

class ProfileManager:
    """Manage build profiles with flexible desktop, init system, and audio options"""

    # Available choices for configuration
    AVAILABLE_DESKTOPS = ['none', 'xfce', 'gnome', 'kde', 'lxqt']
    AVAILABLE_INIT_SYSTEMS = ['sysvinit', 'systemd', 'openrc', 'runit', 's6']
    AVAILABLE_AUDIO = ['none', 'cli', 'studio']

    PROFILES = {
        'minimal': {
            'description': 'Minimal command-line only system',
            'size_gb': 1,
            'build_time_hours': 2,
            'packages': ['base', 'network', 'ssh'],
            'desktop': 'none',
            'init_system': 'sysvinit',
            'audio': 'none',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': False,
            'privacy_tools': False,
            'live_system': False,
            'system_updater': False,
            'desktop_options': ['none'],
            'init_options': ['sysvinit', 'systemd', 'openrc'],
            'audio_options': ['none']
        },
        'gnu-free': {
            'description': '100% Free Software System (FSF compliant)',
            'size_gb': 3,
            'build_time_hours': 4,
            'packages': ['gnu-core', 'gnu-network', 'gnu-dev', 'gnu-utils'],
            'desktop': None,
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': True,
            'live_system': False,
            'system_updater': True,
            'gnu_free': True,
            'kernel': 'linux-libre'
        },
        'gnu-free-full': {
            'description': 'Full GNU System with all GNU packages',
            'size_gb': 10,
            'build_time_hours': 8,
            'packages': ['gnu-all', 'gnu-emacs', 'gnu-octave', 'icecat'],
            'desktop': 'xfce',
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': True,
            'live_system': True,
            'system_updater': True,
            'gnu_free': True,
            'kernel': 'linux-libre'
        },
        'xfce': {
            'description': 'XFCE desktop environment',
            'size_gb': 4,
            'build_time_hours': 4,
            'packages': ['base', 'network', 'ssh', 'xorg', 'xfce', 'apps'],
            'desktop': 'xfce',
            'init_system': 'systemd',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': True,
            'system_updater': True
        },
        'gnome': {
            'description': 'GNOME desktop environment',
            'size_gb': 8,
            'build_time_hours': 8,
            'packages': ['base', 'network', 'ssh', 'xorg', 'gnome', 'apps'],
            'desktop': 'gnome',
            'init_system': 'systemd',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': True,
            'system_updater': True
        },
        'java-dev': {
            'description': 'Java development environment with XFCE',
            'size_gb': 10,
            'build_time_hours': 6,
            'packages': ['base', 'network', 'ssh', 'xorg', 'xfce', 'apps', 'java', 'maven', 'gradle', 'tomcat', 'jenkins', 'docker'],
            'desktop': 'xfce',
            'init_system': 'systemd',
            'java_dev': True,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': True,
            'system_updater': True
        },
        'secure': {
            'description': 'Security-hardened system with privacy tools',
            'size_gb': 6,
            'build_time_hours': 5,
            'packages': ['base', 'network', 'ssh', 'xorg', 'xfce', 'security', 'privacy'],
            'desktop': 'xfce',
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': True,
            'live_system': True,
            'system_updater': True
        },
        'full': {
            'description': 'Complete system with everything',
            'size_gb': 20,
            'build_time_hours': 12,
            'packages': ['all'],
            'desktop': 'gnome',
            'init_system': 'systemd',
            'java_dev': True,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': True,
            'live_system': True,
            'system_updater': True
        },
        'arm64': {
            'description': 'ARM64 server (Raspberry Pi, Orange Pi)',
            'size_gb': 2,
            'build_time_hours': 3,
            'packages': ['base', 'network', 'ssh'],
            'desktop': None,
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': False,
            'system_updater': True,
            'cross_compile': True,
            'architecture': 'aarch64',
            'bootloader': 'uboot'
        },
        'audio-cli': {
            'description': 'CLI-only audio production system',
            'size_gb': 2,
            'build_time_hours': 3,
            'packages': ['base', 'network', 'audio-core', 'audio-midi'],
            'desktop': None,
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': False,
            'system_updater': True
        },
        'pinebook': {
            'description': 'Pinebook / Pinebook Pro ARM64 laptop',
            'size_gb': 4,
            'build_time_hours': 4,
            'packages': ['base', 'network', 'xorg', 'xfce', 'pinebook'],
            'desktop': 'xfce',
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': False,
            'system_updater': True,
            'cross_compile': True,
            'architecture': 'aarch64',
            'bootloader': 'uboot'
        },
        'audio-studio': {
            'description': 'Full audio production studio with XFCE',
            'size_gb': 8,
            'build_time_hours': 6,
            'packages': ['base', 'network', 'xorg', 'xfce', 'audio-core', 'audio-daw', 'audio-plugins', 'audio-midi'],
            'desktop': 'xfce',
            'init_system': 'systemd',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': True,
            'system_updater': True
        },
        'kde': {
            'description': 'KDE Plasma full-featured desktop environment',
            'size_gb': 10,
            'build_time_hours': 12,
            'packages': ['base', 'network', 'ssh', 'xorg', 'kde', 'apps', 'multimedia'],
            'desktop': 'kde',
            'init_system': 'systemd',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': True,
            'system_updater': True
        },
        'lxqt': {
            'description': 'LXQt extremely lightweight Qt desktop environment',
            'size_gb': 2,
            'build_time_hours': 3,
            'packages': ['base', 'network', 'ssh', 'xorg', 'lxqt', 'apps'],
            'desktop': 'lxqt',
            'init_system': 'systemd',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': False,
            'privacy_tools': False,
            'live_system': True,
            'system_updater': True
        },
        'server': {
            'description': 'Production-optimized server configuration',
            'size_gb': 2,
            'build_time_hours': 3,
            'packages': ['base', 'network', 'ssh', 'server-tools'],
            'desktop': None,
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': False,
            'system_updater': True
        },
        'brax3': {
            'description': 'Brax3 Linux smartphone (Qualcomm Snapdragon)',
            'size_gb': 4,
            'build_time_hours': 5,
            'packages': ['base', 'network', 'xorg', 'phosh', 'brax3'],
            'desktop': 'phosh',
            'init_system': 'systemd',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': False,
            'system_updater': True,
            'cross_compile': True,
            'architecture': 'aarch64',
            'bootloader': 'aboot'
        },
        'custom': {
            'description': 'User-defined custom profile template',
            'size_gb': 5,
            'build_time_hours': 5,
            'packages': ['base', 'network', 'ssh'],
            'desktop': None,
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': False,
            'privacy_tools': False,
            'live_system': False,
            'system_updater': True
        }
    }

    @classmethod
    def get_profile(cls, name: str) -> Dict:
        """Get profile configuration"""
        if name not in cls.PROFILES:
            raise ValueError(f"Unknown profile: {name}. Available: {list(cls.PROFILES.keys())}")
        return cls.PROFILES[name]

    @classmethod
    def list_profiles(cls) -> List[str]:
        """List all available profiles"""
        return list(cls.PROFILES.keys())

    @classmethod
    def get_profile_info(cls, name: str,
                         init_system: Optional[str] = None,
                         desktop: Optional[str] = None,
                         live_system: Optional[bool] = None,
                         security_hardening: Optional[bool] = None,
                         privacy_tools: Optional[bool] = None) -> str:
        profile = cls.get_profile(name)
        effective_init = init_system if init_system is not None else profile.get('init_system', 'sysvinit')
        effective_desktop = desktop if desktop is not None else profile.get('desktop')
        effective_live = live_system if live_system is not None else profile.get('live_system', False)
        effective_security = security_hardening if security_hardening is not None else profile.get('security_hardening', False)
        effective_privacy = privacy_tools if privacy_tools is not None else profile.get('privacy_tools', False)

        return f"""
    ╔══════════════════════════════════════════════════════════════════╗
    ║ Profile: {name.upper()}
    ╠══════════════════════════════════════════════════════════════════╣
    ║ Description:   {profile['description']}
    ║ Size:          ~{profile['size_gb']} GB
    ║ Build time:    ~{profile['build_time_hours']} hours
    ║ Desktop:       {effective_desktop or 'None (CLI only)'}
    ║ Init System:   {effective_init}
    ║ Architecture:  {profile.get('architecture', 'x86_64')}
    ║ Bootloader:    {profile.get('bootloader', 'grub')}
    ║ Java Dev:      {'yes' if profile['java_dev'] else 'no'}
    ║ Package Mgr:   {'yes' if profile['package_manager'] else 'no'}
    ║ Security:      {'yes' if effective_security else 'no'}
    ║ Privacy:       {'yes' if effective_privacy else 'no'}
    ║ Live System:   {'yes' if effective_live else 'no'}
    ║ Auto Updates:  {'yes' if profile.get('system_updater', False) else 'no'}
    ╚══════════════════════════════════════════════════════════════════╝
    """


# ============================================================================
# SOURCE DOWNLOADER
# ============================================================================

class SourceDownloader:
    """Download and verify LFS/BLFS sources"""

    def __init__(self, sources_dir: Path, logger: logging.Logger, timeout: int = 30, retries: int = 2):
        self.sources_dir = sources_dir
        self.logger = logger
        self.timeout = max(1, int(timeout))
        self.retries = max(1, int(retries))
        self.session = self._create_session()

    def _create_session(self):
        """Create urllib session with retry logic and permissive SSL"""
        import ssl
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        
        opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))
        opener.addheaders = [('User-Agent', f'LFS-Builder/{__version__}')]
        urllib.request.install_opener(opener)
        return opener

    def download(self, url: str, filename: Optional[str] = None, retries: Optional[int] = None) -> bool:
        """Download a file with retry"""
        if filename is None:
            filename = url.split('/')[-1]

        dest = self.sources_dir / filename
        retries = self.retries if retries is None else max(1, int(retries))

        if dest.exists():
            self.logger.info(f"Already exists: {filename}")
            return True

        for attempt in range(retries):
            self.logger.info(f"Downloading: {filename} (attempt {attempt + 1}/{retries})")
            try:
                previous_timeout = socket.getdefaulttimeout()
                socket.setdefaulttimeout(self.timeout)
                try:
                    urllib.request.urlretrieve(url, dest)
                finally:
                    socket.setdefaulttimeout(previous_timeout)
                return True
            except urllib.error.HTTPError as e:
                self.logger.warning(f"Attempt {attempt + 1} failed: {e}")
                if dest.exists():
                    dest.unlink()
                self.logger.error(f"Failed to download {url}: {e}")
                return False
            except Exception as e:
                self.logger.warning(f"Attempt {attempt + 1} failed: {e}")
                if dest.exists():
                    dest.unlink()
                if attempt < retries - 1:
                    continue
                self.logger.error(f"Failed to download {url}: {e}")
                return False  # at top

    def download_from_list(self, list_file: Path, parallel: int = 4) -> bool:
        """Download multiple sources in parallel"""
        if not list_file.exists():
            self.logger.error(f"Sources list not found: {list_file}")
            return False

        urls = []
        with open(list_file, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    if line.startswith('git://') or line.endswith('.git'):
                        self.logger.info(f"Skipping Git repository (use git clone): {line}")
                        continue
                    urls.append(line)

        self.logger.info(f"Downloading {len(urls)} sources with {parallel} threads")

        failed_urls = []
        with ThreadPoolExecutor(max_workers=parallel) as executor:
            future_to_url = {executor.submit(self.download, url): url for url in urls}
            for future in as_completed(future_to_url):
                url = future_to_url[future]
                try:
                    success = future.result()
                    if not success:
                        failed_urls.append(url)
                except Exception as e:
                    self.logger.error(f"Unexpected error downloading {url}: {e}")
                    failed_urls.append(url)

        if failed_urls:
            self.logger.warning(f"Failed to download {len(failed_urls)} sources:")
            for url in failed_urls:
                self.logger.warning(f"  {url}")
            return False
        else:
            self.logger.info("All sources downloaded successfully")
            return True

    def verify_checksums(self, checksum_file: Path) -> bool:
        """Verify downloaded files against checksums"""
        if not checksum_file.exists():
            self.logger.warning("No checksum file found, skipping verification")
            return True

        all_valid = True
        with open(checksum_file, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue

                parts = line.split()
                if len(parts) != 2:
                    continue

                expected_md5, filename = parts
                filepath = self.sources_dir / filename

                if not filepath.exists():
                    self.logger.warning(f"Missing file: {filename}")
                    all_valid = False
                    continue

                actual_md5 = hashlib.md5(filepath.read_bytes()).hexdigest()
                if actual_md5 != expected_md5:
                    self.logger.error(f"Checksum mismatch: {filename}")
                    all_valid = False

        return all_valid


# ============================================================================
# SCRIPT EXECUTOR
# ============================================================================

class ScriptExecutor:
    """Execute build scripts with proper error handling"""

    def __init__(self, env: Dict, output_dir: Path, logger: logging.Logger):
        self.env = env
        self.output_dir = output_dir
        self.logger = logger
        self.completed_stages = []

    def find_script(self, script_path: str) -> Optional[Path]:
        """Find script in various possible locations"""
        # Direct path
        if Path(script_path).exists():
            return Path(script_path)

        # With scripts/ prefix
        if Path(f"scripts/{script_path}").exists():
            return Path(f"scripts/{script_path}")

        # With no prefix (if already in scripts)
        base = Path(script_path).name
        if Path(base).exists():
            return Path(base)

        return None

    def run_script(self, script_path: str, stage_name: str, timeout: int = 7200) -> bool:
        """Run a single build script"""
        self.logger.info(f"Running stage: {stage_name}")

        script = self.find_script(script_path)
        if not script:
            self.logger.error(f"Script not found: {script_path}")
            return False

        script.chmod(0o755)

        log_file = self.output_dir / 'logs' / f"{stage_name}.log"
        log_file.parent.mkdir(parents=True, exist_ok=True)

        try:
            with open(log_file, 'w') as log:
                result = subprocess.run(
                    [str(script)],
                    env={**os.environ, **self.env},
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    text=True,
                    timeout=timeout
                )

            if result.returncode == 0:
                self.logger.info(f"Stage completed: {stage_name}")
                self.completed_stages.append(stage_name)
                return True
            else:
                self.logger.error(f"Stage failed: {stage_name} (exit code: {result.returncode})")
                self.logger.info(f"  Check log: {log_file}")

                # Show last 10 lines of log for quick debugging
                if log_file.exists():
                    with open(log_file, 'r') as f:
                        lines = f.readlines()[-150:]
                    self.logger.info("  Last 150 log lines:")
                    for line in lines:
                        self.logger.info(f"    {line.rstrip()}")
                return False

        except subprocess.TimeoutExpired:
            self.logger.error(f"✗ Stage timed out after {timeout} seconds: {stage_name}")
            return False
        except Exception as e:
            self.logger.error(f"✗ Exception running stage {stage_name}: {e}")
            return False

    def resume_from(self, resume_stage: str, stages: List[Tuple[str, str]]) -> bool:
        """Resume build from a specific stage"""
        start_index = 0
        for i, (stage_name, _) in enumerate(stages):
            if stage_name == resume_stage:
                start_index = i
                break

        self.logger.info(f"Resuming build from stage: {resume_stage}")

        for stage_name, script_path in stages[start_index:]:
            if not self.run_script(script_path, stage_name):
                return False

        return True


# ============================================================================
# USB WRITER
# ============================================================================

class USBWriter:
    """Write bootable ISO to USB drive"""

    @staticmethod
    def list_devices() -> List[Dict]:
        """List available USB devices with details"""
        devices = []

        if platform.system() == "Linux":
            result = subprocess.run(['lsblk', '-d', '-o', 'NAME,SIZE,MODEL,TYPE,MOUNTPOINT', '-l'],
                                    capture_output=True, text=True)
            for line in result.stdout.split('\n')[1:]:
                if line.strip() and 'disk' in line:
                    parts = line.split()
                    devices.append({
                        'name': f"/dev/{parts[0]}",
                        'size': parts[1] if len(parts) > 1 else '?',
                        'model': parts[2] if len(parts) > 2 else 'Unknown'
                    })
        elif platform.system() == "Darwin":
            result = subprocess.run(['diskutil', 'list'], capture_output=True, text=True)
            for line in result.stdout.split('\n'):
                if '/dev/disk' in line and 'external' in line.lower():
                    devices.append({'name': line.split()[0], 'size': '?', 'model': 'USB Drive'})

        return devices

    @staticmethod
    def write_iso(iso_path: Path, device: str, logger: logging.Logger) -> bool:
        """Write ISO to USB device"""
        if not iso_path.exists():
            logger.error(f"ISO not found: {iso_path}")
            return False

        if not device.startswith('/dev/'):
            device = f"/dev/{device}"

        logger.warning(f"This will overwrite ALL data on {device}")
        response = input("Type 'YES' to continue: ")

        if response != 'YES':
            logger.info("Operation cancelled")
            return False

        system = platform.system()

        if system == "Linux":
            try:
                with open('/proc/mounts', 'r') as f:
                    mounts = f.readlines()
                partitions = [line.split()[0] for line in mounts if line.startswith(device)]
                if partitions:
                    subprocess.run(['sudo', 'umount'] + partitions, capture_output=True, text=True)
            except IOError:
                # Fallback if /proc/mounts is unreadable
                pass
            cmd = ['sudo', 'dd', f'if={iso_path}', f'of={device}', 'bs=4M', 'status=progress', 'conv=fsync']
        elif system == "Darwin":
            raw_device = device.replace('disk', 'rdisk')
            cmd = ['sudo', 'dd', f'if={iso_path}', f'of={raw_device}', 'bs=4m']
        else:
            logger.error("USB writing not supported on this platform")
            return False

        try:
            logger.info(f"Writing ISO to {device}...")
            subprocess.run(cmd, check=True)
            logger.info(f"Successfully written to {device}")

            subprocess.run(['sync'], check=False)
            if system == "Linux":
                subprocess.run(['sudo', 'eject', device], check=False)
            logger.info("USB drive is ready. You can safely remove it.")
            return True
        except subprocess.CalledProcessError as e:
            logger.error(f"Failed to write ISO: {e}")
            return False

# ============================================================================
# BUILD CACHE
# ============================================================================

class BuildCache:
    """Download and extract pre-built root filesystem from cache"""

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
        return arches[arch]

    def download_and_extract(self, entry: Dict, output_dir: Path) -> bool:
        url = entry.get('url')
        sha256_expected = entry.get('sha256')
        if not url:
            self.logger.error("Cache entry missing URL")
            return False

        tmp_path = None
        try:
            import tempfile
            import hashlib
            import tarfile

            with tempfile.NamedTemporaryFile(delete=False, suffix='.tar.xz') as tmp:
                self.logger.info(f"Downloading cache from {url} ...")
                urllib.request.urlretrieve(url, tmp.name, self._reporthook)
                tmp_path = Path(tmp.name)

            if sha256_expected:
                actual = hashlib.sha256(tmp_path.read_bytes()).hexdigest()
                if actual != sha256_expected:
                    self.logger.error(f"Checksum mismatch: expected {sha256_expected}, got {actual}")
                    tmp_path.unlink()
                    return False

            image_dir = output_dir / 'image'
            if image_dir.exists():
                shutil.rmtree(image_dir)
            image_dir.mkdir(parents=True)

            with tarfile.open(tmp_path, 'r:xz') as tar:
                tar.extractall(image_dir)

            self.logger.info(f"Cache extracted to {image_dir}")
            return True

        except Exception as e:
            self.logger.error(f"Failed to download/extract cache: {e}")
            return False
        finally:
            if tmp_path and tmp_path.exists():
                tmp_path.unlink()

    def _reporthook(self, blocknum, blocksize, totalsize):
        if totalsize <= 0:
            return
        percent = int(blocknum * blocksize * 100 / totalsize)
        if percent % 10 == 0:
            sys.stdout.write(f"\r  Download: {percent}%")
            sys.stdout.flush()
        if percent >= 100:
            sys.stdout.write("\n")

# ============================================================================
# MAIN BUILDER CLASS
# ============================================================================

class LFSBuilder:
    """Main orchestrator for LFS/BLFS build process"""

    def __init__(self, profile: str, output_dir: Path, config_file: Path, cache_url: Optional[str] = None):
        self.profile = profile
        self.output_dir = Path(output_dir).resolve()
        if isinstance(config_file, str):
            config_file = Path(config_file)
        self.config = LFSConfig(config_file)
        self.system = platform.system()
        self._detected_system = self.system
        self.logger = self.setup_logging()
        self.profile_config = ProfileManager.get_profile(profile)
        self._cache_url = cache_url or "https://raw.githubusercontent.com/lfs-builder/lfs-builder/main/cache-metadata.json"
        # Apply profile settings to config
        self._apply_profile_settings()

        # Initialize components
        self.downloader = SourceDownloader(
            self.output_dir / 'sources',
            self.logger,
            timeout=self.config.get('build_options.download_timeout', 30),
            retries=self.config.get('build_options.retry_downloads', 2),
        )
        self.refresh_executor()

    def refresh_executor(self):
        """Rebuild script executor with up-to-date environment variables."""
        self.executor = ScriptExecutor(self._get_env(), self.output_dir, self.logger)

    def _apply_profile_settings(self):
        """Apply profile-specific settings to configuration"""
        if self.profile_config.get('desktop'):
            self.config.set('desktop.type', self.profile_config['desktop'])

        if self.profile_config.get('init_system'):
            self.config.set('init_system.choice', self.profile_config['init_system'])

        if self.profile_config.get('kernel'):
            self.config.set('kernel.type', self.profile_config['kernel'])

        # Apply cross-compilation settings from profile
        if self.profile_config.get('cross_compile', False):
            self.config.set('cross_compile', True)
            self.config.set('architecture', self.profile_config.get('architecture', 'aarch64'))
            self.config.set('target_triplet', f"{self.profile_config.get('architecture', 'aarch64')}-lfs-linux-gnu")
            self.config.set('bootloader.type', self.profile_config.get('bootloader', 'uboot'))

        self.config.set('java_dev.enabled', self.profile_config.get('java_dev', False))
        self.config.set('package_manager.enabled', self.profile_config.get('package_manager', True))
        self.config.set('live_system.enabled', self.profile_config.get('live_system', True))
        self.config.set('system_updater.enabled', self.profile_config.get('system_updater', True))

        if self.profile_config.get('security_hardening', False):
            self.config.set('security.kernel_hardening', True)
            self.config.set('security.firewall.enabled', True)
            self.config.set('security.fail2ban.enabled', True)
            self.config.set('security.audit.enabled', True)
            self.config.set('security.hids.enabled', True)

        if self.profile_config.get('privacy_tools', False):
            self.config.set('security.privacy.disable_telemetry', True)

    def is_cross_compile(self) -> bool:
        """Check if cross-compilation is enabled"""
        return self.config.get('cross_compile', False)

    def get_target_architecture(self) -> str:
        """Get target architecture for cross-compilation"""
        return self.config.get('architecture', 'x86_64')

    def get_cross_prefix(self) -> str:
        """Get cross-compilation toolchain prefix"""
        return self.config.get('cross_prefix', f"/usr/bin/{self.get_target_architecture()}-linux-gnu-")

    def get_qemu_user(self) -> str:
        """Get QEMU user emulator for target architecture"""
        arch = self.get_target_architecture()
        qemu_map = {
            'aarch64': 'qemu-aarch64-static',
            'arm': 'qemu-arm-static',
            'armv7l': 'qemu-arm-static',
            'riscv64': 'qemu-riscv64-static',
            'mips64': 'qemu-mips64-static'
        }
        return self.config.get('qemu_user', qemu_map.get(arch, ''))

    def get_sysroot(self) -> str:
        """Get sysroot path for cross-compilation"""
        return self.config.get('sysroot', f"{self.output_dir}/sysroot/{self.get_target_architecture()}")

    def get_init_system(self) -> str:
        """Get init system choice from config"""
        init_choices = ['systemd', 'sysvinit', 'sysv', 'openrc', 'runit', 's6']
        init = self.config.get('init_system.choice', 'sysvinit')

        # Normalize sysv to sysvinit
        if init == 'sysv':
            init = 'sysvinit'

        if init not in init_choices:
            self.logger.warning(f"Unknown init system: {init}, using sysvinit")
            init = 'sysvinit'

        return init

    def _flatten_config(self, obj: Any, prefix: str = '') -> Dict[str, str]:
        """Recursively flatten nested config dictionaries to env variables"""
        env_vars = {}
        
        if isinstance(obj, dict):
            for key, value in obj.items():
                new_key = f"{prefix}_{key}".upper() if prefix else key.upper()
                if isinstance(value, dict):
                    env_vars.update(self._flatten_config(value, new_key))
                elif isinstance(value, bool):
                    env_vars[new_key] = str(value).lower()
                elif isinstance(value, (list, tuple)):
                    env_vars[new_key] = ','.join(str(v) for v in value)
                else:
                    env_vars[new_key] = str(value) if value is not None else ''
        
        return env_vars

    def _get_env(self) -> Dict:
        """Get environment variables for scripts"""
        env = {
            'LFS': str(self.output_dir.resolve()),
            'LFS_TGT': self.config.get('target_triplet'),
            'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
            'MAKEFLAGS': f"-j{self.config.get('build_threads', os.cpu_count())}",
            'PROFILE': self.profile,
            'INIT_SYSTEM': self.get_init_system(),
            'SYSVINIT_STYLE': self.config.get('init_system.service_style', 'lfs-classic'),
            'PARALLEL_STARTUP': str(self.config.get('init_system.parallel_startup', False)).lower(),
            'AUTO_RESTART': str(self.config.get('init_system.auto_restart', True)).lower(),
            'JAVA_DEV': str(self.profile_config.get('java_dev', False)).lower(),
            'LPM_ENABLED': str(self.profile_config.get('package_manager', True)).lower(),
            'SECURITY_HARDENING': str(self.profile_config.get('security_hardening', False)).lower(),
            'PRIVACY_TOOLS': str(self.profile_config.get('privacy_tools', False)).lower(),
            'LIVE_SYSTEM': str(self.profile_config.get('live_system', True)).lower(),
            'KERNEL_TYPE': str(self.config.get('kernel.type', 'linux')).lower(),
            'KERNEL_VERSION': str(self.config.get('kernel.version', '6.16.1')),
            'SYSTEM_UPDATER': str(self.profile_config.get('system_updater', True)).lower(),
            'LFS_VERSION': __version__,
            'LC_ALL': 'POSIX'
        }

        # Add all configuration parameters as environment variables for scripts
        config_flat = self._flatten_config(self.config.data, 'LFS_CONFIG')
        env.update(config_flat)
        
        # Add all profile configuration parameters
        profile_flat = self._flatten_config(self.profile_config, 'LFS_PROFILE')
        env.update(profile_flat)

        # Add cross-compilation variables if enabled
        if self.is_cross_compile():
            env['CROSS_COMPILE'] = self.get_cross_prefix()
            env['CROSS_PREFIX'] = self.get_cross_prefix()
            env['QEMU_USER'] = self.get_qemu_user()
            env['SYSROOT'] = self.get_sysroot()
            env['ARCH'] = self.get_target_architecture()
            self.logger.info(f"Cross-compilation enabled for architecture: {self.get_target_architecture()}")
            self.logger.info(f"  Cross prefix: {self.get_cross_prefix()}")
            self.logger.info(f"  QEMU user: {self.get_qemu_user()}")
            self.logger.info(f"  Sysroot: {self.get_sysroot()}")

        return env

    def setup_logging(self) -> logging.Logger:
        """Setup logging configuration"""
        log_dir = self.output_dir / 'logs'
        log_dir.mkdir(parents=True, exist_ok=True)

        log_level = getattr(logging, self.config.get('logging.level', 'INFO').upper())

        logging.basicConfig(
            level=log_level,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler(log_dir / 'build.log'),
                logging.StreamHandler()
            ]
        )
        return logging.getLogger(__name__)

    def detect_host_distro(self) -> str:
        """Returns 'debian', 'fedora', 'arch', or 'unknown'."""
        override = self.config.get('host.distro_override', 'auto')
        if override in ('debian', 'fedora', 'arch'):
            return override

        os_release = Path('/etc/os-release')
        if os_release.exists():
            content = os_release.read_text().lower()
            if 'fedora' in content:
                return 'fedora'
            if 'debian' in content or 'ubuntu' in content:
                return 'debian'
            if 'arch' in content:
                return 'arch'
        return 'unknown'

    def ensure_lfs_user(self) -> bool:
        try:
            pwd.getpwnam('lfs')
            bashrc = Path('/home/lfs/.bashrc')
            if not bashrc.exists():
                if os.geteuid() == 0:
                    bashrc.touch()
                    shutil.chown(bashrc, user='lfs', group='lfs')
                else:
                    self.logger.error(
                        "lfs user exists but /home/lfs/.bashrc is missing. "
                        "Run: sudo touch /home/lfs/.bashrc && sudo chown lfs:lfs /home/lfs/.bashrc"
                    )
                    return False
            return True
        except KeyError:
            if os.geteuid() == 0:
                subprocess.run(['useradd', '-m', '-s', '/bin/bash', 'lfs'], check=True)
                Path('/home/lfs/.bashrc').touch()
                shutil.chown(Path('/home/lfs/.bashrc'), user='lfs', group='lfs')
                return True
            else:
                self.logger.error(
                    "The 'lfs' user is required but not present.\n"
                    "Create it manually with: sudo useradd -m -s /bin/bash lfs\n"
                    "Then run: sudo touch /home/lfs/.bashrc && sudo chown lfs:lfs /home/lfs/.bashrc"
                )
                return False

    def check_prerequisites(self) -> bool:
        """Check system prerequisites based on platform"""
        runtime_system = platform.system()
        # Honor explicit overrides (e.g., tests forcing builder.system) while still
        # allowing runtime platform patches when the system was not overridden.
        self.system = self.system if self.system != self._detected_system else runtime_system
        self.logger.info(f"Checking prerequisites on {self.system}")
        self.logger.info(f"LFS Builder Version: {__version__}")

        # Skip if running in Docker (container already has all tools)
        if os.path.exists('/.dockerenv'):
            self.logger.info("Docker container detected - skipping host prerequisites check")
            return True

        if self.system == "Linux":
            required_cmds = ['bash', 'gcc', 'make', 'bison', 'gawk', 'm4', 'wget', 'tar', 'gzip', 'xorriso', 'parted']
            required_space = 50
            self.logger.info("Linux detected - Native build mode")
            # Detect host distribution
            host_distro = self.detect_host_distro()
            self.logger.info(f"Detected host distribution: {host_distro}")

            # Cross-compilation requirements with distro-specific packages
            if self.is_cross_compile():
                cross_gcc = f"{self.get_target_architecture()}-linux-gnu-gcc"
                if not shutil.which(cross_gcc):
                    self.logger.warning(f"Cross-compiler not found: {cross_gcc}")
                    if host_distro == 'fedora':
                        self.logger.info(
                            f"Install with: sudo dnf install gcc-{self.get_target_architecture()}-linux-gnu "
                            f"binutils-{self.get_target_architecture()}-linux-gnu"
                        )
                    elif host_distro == 'debian':
                        self.logger.info(
                            f"Install with: sudo apt install gcc-{self.get_target_architecture()}-linux-gnu "
                            f"binutils-{self.get_target_architecture()}-linux-gnu"
                        )
                    elif host_distro == 'arch':
                        self.logger.info(
                            f"Install with: sudo pacman -S aarch64-linux-gnu-gcc"
                        )
                    else:
                        self.logger.info(
                            f"Please install the cross-compiler for {self.get_target_architecture()} manually."
                        )

            # Check for lfs user (required by host-prepare stage)
            # Vérification de l'utilisateur lfs via la méthode dédiée
            if not self.ensure_lfs_user():
                return False

        elif self.system == "Darwin":
            required_cmds = ['bash', 'docker', 'make', 'gawk', 'm4']
            required_space = 60
            self.logger.info("macOS detected - Docker will be used for building")
        elif self.system == "Windows":
            required_cmds = ['wsl', 'bash']
            required_space = 60
            self.logger.info("Windows detected - WSL2 required")
        else:
            self.logger.error(f"Unsupported OS: {self.system}")
            return False

        # Check for required commands
        missing = []
        for cmd in required_cmds:
            if not shutil.which(cmd):
                missing.append(cmd)

        if missing:
            self.logger.error(f"Missing commands: {', '.join(missing)}")
            if self.system == "Linux":
                if host_distro == 'fedora':
                    self.logger.info("Install missing packages: sudo dnf install build-essential bison flex gawk texinfo wget xorriso parted")
                elif host_distro == 'debian':
                    self.logger.info("Install missing packages: sudo apt install build-essential bison flex gawk texinfo wget xorriso parted")
                elif host_distro == 'arch':
                    self.logger.info("Install missing packages: sudo pacman -S base-devel bison flex gawk texinfo wget xorriso parted")
                else:
                    self.logger.info("Please install the required build tools manually.")
            return False

        # Check free disk space
        free_space = shutil.disk_usage(self.output_dir).free // (1024**3)
        if free_space < required_space:
            self.logger.warning(f"Low disk space: {free_space}GB (recommended: {required_space}GB)")

        self.logger.info("Prerequisites check passed")
        return True

    def prepare_environment(self) -> bool:
        """Prepare build environment directories"""
        self.logger.info("Preparing build environment")

        directories = [
            self.output_dir,
            self.output_dir / 'sources',
            self.output_dir / 'tools',
            self.output_dir / 'logs',
            self.output_dir / 'image',
            self.output_dir / 'cache',
            self.output_dir / 'backups',
            self.output_dir / 'live'
        ]

        for d in directories:
            d.mkdir(parents=True, exist_ok=True)
            self.logger.debug(f"Created directory: {d}")

        # Create sysroot for cross-compilation
        if self.is_cross_compile():
            sysroot = Path(self.get_sysroot())
            sysroot.mkdir(parents=True, exist_ok=True)
            self.logger.info(f"Sysroot created: {sysroot}")

        build_info = {
            'profile': self.profile,
            'build_date': datetime.now().isoformat(),
            'builder_version': __version__,
            'lfs_version': self.config.get('lfs_version'),
            'blfs_version': self.config.get('blfs_version'),
            'init_system': self.get_init_system(),
            'system': self.system,
            'cpu_cores': os.cpu_count(),
            'python_version': sys.version,
            'cross_compile': self.is_cross_compile(),
            'target_architecture': self.get_target_architecture() if self.is_cross_compile() else None,
            'features': {
                'java_dev': self.profile_config.get('java_dev', False),
                'security': self.profile_config.get('security_hardening', False),
                'privacy': self.profile_config.get('privacy_tools', False),
                'live_system': self.profile_config.get('live_system', True),
                'system_updater': self.profile_config.get('system_updater', True)
            }
        }

        with open(self.output_dir / 'build_info.json', 'w') as f:
            json.dump(build_info, f, indent=2)

        self.logger.info("Environment prepared")
        return True

    def download_sources(self) -> bool:
        """Download all required sources"""
        self.logger.info("Downloading sources")

        # Update sources.list from official repositories
        self._update_sources_list()

        sources_candidates = [
            Path('packages/sources.list'),
            self.output_dir / 'packages' / 'sources.list'
        ]
        sources_list = next((p for p in sources_candidates if p.exists()), sources_candidates[0])

        checksum_candidates = [
            Path('packages/md5sums'),
            self.output_dir / 'packages' / 'md5sums'
        ]
        checksum_file = next((p for p in checksum_candidates if p.exists()), checksum_candidates[0])

        if not sources_list.exists():
            if not self.config.get('repositories', []):
                sources_list = self.output_dir / 'packages' / 'sources.list'
                sources_list.parent.mkdir(parents=True, exist_ok=True)
                sources_list.write_text("# No repository configured; generated empty sources list\n")
                self.logger.warning(
                    f"Sources list not found and no repositories configured; created empty list: {sources_list}"
                )
            else:
                self.logger.error(f"Sources list not found: {sources_list}")
                return False

        success = self.downloader.download_from_list(sources_list, parallel=4)

        if not success and not sources_list.exists():
            self.logger.error(f"Sources list not found: {sources_list}")
            return False

        if not success:
            self.logger.warning("Some downloads failed, continuing with available sources")

        if checksum_file.exists():
            self.downloader.verify_checksums(checksum_file)

        return True

    def get_build_stages(self) -> List[Tuple[str, str]]:
        """Get ordered list of build stages with correct script paths"""
        stages = []

        # Host preparation (always needed)
        stages.append(('host-check', 'host/01-check-host.sh'))
        stages.append(('host-prepare', 'host/02-prepare-host.sh'))

        # QEMU setup for cross-compilation
        if self.is_cross_compile():
            stages.append(('qemu-setup', 'host/00-setup-qemu.sh'))

        stages.append(('disk-image', 'host/03-create-disk-image.sh'))
        stages.append(('toolchain', 'host/04-build-toolchain.sh'))

        # U-Boot for ARM boards
        bootloader_type = self.config.get('bootloader.type', 'grub')
        if bootloader_type == 'uboot':
            stages.append(('uboot', 'host/05-build-uboot.sh'))

        # LFS core
        stages.append(('lfs-system', 'lfs/05-build-lfs-system.sh'))

        # Init system (sysvinit or systemd)
        stages.append(('init-system', 'lfs/06a-init-system.sh'))
        stages.append(('service-abstraction', 'lfs/06b-service-management.sh'))

        # Configure LFS
        stages.append(('configure-lfs', 'lfs/07-configure-lfs.sh'))

        # BLFS base
        stages.append(('blfs-base', 'blfs/08-build-blfs-base.sh'))

        # Build kernel
        stages.append(('build-kernel', 'lfs/09-build-kernel.sh'))

        # ⚠️ SUPPRIMEZ la ligne suivante (initramfs ne doit pas être ici)
        # stages.append(('initramfs', 'final/12-create-initramfs.sh'))  <--- À RETIRER

        # Desktop (if enabled)
        if self.profile_config.get('desktop'):
            stages.append(('desktop', 'blfs/09-build-desktop.sh'))
            stages.append(('applications', 'blfs/10-build-applications.sh'))
            stages.append(('configure-desktop', 'blfs/11-configure-desktop.sh'))

        # Java development
        if self.profile_config.get('java_dev', False):
            stages.append(('java-dev', 'blfs/12-install-java-dev.sh'))

        # Package manager
        if self.profile_config.get('package_manager', True):
            stages.append(('package-manager', 'blfs/13-create-package-manager.sh'))
            stages.append(('base-packages', 'blfs/14-create-base-packages.sh'))

        # Security hardening
        if self.profile_config.get('security_hardening', False):
            stages.append(('security', 'blfs/15-security-hardening.sh'))

        # Privacy tools
        if self.profile_config.get('privacy_tools', False):
            stages.append(('privacy', 'blfs/16-privacy-tools.sh'))

        # Branding
        stages.append(('branding', 'blfs/21-branding.sh'))

        # First boot service
        stages.append(('first-boot', 'blfs/17-first-boot-service.sh'))

        # System updater
        if self.profile_config.get('system_updater', True):
            stages.append(('system-updater', 'blfs/18-system-updater.sh'))
            stages.append(('package-updater', 'blfs/19-package-updater.sh'))
            stages.append(('lpm-advanced', 'blfs/20-lpm-advanced.sh'))

        # ✅ FINAL STAGES (un seul initramfs ici)
        stages.append(('initramfs', 'final/12-create-initramfs.sh'))
        stages.append(('bootloader', 'final/13-create-bootloader.sh'))
        stages.append(('installer', 'final/14-create-installer.sh'))

        # Live system
        live_from_profile = self.profile_config.get('live_system', True)
        live_from_config = self.config.get('live_system.enabled', live_from_profile)
        if live_from_profile and live_from_config:
            stages.append(('live-system', 'final/15-create-live-system.sh'))

        return stages

    def _update_sources_list(self) -> bool:
        """Update packages/sources.list with official LFS/BLFS URLs + custom sources."""
        sources_file = Path('packages/sources.list')
        custom_file = Path('packages/custom-sources.list')
        repo_urls = self.config.get('repositories', [])

        if not repo_urls:
            self.logger.warning("No repository URLs configured, skipping sources update")
            return False

        urls_by_key: Dict[str, str] = {}
        override_count = 0

        def source_key(url: str) -> str:
            filename = Path(urlparse(url).path).name
            if filename:
                base = re.sub(r'[-_][v]?\d[\d.+]*.*$', '', filename)
                if not base:
                    self.logger.warning(
                        f"source_key: regex stripped entire filename '{filename}'; "
                        "using full filename as key"
                    )
                    return f"pkg:{filename}"
                return f"pkg:{base}"
            return f"url:{url}"

        # 1. Récupérer les listes officielles
        for repo_url in repo_urls:
            try:
                self.logger.info(f"Fetching sources list from {repo_url}")
                with urllib.request.urlopen(repo_url, timeout=30) as resp:
                    content = resp.read().decode('utf-8')
                    for line in content.splitlines():
                        line = line.strip()
                        if line and not line.startswith('#'):
                            key = source_key(line)
                            urls_by_key.setdefault(key, line)
            except Exception as e:
                self.logger.warning(f"Failed to fetch {repo_url}: {e}")

        # 2. Substitution du noyau (seulement si on a des URLs officielles)
        if urls_by_key:
            kernel_type = self.config.get('kernel.type', 'linux')
            kernel_version = self.config.get('kernel.version', '6.16.1')

            kernel_url = None
            if kernel_type == 'linux':
                kernel_url = f"https://www.kernel.org/pub/linux/kernel/v6.x/linux-{kernel_version}.tar.xz"
            elif kernel_type == 'linux-libre':
                kernel_url = f"https://www.linux-libre.fsfla.org/pub/linux-libre/releases/{kernel_version}-gnu/linux-libre-{kernel_version}-gnu.tar.xz"
            elif kernel_type == 'gnu-hurd':
                kernel_url = f"https://ftpmirror.gnu.org/hurd/hurd-{kernel_version}.tar.gz"
            elif kernel_type == 'freebsd':
                kernel_url = f"https://download.freebsd.org/ftp/releases/amd64/{kernel_version}/src.txz"

            if kernel_url:
                keys_to_remove = [k for k in urls_by_key if 'linux-' in k or k.startswith('pkg:linux')]
                for k in keys_to_remove:
                    del urls_by_key[k]
                new_key = f"pkg:{kernel_type}-{kernel_version}"
                urls_by_key[new_key] = kernel_url
                self.logger.info(f"Using {kernel_type} kernel {kernel_version}: {kernel_url}")

        # 3. Ajouter les sources personnalisées (prioritaires)
        if custom_file.exists():
            self.logger.info(f"Appending custom sources from {custom_file}")
            with open(custom_file, 'r') as cf:
                for line in cf:
                    line = line.strip()
                    if line and not line.startswith('#'):
                        key = source_key(line)
                        previous = urls_by_key.get(key)
                        if previous and previous != line:
                            override_count += 1
                        urls_by_key[key] = line

        # 4. Si aucune URL, on retourne False
        if not urls_by_key:
            self.logger.error("No URLs found from official or custom sources")
            return False

        # 5. Créer le répertoire parent et écrire le fichier
        sources_file.parent.mkdir(parents=True, exist_ok=True)
        with open(sources_file, 'w') as f:
            f.write("# LFS Sources - Automatically generated from official wget-lists\n")
            f.write(f"# Generated: {datetime.now().isoformat()}\n")
            f.write("# DO NOT EDIT MANUALLY – changes will be overwritten\n\n")
            for url in sorted(urls_by_key.values()):
                f.write(f"{url}\n")

        if override_count:
            self.logger.info(f"Applied {override_count} custom source override(s)")
        self.logger.info(f"Updated sources.list with {len(urls_by_key)} URLs (official + custom) -> {sources_file}")
        return True

    def build(self, resume_from: Optional[str] = None, use_cache: bool = False, cache_only: bool = False) -> bool:
        self.logger.info("=" * 70)
        self.logger.info(f"LFS Builder v{__version__}")
        self.logger.info(f"Profile: {self.profile}")
        self.logger.info(f"Init system: {self.get_init_system()}")
        self.logger.info(f"Desktop: {self.profile_config.get('desktop', 'None (CLI only)')}")
        self.logger.info(f"Live system: {self.profile_config.get('live_system', True)}")
        self.logger.info(f"Output directory: {self.output_dir}")

        if self.is_cross_compile():
            self.logger.info(f"Cross-compiling for: {self.get_target_architecture()}")
            self.logger.info(f"Bootloader: {self.config.get('bootloader.type', 'grub')}")

        self.logger.info("=" * 70)

        # --- Cache handling ---
        if use_cache:
            cache = BuildCache(self._cache_url, self.logger)
            if cache.fetch_metadata():
                entry = cache.get_cached_entry(
                    profile=self.profile,
                    init=self.get_init_system(),
                    arch=self.config.get('architecture', 'x86_64'),
                    builder_version=__version__
                )
                if entry:
                    self.logger.info("Cache found. Downloading and extracting...")
                    if cache.download_and_extract(entry, self.output_dir):
                        self.logger.info("Cache installation successful. Skipping all build stages.")
                        return True
                    else:
                        if cache_only:
                            self.logger.error("Cache download/extraction failed and --cache-only is set")
                            return False
                        self.logger.warning("Cache download/extraction failed, falling back to full build")
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

        # --- Resume or full build ---
        stages = self.get_build_stages()

        if resume_from:
            return self.executor.resume_from(resume_from, stages)

        total_stages = len(stages)
        for idx, (stage_name, script_path) in enumerate(stages, 1):
            self.logger.info(f"[{idx}/{total_stages}] Processing stage: {stage_name}")
            if not self.executor.run_script(script_path, stage_name):
                self.logger.error(f"Build failed at stage: {stage_name}")
                self.logger.info(f"You can resume with: --resume-from {stage_name}")
                return False

        self.logger.info("=" * 70)
        self.logger.info("BUILD COMPLETED SUCCESSFULLY!")
        self.logger.info("=" * 70)

        iso_path = self.output_dir / 'lfs-installer.iso'
        if iso_path.exists():
            size_mb = iso_path.stat().st_size / (1024 * 1024)
            size_gb = size_mb / 1024
            self.logger.info(f"Installer ISO: {iso_path} ({size_gb:.1f} GB / {size_mb:.0f} MB)")
            sha256 = hashlib.sha256(iso_path.read_bytes()).hexdigest()
            self.logger.info(f"SHA256: {sha256[:32]}...")

        return True

    def create_writable_media(self, device: Optional[str] = None) -> bool:
        """Create bootable USB media from installer ISO"""
        installer = self.output_dir / 'lfs-installer.iso'

        if not installer.exists():
            self.logger.error("Installer ISO not found. Run build first.")
            return False

        if device:
            return USBWriter.write_iso(installer, device, self.logger)
        else:
            self.logger.info(f"ISO created: {installer}")
            self.logger.info("\nAvailable USB devices:")
            devices = USBWriter.list_devices()
            for dev in devices:
                self.logger.info(f"  {dev['name']} - {dev['size']} - {dev['model']}")

            self.logger.info("\nTo write to USB, run:")
            self.logger.info(f"  python3 builder.py --write-usb /dev/sdX")
            self.logger.info("\nOr use:")
            self.logger.info("  sudo dd if=lfs-installer.iso of=/dev/sdX bs=4M status=progress")
            return True


# ============================================================================
# COMMAND LINE INTERFACE
# ============================================================================

def create_parser() -> argparse.ArgumentParser:
    """Create argument parser"""
    parser = argparse.ArgumentParser(
        description='LFS/BLFS Builder - Custom Linux Distribution Builder',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
╔═══════════════════════════════════════════════════════════════════════════╗
║                             LFS Builder v{__version__}
╚═══════════════════════════════════════════════════════════════════════════╝

Examples:
  # Build with default profile (XFCE + Live USB)
  python3 builder.py

  # Build CLI minimal system (no GUI)
  python3 builder.py --profile minimal

  # Build for ARM64 (Raspberry Pi)
  python3 builder.py --profile arm64 --config config/build-cross.conf

  # Build with Java development profile
  python3 builder.py --profile java-dev --output ./lfs-java

  # Build security-hardened system
  python3 builder.py --profile secure --init sysvinit

  # Build full system with everything
  python3 builder.py --profile full --output ./lfs-full

  # Build with sysvinit (LFS classic) instead of systemd
  python3 builder.py --init sysvinit

  # Resume from failed stage
  python3 builder.py --resume-from desktop

  # List available profiles
  python3 builder.py --list-profiles

  # Write ISO to USB
  python3 builder.py --write-usb /dev/sdb

  # Clean build directory
  python3 builder.py --clean --output ./lfs-build
        """
    )

    parser.add_argument('--profile', default='xfce',
                        choices=ProfileManager.list_profiles(),
                        help='Build profile to use (default: xfce)')

    parser.add_argument('--output', default='./lfs-build',
                        help='Output directory (default: ./lfs-build)')

    parser.add_argument('--config', default='config/build.conf',
                        help='Configuration file path')

    parser.add_argument('--resume-from',
                        help='Resume build from specific stage')

    parser.add_argument('--write-usb', metavar='DEVICE',
                        help='Write ISO to USB device (e.g., /dev/sdb)')

    parser.add_argument('--list-profiles', action='store_true',
                        help='List all available build profiles')

    parser.add_argument('--profile-info', metavar='PROFILE',
                        help='Show detailed information about a profile')

    parser.add_argument('--clean', action='store_true',
                        help='Clean build directory')

    parser.add_argument('--verbose', '-v', action='store_true',
                        help='Enable verbose output (DEBUG level)')

    parser.add_argument('--init', choices=['systemd', 'sysvinit', 'openrc', 'runit', 's6'],
                        help='Override init system choice')

    parser.add_argument('--no-live', action='store_true',
                        help='Disable live system creation')

    parser.add_argument('--version', action='version',
                        version=f'LFS Builder v{__version__} ({__build_date__})')

    parser.add_argument('--use-cache', action='store_true',
                        help='Use pre-built cache if available (skip compilation)')

    parser.add_argument('--cache-only', action='store_true',
                        help='Only use cache; fail if not found')

    parser.add_argument('--cache-url', default='https://raw.githubusercontent.com/lfs-builder/lfs-builder/main/cache-metadata.json',
                        help='Custom cache metadata URL')

    parser.add_argument('--kernel-type',
                        choices=['linux', 'linux-libre', 'gnu-hurd', 'freebsd'],
                        default='linux',
                        help='Type de noyau à utiliser (linux, linux-libre, gnu-hurd, freebsd)')

    parser.add_argument('--host-distro', choices=['debian', 'fedora', 'arch', 'auto'], default='auto',
                        help='Override host distribution detection')

    parser.add_argument('--bootloader',
                        choices=['grub', 'uboot', 'aboot'],
                        default=None,
                        help='Override bootloader type (grub, uboot, aboot)')

    parser.add_argument('--generate-sources-list', action='store_true',
                        help='Generate packages/sources.list from configured repositories and exit')

    parser.add_argument('--kernel-version',
                        help='Version du noyau (ex: 6.16.1, 6.12.20, etc.)')

    return parser

def clean_build_directory(output_dir: Path, logger: logging.Logger) -> bool:
    """Clean build directory"""
    if not output_dir.exists():
        logger.info("Build directory does not exist")
        return True

    size_bytes = sum(f.stat().st_size for f in output_dir.rglob('*') if f.is_file())
    size_gb = size_bytes / (1024**3)

    logger.warning(f"Build directory size: {size_gb:.1f} GB")
    response = input(f"Delete {output_dir}? (yes/no): ")

    if response.lower() == 'yes':
        shutil.rmtree(output_dir)
        logger.info(f"Removed: {output_dir}")
        return True
    else:
        logger.info("Clean cancelled")
        return False

def main():
    """Main entry point"""
    parser = create_parser()
    args = parser.parse_args()

    if args.list_profiles:
        print("\n" + "=" * 50)
        print("Available LFS Build Profiles")
        print("=" * 50)
        for profile in ProfileManager.list_profiles():
            info = ProfileManager.get_profile(profile)
            print(f"\n  {profile.upper()}")
            print(f"    Description: {info['description']}")
            print(f"    Size: ~{info['size_gb']} GB")
            print(f"    Build time: ~{info['build_time_hours']} hours")
            print(f"    Desktop: {info['desktop'] or 'CLI only'}")
            print(f"    Init System: {info.get('init_system', 'sysvinit')}")
            print(f"    Architecture: {info.get('architecture', 'x86_64')}")
            print(f"    Security: {'Yes' if info.get('security_hardening', False) else 'No'}")
            print(f"    Live USB: {'Yes' if info.get('live_system', True) else 'No'}")
        print()
        return

    if args.profile_info:
        # Pour `--profile-info`, on peut aussi afficher les valeurs par défaut,
        # mais on peut garder la version simple.
        try:
            print(ProfileManager.get_profile_info(args.profile_info))
        except ValueError as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
        return

    if args.clean:
        output_dir = Path(args.output)
        logging.basicConfig(level=logging.INFO)
        logger = logging.getLogger(__name__)
        clean_build_directory(output_dir, logger)
        return

    builder = LFSBuilder(
        profile=args.profile,
        output_dir=args.output,
        config_file=args.config,
        cache_url=args.cache_url
    )

    if args.host_distro:
        builder.config.set('host.distro_override', args.host_distro)

    refresh_executor = False

    if args.init:
        builder.config.set('init_system.choice', args.init)
        builder.logger.info(f"Init system overridden to: {args.init}")
        refresh_executor = True

    if args.no_live:
        builder.config.set('live_system.enabled', False)
        builder.logger.info("Live system disabled")
        refresh_executor = True

    if args.kernel_type:
        builder.config.set('kernel.type', args.kernel_type)
        builder.logger.info(f"Kernel type overridden to: {args.kernel_type}")
        refresh_executor = True

    if args.kernel_version:
        builder.config.set('kernel.version', args.kernel_version)
        builder.logger.info(f"Kernel version overridden to: {args.kernel_version}")
        refresh_executor = True

    if args.bootloader:
        builder.config.set('bootloader.type', args.bootloader)
        builder.logger.info(f"Bootloader overridden to: {args.bootloader}")
        refresh_executor = True

    if refresh_executor:
        builder.refresh_executor()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
        builder.logger.setLevel(logging.DEBUG)
        builder.logger.info("Verbose logging enabled")

    if args.generate_sources_list:
        builder._update_sources_list()
        print("sources.list generated successfully.")
        return

    # --- Calcul des valeurs effectives ---
    effective_init = builder.get_init_system()
    effective_live = builder.config.get('live_system.enabled', True)
    effective_security = builder.profile_config.get('security_hardening', False)
    effective_privacy = builder.profile_config.get('privacy_tools', False)
    # Pour le bureau, si le profil a 'desktop' mais qu'on pourrait le surcharger (pas dans les options)
    effective_desktop = builder.profile_config.get('desktop')

    print("\n" + "=" * 70)
    print(f"LFS/BLFS Builder v{__version__}")
    print("=" * 70)
    # Affiche le cadre avec les valeurs effectives
    print(ProfileManager.get_profile_info(
        args.profile,
        init_system=effective_init,
        desktop=effective_desktop,
        live_system=effective_live,
        security_hardening=effective_security,
        privacy_tools=effective_privacy
    ))
    # Lignes supplémentaires (pour info)
    print(f"  Init System:    {effective_init}")
    print(f"  Live System:    {'Yes' if effective_live else 'No'}")
    print(f"  Cross-Compile:  {'Yes (' + builder.get_target_architecture() + ')' if builder.is_cross_compile() else 'No'}")
    print(f"  Output:         {args.output}")
    print(f"  Host System:    {builder.system}")
    print("=" * 70 + "\n")

    if not builder.check_prerequisites():
        sys.exit(1)

    if not builder.prepare_environment():
        sys.exit(1)

    if not args.resume_from:
        if not builder.download_sources():
            sys.exit(1)

    if not builder.build(resume_from=args.resume_from, use_cache=args.use_cache, cache_only=args.cache_only):
        sys.exit(1)

    if args.write_usb:
        builder.create_writable_media(args.write_usb)

    print("\n" + "=" * 70)
    print("BUILD COMPLETED SUCCESSFULLY!")
    print("=" * 70)
    print(f"ISO location: {builder.output_dir}/lfs-installer.iso")
    print("\nNext steps:")
    print("  1. Write ISO to USB:")
    print(f"     python3 builder.py --write-usb /dev/sdX")
    print("  2. Boot from USB")
    print("  3. Select 'Try LFS Linux' to test live mode")
    print("  4. Or select 'Install LFS Linux' for permanent installation")

    if builder.is_cross_compile():
        print(f"\nFor ARM64 target ({builder.get_target_architecture()}):")
        print(f"   - Flash to SD card: dd if={builder.output_dir}/lfs-installer.img of=/dev/sdb bs=4M")
        print(f"   - Boot on your ARM device (Raspberry Pi, Orange Pi, etc.)")
        print(f"   - Default login: lfsuser / lfsuser123")

    print("\nAfter installation:")
    print("  - Check for updates:   lfs-update check")
    print("  - Upgrade system:      lfs-update upgrade")
    print("  - System status:       lfs-update status")
    print("  - Package manager:     lpm list")
    print()

    if builder.profile_config.get('security_hardening', False):
        print("Security features: ENABLED")
        print("   - Kernel hardening, Firewall, Fail2ban, Audit, HIDS")
    if builder.profile_config.get('privacy_tools', False):
        print("Privacy tools: ENABLED")
        print("   - DNSCrypt, WireGuard, Tor, Telemetry blocking")
    if builder.is_cross_compile():
        print(f"Cross-compilation: ENABLED for {builder.get_target_architecture()}")
    print()


if __name__ == '__main__':
    main() # pragma: no cover