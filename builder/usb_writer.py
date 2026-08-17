#!/usr/bin/env python3
"""
USB Writer for LFS/BLFS Builder
Author: Jean-Francois Landreville, landrevillejf@protonmail.com, 2026
"""

import platform
import subprocess
import logging
from pathlib import Path
from typing import Dict, List


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
