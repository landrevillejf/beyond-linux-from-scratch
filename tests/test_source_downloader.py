#!/usr/bin/env python3
"""
Tests for SourceDownloader class
"""

import pytest
import hashlib
import urllib.error
from unittest.mock import patch, MagicMock
from pathlib import Path
from builder import SourceDownloader

class TestSourceDownloader:
    """Test SourceDownloader class"""

    def test_init(self, sources_dir, mock_logger):
        """Test initialization"""
        downloader = SourceDownloader(sources_dir, mock_logger)
        assert downloader.sources_dir == sources_dir
        assert downloader.logger == mock_logger

    def test_download_file_already_exists(self, sources_dir, mock_logger):
        """Test downloading file that already exists"""
        # Create existing file
        test_file = sources_dir / "test.tar.gz"
        test_file.write_text("existing content")

        downloader = SourceDownloader(sources_dir, mock_logger)
        result = downloader.download("https://example.com/test.tar.gz", "test.tar.gz")

        assert result is True
        mock_logger.info.assert_called_with("Already exists: test.tar.gz")

    @patch('urllib.request.urlretrieve')
    def test_download_success(self, mock_urlretrieve, sources_dir, mock_logger):
        """Test successful download"""
        downloader = SourceDownloader(sources_dir, mock_logger)
        result = downloader.download("https://example.com/newfile.tar.gz", "newfile.tar.gz")

        assert result is True
        mock_urlretrieve.assert_called_once()

    @patch('urllib.request.urlretrieve')
    def test_download_retry_on_failure(self, mock_urlretrieve, sources_dir, mock_logger):
        """Test retry on download failure"""
        mock_urlretrieve.side_effect = [Exception("Network error"), Exception("Network error"), MagicMock()]

        downloader = SourceDownloader(sources_dir, mock_logger)
        result = downloader.download("https://example.com/retry.tar.gz", "retry.tar.gz", retries=3)

        assert result is True
        assert mock_urlretrieve.call_count == 3

    @patch('urllib.request.urlretrieve')
    def test_download_all_retries_fail(self, mock_urlretrieve, sources_dir, mock_logger):
        """Test all retries fail"""
        mock_urlretrieve.side_effect = Exception("Network error")

        downloader = SourceDownloader(sources_dir, mock_logger)
        result = downloader.download("https://example.com/fail.tar.gz", "fail.tar.gz", retries=2)

        assert result is False
        assert mock_urlretrieve.call_count == 2

    @patch('urllib.request.urlretrieve')
    def test_download_http_404_fails_fast(self, mock_urlretrieve, sources_dir, mock_logger):
        """Test permanent HTTP errors do not consume all retries"""
        mock_urlretrieve.side_effect = urllib.error.HTTPError(
            url="https://example.com/missing.tar.gz",
            code=404,
            msg="Not Found",
            hdrs=None,
            fp=None,
        )

        downloader = SourceDownloader(sources_dir, mock_logger)
        result = downloader.download("https://example.com/missing.tar.gz", "missing.tar.gz", retries=3)

        assert result is False
        assert mock_urlretrieve.call_count == 1

    @patch('urllib.request.urlretrieve')
    def test_download_cleans_up_partial_file_on_exception(self, mock_urlretrieve, sources_dir, mock_logger):
        """Partial files created before an exception should be removed."""
        dest = sources_dir / "partial.tar.gz"

        def create_partial_and_raise(*args, **kwargs):
            dest.write_bytes(b"partial data")
            raise Exception("Connection reset")

        mock_urlretrieve.side_effect = create_partial_and_raise

        downloader = SourceDownloader(sources_dir, mock_logger)
        result = downloader.download("https://example.com/partial.tar.gz", "partial.tar.gz", retries=1)

        assert result is False
        assert not dest.exists(), "Partial file should have been cleaned up"

    @patch('urllib.request.urlretrieve')
    def test_download_cleans_up_partial_file_on_http_error(self, mock_urlretrieve, sources_dir, mock_logger):
        """Partial files created before an HTTP error should be removed."""
        dest = sources_dir / "http_error.tar.gz"

        def create_partial_and_raise(*args, **kwargs):
            dest.write_bytes(b"partial data")
            raise urllib.error.HTTPError(
                url="https://example.com/http_error.tar.gz",
                code=503,
                msg="Service Unavailable",
                hdrs=None,
                fp=None,
            )

        mock_urlretrieve.side_effect = create_partial_and_raise

        downloader = SourceDownloader(sources_dir, mock_logger)
        result = downloader.download("https://example.com/http_error.tar.gz", "http_error.tar.gz", retries=1)

        assert result is False
        assert not dest.exists(), "Partial file should have been cleaned up"

    def test_download_from_list(self, sources_dir, mock_logger, sample_sources_list):
        """Test downloading from sources list"""
        downloader = SourceDownloader(sources_dir, mock_logger)

        with patch.object(downloader, 'download', return_value=True) as mock_download:
            result = downloader.download_from_list(sample_sources_list, parallel=2)

            assert result is True
            # Should download 4 files (2 real + 2 audio)
            assert mock_download.call_count == 4

    def test_download_from_list_skips_git_urls(self, sources_dir, mock_logger, temp_dir):
        """Test that Git URLs are skipped"""
        sources_list = temp_dir / "sources.list"
        sources_list.write_text("""
https://normal.com/file.tar.gz
git://github.com/repo.git
https://git.savannah.gnu.org/git/guix.git
""")

        downloader = SourceDownloader(sources_dir, mock_logger)

        with patch.object(downloader, 'download', return_value=True) as mock_download:
            downloader.download_from_list(sources_list)

            # Only the non-Git URL should be downloaded
            assert mock_download.call_count == 1

    def test_verify_checksums_valid(self, sources_dir, mock_logger, sample_md5sums):
        """Test checksum verification with valid files"""
        # Create test file with matching SHA256
        test_file = sources_dir / "linux-6.16.1.tar.xz"
        test_content = b"test content"
        test_file.write_bytes(test_content)
        expected_sha256 = hashlib.sha256(test_content).hexdigest()

        # Update checksums with correct hash
        md5_file = sources_dir.parent / "md5sums"
        md5_file.write_text(f"{expected_sha256} linux-6.16.1.tar.xz\n")

        downloader = SourceDownloader(sources_dir, mock_logger)
        result = downloader.verify_checksums(md5_file)

        assert result is True

    def test_verify_checksums_invalid(self, sources_dir, mock_logger, temp_dir):
        """Test checksum verification with invalid checksum"""
        test_file = sources_dir / "test.tar.gz"
        test_file.write_text("test content")

        md5_file = temp_dir / "md5sums"
        md5_file.write_text("wrongmd5hash123 test.tar.gz\n")

        downloader = SourceDownloader(sources_dir, mock_logger)
        result = downloader.verify_checksums(md5_file)

        assert result is False
        mock_logger.error.assert_called()

    def test_verify_checksums_missing_file(self, sources_dir, mock_logger, temp_dir):
        """Test checksum verification with missing file"""
        md5_file = temp_dir / "md5sums"
        md5_file.write_text("abc123 missing.tar.gz\n")

        downloader = SourceDownloader(sources_dir, mock_logger)
        result = downloader.verify_checksums(md5_file)

        assert result is False
        mock_logger.warning.assert_called()

    def test_verify_checksums_no_file(self, sources_dir, mock_logger):
        """Test checksum verification with no checksum file"""
        downloader = SourceDownloader(sources_dir, mock_logger)
        result = downloader.verify_checksums(Path("/nonexistent/md5sums"))

        assert result is True
        mock_logger.warning.assert_called()

    def test_download_from_list_handles_exception(self, tmp_path):
        """Test that download_from_list catches exceptions from the download task."""
        list_file = tmp_path / "sources.list"
        list_file.write_text("https://example.com/package.tar.gz\n")

        from unittest.mock import Mock  # ou utilise MagicMock
        logger = Mock()
        downloader = SourceDownloader(sources_dir=tmp_path, logger=logger, timeout=10, retries=1)

        with patch.object(downloader, 'download', side_effect=Exception("Simulated network error")):
            result = downloader.download_from_list(list_file, parallel=1)

        assert result is False
        logger.error.assert_called_once_with(
            "Unexpected error downloading https://example.com/package.tar.gz: Simulated network error"
        )
        logger.warning.assert_any_call("Failed to download 1 sources:")
        logger.warning.assert_any_call("  https://example.com/package.tar.gz")

    @patch('builder.time.sleep')
    def test_download_http_503_retries_with_backoff(self, mock_sleep, sources_dir, mock_logger):
        """Test that 5xx HTTP errors are retried with exponential backoff."""
        downloader = SourceDownloader(sources_dir, mock_logger)

        mock_urlretrieve = patch('urllib.request.urlretrieve')
        with mock_urlretrieve as mock_retrieve:
            mock_retrieve.side_effect = [
                urllib.error.HTTPError(url='http://example.com/f.tar.gz', code=503,
                                       msg='Service Unavailable', hdrs=None, fp=None),
                urllib.error.HTTPError(url='http://example.com/f.tar.gz', code=503,
                                       msg='Service Unavailable', hdrs=None, fp=None),
                MagicMock(),  # success on third attempt
            ]
            result = downloader.download('http://example.com/f.tar.gz', 'f.tar.gz', retries=3)

        assert result is True
        assert mock_retrieve.call_count == 3
        assert mock_sleep.call_count == 2  # slept between attempts

    @patch('builder.time.sleep')
    def test_download_http_429_retries_with_backoff(self, mock_sleep, sources_dir, mock_logger):
        """Test that HTTP 429 (rate limit) is retried."""
        downloader = SourceDownloader(sources_dir, mock_logger)

        with patch('urllib.request.urlretrieve') as mock_retrieve:
            mock_retrieve.side_effect = [
                urllib.error.HTTPError(url='http://example.com/f.tar.gz', code=429,
                                       msg='Too Many Requests', hdrs=None, fp=None),
                MagicMock(),
            ]
            result = downloader.download('http://example.com/f.tar.gz', 'f.tar.gz', retries=2)

        assert result is True
        assert mock_sleep.call_count == 1

    def test_download_from_list_retry_pass_recovers(self, tmp_path):
        """Test that download_from_list retry pass recovers failed downloads."""
        list_file = tmp_path / "sources.list"
        list_file.write_text("https://example.com/package.tar.gz\n")

        logger = MagicMock()
        downloader = SourceDownloader(sources_dir=tmp_path, logger=logger, retries=1)

        call_count = [0]
        original_download = downloader.download

        def mock_download(url, filename=None, retries=None):
            call_count[0] += 1
            if call_count[0] <= 1:
                return False  # first call (parallel pass) fails
            return True  # retry pass succeeds

        with patch.object(downloader, 'download', side_effect=mock_download):
            result = downloader.download_from_list(list_file, parallel=1, retry_passes=2)

        assert result is True
        logger.info.assert_any_call("  Recovered on retry pass 1: package.tar.gz")

    def test_download_from_list_retry_pass_skips_existing(self, tmp_path):
        """Test that retry pass skips files that already exist."""
        list_file = tmp_path / "sources.list"
        list_file.write_text("https://example.com/package.tar.gz\n")

        # Pre-create the file so the retry pass sees it exists
        (tmp_path / "package.tar.gz").write_text("content")

        logger = MagicMock()
        downloader = SourceDownloader(sources_dir=tmp_path, logger=logger, retries=1)

        with patch.object(downloader, 'download', return_value=False):
            result = downloader.download_from_list(list_file, parallel=1, retry_passes=1)

        # The file exists so the retry pass skips it → all good
        assert result is True