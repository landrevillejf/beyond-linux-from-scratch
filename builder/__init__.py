#!/usr/bin/env python3
"""
LFS/BLFS Builder package
Author: Jean-Francois Landreville, landrevillejf@protonmail.com, 2026

Re-exports all public symbols so that ``from builder import ...`` works
identically whether *builder* resolves to the legacy ``builder.py`` module
or to this package.
"""

# -- Constants & version ---------------------------------------------------
from .constants import (          # noqa: F401
    __version__,
    __build_date__,
    SCRIPT_DIRS,
    BUILD_STAGES,
    _get_version,
)

# -- Configuration ---------------------------------------------------------
from .config import LFSConfig     # noqa: F401

# -- Profiles --------------------------------------------------------------
from .profiles import ProfileManager  # noqa: F401

# -- USB writer ------------------------------------------------------------
from .usb_writer import USBWriter  # noqa: F401

# -- Build cache -----------------------------------------------------------
from .build_cache import BuildCache  # noqa: F401

# -- Main builder module (orchestrator, downloader, executor, CLI) ---------
from .builder import (            # noqa: F401
    SourceDownloader,
    ScriptExecutor,
    LFSBuilder,
    create_parser,
    clean_build_directory,
    main,
)

# Re-export urlparse so that tests can patch ``builder.urlparse``
from urllib.parse import urlparse  # noqa: F401

# Re-export stdlib modules that tests patch via ``builder.<module>``
import time  # noqa: F401

__all__ = [
    # version / constants
    '__version__', '__build_date__', 'SCRIPT_DIRS', 'BUILD_STAGES',
    '_get_version',
    # config
    'LFSConfig',
    # profiles
    'ProfileManager',
    # usb
    'USBWriter',
    # cache
    'BuildCache',
    # builder
    'SourceDownloader', 'ScriptExecutor', 'LFSBuilder',
    'create_parser', 'clean_build_directory', 'main',
    # utilities re-exported for test patching
    'urlparse',
]
