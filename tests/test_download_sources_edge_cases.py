#!/usr/bin/env python3
"""Edge cases of LFSBuilder.download_sources() and _validate_kernel_archive().

This file was tests/abc.py: tracked, containing five tests, and never
executed, because tests/pytest.ini sets python_files = test_*.py.  It also
held two definitions of four of those tests, so only the second copy ever
bound a name -- the first four were dead code.  Renaming it here makes the
assertions run in every suite pass.

The two "sources.list missing" cases used to delete packages/sources.list
from the repository before calling download_sources(), because that method
probes the CWD-relative Path('packages/sources.list').  That side effect
removed a generated file from the developer's tree, so the cases now change
the working directory into tmp_path instead: same relative path, same
scenario, nothing touched outside the fixture.
"""

import logging
import tarfile
from unittest.mock import Mock, patch

from builder import LFSBuilder, SourceDownloader


def test_download_sources_sources_list_missing_with_repos(tmp_path, monkeypatch):
    """A configured repository cannot rescue a missing sources.list."""
    config_data = {
        'repositories': ['https://example.com/wget-list'],
        'build_options': {'download_timeout': 300, 'retry_downloads': 3},
        'kernel': {'version': '6.16.1', 'type': 'linux'},
        'init_system': {'choice': 'sysvinit'},
        'cross_compile': False,
        'architecture': 'x86_64',
        'target_triplet': 'x86_64-lfs-linux-gnu',
        'build_threads': 4,
        'logging': {'level': 'INFO'}
    }

    config_file = tmp_path / 'config.json'
    config_file.write_text('{}')
    monkeypatch.chdir(tmp_path)

    with patch('builder.LFSConfig') as MockConfig:
        mock_config = MockConfig.return_value
        mock_config.get.side_effect = lambda key, default=None: config_data.get(key, default)
        mock_config.data = config_data

        builder = LFSBuilder(
            profile='minimal',
            output_dir=tmp_path / 'output',
            config_file=config_file
        )
        builder.logger = Mock(spec=logging.Logger)
        builder._generated_sources_list = None

        with patch.object(builder, '_update_sources_list', return_value=False):
            builder.downloader = Mock(spec=SourceDownloader)

            def exists_side_effect(*args, **kwargs):
                return False

            with patch('pathlib.Path.exists', side_effect=exists_side_effect):
                result = builder.download_sources()
                assert result is False
                builder.logger.error.assert_called_once()
                assert "Sources list not found" in builder.logger.error.call_args[0][0]


def test_download_sources_kernel_invalid_after_download(tmp_path):
    """Cross-compile: an unusable kernel tarball fails the download stage."""
    config_data = {
        'cross_compile': True,
        'architecture': 'aarch64',
        'kernel': {'version': '6.16.1', 'type': 'linux'},
        'repositories': [],
        'build_options': {'download_timeout': 300, 'retry_downloads': 3},
        'init_system': {'choice': 'sysvinit'},
        'target_triplet': 'aarch64-lfs-linux-gnu',
        'build_threads': 4,
        'logging': {'level': 'INFO'}
    }

    config_file = tmp_path / 'config.json'
    config_file.write_text('{}')

    with patch('builder.LFSConfig') as MockConfig:
        mock_config = MockConfig.return_value
        mock_config.get.side_effect = lambda key, default=None: config_data.get(key, default)
        mock_config.data = config_data

        builder = LFSBuilder(
            profile='arm64',
            output_dir=tmp_path / 'output',
            config_file=config_file
        )
        builder.logger = Mock(spec=logging.Logger)

        kernel_archive = builder.output_dir / 'sources' / 'linux-6.16.1.tar.xz'
        kernel_archive.parent.mkdir(parents=True, exist_ok=True)
        kernel_archive.touch()

        builder._validate_kernel_archive = Mock(return_value=False)
        builder.downloader = Mock(spec=SourceDownloader)
        builder.downloader.download.return_value = True

        sources_file = builder.output_dir / 'packages' / 'sources.list'
        sources_file.parent.mkdir(parents=True, exist_ok=True)
        sources_file.write_text('# dummy\n')

        checksum_file = builder.output_dir / 'packages' / 'md5sums'
        checksum_file.parent.mkdir(parents=True, exist_ok=True)
        checksum_file.write_text('')

        with patch.object(builder, '_update_sources_list', return_value=False):
            result = builder.download_sources()
            assert result is False
            builder.logger.error.assert_called_once()
            assert ("Kernel tarball still invalid after download"
                    in builder.logger.error.call_args[0][0])


def test_download_sources_sources_list_missing_no_repos(tmp_path, monkeypatch):
    """No repository at all: an empty sources.list is created, not an error."""
    config_data = {
        'repositories': [],
        'build_options': {'download_timeout': 300, 'retry_downloads': 3},
        'kernel': {'version': '6.16.1', 'type': 'linux'},
        'init_system': {'choice': 'sysvinit'},
        'cross_compile': False,
        'architecture': 'x86_64',
        'target_triplet': 'x86_64-lfs-linux-gnu',
        'build_threads': 4,
        'logging': {'level': 'INFO'}
    }

    config_file = tmp_path / 'config.json'
    config_file.write_text('{}')
    monkeypatch.chdir(tmp_path)

    with patch('builder.LFSConfig') as MockConfig:
        mock_config = MockConfig.return_value
        mock_config.get.side_effect = lambda key, default=None: config_data.get(key, default)
        mock_config.data = config_data

        builder = LFSBuilder(
            profile='minimal',
            output_dir=tmp_path / 'output',
            config_file=config_file
        )
        builder.logger = Mock(spec=logging.Logger)
        builder._generated_sources_list = None

        sources_file = builder.output_dir / 'packages' / 'sources.list'

        builder.downloader = Mock(spec=SourceDownloader)
        builder.downloader.download_from_list.return_value = True

        with patch.object(builder, '_update_sources_list', return_value=False):
            result = builder.download_sources()
            assert result is True
            assert sources_file.exists()
            builder.logger.warning.assert_called_with(
                f"Sources list not found and no repositories configured; "
                f"created empty list: {sources_file}"
            )


def test_validate_kernel_archive_exception(tmp_path):
    """An unreadable tarball is reported as invalid, not raised."""
    builder = LFSBuilder(
        profile='minimal',
        output_dir=tmp_path,
        config_file=tmp_path / 'config.json'
    )
    builder.get_target_architecture = Mock(return_value='aarch64')
    kernel_archive = tmp_path / 'dummy'

    with patch('tarfile.open', side_effect=tarfile.ReadError):
        assert builder._validate_kernel_archive(kernel_archive, '6.16.1') is False


def test_validate_kernel_archive_missing_file(tmp_path):
    """A kernel archive that is not there fails validation."""
    builder = LFSBuilder(
        profile='minimal',
        output_dir=tmp_path,
        config_file=tmp_path / 'config.json'
    )
    kernel_archive = tmp_path / 'nonexistent.tar.xz'
    assert builder._validate_kernel_archive(kernel_archive, '6.16.1') is False
