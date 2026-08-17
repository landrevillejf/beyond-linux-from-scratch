#!/usr/bin/env python3
"""
Constants for LFS/BLFS Builder
Author: Jean-Francois Landreville, landrevillejf@protonmail.com, 2026
"""

from pathlib import Path
from datetime import datetime


def _get_version():
    """Read version from VERSION file"""
    version_file = Path(__file__).parent.parent / "VERSION"
    if version_file.exists():
        return version_file.read_text().strip()
    return "dev"


__version__ = _get_version()
__build_date__ = datetime.now().strftime("%Y-%m-%d")

# Script directories (based on actual structure)
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
    ('lfs-basic', 'lfs/05a-build-lfs-basic.sh'),
    ('lfs-system', 'lfs/05b-build-lfs-system.sh'),
    ('init-system', 'lfs/06a-init-system.sh'),
    ('service-mgmt', 'lfs/06b-service-management.sh'),
    ('configure-lfs', 'lfs/07-configure-lfs.sh'),
    ('blfs-base', 'blfs/08-build-blfs-base.sh'),
    ('blfs-libs', 'blfs/08a-build-blfs-libs.sh'),
    ('xorg', 'blfs/08b-build-xorg.sh'),
    ('wayland', 'blfs/08c-build-wayland.sh'),
    ('display-manager', 'blfs/08d-build-display-manager.sh'),
    ('desktop', 'blfs/09-build-desktop.sh'),
    ('applications', 'blfs/10-build-applications.sh'),
    ('configure-desktop', 'blfs/11-configure-desktop.sh'),
    ('java-dev', 'blfs/12-install-java-dev.sh'),
    ('base-packages', 'blfs/14-create-base-packages.sh'),
    ('security', 'blfs/15-security-hardening.sh'),
    ('privacy', 'blfs/16-privacy-tools.sh'),
    ('branding', 'blfs/20-branding.sh'),
    ('first-boot', 'blfs/17-first-boot-service.sh'),
    ('system-updater', 'blfs/18-system-updater.sh'),
    ('lpm', 'blfs/19-lpm.sh'),
    ('initramfs', 'final/12-create-initramfs.sh'),
    ('bootloader', 'final/13-create-bootloader.sh'),
    ('installer', 'final/14-create-installer.sh'),
    ('live-system', 'final/15-create-live-system.sh'),
]
