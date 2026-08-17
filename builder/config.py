"""Configuration management for LFS Builder"""

import json
import logging
import os
from pathlib import Path
from typing import Dict, Optional


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
        """Save configuration to JSON file.

        Silently skips the write when the process lacks write permission for the
        config file (e.g. when running builder.py as an unprivileged build user
        against a checkout owned by a different user).  In that scenario the
        in-memory configuration is still valid and is used for environment-variable
        export to stage scripts.
        """
        try:
            with open(self.config_file, 'w') as f:
                json.dump(self.data, f, indent=2)
        except PermissionError:
            logging.getLogger(__name__).warning(
                "Cannot write config file '%s' (permission denied); "
                "configuration will be used from memory only.", self.config_file
            )

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
