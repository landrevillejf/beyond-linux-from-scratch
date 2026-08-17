import hashlib
import json
import shutil
import sys
import tarfile
import tempfile
from pathlib import Path
from unittest.mock import patch, MagicMock, mock_open

import pytest
from builder import BuildCache, LFSBuilder, __version__


class TestBuildCache:

    @pytest.fixture
    def cache(self, mock_logger):
        return BuildCache("https://example.com/metadata.json", mock_logger)

    @pytest.fixture
    def sample_metadata(self):
        return {
            "profiles": {
                "kde": {
                    "systemd": {
                        "x86_64": {
                            "url": "https://example.com/cache.tar.xz",
                            "sha256": "a" * 64,
                            "size_mb": 1024
                        }
                    }
                }
            }
        }

    def test_fetch_metadata_success(self, cache, sample_metadata):
        with patch('urllib.request.urlopen') as mock_urlopen:
            mock_response = MagicMock()
            mock_response.read.return_value = json.dumps(sample_metadata).encode()
            mock_urlopen.return_value.__enter__.return_value = mock_response
            result = cache.fetch_metadata()
            assert result is True
            assert cache.metadata == sample_metadata

    def test_fetch_metadata_failure(self, cache):
        with patch('urllib.request.urlopen', side_effect=Exception("Network error")):
            result = cache.fetch_metadata()
            assert result is False
            assert cache.metadata is None

    def test_get_cached_entry_no_metadata(self, cache):
        assert cache.get_cached_entry("kde", "systemd", "x86_64", "0.4.3") is None

    def test_get_cached_entry_profile_missing(self, cache, sample_metadata):
        cache.metadata = sample_metadata
        assert cache.get_cached_entry("gnome", "systemd", "x86_64", "0.4.3") is None

    def test_get_cached_entry_init_missing(self, cache, sample_metadata):
        cache.metadata = sample_metadata
        assert cache.get_cached_entry("kde", "sysvinit", "x86_64", "0.4.3") is None

    def test_get_cached_entry_arch_missing(self, cache, sample_metadata):
        cache.metadata = sample_metadata
        assert cache.get_cached_entry("kde", "systemd", "aarch64", "0.4.3") is None

    def test_get_cached_entry_success(self, cache, sample_metadata):
        cache.metadata = sample_metadata
        entry = cache.get_cached_entry("kde", "systemd", "x86_64", "0.4.3")
        assert entry == sample_metadata["profiles"]["kde"]["systemd"]["x86_64"]

    def test_download_and_extract_no_url(self, cache, tmp_path, mock_logger):
        entry = {"sha256": "a" * 64}
        result = cache.download_and_extract(entry, tmp_path)
        assert result is False
        assert "Cache entry missing URL" in mock_logger.error.call_args[0][0]

    def test_download_and_extract_success(self, cache, tmp_path):
        # Create a dummy tarball
        image_dir = tmp_path / "image"
        image_dir.mkdir()
        (image_dir / "dummy").touch()
        tarball_path = tmp_path / "cache.tar.xz"
        with tarfile.open(tarball_path, "w:xz") as tar:
            tar.add(image_dir, arcname=".")

        # Compute SHA256
        sha256 = hashlib.sha256(tarball_path.read_bytes()).hexdigest()

        entry = {
            "url": "https://example.com/cache.tar.xz",
            "sha256": sha256
        }

        with patch('urllib.request.urlretrieve') as mock_retrieve:
            # Simulate download: copy tarball to temp file
            def fake_retrieve(url, tmp_name, reporthook):
                shutil.copy2(tarball_path, tmp_name)
                return (tmp_name, None)
            mock_retrieve.side_effect = fake_retrieve

            # Remove existing image_dir so extraction creates new one
            shutil.rmtree(image_dir)

            result = cache.download_and_extract(entry, tmp_path)
            assert result is True
            assert (tmp_path / "image" / "dummy").exists()
            assert (tmp_path / "image").exists()

    def test_download_and_extract_checksum_mismatch(self, cache, tmp_path):
        entry = {
            "url": "https://example.com/cache.tar.xz",
            "sha256": "a" * 64
        }

        with patch('urllib.request.urlretrieve') as mock_retrieve:
            # Create a dummy file with wrong content
            def fake_retrieve(url, tmp_name, reporthook):
                (tmp_name).write_text("dummy")
                return (tmp_name, None)
            mock_retrieve.side_effect = fake_retrieve

            result = cache.download_and_extract(entry, tmp_path)
            assert result is False
            assert not (tmp_path / "image").exists()

    def test_download_and_extract_download_failure(self, cache, tmp_path):
        entry = {
            "url": "https://example.com/cache.tar.xz",
            "sha256": "a" * 64
        }

        with patch('urllib.request.urlretrieve', side_effect=Exception("Download failed")):
            result = cache.download_and_extract(entry, tmp_path)
            assert result is False

    def test_download_and_extract_extraction_failure(self, cache, tmp_path):
        entry = {
            "url": "https://example.com/cache.tar.xz",
            "sha256": "a" * 64
        }

        with patch('urllib.request.urlretrieve') as mock_retrieve:
            def fake_retrieve(url, tmp_name, reporthook):
                # Write invalid tar data
                Path(tmp_name).write_text("not a tar")
                return (tmp_name, None)
            mock_retrieve.side_effect = fake_retrieve

            result = cache.download_and_extract(entry, tmp_path)
            assert result is False

    def test_reporthook(self, cache, capsys):
        # Test with totalsize > 0
        cache._reporthook(0, 1024, 1024 * 10)  # 0% progress
        captured = capsys.readouterr()
        assert "Download: 0%" in captured.out

        cache._reporthook(1, 1024, 1024 * 10)  # 10%
        captured = capsys.readouterr()
        assert "Download: 10%" in captured.out

        # Test when totalsize <= 0
        cache._reporthook(1, 1024, 0)
        captured = capsys.readouterr()
        assert captured.out == ""

        # Test 100% triggers newline
        cache._reporthook(10, 1024, 1024 * 10)
        captured = capsys.readouterr()
        assert "Download: 100%" in captured.out
        assert "\n" in captured.out


class TestLFSBuilderCacheIntegration:

    @pytest.fixture
    def builder(self, tmp_path):
        # Create a minimal builder with a dummy config
        config_file = tmp_path / "config/build.conf"
        config_file.parent.mkdir(parents=True)
        with open(config_file, 'w') as f:
            json.dump({"lfs_version": "13.0", "blfs_version": "13.0"}, f)
        return LFSBuilder(profile="minimal", output_dir=tmp_path / "output", config_file=config_file)

    def test_init_cache_url_default(self, builder):
        assert builder._cache_url == "https://raw.githubusercontent.com/lfs-builder/lfs-builder/main/cache-metadata.json"

    def test_init_cache_url_custom(self, tmp_path):
        config_file = tmp_path / "config/build.conf"
        config_file.parent.mkdir(parents=True)
        with open(config_file, 'w') as f:
            json.dump({"lfs_version": "13.0"}, f)
        builder = LFSBuilder(profile="minimal", output_dir=tmp_path / "output", config_file=config_file, cache_url="https://my-server/metadata.json")
        assert builder._cache_url == "https://my-server/metadata.json"

    def test_build_with_use_cache_success(self, builder):
        # Mock BuildCache behavior
        with patch('builder.BuildCache') as mock_build_cache:
            mock_cache_instance = mock_build_cache.return_value
            mock_cache_instance.fetch_metadata.return_value = True
            mock_cache_instance.get_cached_entry.return_value = {"url": "http://example.com/cache.tar.xz", "sha256": "a" * 64}
            mock_cache_instance.download_and_extract.return_value = True

            result = builder.build(use_cache=True)
            assert result is True
            mock_cache_instance.fetch_metadata.assert_called_once()
            mock_cache_instance.get_cached_entry.assert_called_once_with(
                profile=builder.profile,
                init=builder.get_init_system(),
                arch='x86_64',  # matches the default config architecture
                builder_version=__version__
            )
            mock_cache_instance.download_and_extract.assert_called_once()

    def test_build_with_use_cache_extract_fails_cache_only(self, builder):
        with patch('builder.BuildCache') as mock_build_cache:
            mock_cache_instance = mock_build_cache.return_value
            mock_cache_instance.fetch_metadata.return_value = True
            mock_cache_instance.get_cached_entry.return_value = {"url": "http://example.com/cache.tar.xz", "sha256": "a" * 64}
            mock_cache_instance.download_and_extract.return_value = False

            result = builder.build(use_cache=True, cache_only=True)
            assert result is False

    def test_build_with_use_cache_entry_missing_cache_only(self, builder):
        with patch('builder.BuildCache') as mock_build_cache:
            mock_cache_instance = mock_build_cache.return_value
            mock_cache_instance.fetch_metadata.return_value = True
            mock_cache_instance.get_cached_entry.return_value = None

            result = builder.build(use_cache=True, cache_only=True)
            assert result is False

    def test_build_with_use_cache_metadata_fails_cache_only(self, builder):
        with patch('builder.BuildCache') as mock_build_cache:
            mock_cache_instance = mock_build_cache.return_value
            mock_cache_instance.fetch_metadata.return_value = False

            result = builder.build(use_cache=True, cache_only=True)
            assert result is False

    def test_build_with_use_cache_fallback_full_build(self, builder):
        # When use_cache=True, but cache is not available, it falls back to full build.
        # We need to mock the full build stages to succeed.
        with patch('builder.BuildCache') as mock_build_cache:
            mock_cache_instance = mock_build_cache.return_value
            mock_cache_instance.fetch_metadata.return_value = True
            mock_cache_instance.get_cached_entry.return_value = None

            # Mock the executor to simulate successful build
            with patch.object(builder.executor, 'run_script', return_value=True):
                result = builder.build(use_cache=True, cache_only=False)
                assert result is True
                # Ensure run_script was called (i.e., full build executed)
                builder.executor.run_script.assert_called()