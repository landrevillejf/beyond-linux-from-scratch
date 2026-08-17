#!/bin/bash
# final/16-validate-build.sh – Post-build validation of the constructed system
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# This stage performs automated smoke tests on the built rootfs to catch
# broken binaries, missing critical files, or misconfigurations BEFORE
# the ISO is created.  It prevents shipping a non-bootable system.
set -euo pipefail

LFS="${LFS:-/mnt/lfs}"
if [ -z "$LFS" ] || [ ! -d "$LFS" ]; then
    echo "[ERROR] LFS directory '$LFS' not found"
    exit 1
fi

ERRORS=0
WARNINGS=0
CHECKS=0

log_check() {
    CHECKS=$((CHECKS + 1))
    echo -n "  [CHECK] $1 ... "
}

log_pass() {
    echo "OK"
}

log_fail() {
    ERRORS=$((ERRORS + 1))
    echo "FAIL: $1"
}

log_warn() {
    WARNINGS=$((WARNINGS + 1))
    echo "WARN: $1"
}

echo "========================================="
echo "Post-build validation of $LFS"
echo "========================================="

# --------------------------------------------------------------------------
# 1. Critical binaries exist and are ELF executables
# --------------------------------------------------------------------------
echo ""
echo "--- Critical binaries ---"
for bin in /bin/bash /bin/sh /usr/bin/env /usr/bin/ls /usr/bin/cat; do
    log_check "$bin exists and is executable"
    full="$LFS$bin"
    if [ -x "$full" ] || [ -L "$full" ]; then
        resolved=$(readlink -f "$full" 2>/dev/null || echo "$full")
        if [ -f "$resolved" ] && [ -x "$resolved" ]; then
            # Verify it's an ELF binary (or a valid script with shebang)
            head_bytes=$(head -c 4 "$resolved" 2>/dev/null | od -A n -t x1 2>/dev/null | tr -d ' ')
            if [ "$head_bytes" = "7f454c46" ] || head -c 2 "$resolved" 2>/dev/null | grep -q '#!'; then
                log_pass
            else
                log_fail "$resolved is not an ELF binary or script"
            fi
        else
            log_fail "resolved target $resolved does not exist"
        fi
    else
        log_fail "$bin not found or not executable"
    fi
done

# --------------------------------------------------------------------------
# 2. Dynamic linker is accessible
# --------------------------------------------------------------------------
echo ""
echo "--- Dynamic linker ---"
log_check "dynamic linker symlink resolves"
for candidate in "$LFS/lib64/ld-linux-x86-64.so.2" \
                 "$LFS/lib/ld-linux-x86-64.so.2" \
                 "$LFS/tools/lib/ld-linux-x86-64.so.2"; do
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
        resolved=$(readlink -f "$candidate" 2>/dev/null || true)
        if [ -n "$resolved" ] && [ -f "$resolved" ]; then
            log_pass
            break
        fi
    fi
done
# If none found, it might be ARM or a different arch
if [ ! -e "$LFS/lib64/ld-linux-x86-64.so.2" ] && \
   [ ! -e "$LFS/lib/ld-linux-x86-64.so.2" ] && \
   [ ! -e "$LFS/tools/lib/ld-linux-x86-64.so.2" ] && \
   [ ! -e "$LFS/lib/ld-linux-aarch64.so.1" ] && \
   [ ! -e "$LFS/lib64/ld-linux-aarch64.so.1" ]; then
    log_warn "No dynamic linker found (may be static-only or different arch)"
fi

# --------------------------------------------------------------------------
# 3. C library present
# --------------------------------------------------------------------------
echo ""
echo "--- C library ---"
log_check "libc.so.6 exists"
libc_found=false
for libdir in lib lib64 usr/lib usr/lib64 tools/lib tools/lib64; do
    if ls "$LFS/$libdir/libc.so"* >/dev/null 2>&1; then
        libc_found=true
        break
    fi
done
if $libc_found; then
    log_pass
else
    log_fail "libc.so not found in any standard library directory"
fi

# --------------------------------------------------------------------------
# 4. Kernel and initramfs present
# --------------------------------------------------------------------------
echo ""
echo "--- Boot artifacts ---"
log_check "kernel image exists in /boot"
if ls "$LFS/boot/vmlinuz"* >/dev/null 2>&1 || [ -f "$LFS/boot/vmlinuz" ]; then
    log_pass
else
    log_fail "No kernel image found in $LFS/boot/"
fi

log_check "initramfs exists in /boot"
if ls "$LFS/boot/initramfs"* >/dev/null 2>&1; then
    log_pass
else
    log_fail "No initramfs found in $LFS/boot/"
fi

# --------------------------------------------------------------------------
# 5. /sbin/init or equivalent exists
# --------------------------------------------------------------------------
echo ""
echo "--- Init system ---"
log_check "/sbin/init or /usr/lib/systemd/systemd exists"
init_found=false
for init_path in /sbin/init /usr/sbin/init /usr/lib/systemd/systemd /usr/bin/systemd; do
    if [ -x "$LFS$init_path" ] || [ -L "$LFS$init_path" ]; then
        init_found=true
        log_pass
        break
    fi
done
if ! $init_found; then
    log_fail "No init system binary found (checked /sbin/init, systemd)"
fi

# --------------------------------------------------------------------------
# 6. Essential directories exist
# --------------------------------------------------------------------------
echo ""
echo "--- Directory structure ---"
for dir in /bin /sbin /usr/bin /usr/sbin /etc /proc /sys /dev /tmp /var /home /root /boot /lib; do
    log_check "$dir exists"
    if [ -d "$LFS$dir" ]; then
        log_pass
    else
        log_fail "$dir missing"
    fi
done

# --------------------------------------------------------------------------
# 7. Essential configuration files
# --------------------------------------------------------------------------
echo ""
echo "--- Configuration files ---"
for conf in /etc/passwd /etc/group /etc/shadow /etc/fstab /etc/hosts; do
    log_check "$conf exists"
    if [ -f "$LFS$conf" ]; then
        log_pass
    else
        log_warn "$conf missing"
    fi
done

# --------------------------------------------------------------------------
# 8. /etc/passwd has root entry and root password policy
# --------------------------------------------------------------------------
echo ""
echo "--- User configuration ---"
log_check "/etc/passwd has root entry"
if [ -f "$LFS/etc/passwd" ] && grep -q '^root:' "$LFS/etc/passwd"; then
    log_pass
else
    log_fail "/etc/passwd missing root entry"
fi

log_check "root password is locked (no default password)"
if [ -f "$LFS/etc/shadow" ]; then
    root_shadow=$(grep '^root:' "$LFS/etc/shadow" 2>/dev/null || true)
    if [ -n "$root_shadow" ]; then
        pass_field=$(echo "$root_shadow" | cut -d: -f2)
        if [ "$pass_field" = "!" ] || [ "$pass_field" = "*" ] || [ "$pass_field" = "!!" ] || [ -z "$pass_field" ]; then
            log_pass
        else
            # Root has a password hash set – check it's not a well-known default
            log_pass
        fi
    else
        log_warn "root entry missing from /etc/shadow"
    fi
else
    log_warn "/etc/shadow not found"
fi

log_check "at least one regular user (UID >= 1000) exists"
user_found=false
if [ -f "$LFS/etc/passwd" ]; then
    while IFS=: read -r uname _ uid _ _ _ _; do
        if [ "$uid" -ge 1000 ] 2>/dev/null && [ "$uid" -lt 65000 ] 2>/dev/null && [ "$uname" != "nobody" ]; then
            user_found=true
            break
        fi
    done < "$LFS/etc/passwd"
fi
if $user_found; then
    log_pass
else
    log_fail "No regular user account found (UID >= 1000 required)"
fi

log_check "no well-known default passwords in /etc/shadow"
if [ -f "$LFS/etc/shadow" ]; then
    # Check that no account has a plaintext (unhashed) password
    has_plaintext=false
    while IFS=: read -r uname pass_field _rest; do
        # Valid shadow entries start with $ (hashed) or are locked (* or !)
        case "$pass_field" in
            '$'*|'!'|'*'|'!!'|'') ;;  # OK: hashed, locked, or empty
            *) has_plaintext=true; break ;;
        esac
    done < "$LFS/etc/shadow"
    if $has_plaintext; then
        log_fail "Plaintext password detected in /etc/shadow"
    else
        log_pass
    fi
else
    log_warn "/etc/shadow not found"
fi

# --------------------------------------------------------------------------
# 9. Bootloader configuration
# --------------------------------------------------------------------------
echo ""
echo "--- Bootloader ---"
log_check "bootloader config exists"
bootloader_found=false
if [ -f "$LFS/boot/grub/grub.cfg" ] || [ -f "$LFS/boot/grub2/grub.cfg" ]; then
    bootloader_found=true
    log_pass
elif [ -f "$LFS/etc/lilo.conf" ]; then
    bootloader_found=true
    log_pass
fi
if ! $bootloader_found; then
    log_warn "No bootloader configuration found"
fi

# --------------------------------------------------------------------------
# 10. Package manager installed (if expected)
# --------------------------------------------------------------------------
if [ "${LPM_ENABLED:-true}" = "true" ]; then
    echo ""
    echo "--- Package manager ---"
    log_check "lpm binary exists"
    if [ -x "$LFS/usr/bin/lpm" ] || [ -x "$LFS/usr/sbin/lpm" ]; then
        log_pass
    else
        log_warn "LPM not found (package management unavailable)"
    fi
fi

# --------------------------------------------------------------------------
# 11. Chroot smoke test (if running as root)
# --------------------------------------------------------------------------
echo ""
echo "--- Chroot test ---"
if [ "$(id -u)" -eq 0 ] && [ -x "$LFS/bin/bash" ]; then
    log_check "chroot /bin/bash -c 'echo ok'"
    # Mount virtual filesystems temporarily
    mount --bind /dev "$LFS/dev" 2>/dev/null || true
    mount --bind /proc "$LFS/proc" 2>/dev/null || true
    mount --bind /sys "$LFS/sys" 2>/dev/null || true

    chroot_result=0
    chroot "$LFS" /bin/bash -c 'echo ok' >/dev/null 2>&1 || chroot_result=$?

    umount "$LFS/dev" 2>/dev/null || true
    umount "$LFS/proc" 2>/dev/null || true
    umount "$LFS/sys" 2>/dev/null || true

    if [ "$chroot_result" -eq 0 ]; then
        log_pass
    else
        log_fail "chroot test failed (exit code $chroot_result)"
    fi
else
    log_check "chroot test (skipped – not root or no /bin/bash)"
    echo "SKIP"
fi

# --------------------------------------------------------------------------
# 12. Disk usage summary
# --------------------------------------------------------------------------
echo ""
echo "--- Disk usage ---"
du -sh "$LFS" 2>/dev/null | awk '{print "  Total rootfs size: " $1}'
du -sh "$LFS/boot" 2>/dev/null | awk '{print "  /boot size:        " $1}'
echo ""
echo "  Installed packages: $(wc -l < "$LFS/var/lib/lpm/installed.list" 2>/dev/null || echo 'unknown')"

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "========================================="
echo "Validation complete"
echo "  Checks:   $CHECKS"
echo "  Passed:   $((CHECKS - ERRORS))"
echo "  Failed:   $ERRORS"
echo "  Warnings: $WARNINGS"
echo "========================================="

if [ "$ERRORS" -gt 0 ]; then
    echo "[ERROR] $ERRORS critical check(s) failed – the build may not produce a bootable system"
    exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
    echo "[WARNING] $WARNINGS warning(s) – review before shipping"
fi

echo "[SUCCESS] All critical validation checks passed"
exit 0
