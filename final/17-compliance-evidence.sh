#!/bin/bash
# final/17-compliance-evidence.sh – Best-effort compliance evidence (Phase 7)
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# Runs the audit scanners present in the finished rootfs -- lynis (built by
# blfs/32 under security_hardening) and, when an operator built it, openscap
# against scap-security-guide content -- and records what ran into a small JSON
# manifest so a reviewer can tell "no scanner present" from "scanner ran".
# Reports land inside the rootfs at /var/log/compliance and ship with the image.
#
# This stage NEVER fails the build: evidence generation is best-effort and the
# hard gate lives in final/16-validate-build.sh.  It is scheduled only when
# security.compliance.profiles is non-empty (opt-in), so the default build never
# runs it, and the scanners audit through a chroot only when run as root.
set -euo pipefail

LFS="${LFS:-/mnt/lfs}"
if [ -z "$LFS" ] || [ ! -d "$LFS" ]; then
    echo "[ERROR] LFS directory '$LFS' not found"
    exit 1
fi

PROFILES="${LFS_CONFIG_SECURITY_COMPLIANCE_PROFILES:-}"

echo "========================================="
echo "Compliance evidence generation for $LFS"
echo "  requested profiles: ${PROFILES:-<none>}"
echo "========================================="

# Evidence lives in the rootfs when it is writable; a root-owned rootfs and an
# unprivileged build user fall back to a host-side sibling directory so the
# manifest is still captured.
EVIDENCE_DIR="$LFS/var/log/compliance"
if ! mkdir -p "$EVIDENCE_DIR" 2>/dev/null; then
    EVIDENCE_DIR="$(dirname "$LFS")/compliance-evidence"
    mkdir -p "$EVIDENCE_DIR"
fi

MANIFEST="$EVIDENCE_DIR/compliance-evidence.json"
printf '{\n  "profiles": "%s",\n  "runs": [' "$PROFILES" >"$MANIFEST"
first_run=true

record_run() {
    # $1 = tool, $2 = status, $3 = artifact path (may be empty)
    if [ "$first_run" = true ]; then
        first_run=false
        printf '\n' >>"$MANIFEST"
    else
        printf ',\n' >>"$MANIFEST"
    fi
    printf '    {"tool": "%s", "status": "%s", "artifact": "%s"}' \
        "$1" "$2" "$3" >>"$MANIFEST"
}

chroot_scan() {
    # Run a scanner inside the rootfs.  $1 is the absolute in-rootfs binary
    # path (used for the presence check and as argv[0]); the rest are its
    # arguments.  Returns non-zero when it cannot run, so callers record a
    # skip rather than an empty report.
    local bin="$1"
    shift
    if [ "$(id -u)" -ne 0 ]; then
        echo "  [SKIP] not root; cannot chroot to run $(basename "$bin")"
        return 1
    fi
    if [ ! -x "$LFS$bin" ] && [ ! -L "$LFS$bin" ]; then
        echo "  [SKIP] $(basename "$bin") not present in the rootfs"
        return 1
    fi
    mkdir -p "$LFS/var/log/compliance" 2>/dev/null || true
    mount --bind /dev "$LFS/dev" 2>/dev/null || true
    mount --bind /proc "$LFS/proc" 2>/dev/null || true
    mount --bind /sys "$LFS/sys" 2>/dev/null || true
    local rc=0
    chroot "$LFS" "$bin" "$@" >/dev/null 2>&1 || rc=$?
    umount "$LFS/dev" 2>/dev/null || true
    umount "$LFS/proc" 2>/dev/null || true
    umount "$LFS/sys" 2>/dev/null || true
    return $rc
}

# ---- lynis (built by blfs/32 under security_hardening) ------------------
echo ""
echo "--- lynis audit ---"
if chroot_scan /usr/local/bin/lynis audit system --quick --no-colors \
    --report-file /var/log/compliance/lynis-report.dat; then
    record_run "lynis" "ok" "/var/log/compliance/lynis-report.dat"
else
    record_run "lynis" "skipped" ""
fi

# ---- openscap (operator opt-in build; not downloaded by default) --------
echo ""
echo "--- openscap xccdf eval ---"
if [ -x "$LFS/usr/bin/oscap" ] || [ -L "$LFS/usr/bin/oscap" ]; then
    IFS=',' read -r -a req_profiles <<<"$PROFILES"
    for prof in "${req_profiles[@]}"; do
        [ -n "$prof" ] || continue
        # Best-effort: point oscap at the scap-security-guide datastream and
        # let it resolve the profile id.  An unsupported token fails only its
        # own run; the stage as a whole never aborts.
        if chroot_scan /usr/bin/oscap xccdf eval --profile "$prof" \
            --results "/var/log/compliance/oscap-${prof}-results.xml" \
            --report "/var/log/compliance/oscap-${prof}-report.html" \
            /usr/share/xml/scap/ssg/content/ssg-linux-ds.xml; then
            record_run "oscap:$prof" "ok" \
                "/var/log/compliance/oscap-${prof}-report.html"
        else
            record_run "oscap:$prof" "skipped" ""
        fi
    done
else
    echo "  [SKIP] oscap not present (openscap is an operator opt-in build)"
    record_run "oscap" "absent" ""
fi

printf '\n  ]\n}\n' >>"$MANIFEST"

echo ""
echo "Compliance evidence manifest: $MANIFEST"
echo "[SUCCESS] compliance-evidence stage complete (best-effort)"
exit 0
