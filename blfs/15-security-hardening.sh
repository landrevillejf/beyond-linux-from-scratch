#!/bin/bash
# 15-security-hardening.sh
# Security hardening - Docker compatible minimal
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e
LFS=${LFS:-/output/image}
echo "[INFO] Security hardening (Docker mode)"
mkdir -pv "$LFS"/etc/sysctl.d
mkdir -pv "$LFS"/etc/security/limits.d
mkdir -pv "$LFS"/etc/profile.d
mkdir -pv "$LFS"/etc/cron.daily
mkdir -pv "$LFS"/etc/audit
mkdir -pv "$LFS"/usr/local/bin
mkdir -pv "$LFS"/usr/local/sbin
mkdir -pv "$LFS"/var/log
cat > "$LFS"/etc/sysctl.d/99-security.conf << 'SYSCONF'
# Security sysctl settings
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
net.ipv4.conf.all.rp_filter = 1
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
SYSCONF
echo "Security hardening skeleton created"
exit 0
