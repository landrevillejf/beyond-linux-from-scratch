#!/usr/bin/env python3
"""
Tests for edge cases and error handling
Covers the remaining uncovered lines in builder.py
"""

import logging
import subprocess
from unittest.mock import MagicMock, patch

from builder import (
    SourceDownloader, ScriptExecutor, USBWriter, LFSBuilder
)


class TestNetworkExceptions:
    """Test network exception handling (line ~484)"""

    def test_download_network_exception_handling(self, tmp_path):
        """Test that network exceptions are caught and logged"""
        logger = logging.getLogger('test')
        downloader = SourceDownloader(tmp_path, logger)

        with patch('urllib.request.urlretrieve', side_effect=Exception("Connection refused")):
            with patch.object(logger, 'warning') as mock_warning:
                result = downloader.download("http://example.com/file.tar.gz", retries=1)
                assert result is False
                mock_warning.assert_called()

    def test_download_ssl_exception_handling(self, tmp_path):
        """Test SSL certificate errors"""
        logger = logging.getLogger('test')
        downloader = SourceDownloader(tmp_path, logger)

        with patch(
            'urllib.request.urlretrieve',
            side_effect=Exception("SSL: CERTIFICATE_VERIFY_FAILED"),
        ):
            with patch.object(logger, 'warning') as mock_warning:
                result = downloader.download("https://example.com/file.tar.gz", retries=2)
                assert result is False
                assert mock_warning.call_count >= 1

    def test_download_timeout_exception_handling(self, tmp_path):
        """Test timeout exceptions during download"""
        logger = logging.getLogger('test')
        downloader = SourceDownloader(tmp_path, logger)

        with patch('urllib.request.urlretrieve', side_effect=Exception("timed out")):
            with patch.object(logger, 'warning') as mock_warning:
                result = downloader.download("http://slow.example.com/file.tar.gz", retries=2)
                assert result is False
                mock_warning.assert_called()

    def test_download_http_error_404_handling(self, tmp_path):
        """Test HTTP 404 errors"""
        logger = logging.getLogger('test')
        downloader = SourceDownloader(tmp_path, logger)

        with patch('urllib.request.urlretrieve', side_effect=Exception("HTTP Error 404: Not Found")):
            with patch.object(logger, 'warning') as mock_warning:
                result = downloader.download("http://example.com/notfound.tar.gz", retries=2)
                assert result is False
                mock_warning.assert_called()


class TestSubprocessTimeout:
    """Test subprocess timeout handling (line ~637)"""

    def test_script_execution_timeout(self, tmp_path):
        """Test that subprocess timeout is caught"""
        logger = logging.getLogger('test')
        env = {}
        output_dir = tmp_path / "output"
        output_dir.mkdir()
        executor = ScriptExecutor(env, output_dir, logger)

        script_file = tmp_path / "slow_script.sh"
        script_file.write_text("#!/bin/bash\nsleep 10\necho done")
        script_file.chmod(0o755)

        with patch('subprocess.run', side_effect=subprocess.TimeoutExpired(cmd='sleep', timeout=2)):
            with patch.object(logger, 'error') as mock_error:
                result = executor.run_script(str(script_file), "test-stage", timeout=2)
                assert result is False
                mock_error.assert_called_with("✗ Stage timed out after 2 seconds: test-stage")

    def test_script_execution_timeout_with_different_timeout(self, tmp_path):
        """Test timeout with custom timeout value"""
        logger = logging.getLogger('test')
        env = {}
        output_dir = tmp_path / "output"
        output_dir.mkdir()
        executor = ScriptExecutor(env, output_dir, logger)

        script_file = tmp_path / "slow_script2.sh"
        script_file.write_text("#!/bin/bash\nsleep 30")
        script_file.chmod(0o755)

        with patch('subprocess.run', side_effect=subprocess.TimeoutExpired(cmd='sleep', timeout=5)):
            with patch.object(logger, 'error') as mock_error:
                result = executor.run_script(str(script_file), "test-stage-long", timeout=5)
                assert result is False
                mock_error.assert_called()


class TestUSBErrors:
    """Test USB error handling (line ~731) - CORRIGÉ"""

    def test_usb_write_io_error(self, tmp_path):
        """Test USB write I/O error"""
        logger = logging.getLogger('test')
        iso_file = tmp_path / "test.iso"
        iso_file.write_text("FAKE ISO CONTENT")

        with patch('builtins.input', return_value='YES'):
            with patch('platform.system', return_value='Linux'):
                # Simuler que umount réussit, puis dd échoue avec I/O error
                mock_calls = [
                    MagicMock(returncode=0),  # umount
                    subprocess.CalledProcessError(1, 'dd', stderr="No space left on device"),  # dd I/O error
                ]

                with patch('subprocess.run', side_effect=mock_calls):
                    with patch.object(logger, 'error') as mock_error:
                        result = USBWriter.write_iso(iso_file, "/dev/sdb", logger)
                        assert result is False
                        mock_error.assert_called()

    def test_usb_write_permission_denied(self, tmp_path):
        """Test USB write permission denied"""
        logger = logging.getLogger('test')
        iso_file = tmp_path / "test.iso"
        iso_file.write_text("FAKE ISO CONTENT")

        with patch('builtins.input', return_value='YES'):
            with patch('platform.system', return_value='Linux'):
                mock_calls = [
                    MagicMock(returncode=0),  # umount
                    subprocess.CalledProcessError(13, 'dd', stderr="Permission denied"),  # dd permission denied
                ]

                with patch('subprocess.run', side_effect=mock_calls):
                    with patch.object(logger, 'error') as mock_error:
                        result = USBWriter.write_iso(iso_file, "/dev/sdb", logger)
                        assert result is False
                        mock_error.assert_called()

    def test_usb_write_device_busy(self, tmp_path):
        """Test USB device busy error"""
        logger = logging.getLogger('test')
        iso_file = tmp_path / "test.iso"
        iso_file.write_text("FAKE ISO CONTENT")

        with patch('builtins.input', return_value='YES'):
            with patch('platform.system', return_value='Linux'):
                mock_calls = [
                    MagicMock(returncode=0),  # umount
                    subprocess.CalledProcessError(16, 'dd', stderr="Device or resource busy"),  # dd device busy
                ]

                with patch('subprocess.run', side_effect=mock_calls):
                    with patch.object(logger, 'error') as mock_error:
                        result = USBWriter.write_iso(iso_file, "/dev/sdb", logger)
                        assert result is False
                        mock_error.assert_called()


class TestDockerEnvironment:
    """Test Docker environment detection (line ~891)"""

    def test_docker_environment_detection(self, tmp_path):
        """Test Docker environment detection."""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("minimal", tmp_path, config_file)

        with patch('os.path.exists', return_value=True):
            with patch.object(builder.logger, 'info') as mock_info:
                result = builder.check_prerequisites()
                assert result is True
                mock_info.assert_called_with(
                    "Docker container detected - skipping host prerequisites check"
                )

    def test_non_docker_environment(self, tmp_path):
        """Test normal prerequisite checks outside Docker."""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("minimal", tmp_path, config_file)

        with patch('os.path.exists', return_value=False):
            with patch('platform.system', return_value='Linux'):
                with patch('shutil.which', return_value='/usr/bin/gcc'):
                    with patch(
                        'shutil.disk_usage',
                        return_value=MagicMock(free=100 * 1024**3),
                    ):
                        with patch.object(builder, 'ensure_lfs_user', return_value=True):
                            result = builder.check_prerequisites()
                            assert result is True

    def test_docker_environment_with_cross_compile(self, tmp_path):
        """Test Docker detection for cross-compilation builds."""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("arm64", tmp_path, config_file)

        with patch('os.path.exists', return_value=True):
            with patch.object(builder.logger, 'info') as mock_info:
                result = builder.check_prerequisites()
                assert result is True
                mock_info.assert_called()


class TestCombinedEdgeCases:
    """Test combinations of edge cases"""

    def test_download_retry_logic_with_mixed_errors(self, tmp_path):
        logger = logging.getLogger('test')
        downloader = SourceDownloader(tmp_path, logger)

        errors = [
            Exception("Connection refused"),
            Exception("Timeout"),
            None  # Success on third try
        ]

        with patch('urllib.request.urlretrieve') as mock_retrieve:
            def side_effect(*args, **kwargs):
                error = errors.pop(0)
                if error:
                    raise error
                return MagicMock()

            mock_retrieve.side_effect = side_effect
            result = downloader.download("http://example.com/file.tar.gz", retries=3)
            assert result is True

    def test_verify_checksums_with_missing_file_and_invalid_line(self, tmp_path):
        """Test checksum verification with malformed and missing entries."""
        logger = logging.getLogger('test')
        downloader = SourceDownloader(tmp_path, logger)

        checksum_file = tmp_path / "md5sums"
        checksum_file.write_text("""
# Comment line
abc123 missing.tar.gz
invalid_line
def456 another_missing.tar.gz
""")

        result = downloader.verify_checksums(checksum_file)
        assert result is False

    def test_run_script_with_exception_during_log_read(self, tmp_path):
        """Test script failures when reading the log also raises an exception."""
        logger = logging.getLogger('test')
        env = {}
        output_dir = tmp_path / "output"
        output_dir.mkdir()
        executor = ScriptExecutor(env, output_dir, logger)

        script_file = tmp_path / "failing.sh"
        script_file.write_text("#!/bin/bash\nexit 1")
        script_file.chmod(0o755)

        with patch('subprocess.run', return_value=MagicMock(returncode=1)):
            with patch('builtins.open', side_effect=Exception("Cannot read log")):
                result = executor.run_script(str(script_file), "test-stage")
                assert result is False