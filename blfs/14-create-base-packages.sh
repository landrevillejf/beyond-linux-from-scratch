#!/bin/bash
# Base packages - Docker compatible minimal
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e
LFS=${LFS:-/output/image}
echo "[INFO] Creating base packages structure (Docker mode)"
mkdir -pv "$LFS"/var/cache/lpm
mkdir -pv "$LFS"/var/lib/lpm
mkdir -pv "$LFS"/usr/share/lpm
echo "# Base packages" > "$LFS"/usr/share/lpm/base-packages.list
echo "[SUCCESS] Base packages skeleton created"
exit 0
