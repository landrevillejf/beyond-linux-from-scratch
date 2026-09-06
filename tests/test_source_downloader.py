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
        # Create existing file with a valid gzip header so it is trusted
        test_file = sources_dir / "test.tar.gz"
        test_file.write_bytes(b"\x1f\x8b\x08\x00existing content")

        downloader = SourceDownloader(sources_dir, mock_logger)
        result = downloader.download("https://example.com/test.tar.gz", "test.tar.gz")

        assert result is True
        mock_logger.info.assert_called_with("Already exists: test.tar.gz")

    def test_download_success(self, fake_urlretrieve, sources_dir, mock_logger):
        """Test successful download"""
        downloader = SourceDownloader(sources_dir, mock_logger)
        with patch('urllib.request.urlretrieve',
                   side_effect=fake_urlretrieve()) as mock_urlretrieve:
            result = downloader.download("https://example.com/newfile.tar.gz", "newfile.tar.gz")

        assert result is True
        mock_urlretrieve.assert_called_once()

    def test_download_retry_on_failure(self, fake_urlretrieve, sources_dir, mock_logger):
        """Test retry on download failure"""
        downloader = SourceDownloader(sources_dir, mock_logger)
        with patch('urllib.request.urlretrieve',
                   side_effect=fake_urlretrieve(Exception("Network error"),
                                                Exception("Network error"))) as mock_urlretrieve:
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
    def test_download_http_503_retries_with_backoff(self, mock_sleep, fake_urlretrieve,
                                                    sources_dir, mock_logger):
        """Test that 5xx HTTP errors are retried with exponential backoff."""
        downloader = SourceDownloader(sources_dir, mock_logger)

        unavailable = urllib.error.HTTPError(url='http://example.com/f.tar.gz', code=503,
                                             msg='Service Unavailable', hdrs=None, fp=None)
        with patch('urllib.request.urlretrieve',
                   side_effect=fake_urlretrieve(unavailable, unavailable)) as mock_retrieve:
            result = downloader.download('http://example.com/f.tar.gz', 'f.tar.gz', retries=3)

        assert result is True
        assert mock_retrieve.call_count == 3
        assert mock_sleep.call_count == 2  # slept between attempts

    @patch('builder.time.sleep')
    def test_download_http_429_retries_with_backoff(self, mock_sleep, fake_urlretrieve,
                                                    sources_dir, mock_logger):
        """Test that HTTP 429 (rate limit) is retried."""
        downloader = SourceDownloader(sources_dir, mock_logger)

        throttled = urllib.error.HTTPError(url='http://example.com/f.tar.gz', code=429,
                                           msg='Too Many Requests', hdrs=None, fp=None)
        with patch('urllib.request.urlretrieve',
                   side_effect=fake_urlretrieve(throttled)) as mock_retrieve:
            result = downloader.download('http://example.com/f.tar.gz', 'f.tar.gz', retries=2)

        assert result is True
        assert mock_sleep.call_count == 1

    @patch('builder.time.sleep')
    def test_download_http_418_retries_with_backoff(self, mock_sleep, fake_urlretrieve,
                                                    sources_dir, mock_logger):
        """HTTP 418 (freedesktop.org anti-abuse) is transient and retried.

        Nightly #208: freedesktop.org's CDN answers parallel CI download
        bursts with "418 I'm a teapot".  It was lumped in with permanent
        4xx errors, so libevdev gave up on the first response and aborted
        blfs-libs for the xfce jobs.  418 must fall through to the same
        backoff retry as 429.
        """
        downloader = SourceDownloader(sources_dir, mock_logger)

        teapot = urllib.error.HTTPError(url='http://example.com/f.tar.gz', code=418,
                                        msg="I'm a teapot", hdrs=None, fp=None)
        with patch('urllib.request.urlretrieve',
                   side_effect=fake_urlretrieve(teapot)) as mock_retrieve:
            result = downloader.download('http://example.com/f.tar.gz', 'f.tar.gz', retries=2)

        assert result is True
        assert mock_retrieve.call_count == 2
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


class TestNightly212DownloadResilience:
    """Regression tests for the Nightly #212 download failures.

    Every x86_64 job lost sources that the build could not recover from:
    freedesktop.org answered "418 I'm a teapot" to each libevdev attempt
    (the 30 s backoff cap re-entered the same throttle window) and
    several wget-list archives now 404 upstream (exim, ImageMagick), so
    a mirror fallback and a longer rate-limit backoff are required.
    """

    def test_mirror_candidates_derives_blfs_package_dir(self, sources_dir, mock_logger):
        """The conglomeration tree is keyed <mirror>/<package>/<file>."""
        downloader = SourceDownloader(sources_dir, mock_logger)
        assert downloader._mirror_candidates(
            'https://ftp.exim.org/pub/exim/exim4/exim-4.98.2.tar.xz'
        ) == ['https://ftp2.osuosl.org/pub/blfs/conglomeration/exim/exim-4.98.2.tar.xz']
        # A trailing revision tag belongs to the version, not the package.
        assert downloader._mirror_candidates(
            'https://www.imagemagick.org/archive/releases/ImageMagick-7.1.2-1.tar.xz'
        ) == ['https://ftp2.osuosl.org/pub/blfs/conglomeration/'
              'ImageMagick/ImageMagick-7.1.2-1.tar.xz']

    def test_mirror_candidates_skips_names_without_a_version(self, sources_dir, mock_logger):
        """Guessing a directory would only buy extra 404s."""
        downloader = SourceDownloader(sources_dir, mock_logger)
        for url in (
            'https://example.com/noversion.tar.gz',
            'https://example.com/python-3.13.7-docs-html.tar.bz2',
            'https://example.com/tcl8.6.16-src.tar.gz',
            'https://www.linuxfromscratch.org/patches/lfs/12.4/coreutils-9.7-i18n-1.patch',
            'https://example.com/',
        ):
            assert downloader._mirror_candidates(url) == [], url

    def test_download_falls_back_to_conglomeration_mirror(self, sources_dir, mock_logger):
        """A dead upstream URL must be retried on the BLFS mirror."""
        dest = sources_dir / 'exim-4.98.2.tar.xz'
        seen = []

        def fake_retrieve(url, path, *args):
            seen.append(url)
            if len(seen) == 1:
                raise urllib.error.HTTPError(url=url, code=404,
                                             msg='Not Found', hdrs=None, fp=None)
            Path(path).write_bytes(b'\xfd7zXZ\x00payload')

        downloader = SourceDownloader(sources_dir, mock_logger)
        with patch('urllib.request.urlretrieve', side_effect=fake_retrieve):
            result = downloader.download(
                'https://ftp.exim.org/pub/exim/exim4/exim-4.98.2.tar.xz', retries=1)

        assert result is True
        assert seen == [
            'https://ftp.exim.org/pub/exim/exim4/exim-4.98.2.tar.xz',
            'https://ftp2.osuosl.org/pub/blfs/conglomeration/exim/exim-4.98.2.tar.xz',
        ]
        assert dest.exists()
        mock_logger.warning.assert_any_call(
            'Primary host failed for exim-4.98.2.tar.xz, trying mirror: '
            'https://ftp2.osuosl.org/pub/blfs/conglomeration/exim/exim-4.98.2.tar.xz'
        )

    def test_download_returns_false_when_the_mirror_also_fails(self, sources_dir, mock_logger):
        """The fallback must not turn a missing source into a success."""
        downloader = SourceDownloader(sources_dir, mock_logger)
        with patch('urllib.request.urlretrieve') as mock_retrieve:
            mock_retrieve.side_effect = urllib.error.HTTPError(
                url='https://example.com/gegl-0.4.62.tar.xz', code=404,
                msg='Not Found', hdrs=None, fp=None)
            result = downloader.download(
                'https://download.gimp.org/pub/gegl/0.4/gegl-0.4.62.tar.xz', retries=1)

        assert result is False
        # A 404 is permanent on every host, so each attempt gives up after
        # a single request: primary plus both mirror tiers.
        assert mock_retrieve.call_count == 3
        assert not (sources_dir / 'gegl-0.4.62.tar.xz').exists()

    @patch('builder.time.sleep')
    def test_mirror_gets_its_own_retry_budget_on_transient_errors(
            self, mock_sleep, sources_dir, mock_logger):
        """A 5xx on the mirror must exhaust MIRROR_RETRIES, not one shot."""
        downloader = SourceDownloader(sources_dir, mock_logger)
        with patch('urllib.request.urlretrieve') as mock_retrieve:
            mock_retrieve.side_effect = urllib.error.HTTPError(
                url='https://example.com/gegl-0.4.62.tar.xz', code=503,
                msg='Service Unavailable', hdrs=None, fp=None)
            result = downloader.download(
                'https://download.gimp.org/pub/gegl/0.4/gegl-0.4.62.tar.xz', retries=1)

        assert result is False
        assert mock_retrieve.call_count == 1 + 2 * SourceDownloader.MIRROR_RETRIES
        assert mock_retrieve.call_args[0][0] == (
            'https://sources.voidlinux.org/gegl-0.4.62/gegl-0.4.62.tar.xz'
        )
        assert mock_sleep.called

    def test_download_attempt_with_no_retries_fails(self, sources_dir, mock_logger):
        """retries=0 must not loop at all."""
        downloader = SourceDownloader(sources_dir, mock_logger)
        with patch('urllib.request.urlretrieve') as mock_retrieve:
            assert downloader._download_attempt(
                'https://example.com/f.tar.gz', sources_dir / 'f.tar.gz',
                'f.tar.gz', 0) is False
        mock_retrieve.assert_not_called()

    def test_backoff_delay_is_longer_for_rate_limits(self, sources_dir, mock_logger):
        """A 418/429 throttle window outlives the plain retry cap."""
        downloader = SourceDownloader(sources_dir, mock_logger)
        with patch('builder.random.uniform', return_value=0.0):
            assert downloader._backoff_delay(0) == 1.0
            assert downloader._backoff_delay(0, rate_limited=True) == 8.0
            assert downloader._backoff_delay(30) <= downloader.RETRY_BACKOFF_CAP
            assert downloader._backoff_delay(30, rate_limited=True) <= \
                downloader.RATE_LIMIT_BACKOFF_CAP

    @patch('builder.time.sleep')
    @patch('builder.random.uniform', return_value=0.0)
    def test_418_uses_the_rate_limit_backoff(self, mock_uniform, mock_sleep, fake_urlretrieve,
                                             sources_dir, mock_logger):
        """freedesktop.org's 418 must wait out the throttle window."""
        downloader = SourceDownloader(sources_dir, mock_logger)
        teapot = urllib.error.HTTPError(url='http://example.com/f.tar.gz', code=418,
                                        msg="I'm a teapot", hdrs=None, fp=None)
        with patch('urllib.request.urlretrieve',
                   side_effect=fake_urlretrieve(teapot)):
            assert downloader.download(
                'http://example.com/f.tar.gz', 'f.tar.gz', retries=2) is True

        assert mock_sleep.call_args[0][0] == 8.0


class TestNightly213VoidMirrorFallback:
    """Regression tests for the Nightly #213 libevdev loss.

    freedesktop.org answered "418 I'm a teapot" to every request from the
    runner for the whole run, and the BLFS conglomeration tree carries no
    libevdev directory, so the gnome and audio-studio jobs aborted the
    blfs-libs stage with "no source archive found for libevdev".  A second
    mirror tier (Void Linux, keyed by archive stem) recovers those hosts.
    """

    def test_void_candidates_uses_the_archive_stem(self, sources_dir, mock_logger):
        """The Void tree is keyed <mirror>/<stem>/<file>."""
        downloader = SourceDownloader(sources_dir, mock_logger)
        assert downloader._void_candidates(
            'https://www.freedesktop.org/software/libevdev/releases/'
            'libevdev-1.13.4/libevdev-1.13.4.tar.xz'
        ) == ['https://sources.voidlinux.org/libevdev-1.13.4/libevdev-1.13.4.tar.xz']
        # A trailing revision tag stays part of the stem.
        assert downloader._void_candidates(
            'https://www.imagemagick.org/archive/releases/ImageMagick-7.1.2-1.tar.xz'
        ) == ['https://sources.voidlinux.org/'
              'ImageMagick-7.1.2-1/ImageMagick-7.1.2-1.tar.xz']

    def test_void_candidates_skips_names_without_a_trailing_version(
            self, sources_dir, mock_logger):
        """Guessing a stem would only buy extra 404s."""
        downloader = SourceDownloader(sources_dir, mock_logger)
        for url in (
            'https://example.com/noversion.tar.gz',
            'https://example.com/python-3.13.7-docs-html.tar.bz2',
            'https://example.com/tcl8.6.16-src.tar.gz',
            'https://www.linuxfromscratch.org/patches/lfs/12.4/coreutils-9.7-i18n-1.patch',
            'https://example.com/',
        ):
            assert downloader._void_candidates(url) == [], url

    def test_download_falls_back_to_void_when_conglomeration_404s(
            self, sources_dir, mock_logger):
        """The libevdev #213 path: 418 upstream, 404 on conglomeration."""
        dest = sources_dir / 'libevdev-1.13.4.tar.xz'
        seen = []

        def fake_retrieve(url, path, *args):
            seen.append(url)
            if 'freedesktop.org' in url:
                raise urllib.error.HTTPError(url=url, code=418,
                                             msg="I'm a teapot", hdrs=None, fp=None)
            if 'conglomeration' in url:
                raise urllib.error.HTTPError(url=url, code=404,
                                             msg='Not Found', hdrs=None, fp=None)
            Path(path).write_bytes(b'\xfd7zXZ\x00payload')

        downloader = SourceDownloader(sources_dir, mock_logger)
        with patch('builder.time.sleep'), \
                patch('urllib.request.urlretrieve', side_effect=fake_retrieve):
            result = downloader.download(
                'https://www.freedesktop.org/software/libevdev/releases/'
                'libevdev-1.13.4/libevdev-1.13.4.tar.xz', retries=1)

        assert result is True
        assert seen[-1] == (
            'https://sources.voidlinux.org/libevdev-1.13.4/libevdev-1.13.4.tar.xz'
        )
        assert dest.exists()
        mock_logger.warning.assert_any_call(
            'Primary host failed for libevdev-1.13.4.tar.xz, trying mirror: '
            'https://sources.voidlinux.org/libevdev-1.13.4/libevdev-1.13.4.tar.xz'
        )

    def test_conglomeration_is_tried_before_void(self, sources_dir, mock_logger):
        """The BLFS mirror stays the preferred fallback."""
        downloader = SourceDownloader(sources_dir, mock_logger)
        url = 'https://download.gimp.org/pub/gegl/0.4/gegl-0.4.62.tar.xz'
        candidates = downloader._mirror_candidates(url) + downloader._void_candidates(url)
        assert candidates[0].startswith('https://ftp2.osuosl.org/pub/blfs/conglomeration/')
        assert candidates[-1].startswith('https://sources.voidlinux.org/')


class TestBaseCacheRun5GnuMirrorFallback:
    """Regression tests for the build-base-cache run #5 GNU outage.

    ftpmirror.gnu.org answered 502/504 to every request for m4, mpc, sed
    and readline while ftp.gnu.org and mirrors.kernel.org served the same
    files.  The two existing fallback tiers could not help: the BLFS
    conglomeration tree carries no LFS core package and Void has no stem
    for them either, so all four sources were declared missing and, since
    download_sources() only warns, the job kept building towards a
    toolchain stage that could not succeed.
    """

    def test_gnu_candidates_repoints_the_redirector(self, sources_dir, mock_logger):
        """The redirector's document root is the gnu tree itself."""
        downloader = SourceDownloader(sources_dir, mock_logger)
        assert downloader._gnu_candidates(
            'https://ftpmirror.gnu.org/m4/m4-1.4.20.tar.xz'
        ) == [
            'https://ftp.gnu.org/gnu/m4/m4-1.4.20.tar.xz',
            'https://mirrors.kernel.org/gnu/m4/m4-1.4.20.tar.xz',
            'https://mirror.team-cymru.com/gnu/m4/m4-1.4.20.tar.xz',
            'https://mirrors.ocf.berkeley.edu/gnu/m4/m4-1.4.20.tar.xz',
        ]
        # gcc nests the tarball one directory deeper; the whole tail must
        # survive the rewrite.
        assert downloader._gnu_candidates(
            'https://ftpmirror.gnu.org/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz'
        ) == [
            'https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz',
            'https://mirrors.kernel.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz',
            'https://mirror.team-cymru.com/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz',
            'https://mirrors.ocf.berkeley.edu/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz',
        ]

    def test_gnu_candidates_drops_the_gnu_prefix_and_the_origin_host(
            self, sources_dir, mock_logger):
        """A healthy mirror must not be asked for the file it just failed on."""
        downloader = SourceDownloader(sources_dir, mock_logger)
        assert downloader._gnu_candidates(
            'https://mirrors.kernel.org/gnu/mpc/mpc-1.3.1.tar.gz'
        ) == [
            'https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz',
            'https://mirror.team-cymru.com/gnu/mpc/mpc-1.3.1.tar.gz',
            'https://mirrors.ocf.berkeley.edu/gnu/mpc/mpc-1.3.1.tar.gz',
        ]
        assert downloader._gnu_candidates(
            'https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz'
        )[0] == 'https://mirrors.kernel.org/gnu/sed/sed-4.9.tar.xz'

    def test_gnu_candidates_skips_urls_that_are_not_gnu_archives(
            self, sources_dir, mock_logger):
        """Re-pointing a foreign URL at a GNU mirror only buys extra 404s."""
        downloader = SourceDownloader(sources_dir, mock_logger)
        for url in (
            'https://download.gimp.org/pub/gegl/0.4/gegl-0.4.62.tar.xz',
            'https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.16.1.tar.xz',
            'https://ftpmirror.gnu.org/',
            'https://ftpmirror.gnu.org/m4/',
            'https://example.com/gnu/',
        ):
            assert downloader._gnu_candidates(url) == [], url

    def test_gnu_tier_is_tried_before_the_guessed_tiers(self, sources_dir, mock_logger):
        """An exact path rewrite beats a package directory derived from a name."""
        downloader = SourceDownloader(sources_dir, mock_logger)
        url = 'https://ftpmirror.gnu.org/m4/m4-1.4.20.tar.xz'
        candidates = (downloader._gnu_candidates(url)
                      + downloader._mirror_candidates(url)
                      + downloader._void_candidates(url))
        assert candidates[0] == 'https://ftp.gnu.org/gnu/m4/m4-1.4.20.tar.xz'
        assert candidates[-1] == 'https://sources.voidlinux.org/m4-1.4.20/m4-1.4.20.tar.xz'

    @patch('builder.time.sleep')
    def test_download_recovers_a_core_tarball_from_a_gnu_mirror(
            self, mock_sleep, sources_dir, mock_logger):
        """The run #5 path: 504 on the redirector, 200 on ftp.gnu.org."""
        dest = sources_dir / 'm4-1.4.20.tar.xz'
        seen = []

        def fake_retrieve(url, path, *args):
            seen.append(url)
            if 'ftpmirror.gnu.org' in url:
                raise urllib.error.HTTPError(url=url, code=504,
                                             msg='Gateway Time-out', hdrs=None, fp=None)
            Path(path).write_bytes(b'\xfd7zXZ\x00payload')

        downloader = SourceDownloader(sources_dir, mock_logger)
        with patch('urllib.request.urlretrieve', side_effect=fake_retrieve):
            result = downloader.download(
                'https://ftpmirror.gnu.org/m4/m4-1.4.20.tar.xz', retries=1)

        assert result is True
        assert seen == [
            'https://ftpmirror.gnu.org/m4/m4-1.4.20.tar.xz',
            'https://ftp.gnu.org/gnu/m4/m4-1.4.20.tar.xz',
        ]
        assert dest.exists()
        mock_logger.warning.assert_any_call(
            'Primary host failed for m4-1.4.20.tar.xz, trying mirror: '
            'https://ftp.gnu.org/gnu/m4/m4-1.4.20.tar.xz'
        )
