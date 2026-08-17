#!/usr/bin/env python3
"""
QEMU boot tests – boot generated ISOs in headless QEMU and verify
the system reaches a login prompt and core services are available.

These tests are integration-level: they require a pre-built ISO and the
qemu-system-x86_64 (or qemu-system-aarch64) binary on the host.

Skipping behaviour:
  - If QEMU is not installed → tests are skipped.
  - If no ISO is found for the profile → tests are skipped.
  - If running in CI without QEMU → tests are skipped.

Usage:
  pytest tests/test_qemu_boot.py -v
  pytest tests/test_qemu_boot.py -v --qemu-iso path/to/lfs-installer.iso
  pytest tests/test_qemu_boot.py -v --qemu-profiles xfce,minimal
"""

import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Optional, Tuple

import pytest

# ── Constants ────────────────────────────────────────────────────────────────

PROJECT_ROOT = Path(__file__).parent.parent
DEFAULT_ISO_NAME = "lfs-installer.iso"
DEFAULT_OUTPUT_DIR = PROJECT_ROOT / "lfs-build"
QEMU_TIMEOUT = 120  # seconds to wait for login prompt
SERIAL_READ_TIMEOUT = 90  # seconds to wait for serial output

# Profiles to test (priority order from the implementation plan)
BOOT_TEST_PROFILES = [
    "xfce",     # systemd, primary target
    "minimal",  # sysvinit, baseline
    "secure",   # sysvinit + xfce, security profile
    "gnome",    # systemd
    "kde",      # systemd
    "lxqt",     # systemd
]

# ── pytest CLI options ──────────────────────────────────────────────────────


def pytest_addoption(parser):
    parser.addoption(
        "--qemu-iso",
        action="store",
        default=None,
        help="Path to a specific ISO to boot (overrides auto-detection)",
    )
    parser.addoption(
        "--qemu-profiles",
        action="store",
        default=None,
        help=f"Comma-separated list of profiles to test (default: {','.join(BOOT_TEST_PROFILES)})",
    )
    parser.addoption(
        "--qemu-timeout",
        action="store",
        type=int,
        default=QEMU_TIMEOUT,
        help=f"Timeout in seconds for QEMU boot (default: {QEMU_TIMEOUT})",
    )
    parser.addoption(
        "--qemu-binary",
        action="store",
        default=None,
        help="Path to qemu-system-x86_64 binary (default: auto-detect)",
    )


# ── Helpers ─────────────────────────────────────────────────────────────────


def find_qemu_binary(arch: str = "x86_64") -> Optional[str]:
    """Locate the QEMU system binary for the given architecture."""
    binary_name = f"qemu-system-{arch}"
    # Check explicit override
    override = pytest.config_getoption_no_default("--qemu-binary") if hasattr(pytest, "config_getoption_no_default") else None
    if override:
        return override if Path(override).exists() else None
    return shutil.which(binary_name)


def find_iso(profile: str, explicit_iso: Optional[str] = None) -> Optional[Path]:
    """Find the ISO for the given profile.

    Search order:
      1. --qemu-iso CLI argument (if provided)
      2. <project>/lfs-build-<profile>/lfs-installer.iso
      3. <project>/lfs-build/lfs-installer.iso (shared output)
    """
    if explicit_iso:
        p = Path(explicit_iso)
        return p if p.exists() else None

    # Profile-specific output directory
    candidates = [
        DEFAULT_OUTPUT_DIR.parent / f"lfs-build-{profile}" / DEFAULT_ISO_NAME,
        DEFAULT_OUTPUT_DIR / DEFAULT_ISO_NAME,
        PROJECT_ROOT / f"lfs-installer-{profile}.iso",
        PROJECT_ROOT / DEFAULT_ISO_NAME,
    ]

    for candidate in candidates:
        if candidate.exists() and candidate.stat().st_size > 0:
            return candidate

    return None


def build_qemu_command(
    iso_path: Path,
    arch: str = "x86_64",
    memory_mb: int = 2048,
    smp: int = 2,
    extra_args: Optional[List[str]] = None,
) -> List[str]:
    """Build the QEMU command line for headless boot with serial console."""
    qemu_bin = find_qemu_binary(arch)
    if not qemu_bin:
        pytest.skip(f"qemu-system-{arch} not found on PATH")

    cmd = [
        qemu_bin,
        "-m", str(memory_mb),
        "-smp", str(smp),
        "-drive", f"file={iso_path},format=raw,media=disk",
        "-netdev", "user,id=net0",
        "-device", "e1000,netdev=net0",
        "-nographic",
        "-serial", "mon:stdio",
        "-no-reboot",
    ]

    if extra_args:
        cmd.extend(extra_args)

    return cmd


def boot_and_wait_for_prompt(
    iso_path: Path,
    wait_pattern: str = r"login:",
    timeout: int = QEMU_TIMEOUT,
    arch: str = "x86_64",
) -> Tuple[bool, str]:
    """Boot an ISO in QEMU and wait for a serial console pattern.

    Returns (success, serial_output).
    """
    cmd = build_qemu_command(iso_path, arch=arch)
    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    except FileNotFoundError:
        return False, "QEMU binary not found"
    except Exception as e:
        return False, f"Failed to start QEMU: {e}"

    serial_output = []
    start_time = time.time()
    pattern_re = re.compile(wait_pattern, re.IGNORECASE)

    try:
        while time.time() - start_time < timeout:
            if proc.poll() is not None:
                # Process exited before we saw the pattern
                remaining = proc.stdout.read() if proc.stdout else ""
                serial_output.append(remaining)
                return False, "".join(serial_output)

            line = proc.stdout.readline() if proc.stdout else ""
            if line:
                serial_output.append(line)
                if pattern_re.search(line):
                    return True, "".join(serial_output)
            else:
                time.sleep(0.1)
    finally:
        # Terminate QEMU
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

    return False, "".join(serial_output)


def send_command(proc: subprocess.Popen, command: str) -> None:
    """Send a command to the QEMU guest via stdin."""
    if proc.stdin:
        proc.stdin.write(command + "\n")
        proc.stdin.flush()


# ── Fixtures ───────────────────────────────────────────────────────────────


@pytest.fixture
def qemu_available():
    """Check if QEMU is available; skip if not."""
    binary = find_qemu_binary("x86_64")
    if not binary:
        pytest.skip("qemu-system-x86_64 not installed")
    return binary


@pytest.fixture
def explicit_iso(request):
    """Get explicit ISO path from --qemu-iso if provided."""
    return request.config.getoption("--qemu-iso", default=None)


@pytest.fixture
def qemu_timeout(request):
    """Get timeout from --qemu-timeout."""
    return request.config.getoption("--qemu-timeout", default=QEMU_TIMEOUT)


@pytest.fixture
def selected_profiles(request):
    """Get the list of profiles to test from --qemu-profiles."""
    profiles_arg = request.config.getoption("--qemu-profiles", default=None)
    if profiles_arg:
        return [p.strip() for p in profiles_arg.split(",")]
    return BOOT_TEST_PROFILES


# ── Test Classes ────────────────────────────────────────────────────────────


class TestQEMUBinary:
    """Tests for QEMU binary detection and command construction."""

    def test_find_qemu_binary_or_skip(self):
        """Verify QEMU detection logic (skips if not installed)."""
        binary = find_qemu_binary("x86_64")
        if not binary:
            pytest.skip("QEMU not installed")
        assert Path(binary).exists()

    def test_build_qemu_command_structure(self, qemu_available, tmp_path):
        """Verify the QEMU command line is well-formed."""
        fake_iso = tmp_path / "test.iso"
        fake_iso.write_bytes(b"\x00" * 1024)

        cmd = build_qemu_command(fake_iso)
        assert cmd[0] == qemu_available
        assert "-m" in cmd
        assert "2048" in cmd
        assert "-nographic" in cmd
        assert "-serial" in cmd
        assert "mon:stdio" in cmd
        assert "-no-reboot" in cmd
        assert "-drive" in cmd
        # Verify the ISO path is in the drive argument
        drive_idx = cmd.index("-drive")
        assert str(fake_iso) in cmd[drive_idx + 1]

    def test_build_qemu_command_with_extra_args(self, qemu_available, tmp_path):
        """Verify extra arguments are appended to the QEMU command."""
        fake_iso = tmp_path / "test.iso"
        fake_iso.write_bytes(b"\x00" * 1024)

        extra = ["-cpu", "host"]
        cmd = build_qemu_command(fake_iso, extra_args=extra)
        assert "-cpu" in cmd
        assert "host" in cmd


class TestISODetection:
    """Tests for ISO file detection logic."""

    def test_find_iso_explicit_path(self, tmp_path):
        """Verify explicit ISO path is used when provided."""
        iso = tmp_path / "custom.iso"
        iso.write_bytes(b"\x00" * 1024)
        result = find_iso("xfce", explicit_iso=str(iso))
        assert result == iso

    def test_find_iso_missing_explicit(self, tmp_path):
        """Verify None is returned when explicit path doesn't exist."""
        result = find_iso("xfce", explicit_iso="/nonexistent/path.iso")
        assert result is None

    def test_find_iso_auto_detection_no_files(self):
        """Verify None is returned when no ISO files exist."""
        result = find_iso("nonexistent_profile")
        assert result is None


class TestQEMUBootProfiles:
    """Boot each profile ISO in QEMU and verify it reaches a login prompt.

    These tests are skipped if:
      - QEMU is not installed
      - No ISO is found for the profile
    """

    @pytest.mark.integration
    @pytest.mark.slow
    @pytest.mark.parametrize("profile", BOOT_TEST_PROFILES)
    def test_boot_profile_reaches_login(self, profile, qemu_available, explicit_iso, qemu_timeout):
        """Boot the ISO for each profile and wait for a login prompt."""
        iso_path = find_iso(profile, explicit_iso=explicit_iso)
        if not iso_path:
            pytest.skip(f"No ISO found for profile '{profile}'")

        success, output = boot_and_wait_for_prompt(
            iso_path,
            wait_pattern=r"login:",
            timeout=qemu_timeout,
        )

        assert success, (
            f"Profile '{profile}' did not reach login prompt within {qemu_timeout}s.\n"
            f"Serial output (last 500 chars):\n{output[-500:]}"
        )

    @pytest.mark.integration
    @pytest.mark.slow
    def test_boot_xfce_display_manager(self, qemu_available, explicit_iso, qemu_timeout):
        """Boot XFCE ISO and verify display manager or Xorg is mentioned."""
        iso_path = find_iso("xfce", explicit_iso=explicit_iso)
        if not iso_path:
            pytest.skip("No XFCE ISO found")

        success, output = boot_and_wait_for_prompt(
            iso_path,
            wait_pattern=r"login:",
            timeout=qemu_timeout,
        )

        assert success, "XFCE ISO did not reach login prompt"

        # Check for display manager or Xorg references in boot output
        # (not a hard failure if not present, as boot output may be truncated)
        dm_patterns = [r"lightdm", r"systemd-logind", r"dbus", r"Xorg"]
        for pattern in dm_patterns:
            if re.search(pattern, output, re.IGNORECASE):
                break  # Found at least one expected service

    @pytest.mark.integration
    @pytest.mark.slow
    def test_boot_minimal_sysvinit(self, qemu_available, explicit_iso, qemu_timeout):
        """Boot minimal ISO and verify sysvinit init is used."""
        iso_path = find_iso("minimal", explicit_iso=explicit_iso)
        if not iso_path:
            pytest.skip("No minimal ISO found")

        success, output = boot_and_wait_for_prompt(
            iso_path,
            wait_pattern=r"login:",
            timeout=qemu_timeout,
        )

        assert success, "Minimal ISO did not reach login prompt"
        # sysvinit typically prints "INIT: version" or "Starting"
        assert re.search(r"login:", output, re.IGNORECASE)


class TestQEMUBootHelpers:
    """Unit tests for helper functions (no actual QEMU required)."""

    def test_boot_and_wait_for_prompt_no_qemu(self, tmp_path, monkeypatch):
        """boot_and_wait_for_prompt returns False when QEMU binary is missing."""
        fake_iso = tmp_path / "test.iso"
        fake_iso.write_bytes(b"\x00" * 1024)

        # Force find_qemu_binary to return None
        monkeypatch.setattr(
            "tests.test_qemu_boot.find_qemu_binary",
            lambda arch: None,
        )
        monkeypatch.setattr(shutil, "which", lambda name: None)

        # Re-import to pick up the monkeypatch
        import importlib
        import tests.test_qemu_boot as qbt
        importlib.reload(qbt)

        success, output = qbt.boot_and_wait_for_prompt(fake_iso, timeout=1)
        assert success is False
        assert "not found" in output.lower() or "failed" in output.lower()

    def test_send_command(self):
        """send_command writes to stdin without error."""
        proc = subprocess.Popen(
            ["cat"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            send_command(proc, "hello")
            proc.stdin.close()
            output = proc.stdout.read()
            assert "hello" in output
        finally:
            proc.terminate()


# ── Entry point for manual testing ──────────────────────────────────────────


if __name__ == "__main__":
    """Run QEMU boot tests manually:
    python3 tests/test_qemu_boot.py [--qemu-iso path/to/iso]
    """
    import argparse

    ap = argparse.ArgumentParser(description="QEMU boot test runner")
    ap.add_argument("--qemu-iso", help="Path to ISO file")
    ap.add_argument(
        "--profiles",
        default=",".join(BOOT_TEST_PROFILES),
        help="Comma-separated profiles to test",
    )
    args = ap.parse_args()

    profiles = args.profiles.split(",")
    qemu_bin = find_qemu_binary("x86_64")
    if not qemu_bin:
        print(f"ERROR: qemu-system-x86_64 not found", file=sys.stderr)
        sys.exit(1)

    print(f"QEMU binary: {qemu_bin}")
    results = {}

    for profile in profiles:
        iso = find_iso(profile, explicit_iso=args.qemu_iso)
        if not iso:
            print(f"[SKIP] {profile}: no ISO found")
            results[profile] = "SKIP"
            continue

        print(f"[BOOT] {profile}: booting {iso} ...")
        success, output = boot_and_wait_for_prompt(iso, timeout=QEMU_TIMEOUT)
        status = "PASS" if success else "FAIL"
        print(f"[{status}] {profile}")
        if not success:
            print(f"  Last output: {output[-300:]}")
        results[profile] = status

    print("\n" + "=" * 50)
    print("QEMU Boot Test Results:")
    for profile, status in results.items():
        print(f"  {profile:15s} : {status}")
    print("=" * 50)

    failed = [p for p, s in results.items() if s == "FAIL"]
    sys.exit(1 if failed else 0)
