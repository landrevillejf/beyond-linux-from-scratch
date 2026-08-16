import pytest
import tarfile
import json
from pathlib import Path
from unittest.mock import patch, MagicMock
from builder import LFSBuilder


class TestKernelValidation:

    def test_kernel_archive_missing_arch(self, tmp_path):
        """Si le Makefile de l'arch est manquant, on le retélécharge."""
        builder = LFSBuilder(
            profile='arm64',
            output_dir=tmp_path,
            config_file='config/build.conf'
        )
        builder.config.set('kernel.version', '6.16.1')
        builder.config.set('architecture', 'aarch64')
        builder.config.set('cross_compile', True)
        builder._generated_sources_list = tmp_path / 'sources.list'

        sources_dir = builder.output_dir / 'sources'
        sources_dir.mkdir(parents=True)

        kernel_version = '6.16.1'
        tarball_path = sources_dir / f'linux-{kernel_version}.tar.xz'
        # Créer un tarball sans arch/aarch64
        with tarfile.open(tarball_path, 'w:xz') as tar:
            info = tarfile.TarInfo('linux-6.16.1/README')
            info.type = tarfile.REGTYPE
            info.size = 0
            tar.addfile(info)

        kernel_url = f"https://www.kernel.org/pub/linux/kernel/v6.x/linux-{kernel_version}.tar.xz"

        with patch.object(builder.downloader, 'download', return_value=True) as mock_download:
            builder.download_sources()
            # Vérifier que l'URL du noyau a été appelée
            calls = [c[0][0] for c in mock_download.call_args_list]
            assert kernel_url in calls

    def test_kernel_archive_corrupt(self, tmp_path):
        """Si le tarball est corrompu, on le retélécharge."""
        builder = LFSBuilder(
            profile='arm64',
            output_dir=tmp_path,
            config_file='config/build.conf'
        )
        builder.config.set('kernel.version', '6.16.1')
        builder.config.set('architecture', 'aarch64')
        builder.config.set('cross_compile', True)
        builder._generated_sources_list = tmp_path / 'sources.list'

        sources_dir = builder.output_dir / 'sources'
        sources_dir.mkdir(parents=True)

        kernel_version = '6.16.1'
        tarball_path = sources_dir / f'linux-{kernel_version}.tar.xz'
        tarball_path.write_text('this is not a tar file')

        kernel_url = f"https://www.kernel.org/pub/linux/kernel/v6.x/linux-{kernel_version}.tar.xz"

        with patch.object(builder.downloader, 'download', return_value=True) as mock_download:
            builder.download_sources()
            calls = [c[0][0] for c in mock_download.call_args_list]
            assert kernel_url in calls

    def test_kernel_archive_not_exists(self, tmp_path):
        """Si le tarball n'existe pas, on le télécharge."""
        builder = LFSBuilder(
            profile='arm64',
            output_dir=tmp_path,
            config_file='config/build.conf'
        )
        builder.config.set('kernel.version', '6.16.1')
        builder.config.set('architecture', 'aarch64')
        builder.config.set('cross_compile', True)
        builder._generated_sources_list = tmp_path / 'sources.list'

        sources_dir = builder.output_dir / 'sources'
        sources_dir.mkdir(parents=True)

        # Pas de tarball
        kernel_version = '6.16.1'
        kernel_url = f"https://www.kernel.org/pub/linux/kernel/v6.x/linux-{kernel_version}.tar.xz"

        with patch.object(builder.downloader, 'download', return_value=True) as mock_download:
            builder.download_sources()
            calls = [c[0][0] for c in mock_download.call_args_list]
            assert kernel_url in calls

    def test_kernel_validation_skipped_if_not_cross_compile(self, tmp_path, monkeypatch):
        """Si cross_compile=False, la validation est ignorée et le noyau n'est pas téléchargé."""
        # Isoler le test dans un répertoire temporaire pour éviter les fichiers réels
        monkeypatch.chdir(tmp_path)

        # Créer un fichier de configuration
        config_file = tmp_path / 'build.conf'
        config_data = {
            "cross_compile": False,
            "architecture": "x86_64",
            "kernel": {"version": "6.16.1"},
            "repositories": ["https://example.com/wget-list"]
        }
        with open(config_file, 'w') as f:
            json.dump(config_data, f)

        # Créer un dossier packages avec un custom-sources.list vide
        packages_dir = tmp_path / 'packages'
        packages_dir.mkdir()
        (packages_dir / 'custom-sources.list').write_text('')
        (packages_dir / 'sources.list').write_text('')  # facultatif

        builder = LFSBuilder(
            profile='minimal',
            output_dir=tmp_path,
            config_file=config_file
        )
        builder.config.set('kernel.version', '6.16.1')
        builder.config.set('architecture', 'x86_64')
        builder.config.set('cross_compile', False)
        builder._generated_sources_list = tmp_path / 'sources.list'

        sources_dir = builder.output_dir / 'sources'
        sources_dir.mkdir(parents=True)

        kernel_version = '6.16.1'
        tarball_path = sources_dir / f'linux-{kernel_version}.tar.xz'
        tarball_path.write_text('corrupt')  # sera ignoré car cross_compile=False

        kernel_url = f"https://www.kernel.org/pub/linux/kernel/v6.x/linux-{kernel_version}.tar.xz"

        # Simuler une réponse du repository sans l'URL du noyau
        fake_repo_content = b"https://example.com/other-package.tar.gz\n"
        with patch('urllib.request.urlopen', return_value=MagicMock(read=lambda: fake_repo_content)) as mock_urlopen:
            with patch.object(builder.downloader, 'download', return_value=True) as mock_download:
                builder.download_sources()
                # Vérifier que l'URL du noyau n'a PAS été appelée
                kernel_calls = [c for c in mock_download.call_args_list if c[0][0] == kernel_url]
                assert len(kernel_calls) == 0

    def test_kernel_archive_makefile_not_regular_file(self, tmp_path, monkeypatch):
        """Si le Makefile de l'arch existe mais n'est pas un fichier régulier, on le retélécharge."""
        monkeypatch.chdir(tmp_path)

        config_file = tmp_path / 'build.conf'
        config_data = {
            "cross_compile": True,
            "architecture": "aarch64",
            "kernel": {"version": "6.16.1"},
            "repositories": ["https://example.com/wget-list"]
        }
        with open(config_file, 'w') as f:
            json.dump(config_data, f)

        packages_dir = tmp_path / 'packages'
        packages_dir.mkdir()
        (packages_dir / 'custom-sources.list').write_text('')
        (packages_dir / 'sources.list').write_text('')

        builder = LFSBuilder(
            profile='arm64',
            output_dir=tmp_path,
            config_file=config_file
        )
        builder.config.set('kernel.version', '6.16.1')
        builder.config.set('architecture', 'aarch64')
        builder.config.set('cross_compile', True)
        builder._generated_sources_list = tmp_path / 'sources.list'

        sources_dir = builder.output_dir / 'sources'
        sources_dir.mkdir(parents=True)

        kernel_version = '6.16.1'
        tarball_path = sources_dir / f'linux-{kernel_version}.tar.xz'

        # Créer un tarball où arch/aarch64/Makefile est un lien symbolique
        import os
        with tarfile.open(tarball_path, 'w:xz') as tar:
            # Créer un répertoire arch/aarch64
            dir_info = tarfile.TarInfo('linux-6.16.1/arch/aarch64')
            dir_info.type = tarfile.DIRTYPE
            tar.addfile(dir_info)
            # Ajouter un lien symbolique pour Makefile
            link_info = tarfile.TarInfo('linux-6.16.1/arch/aarch64/Makefile')
            link_info.type = tarfile.SYMTYPE
            link_info.linkname = 'dummy'
            tar.addfile(link_info)

        kernel_url = f"https://www.kernel.org/pub/linux/kernel/v6.x/linux-{kernel_version}.tar.xz"

        fake_repo_content = b"https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.16.1.tar.xz\nhttps://example.com/other-package.tar.gz\n"
        with patch('urllib.request.urlopen', return_value=MagicMock(read=lambda: fake_repo_content)) as mock_urlopen:
            with patch.object(builder.downloader, 'download', return_value=True) as mock_download:
                builder.download_sources()
                # Vérifier que l'URL du noyau a été appelée (retéléchargement)
                calls = [c[0][0] for c in mock_download.call_args_list]
                assert kernel_url in calls
                # Vérifier que le fichier a été supprimé (il ne doit plus exister)
                assert not tarball_path.exists()

    def test_main_arch_x86_64_sets_grub_bootloader(self, monkeypatch):
        """Vérifie que --arch x86_64 définit bootloader.type = grub."""
        from builder import main
        import sys

        test_args = ['builder.py', '--arch', 'x86_64', '--profile', 'minimal']
        monkeypatch.setattr(sys, 'argv', test_args)

        with patch('builder.LFSBuilder') as MockBuilder:
            mock_instance = MagicMock()
            MockBuilder.return_value = mock_instance

            # Simuler les appels de config.get pour éviter les erreurs
            def get_side_effect(key, default=None):
                # On retourne des valeurs factices pour éviter que main ne plante
                if key == 'live_system.enabled':
                    return True
                if key == 'kernel.type':
                    return 'linux'
                if key == 'init_system.choice':
                    return 'sysvinit'
                if key == 'desktop.type':
                    return None
                return default
            mock_instance.config.get.side_effect = get_side_effect

            # Mocker ProfileManager.get_profile_info pour éviter l'affichage
            with patch('builder.ProfileManager.get_profile_info', return_value=''):
                with patch('sys.exit'):
                    main()
                    # Vérifier que config.set a été appelé avec ('bootloader.type', 'grub')
                    calls = mock_instance.config.set.call_args_list
                    assert any(call[0] == ('bootloader.type', 'grub') for call in calls)


# ============================================================================
# Tests extraits de la classe TestKernelValidation
# ============================================================================

def test_validate_kernel_archive_missing_file(tmp_path):
    from builder import LFSBuilder
    builder = LFSBuilder(
        profile='minimal',
        output_dir=tmp_path,
        config_file=tmp_path / 'config.json'
    )
    kernel_archive = tmp_path / 'nonexistent.tar.xz'
    assert builder._validate_kernel_archive(kernel_archive, '6.16.1') is False


def test_kernel_archive_valid(tmp_path):
    import shutil
    import tarfile
    from unittest.mock import patch, Mock, call
    from builder import LFSBuilder, SourceDownloader

    # Créer une archive valide avec la structure correcte pour aarch64 → arm64
    archive_path = tmp_path / 'linux-6.16.1.tar.xz'
    with tarfile.open(archive_path, 'w:xz') as tar:
        # Le code _validate_kernel_archive utilise _get_kernel_arch() qui renvoie "arm64" pour aarch64
        info = tarfile.TarInfo(name='linux-6.16.1/arch/arm64/Makefile')
        info.type = tarfile.REGTYPE
        info.size = 0
        tar.addfile(info)

    # Créer un builder en cross-compilation pour aarch64
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

        # S'assurer que l'archive est bien placée dans le répertoire sources
        sources_dir = builder.output_dir / 'sources'
        sources_dir.mkdir(parents=True, exist_ok=True)
        dest_archive = sources_dir / 'linux-6.16.1.tar.xz'
        shutil.copy(archive_path, dest_archive)

        # Mock _update_sources_list pour ne pas interférer
        with patch.object(builder, '_update_sources_list', return_value=True):
            # Mock du downloader pour capturer les appels
            builder.downloader = Mock(spec=SourceDownloader)
            builder.downloader.download.return_value = True

            # Appeler download_sources
            result = builder.download_sources()

            # Vérifier que le résultat est True (l'archive est valide)
            assert result is True

            # Vérifier que download n'a PAS été appelé avec l'URL du noyau
            kernel_url = "https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.16.1.tar.xz"
            calls = [call[0][0] for call in builder.downloader.download.call_args_list]
            assert kernel_url not in calls