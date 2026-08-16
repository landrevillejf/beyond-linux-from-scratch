#!/usr/bin/env python3
"""
Tests spécifiques pour couvrir les lignes 1490, 1447‑1451 et 1482‑1487 de builder.py.
"""

import pytest
import logging
import tarfile
from pathlib import Path
from unittest.mock import Mock, patch, MagicMock

from builder import LFSBuilder, SourceDownloader


# ============================================================================
# Test 1 : Ligne 1490 – sources.list absent ET repositories configurés
# ============================================================================

def test_download_sources_sources_list_missing_with_repos(tmp_path):
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
        if sources_file.exists():
            sources_file.unlink()
        if Path('packages/sources.list').exists():
            Path('packages/sources.list').unlink()

        with patch.object(builder, '_update_sources_list', return_value=False):
            builder.downloader = Mock(spec=SourceDownloader)
            def exists_side_effect(*args, **kwargs):
                # On retourne False pour tout -> sources.list n'existe pas
                return False
            with patch('pathlib.Path.exists', side_effect=exists_side_effect):
                result = builder.download_sources()
                assert result is False
                builder.logger.error.assert_called_once()
                assert "Sources list not found" in builder.logger.error.call_args[0][0]


# ============================================================================
# Test 2 : Lignes 1447‑1451 – cross‑compilation, tarball invalide après téléchargement
# ============================================================================

def test_download_sources_kernel_invalid_after_download(tmp_path):
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
            # On ne patch pas Path.exists, on laisse les fichiers réels
            result = builder.download_sources()
            assert result is False
            builder.logger.error.assert_called_once()
            assert "Kernel tarball still invalid after download" in builder.logger.error.call_args[0][0]


# ============================================================================
# Test 3 : Lignes 1482‑1487 – sources.list absent, aucun repo → création
# ============================================================================

def test_download_sources_sources_list_missing_no_repos(tmp_path):
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
        if sources_file.exists():
            sources_file.unlink()
        if Path('packages/sources.list').exists():
            Path('packages/sources.list').unlink()

        builder.downloader = Mock(spec=SourceDownloader)
        builder.downloader.download_from_list.return_value = True

        # On ne patch pas Path.exists, on laisse les fichiers réels
        with patch.object(builder, '_update_sources_list', return_value=False):
            # Maintenant on appelle download_sources sans patch, donc le code va voir que
            # sources_file n'existe pas, et comme repositories est vide, il va créer le fichier.
            result = builder.download_sources()
            assert result is True
            # On vérifie que le fichier a bien été créé
            assert sources_file.exists()
            builder.logger.warning.assert_called_with(
                f"Sources list not found and no repositories configured; "
                f"created empty list: {sources_file}"
            )


# ============================================================================
# Test 4 : validation de l'archive – gestion des exceptions
# ============================================================================

def test_validate_kernel_archive_exception(tmp_path):
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
    builder = LFSBuilder(
        profile='minimal',
        output_dir=tmp_path,
        config_file=tmp_path / 'config.json'
    )
    kernel_archive = tmp_path / 'nonexistent.tar.xz'
    assert builder._validate_kernel_archive(kernel_archive, '6.16.1') is False


def test_validate_kernel_archive_valid(tmp_path):
    archive_path = tmp_path / 'linux-6.16.1.tar.xz'
    with tarfile.open(archive_path, 'w:xz') as tar:
        info = tarfile.TarInfo(name='linux-6.16.1/arch/aarch64/Makefile')
        info.type = tarfile.REGTYPE
        info.size = 0
        tar.addfile(info)

    builder = LFSBuilder(
        profile='minimal',
        output_dir=tmp_path,
        config_file=tmp_path / 'config.json'
    )
    builder.get_target_architecture = Mock(return_value='aarch64')
    assert builder._validate_kernel_archive(archive_path, '6.16.1') is True