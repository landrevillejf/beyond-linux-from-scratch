#!/usr/bin/env python3
"""
Tests USB avec mocks complets - Version FINALE CORRECTE
"""

import logging
import subprocess
from pathlib import Path
from unittest.mock import patch, MagicMock

import pytest

from builder import USBWriter


class TestUSBWriterFullCoverage:
    """Tests USBWriter avec mocks - Couverture à 100%"""

    @staticmethod
    @pytest.fixture
    def iso_file(tmp_path):
        """Create a temporary fake ISO file for testing."""
        iso = tmp_path / "test.iso"
        iso.write_text("FAKE ISO CONTENT")
        return iso

    @pytest.fixture
    def logger(self):
        return logging.getLogger('test')

    # ========================================================================
    # Tests Linux
    # ========================================================================

    @staticmethod
    def test_write_iso_linux_success(iso_file, logger):
        """Test successful ISO write on Linux."""
        with patch('builtins.input', return_value='YES'):
            with patch('platform.system', return_value='Linux'):
                with patch('subprocess.run') as mock_run:
                    mock_run.return_value = MagicMock(returncode=0)
                    result = USBWriter.write_iso(iso_file, "/dev/sdb", logger)
                    assert result is True

    @staticmethod
    def test_write_iso_linux_dd_fails(iso_file, logger):
        with patch('builtins.input', return_value='YES'):
            with patch('platform.system', return_value='Linux'):
                with patch('subprocess.run') as mock_run:
                    # Simuler que umount OK, dd échoue
                    mock_run.side_effect = [
                        MagicMock(returncode=0),
                        subprocess.CalledProcessError(1, 'dd'),
                    ]
                    result = USBWriter.write_iso(iso_file, "/dev/sdb", logger)
                    assert result is False

    def test_write_iso_linux_sync_fails(self, iso_file, logger):
        """Test ISO write failure when sync command fails on Linux."""
        with patch('builtins.input', return_value='YES'):
            with patch('platform.system', return_value='Linux'):
                with patch('subprocess.run') as mock_run:
                    def mock_run_side_effect(cmd, *args, **kwargs):
                        if 'sync' in cmd:
                            raise subprocess.CalledProcessError(1, 'sync')
                        return MagicMock(returncode=0)
                    mock_run.side_effect = mock_run_side_effect
                    result = USBWriter.write_iso(iso_file, "/dev/sdb", logger)
                    assert result is False

    # ========================================================================
    # Tests macOS
    # ========================================================================

    def test_write_iso_darwin_success(self, iso_file, logger):
        """Test successful ISO write on macOS (Darwin)."""
        with patch('builtins.input', return_value='YES'):
            with patch('platform.system', return_value='Darwin'):
                with patch('subprocess.run') as mock_run:
                    mock_run.return_value = MagicMock(returncode=0)
                    result = USBWriter.write_iso(iso_file, "disk2", logger)
                    assert result is True

    @staticmethod
    def test_write_iso_darwin_dd_fails(iso_file, logger):
        """Test ISO write failure when dd command fails on macOS."""
        with patch('builtins.input', return_value='YES'):
            with patch('platform.system', return_value='Darwin'):
                with patch('subprocess.run', side_effect=subprocess.CalledProcessError(1, 'dd')):
                    result = USBWriter.write_iso(iso_file, "disk2", logger)
                    assert result is False

    # ========================================================================
    # Tests Windows
    # ========================================================================

    @staticmethod
    def test_write_iso_windows_not_supported(iso_file, logger):
        with patch('platform.system', return_value='Windows'):
            with patch('builtins.input', return_value='YES'):
                result = USBWriter.write_iso(iso_file, "E:", logger)
                assert result is False

    # ========================================================================
    # Tests validation
    # ========================================================================

    def test_write_iso_file_not_found(self, tmp_path, logger):
        """Test ISO write failure when the ISO file does not exist."""
        iso_path = tmp_path / "nonexistent.iso"
        result = USBWriter.write_iso(iso_path, "/dev/sdb", logger)
        assert result is False

    @staticmethod
    def test_write_iso_cancelled_by_user(iso_file, logger):
        """Test that ISO write is cancelled when user does not confirm."""
        with patch('builtins.input', return_value='NO'):
            result = USBWriter.write_iso(iso_file, "/dev/sdb", logger)
            assert result is False

    def test_write_iso_permission_denied(self, iso_file, logger):
        with patch('builtins.input', return_value='YES'):
            with patch('platform.system', return_value='Linux'):
                with patch('subprocess.run') as mock_run:
                    mock_run.side_effect = [
                        MagicMock(returncode=0),
                        subprocess.CalledProcessError(13, 'dd'),
                    ]
                    result = USBWriter.write_iso(iso_file, "/dev/sdb", logger)
                    assert result is False

    @staticmethod
    def test_write_iso_device_busy(iso_file, logger):
        with patch('builtins.input', return_value='YES'):
            with patch('platform.system', return_value='Linux'):
                with patch('subprocess.run') as mock_run:
                    mock_run.side_effect = [
                        MagicMock(returncode=0),
                        subprocess.CalledProcessError(16, 'dd'),
                    ]
                    result = USBWriter.write_iso(iso_file, "/dev/sdb", logger)
                    assert result is False

    # ========================================================================
    # Tests list_devices
    # ========================================================================

    @staticmethod
    def test_list_devices_linux_empty():
        with patch('platform.system', return_value='Linux'):
            with patch('subprocess.run') as mock_run:
                mock_run.return_value = MagicMock(stdout="")
                devices = USBWriter.list_devices()
                assert devices == []

    @staticmethod
    def test_list_devices_linux_with_devices():
        mock_output = """NAME SIZE MODEL TYPE MOUNTPOINT
sda  120G SSD   disk
sdb  32G  USB Drive disk
"""
        with patch('platform.system', return_value='Linux'):
            with patch('subprocess.run') as mock_run:
                mock_run.return_value = MagicMock(stdout=mock_output)
                devices = USBWriter.list_devices()
                assert len(devices) == 2
                assert devices[0]['name'] == '/dev/sda'
                assert devices[1]['name'] == '/dev/sdb'

    @staticmethod
    def test_list_devices_darwin_empty():
        with patch('platform.system', return_value='Darwin'):
            with patch('subprocess.run') as mock_run:
                mock_run.return_value = MagicMock(stdout="")
                devices = USBWriter.list_devices()
                assert devices == []

    @staticmethod
    def test_list_devices_darwin_with_devices():
        mock_output = """
/dev/disk0 (internal):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:      GUID_partition_scheme                        *500.3 GB   disk0
/dev/disk2 (external, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:     FDisk_partition_scheme                        *32.0 GB    disk2
"""
        with patch('platform.system', return_value='Darwin'):
            with patch('subprocess.run') as mock_run:
                mock_run.return_value = MagicMock(stdout=mock_output)
                devices = USBWriter.list_devices()
                assert len(devices) == 1
                assert '/dev/disk2' in devices[0]['name']

    @staticmethod
    def test_list_devices_unknown_platform():
        with patch('platform.system', return_value='FreeBSD'):
            devices = USBWriter.list_devices()
            assert devices == []

    # ========================================================================
    # Edge cases
    # ========================================================================

    def test_write_iso_device_path_already_has_dev(self, iso_file, logger):
        """Test ISO write when device path already starts with /dev/."""
        with patch('builtins.input', return_value='YES'):
            with patch('platform.system', return_value='Linux'):
                with patch('subprocess.run') as mock_run:
                    mock_run.return_value = MagicMock(returncode=0)
                    result = USBWriter.write_iso(iso_file, "/dev/sdb", logger)
                    assert result is True

    def test_write_iso_very_large_iso(self, tmp_path, logger):
        iso_file = tmp_path / "large.iso"
        iso_file.write_bytes(b'\x00' * (1024 * 1024))
        with patch('builtins.input', return_value='YES'):
            with patch('platform.system', return_value='Linux'):
                with patch('subprocess.run') as mock_run:
                    mock_run.return_value = MagicMock(returncode=0)
                    result = USBWriter.write_iso(iso_file, "/dev/sdb", logger)
                    assert result is True
