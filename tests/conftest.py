#!/usr/bin/env python3
"""
Pytest configuration and shared fixtures
"""

import json
import os
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Dict, Any
from unittest.mock import MagicMock, patch

import pytest

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from builder import LFSConfig, SourceDownloader, LFSBuilder


@pytest.fixture
def temp_dir():
    """Create a temporary directory for tests"""
    with tempfile.TemporaryDirectory() as tmpdir:
        yield Path(tmpdir)


@pytest.fixture
def mock_config_file(temp_dir):
    """Create a mock configuration file"""
    config_path = temp_dir / "test_config.json"
    config_data = {
        "lfs_version": "13.0",
        "blfs_version": "13.0",
        "architecture": "x86_64",
        "target_triplet": "x86_64-lfs-linux-gnu",
        "build_threads": 4,
        "cross_compile": False,
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
            "version": "1.0.0"
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
            "distribution": "temurin"
        },
        "desktop": {
            "type": "xfce",
            "display_manager": "lightdm",
            "theme": "adwaita"
        },
        "security": {
            "kernel_hardening": True,
            "firewall": {"enabled": True},
            "privacy": {"disable_telemetry": True}
        },
        "bootloader": {
            "type": "grub",
            "config": "config/grub.cfg"
        },
        "filesystem": {
            "type": "ext4",
            "size_mb": 10240,
            "swap_mb": 2048,
            "boot_mb": 512
        },
        "kernel": {
            "version": "6.16.1",
            "config": "config/kernel-config",
            "modules": ["ext4", "xfs", "nvme"]
        },
        "locale": "en_US.UTF-8",
        "timezone": "UTC",
        "hostname": "lfs-desktop",
        "keyboard_layout": "us",
        "users": [{"name": "lfsuser", "groups": ["wheel"], "sudo": True}],
        "network": {"dhcp": True, "dns_servers": ["8.8.8.8"]},
        "custom_scripts": {"post_install": []},
        "repositories": [],
        "build_options": {
            "parallel_build": True,
            "keep_build_dirs": False,
            "strip_binaries": True,
            "checksum_verification": True,
            "verbose_logging": False,
            "download_timeout": 300,
            "retry_downloads": 3
        },
        "logging": {"level": "INFO", "max_size_mb": 100, "max_files": 10}
    }

    with open(config_path, 'w') as f:
        json.dump(config_data, f, indent=2)

    return config_path


@pytest.fixture
def lfs_config(mock_config_file):
    """Create LFSConfig instance"""
    return LFSConfig(mock_config_file)


@pytest.fixture
def mock_logger():
    """Create a mock logger"""
    logger = MagicMock()
    return logger


@pytest.fixture
def sources_dir(temp_dir):
    """Create sources directory"""
    src_dir = temp_dir / "sources"
    src_dir.mkdir(parents=True, exist_ok=True)
    return src_dir


@pytest.fixture
def sample_sources_list(temp_dir):
    """Create sample sources.list file"""
    sources_file = temp_dir / "sources.list"
    content = """# LFS Core Packages
https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.16.1.tar.xz
https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz

# Audio Packages
https://github.com/jackaudio/jack2/releases/download/v1.9.22/jack2-1.9.22.tar.gz
https://github.com/FluidSynth/fluidsynth/releases/download/v2.5.0/fluidsynth-2.5.0.tar.gz
"""
    sources_file.write_text(content)
    return sources_file


@pytest.fixture
def sample_md5sums(temp_dir):
    """Create sample md5sums file"""
    md5_file = temp_dir / "md5sums"
    content = """1234567890abcdef1234567890abcdef linux-6.16.1.tar.xz
abcdef1234567890abcdef1234567890 gcc-15.2.0.tar.xz
"""
    md5_file.write_text(content)
    return md5_file


@pytest.fixture
def mock_script(temp_dir):
    """Create a mock shell script"""
    script_dir = temp_dir / "scripts"
    script_dir.mkdir(parents=True, exist_ok=True)
    script_path = script_dir / "test-script.sh"
    script_path.write_text("#!/bin/bash\necho 'Script executed'\nexit 0")
    script_path.chmod(0o755)
    return script_path


@pytest.fixture
def output_dir(temp_dir):
    """Create output directory"""
    out_dir = temp_dir / "lfs-build"
    out_dir.mkdir(parents=True, exist_ok=True)
    return out_dir


@pytest.fixture
def builder(temp_dir, mock_config_file):
    """Create LFSBuilder instance"""
    output_dir = temp_dir / "lfs-build"
    return LFSBuilder(
        profile="xfce",
        output_dir=output_dir,
        config_file=mock_config_file
    )

@pytest.fixture
def test_env(temp_dir):
    """Environment variables for testing"""
    return {
        'LFS': str(temp_dir / 'lfs'),
        'TEST_MODE': '1',
        'PATH': os.environ.get('PATH', ''),
        'HOME': str(temp_dir),
    }


@pytest.fixture
def downloader(temp_dir, mock_logger):
    """SourceDownloader instance for tests"""
    sources_dir = temp_dir / "sources"
    sources_dir.mkdir(exist_ok=True)
    return SourceDownloader(sources_dir, mock_logger)


@pytest.fixture
def real_sources_list():
    """Path to real sources.list"""
    sources_list = Path("packages/sources.list")
    if not sources_list.exists():
        pytest.skip("sources.list not found")
    return sources_list

def pytest_addoption(parser):
    parser.addoption("--usb-device", action="store", default=None,
                     help="USB device to test (e.g., /dev/sdb)")
    parser.addoption("--dangerous", action="store_true", default=False,
                     help="Allow destructive USB tests")