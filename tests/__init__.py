#!/usr/bin/env python3
"""
Test suite for LFS/BLFS Builder
"""

from pathlib import Path

def _get_version():
    version_file = Path(__file__).parent.parent / "VERSION"
    if version_file.exists():
        return version_file.read_text().strip()
    return "dev"

__version__ = _get_version()