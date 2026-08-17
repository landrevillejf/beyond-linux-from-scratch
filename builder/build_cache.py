#!/usr/bin/env python3
"""
Build Cache for LFS/BLFS Builder
Author: Jean-Francois Landreville, landrevillejf@protonmail.com, 2026
"""

import json
import logging
import sys
import tarfile
import tempfile
import hashlib
import urllib.request
from pathlib import Path
from typing import Dict, Optional


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
                import shutil
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
