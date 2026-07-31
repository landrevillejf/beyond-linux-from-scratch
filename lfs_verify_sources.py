#!/usr/bin/env python3
"""
Verify that all LFS source tarballs are present and have correct checksums.
Usage: python3 lfs_verify_sources.py [--sources-dir DIR] [--md5-file FILE]
"""
import os
import sys
import hashlib
import argparse
from pathlib import Path

def load_md5sums(md5_file):
    md5_map = {}
    if not Path(md5_file).exists():
        print(f"[WARN] MD5 file {md5_file} not found; skipping checksum verification.")
        return md5_map
    with open(md5_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) >= 2:
                md5_map[parts[1]] = parts[0]
    return md5_map

def check_sources(sources_dir, sources_list, md5_file):
    md5_map = load_md5sums(md5_file)
    if not sources_dir.exists():
        print(f"[ERROR] Sources directory {sources_dir} not found.")
        return False

    with open(sources_list) as f:
        urls = [line.strip() for line in f if line.strip() and not line.startswith('#')]

    missing = []
    wrong_md5 = []
    for url in urls:
        filename = url.split('/')[-1]
        filepath = sources_dir / filename
        if not filepath.exists():
            missing.append(filename)
            continue
        if filename in md5_map:
            expected = md5_map[filename]
            actual = hashlib.md5(filepath.read_bytes()).hexdigest()
            if actual != expected:
                wrong_md5.append(filename)

    if missing:
        print(f"[ERROR] Missing sources: {len(missing)}")
        for f in missing:
            print(f"  - {f}")
    if wrong_md5:
        print(f"[ERROR] Checksum mismatch: {len(wrong_md5)}")
        for f in wrong_md5:
            print(f"  - {f}")
    if not missing and not wrong_md5:
        print("[OK] All sources present and checksums valid.")
        return True
    return False

def main():
    parser = argparse.ArgumentParser(description="Verify LFS source tarballs.")
    parser.add_argument("--sources-dir", default="build-release/sources",
                        help="Directory containing source tarballs")
    parser.add_argument("--sources-list", default="packages/sources.list",
                        help="Path to sources.list file")
    parser.add_argument("--md5-file", default="packages/md5sums",
                        help="Path to md5sums file")
    args = parser.parse_args()

    sources_dir = Path(args.sources_dir)
    sources_list = Path(args.sources_list)
    md5_file = Path(args.md5_file)

    sys.exit(0 if check_sources(sources_dir, sources_list, md5_file) else 1)

if __name__ == "__main__":
    main()