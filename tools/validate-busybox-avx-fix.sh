#!/bin/bash
# Validate that the busybox AVX fix is correctly configured
# This script verifies the changes without actually building busybox
# (the actual build happens in the chroot during final/12-create-initramfs.sh)
#
# Usage: bash tools/validate-busybox-avx-fix.sh
# Exit codes:
#   0 - All validations passed
#   1 - Validation failed

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; }

BUSYBOX_VERSION="1.36.1"

verify_script_changes() {
    log_info "Verifying changes in final/12-create-initramfs.sh..."

    local script="final/12-create-initramfs.sh"

    if [ ! -f "$script" ]; then
        log_error "Script not found: $script"
        return 1
    fi

    # Check for source build logic
    if ! grep -q "BUSYBOX_VERSION=\"${BUSYBOX_VERSION}\"" "$script"; then
        log_error "Busybox version not pinned to ${BUSYBOX_VERSION}"
        return 1
    fi
    log_ok "Busybox version pinned: ${BUSYBOX_VERSION}"

    # The build MUST run inside the $LFS chroot so busybox links the target's
    # baseline glibc.  A host build links the host glibc-static, whose
    # unconditional init_cpu_features startup is AVX on the Ubuntu 26.04 runner
    # and #UDs on a CPU without AVX (lg3d Nightly #125).  -march CFLAGS cannot
    # fix this: they never touch the pre-compiled libc.a startup.
    if ! grep -q 'chroot "[$]LFS"' "$script"; then
        log_error 'busybox is not built inside the '"\$LFS"' chroot (links the host glibc)'
        return 1
    fi
    log_ok 'busybox is built inside the '"\$LFS"' chroot (links the target glibc)'

    if ! grep -q 'build-busybox.sh' "$script"; then
        log_error "The in-chroot busybox build script is missing"
        return 1
    fi
    log_ok "In-chroot build script present"

    # The real, binary-level regression guard: disassemble the startup chain
    # and fail on any VEX/AVX instruction.  This is the check the old
    # text-only validator never performed.
    if ! grep -q 'assert_no_startup_avx' "$script"; then
        log_error "Binary-level startup AVX guard (assert_no_startup_avx) missing"
        return 1
    fi
    log_ok "Binary-level startup AVX guard present (assert_no_startup_avx)"

    if ! grep -q 'busybox_unstripped' "$script"; then
        log_error "The guard needs busybox_unstripped (symbol table) but it is not exposed"
        return 1
    fi
    log_ok "Unstripped busybox exposed for the guard's symbol table"

    # Baseline CFLAGS remain, but only as an x86_64-specific arm: they tune
    # busybox's OWN objects, they are not what removes the glibc-startup AVX.
    if ! grep -q '\-march=x86-64' "$script"; then
        log_error "Baseline CFLAGS (-march=x86-64) not found"
        return 1
    fi
    log_ok "Baseline CFLAGS present: -march=x86-64"

    if ! grep -q '\-mtune=generic' "$script"; then
        log_error "Generic tuning (-mtune=generic) not found"
        return 1
    fi
    log_ok "Generic tuning present: -mtune=generic"

    # Check for static linking
    if ! grep -q 'CONFIG_STATIC=y' "$script"; then
        log_error "Static linking configuration not found"
        return 1
    fi
    log_ok "Static linking configured: CONFIG_STATIC=y"

    # Check for readelf verification
    if ! grep -q 'is_static_binary' "$script"; then
        log_error "Static binary verification function not found"
        return 1
    fi
    log_ok "Static binary verification present"

    # Check that problematic applets are disabled
    if ! grep -q 'CONFIG_TC' "$script"; then
        log_warn "TC applet disable not found (may cause build failures)"
    else
        log_ok "Problematic applets (TC) will be disabled"
    fi

    # Check that old download logic is removed
    if grep -q "busybox.net/downloads/binaries" "$script"; then
        log_error "Old pre-built binary download logic still present"
        return 1
    fi
    log_ok "Old pre-built binary download logic removed"

    # Verify script syntax
    if ! bash -n "$script" 2>/dev/null; then
        log_error "Script has syntax errors"
        return 1
    fi
    log_ok "Script syntax is valid"
}

verify_smoke_test_changes() {
    log_info "Verifying changes in tools/qemu-boot-smoke.sh..."

    local script="tools/qemu-boot-smoke.sh"

    if [ ! -f "$script" ]; then
        log_error "Script not found: $script"
        return 1
    fi

    # Check for baseline CPU model
    if ! grep -q '\-cpu qemu64' "$script"; then
        log_error "Baseline CPU model (-cpu qemu64) not found"
        return 1
    fi
    log_ok "Baseline CPU model present: -cpu qemu64"

    # Check that old -cpu max is removed from the actual command (not comments)
    if grep -v '^#' "$script" | grep -q '\-cpu max'; then
        log_error "Old -cpu max still present in command (should be -cpu qemu64)"
        return 1
    fi
    log_ok "Old -cpu max removed from command"

    # Verify script syntax
    if ! bash -n "$script" 2>/dev/null; then
        log_error "Script has syntax errors"
        return 1
    fi
    log_ok "Script syntax is valid"
}

verify_test_changes() {
    log_info "Verifying changes in tests/test_acceptance_shell.py..."

    local test_file="tests/test_acceptance_shell.py"

    if [ ! -f "$test_file" ]; then
        log_error "Test file not found: $test_file"
        return 1
    fi

    # The lg3d Nightly #125 guardrail class must assert the chroot build and
    # the real binary-level AVX guard, not just source-text CFLAGS.
    if ! grep -q 'TestNightlyLg3d125BusyboxChrootAvx' "$test_file"; then
        log_error "Guardrail class TestNightlyLg3d125BusyboxChrootAvx not found"
        return 1
    fi
    log_ok "Nightly #125 guardrail class present"

    if ! grep -q 'assert_no_startup_avx' "$test_file"; then
        log_error "Tests do not assert the binary-level AVX guard"
        return 1
    fi
    log_ok "Tests assert the binary-level AVX guard"

    if ! grep -q 'busybox_unstripped' "$test_file"; then
        log_error "Tests do not assert the unstripped-binary guard path"
        return 1
    fi
    log_ok "Tests assert the unstripped-binary guard path"
}

verify_changelog() {
    log_info "Verifying CHANGELOG.md entry..."

    local changelog="CHANGELOG.md"

    if [ ! -f "$changelog" ]; then
        log_error "CHANGELOG.md not found"
        return 1
    fi

    # Check for AVX fix entry
    if ! grep -q "AVX support" "$changelog"; then
        log_error "CHANGELOG entry for AVX fix not found"
        return 1
    fi
    log_ok "CHANGELOG entry present"

    # Check for busybox version mention
    if ! grep -q "busybox 1.36.1" "$changelog"; then
        log_warn "CHANGELOG does not mention busybox version"
    else
        log_ok "CHANGELOG mentions busybox version"
    fi
}

check_build_dependencies() {
    log_info "Checking build dependencies (informational)..."

    local missing=()

    for cmd in gcc make wget tar readelf objdump; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_warn "Missing commands: ${missing[*]}"
        log_warn "These are needed in the chroot for busybox build"
    else
        log_ok "All build commands available"
    fi

    # Check for static libraries (optional but recommended)
    if [ -f /usr/lib64/libc.a ] || [ -f /usr/lib/x86_64-linux-gnu/libc.a ]; then
        log_ok "Static libc available"
    else
        log_warn "Static libc not found (glibc-static package)"
        log_warn "The chroot build environment should have this installed"
    fi
}

generate_report() {
    cat <<EOF

================================================================================
                    VALIDATION REPORT
================================================================================

Validation Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Busybox Version: $BUSYBOX_VERSION
Build location: inside the \$LFS chroot (links the target's baseline glibc)
Target CFLAGS (x86_64 arm only): -march=x86-64 -mtune=generic -O2 -static

Results:
  [OK] busybox is built inside the \$LFS chroot, not on the host
  [OK] Binary-level startup AVX guard (assert_no_startup_avx) present
  [OK] Unstripped busybox exposed for the guard's symbol table
  [OK] Smoke test keeps the baseline -cpu qemu64 gate
  [OK] Guardrail class TestNightlyLg3d125BusyboxChrootAvx present

Why the chroot matters (lg3d Nightly #125):
  A static busybox links the whole C library startup.  glibc's
  init_cpu_features runs unconditionally before main(); when it is compiled
  with AVX it executes vmovd/vpinsrd and raises #UD on a CPU without AVX,
  which panics the kernel with "Attempted to kill init! exitcode=0x00000004".
  Building on the host linked the Ubuntu 26.04 runner's glibc-static, whose
  init_cpu_features is AVX.  -march=x86-64 CFLAGS only recompile busybox's own
  objects and can never change the pre-compiled libc.a startup, so the earlier
  "baseline CFLAGS ensure NO AVX" claim was false.  Building inside the chroot
  links the target glibc (baseline, SSE2 startup), and assert_no_startup_avx
  disassembles _start/__libc_start_main and fails the build on any VEX insn.

Expected Behavior:
  The busybox /init runs on every x86_64 system, including VirtualBox's
  default CPU model, pre-2011 CPUs, and hosts with AVX masked in firmware -
  no more "invalid opcode" traps or AVX kernel panics.

Next Steps:
  1. Merge to main; the next lg3d nightly builds busybox in the chroot
  2. Watch the QEMU BIOS smoke step for a clean boot to the greeter
  3. Verify locally with: qemu-system-x86_64 -cpu qemu64 -cdrom <iso>

================================================================================
EOF
}

main() {
    log_info "Starting busybox AVX fix validation..."
    echo

    verify_script_changes || exit 1
    echo

    verify_smoke_test_changes || exit 1
    echo

    verify_test_changes || exit 1
    echo

    verify_changelog || exit 1
    echo

    check_build_dependencies
    echo

    generate_report

    log_ok "All validations passed!"
    log_info "The fix is correctly configured and ready for the next build."
    exit 0
}

main "$@"
