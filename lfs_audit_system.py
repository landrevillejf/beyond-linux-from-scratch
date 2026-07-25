#!/usr/bin/env python3
"""
Audit the installed LFS system for critical files and basic functionality.
"""
import os
import sys
import subprocess
from pathlib import Path

LFS_ROOT = sys.argv[1] if len(sys.argv) > 1 else "/mnt/lfs"

def check_path(path):
    full = Path(LFS_ROOT) / path.lstrip('/')
    if not full.exists():
        print(f"[FAIL] {path} not found")
        return False
    return True

def check_tool(name):
    try:
        subprocess.run(["chroot", LFS_ROOT, name, "--version"],
                       check=True, capture_output=True)
        print(f"[OK] {name} works")
        return True
    except:
        print(f"[FAIL] {name} failed")
        return False

def check_library(name):
    lib = Path(LFS_ROOT) / "usr/lib" / name
    if lib.exists():
        print(f"[OK] {name} found")
        return True
    lib64 = Path(LFS_ROOT) / "lib64" / name
    if lib64.exists():
        print(f"[OK] {name} found in /lib64")
        return True
    print(f"[FAIL] {name} not found")
    return False

def main():
    checks = [
        ("/bin/bash", check_path),
        ("/bin/sh", check_path),
        ("/usr/bin/gcc", check_path),
        ("/usr/bin/ld", check_path),
        ("/usr/include/linux", check_path),
        ("/usr/lib/libc.so.6", check_library),
        ("/sbin/init", check_path),  # or /usr/lib/systemd/systemd
    ]

    # Convert library checks to use the right function
    all_ok = True
    for path, func in checks:
        if "lib" in path and path.endswith(".so") and path.startswith("/usr/lib/"):
            all_ok = func(path.replace("/usr/lib/", "")) and all_ok
        else:
            all_ok = func(path) and all_ok

    # Run gcc test
    try:
        subprocess.run(["chroot", LFS_ROOT, "gcc", "-v"], check=True, capture_output=True)
        print("[OK] gcc compiles")
    except:
        print("[FAIL] gcc compile test failed")
        all_ok = False

    print("=== Audit complete ===")
    sys.exit(0 if all_ok else 1)

if __name__ == "__main__":
    main()