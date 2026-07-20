#!/bin/bash
# Package manager - Docker compatible minimal
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e
LFS=${LFS:-/output/image}
echo "[INFO] Creating package manager structure (Docker mode)"
mkdir -pv "$LFS"/var/lib/lpm
mkdir -pv "$LFS"/etc/lpm/repos.d
cat > "$LFS"/etc/lpm/repos.d/official.repo << 'REPO'
[official]
name=Official LFS Repository
baseurl=https://www.linuxfromscratch.org/lfs/repo
enabled=1
gpgcheck=0
REPO
echo "LPM_VERSION=1.0.0" > "$LFS"/var/lib/lpm/version
echo "[SUCCESS] Package manager skeleton created"
exit 0
