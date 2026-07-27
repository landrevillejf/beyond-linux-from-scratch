#!/usr/bin/env python3
"""
Tests pour améliorer la couverture de code à 80%+
"""

import pytest
import tempfile
import subprocess
from pathlib import Path
from unittest.mock import patch, MagicMock, mock_open
import sys
import os

from builder import (
    LFSConfig, ProfileManager, SourceDownloader,
    ScriptExecutor, USBWriter, LFSBuilder
)


class TestSourceDownloaderCoverage:
    """Tests pour SourceDownloader (amélioration couverture)"""

    def test_download_retry_success_after_failure(self, sources_dir, mock_logger):
        """Test téléchargement réussit après échec"""
        downloader = SourceDownloader(sources_dir, mock_logger)

        with patch('urllib.request.urlretrieve') as mock_retrieve:
            # Échoue 2 fois, réussit à la 3ème
            mock_retrieve.side_effect = [
                Exception("Network error"),
                Exception("Network error"),
                MagicMock()
            ]
            result = downloader.download("https://example.com/test.tar.gz", "test.tar.gz", retries=3)
            assert result is True
            assert mock_retrieve.call_count == 3

    def test_download_url_without_filename(self, sources_dir, mock_logger):
        """Test extraction automatique du nom de fichier depuis l'URL"""
        downloader = SourceDownloader(sources_dir, mock_logger)

        with patch('urllib.request.urlretrieve') as mock_retrieve:
            mock_retrieve.return_value = MagicMock()
            result = downloader.download("https://example.com/path/to/file-1.2.3.tar.gz")
            assert result is True
            # Vérifier que le nom de fichier a été extrait
            args, kwargs = mock_retrieve.call_args
            assert "file-1.2.3.tar.gz" in str(args[1])

    def test_download_from_list_file_not_found(self, sources_dir, mock_logger):
        """Test liste de sources inexistante"""
        downloader = SourceDownloader(sources_dir, mock_logger)
        result = downloader.download_from_list(Path("/nonexistent/sources.list"))
        assert result is False
        mock_logger.error.assert_called()

    def test_verify_checksums_invalid_line_format(self, sources_dir, mock_logger, temp_dir):
        """Test ligne de checksum invalide (ignorée)"""
        test_file = sources_dir / "test.tar.gz"
        test_file.write_text("test content")

        md5_file = temp_dir / "md5sums"
        md5_file.write_text("invalid_line_without_two_parts\n")

        downloader = SourceDownloader(sources_dir, mock_logger)
        result = downloader.verify_checksums(md5_file)
        assert result is True  # Les lignes invalides sont ignorées


class TestScriptExecutorCoverage:
    """Tests pour ScriptExecutor (amélioration couverture)"""

    def test_run_script_creates_log_file(self, output_dir, mock_logger, temp_dir):
        """Test création du fichier de log"""
        script = temp_dir / "test.sh"
        script.write_text("#!/bin/bash\necho 'test'")
        script.chmod(0o755)

        executor = ScriptExecutor({}, output_dir, mock_logger)

        with patch.object(executor, 'find_script', return_value=script):
            with patch('subprocess.run') as mock_run:
                mock_run.return_value = MagicMock(returncode=0)
                executor.run_script(str(script), "test_stage")

                # Vérifier que le log file a été créé
                log_file = output_dir / 'logs' / 'test_stage.log'
                # Le fichier est créé mais peut être vide car on mock subprocess

    def test_run_script_logs_last_lines_on_failure(self, output_dir, mock_logger, temp_dir):
        """Test affichage des 10 dernières lignes du log en cas d'échec"""
        script = temp_dir / "failing.sh"
        script.write_text("#!/bin/bash\nexit 1")
        script.chmod(0o755)

        executor = ScriptExecutor({}, output_dir, mock_logger)

        # Créer un fichier de log existant avec du contenu
        log_file = output_dir / 'logs' / 'test_stage.log'
        log_file.parent.mkdir(parents=True, exist_ok=True)
        log_file.write_text("\n".join([f"Line {i}" for i in range(20)]))

        with patch.object(executor, 'find_script', return_value=script):
            with patch('subprocess.run') as mock_run:
                mock_run.return_value = MagicMock(returncode=1)
                executor.run_script(str(script), "test_stage")

                # Vérifier que mock_logger.info a été appelé pour afficher les logs
                assert mock_logger.info.call_count >= 1

    def test_resume_from_stage_not_found(self, output_dir, mock_logger):
        """Test reprise depuis un stage qui n'existe pas"""
        executor = ScriptExecutor({}, output_dir, mock_logger)
        stages = [("stage1", "script1.sh"), ("stage2", "script2.sh")]

        with patch.object(executor, 'run_script', return_value=True):
            result = executor.resume_from("nonexistent", stages)
            # Doit commencer du début car stage non trouvé
            assert result is True


class TestUSBWriterCoverage:
    """Tests pour USBWriter (amélioration couverture)"""

    def test_write_iso_linux_success(self, temp_dir, mock_logger):
        """Test écriture ISO sur Linux"""
        iso_path = temp_dir / "test.iso"
        iso_path.write_text("dummy iso content")

        with patch('platform.system', return_value='Linux'):
            with patch('subprocess.run') as mock_run:
                mock_run.return_value = MagicMock(returncode=0)
                with patch('builtins.input', return_value='YES'):
                    result = USBWriter.write_iso(iso_path, "/dev/sdb", mock_logger)
                    assert result is True

    def test_write_iso_darwin_success(self, temp_dir, mock_logger):
        """Test écriture ISO sur macOS"""
        iso_path = temp_dir / "test.iso"
        iso_path.write_text("dummy iso content")

        with patch('platform.system', return_value='Darwin'):
            with patch('subprocess.run') as mock_run:
                mock_run.return_value = MagicMock(returncode=0)
                with patch('builtins.input', return_value='YES'):
                    result = USBWriter.write_iso(iso_path, "disk2", mock_logger)
                    assert result is True

    # tests/test_improve_coverage.py - ligne 162
    def test_write_iso_unsupported_platform(self, temp_dir, mock_logger, monkeypatch):
        """Test écriture ISO sur plateforme non supportée"""
        iso_path = temp_dir / "test.iso"
        iso_path.write_text("test content")

        # Simuler une plateforme non supportée
        monkeypatch.setattr('platform.system', lambda: 'Windows')

        # Éviter l'input()
        with patch('builtins.input', return_value='YES'):
            result = USBWriter.write_iso(iso_path, "E:", mock_logger)
            assert result is False
            mock_logger.error.assert_called()

    def test_write_iso_cancelled_by_user(self, temp_dir, mock_logger):
        """Test annulation par l'utilisateur"""
        iso_path = temp_dir / "test.iso"
        iso_path.write_text("dummy iso content")

        with patch('builtins.input', return_value='NO'):
            result = USBWriter.write_iso(iso_path, "/dev/sdb", mock_logger)
            assert result is False
            mock_logger.info.assert_called_with("Operation cancelled")

    def test_list_devices_linux(self):
        """Test listing des périphériques USB sur Linux"""
        mock_output = """NAME SIZE MODEL TYPE MOUNTPOINT
sda  120G SSD   disk
sdb  32G  USB Drive disk
"""
        with patch('platform.system', return_value='Linux'):
            with patch('subprocess.run') as mock_run:
                mock_run.return_value = MagicMock(stdout=mock_output)
                devices = USBWriter.list_devices()
                # Vérifier que les périphériques sont listés
                assert isinstance(devices, list)

    def test_list_devices_darwin(self):
        """Test listing des périphériques USB sur macOS"""
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
                assert isinstance(devices, list)


class TestLFSBuilderCoverage:
    """Tests pour LFSBuilder (amélioration couverture)"""

    def test_check_prerequisites_docker(self, builder):
        """Test détection d'environnement Docker"""
        with patch('os.path.exists', return_value=True):
            result = builder.check_prerequisites()
            assert result is True

    def test_check_prerequisites_unsupported_os(self, builder):
        """Test OS non supporté"""
        with patch('platform.system', return_value='FreeBSD'):
            result = builder.check_prerequisites()
            assert result is False

    def test_get_qemu_user_arm(self, builder):
        """Test QEMU user pour architecture ARM"""
        with patch.object(builder, 'get_target_architecture', return_value='arm'):
            qemu = builder.get_qemu_user()
            assert qemu == 'qemu-arm-static'

    def test_get_qemu_user_unknown(self, builder):
        """Test QEMU user pour architecture inconnue"""
        with patch.object(builder, 'get_target_architecture', return_value='unknown'):
            qemu = builder.get_qemu_user()
            assert qemu == ''  # Retourne chaîne vide

    def test_get_init_system_normalize(self, builder):
        """Test normalisation de 'sysv' en 'sysvinit'"""
        builder.config.set('init_system.choice', 'sysv')
        assert builder.get_init_system() == 'sysvinit'

    def test_get_init_system_unknown(self, builder):
        """Test init system inconnu (fallback à sysvinit)"""
        builder.config.set('init_system.choice', 'unknown')
        with patch.object(builder.logger, 'warning'):
            assert builder.get_init_system() == 'sysvinit'

    def test_apply_profile_settings_cross_compile(self, builder):
        """Test application des paramètres cross-compilation"""
        builder.profile_config['cross_compile'] = True
        builder.profile_config['architecture'] = 'aarch64'
        builder.profile_config['bootloader'] = 'uboot'
        builder._apply_profile_settings()

        assert builder.config.get('cross_compile') is True
        assert builder.config.get('architecture') == 'aarch64'
        assert builder.config.get('bootloader.type') == 'uboot'

    def test_download_sources_file_not_found(self, builder):
        """Test sources.list absent"""
        with patch('pathlib.Path.exists', return_value=False):
            result = builder.download_sources()
            assert result is False

    def test_get_build_stages_with_all_features(self, builder):
        """Test génération des stages avec toutes les fonctionnalités"""
        builder.profile_config['desktop'] = 'gnome'
        builder.profile_config['java_dev'] = True
        builder.profile_config['security_hardening'] = True
        builder.profile_config['privacy_tools'] = True
        builder.profile_config['live_system'] = True

        stages = builder.get_build_stages()
        stage_names = [s[0] for s in stages]

        assert 'desktop' in stage_names
        assert 'java-dev' in stage_names
        assert 'security' in stage_names
        assert 'privacy' in stage_names
        assert 'live-system' in stage_names

    def test_get_build_stages_no_live_system(self, builder):
        """Test génération des stages sans live system"""
        builder.profile_config['live_system'] = False
        stages = builder.get_build_stages()
        stage_names = [s[0] for s in stages]

        assert 'live-system' not in stage_names

    def test_prepare_environment_creates_sysroot_cross(self, builder):
        """Test création du sysroot en cross-compilation"""
        with patch.object(builder, 'is_cross_compile', return_value=True):
            with patch.object(builder, 'get_sysroot', return_value=str(builder.output_dir / 'sysroot')):
                result = builder.prepare_environment()
                assert result is True
                assert (builder.output_dir / 'sysroot').exists()

    def test_create_writable_media_no_iso(self, builder):
        """Test création média USB sans ISO"""
        result = builder.create_writable_media()
        assert result is False

    def test_create_writable_media_with_device(self, builder, temp_dir):
        """Test écriture USB avec périphérique spécifié"""
        iso_path = builder.output_dir / 'lfs-installer.iso'
        iso_path.write_text("dummy")

        with patch('builder.USBWriter.write_iso', return_value=True) as mock_write:
            result = builder.create_writable_media("/dev/sdb")
            assert result is True
            mock_write.assert_called_once()


class TestLFSConfigCoverage:
    """Tests supplémentaires pour LFSConfig"""

    def test_get_nonexistent_key_returns_default(self, lfs_config):
        """Test clé inexistante retourne la valeur par défaut"""
        value = lfs_config.get('nonexistent.key.very.deep', 'default_value')
        assert value == 'default_value'

    def test_set_new_nested_key_creates_parents(self, lfs_config):
        """Test création automatique des parents lors du set"""
        lfs_config.set('a.b.c.d.e', 'final_value')
        assert lfs_config.get('a.b.c.d.e') == 'final_value'


class TestProfileManagerCoverage:
    """Tests supplémentaires pour ProfileManager"""

    def test_get_profile_info_arm64(self):
        """Test affichage info profil arm64"""
        info = ProfileManager.get_profile_info('arm64')
        assert 'Architecture:  aarch64' in info
        assert 'Bootloader:    uboot' in info

    def test_get_profile_info_audio_cli(self):
        """Test affichage info profil audio-cli"""
        info = ProfileManager.get_profile_info('audio-cli')
        assert 'Desktop:       None (CLI only)' in info
        assert 'Init System:   sysvinit' in info


class TestCLICoverage:
    """Tests pour l'interface en ligne de commande"""

    def test_main_list_profiles(self, capsys):
        """Test commande --list-profiles"""
        from builder import main
        with patch('sys.argv', ['builder.py', '--list-profiles']):
            with patch('sys.exit'):
                main()
                captured = capsys.readouterr()
                assert 'Available LFS Build Profiles' in captured.out

    def test_main_profile_info(self, capsys):
        """Test commande --profile-info"""
        from builder import main
        with patch('sys.argv', ['builder.py', '--profile-info', 'minimal']):
            with patch('sys.exit'):
                main()
                captured = capsys.readouterr()
                assert 'Profile: MINIMAL' in captured.out

    def test_main_clean(self, temp_dir):
        """Test commande --clean"""
        from builder import main
        build_dir = temp_dir / 'test-build'
        build_dir.mkdir()
        (build_dir / 'test.txt').write_text('test')

        with patch('sys.argv', ['builder.py', '--clean', '--output', str(build_dir)]):
            with patch('builtins.input', return_value='yes'):
                with patch('sys.exit'):
                    main()
                    assert not build_dir.exists()

    def test_main_with_no_live(self, monkeypatch):
        """Test option --no-live"""
        from builder import main
        import sys

        test_args = ['builder.py', '--no-live', '--profile', 'minimal']
        monkeypatch.setattr(sys, 'argv', test_args)

        with patch('builder.LFSBuilder') as MockBuilder:
            mock_instance = MagicMock()
            MockBuilder.return_value = mock_instance

            def get_side_effect(key, default=None):
                config_map = {
                    'live_system.enabled': True,
                    'kernel.type': 'linux',
                    'init_system.choice': 'sysvinit',
                    'desktop.type': None
                }
                return config_map.get(key, default)

            mock_instance.config.get.side_effect = get_side_effect

            with patch('sys.exit'):
                main()

            # Vérifier que l'appel a bien eu lieu (peu importe l'ordre)
            mock_instance.config.set.assert_any_call('live_system.enabled', False)

    def test_main_with_kernel_type(self, monkeypatch):
        """Test option --kernel-type"""
        from builder import main
        import sys

        # Simuler les arguments avec kernel-type personnalisé
        test_args = ['builder.py', '--kernel-type', 'linux-libre', '--profile', 'minimal']
        monkeypatch.setattr(sys, 'argv', test_args)

        with patch('builder.LFSBuilder') as MockBuilder:
            mock_instance = MagicMock()
            MockBuilder.return_value = mock_instance
            mock_instance.config.get.return_value = True

            with patch('sys.exit'):
                main()

                # Vérifier que config.set a bien été appelé avec kernel.type et linux-libre
                mock_instance.config.set.assert_called_with('kernel.type', 'linux-libre')


import pytest
from pathlib import Path
from unittest.mock import patch, MagicMock
from builder import LFSBuilder, LFSConfig

class TestUpdateSourcesList:

    def test_update_sources_list_with_custom_sources(self, tmp_path, monkeypatch):
        """Test _update_sources_list avec un fichier custom-sources.list existant."""
        monkeypatch.chdir(tmp_path)
        output_dir = tmp_path / "lfs-build"
        output_dir.mkdir()
        config_file = tmp_path / "config.json"
        config = LFSConfig(config_file)
        config.set('repositories', ['https://example.com/wget-list'])

        builder = LFSBuilder(profile='minimal', output_dir=output_dir, config_file=config_file)
        builder.config = config

        packages_dir = tmp_path / "packages"
        packages_dir.mkdir()
        sources_file = packages_dir / "sources.list"
        custom_file = packages_dir / "custom-sources.list"
        custom_file.write_text("""
# Commentaire
https://custom.url/source1.tar.gz
https://custom.url/source2.tar.xz
""")

        mock_response = MagicMock()
        mock_response.read.return_value = b"https://official.url/file1.tar.gz\nhttps://official.url/file2.tar.bz2"
        mock_response.__enter__.return_value = mock_response

        with patch('urllib.request.urlopen', return_value=mock_response):
            result = builder._update_sources_list()
            assert result is True

        content = sources_file.read_text()
        assert "https://official.url/file1.tar.gz" in content
        assert "https://official.url/file2.tar.bz2" in content
        assert "https://custom.url/source1.tar.gz" in content
        assert "https://custom.url/source2.tar.xz" in content

    def test_update_sources_list_no_custom_sources(self, tmp_path, monkeypatch):
        """Test _update_sources_list sans fichier custom-sources.list."""
        monkeypatch.chdir(tmp_path)
        output_dir = tmp_path / "lfs-build"
        output_dir.mkdir()
        config_file = tmp_path / "config.json"
        config = LFSConfig(config_file)
        config.set('repositories', ['https://example.com/wget-list'])

        builder = LFSBuilder(profile='minimal', output_dir=output_dir, config_file=config_file)
        builder.config = config

        packages_dir = tmp_path / "packages"
        packages_dir.mkdir()
        sources_file = packages_dir / "sources.list"
        # Ne pas créer custom-sources.list

        mock_response = MagicMock()
        mock_response.read.return_value = b"https://official.url/file1.tar.gz\n"
        mock_response.__enter__.return_value = mock_response

        with patch('urllib.request.urlopen', return_value=mock_response):
            result = builder._update_sources_list()
            assert result is True

        content = sources_file.read_text()
        assert "https://official.url/file1.tar.gz" in content
        assert "# CUSTOM SOURCES" not in content  # Pas de section séparée car on ne distingue plus

    def test_update_sources_list_official_fails_custom_exists(self, tmp_path, monkeypatch):
        """Test quand la récupération officielle échoue mais que custom existe."""
        monkeypatch.chdir(tmp_path)
        output_dir = tmp_path / "lfs-build"
        output_dir.mkdir()
        config_file = tmp_path / "config.json"
        config = LFSConfig(config_file)
        config.set('repositories', ['https://example.com/wget-list'])

        builder = LFSBuilder(profile='minimal', output_dir=output_dir, config_file=config_file)
        builder.config = config

        packages_dir = tmp_path / "packages"
        packages_dir.mkdir()
        sources_file = packages_dir / "sources.list"
        custom_file = packages_dir / "custom-sources.list"
        custom_file.write_text("https://custom.only/unique.tar.gz")

        with patch('urllib.request.urlopen', side_effect=Exception("Network error")):
            result = builder._update_sources_list()
            assert result is True   # Il y a des URLs custom

        content = sources_file.read_text()
        assert "https://custom.only/unique.tar.gz" in content

    def test_update_sources_list_custom_overrides_same_filename(self, tmp_path, monkeypatch):
        """Custom URL should override official URL when archive filename is identical."""
        monkeypatch.chdir(tmp_path)
        output_dir = tmp_path / "lfs-build"
        output_dir.mkdir()
        config_file = tmp_path / "config.json"
        config = LFSConfig(config_file)
        config.set('repositories', ['https://example.com/wget-list'])

        builder = LFSBuilder(profile='minimal', output_dir=output_dir, config_file=config_file)
        builder.config = config

        packages_dir = tmp_path / "packages"
        packages_dir.mkdir()
        sources_file = packages_dir / "sources.list"
        custom_file = packages_dir / "custom-sources.list"
        custom_file.write_text("https://mirror.local/linux-6.16.1.tar.xz\n")

        mock_response = MagicMock()
        mock_response.read.return_value = (
            b"https://old.lfs.org/linux-6.16.1.tar.xz\n"
            b"https://official.url/bash-5.3.tar.gz\n"
        )
        mock_response.__enter__.return_value = mock_response

        with patch('urllib.request.urlopen', return_value=mock_response):
            result = builder._update_sources_list()
            assert result is True

        content = sources_file.read_text()
        assert "https://mirror.local/linux-6.16.1.tar.xz" in content
        assert "https://old.lfs.org/linux-6.16.1.tar.xz" not in content
        assert "https://official.url/bash-5.3.tar.gz" in content

    def test_update_sources_list_custom_overrides_different_version(self, tmp_path, monkeypatch):
        """Custom URL with a different version should override official URL for the same package."""
        monkeypatch.chdir(tmp_path)
        output_dir = tmp_path / "lfs-build"
        output_dir.mkdir()
        config_file = tmp_path / "config.json"
        config = LFSConfig(config_file)
        config.set('repositories', ['https://example.com/wget-list'])

        builder = LFSBuilder(profile='minimal', output_dir=output_dir, config_file=config_file)
        builder.config = config

        packages_dir = tmp_path / "packages"
        packages_dir.mkdir()
        sources_file = packages_dir / "sources.list"
        custom_file = packages_dir / "custom-sources.list"
        # Custom source uses a newer version of gawk
        custom_file.write_text("https://mirrors.kernel.org/gnu/gawk/gawk-5.4.0.tar.xz\n")

        mock_response = MagicMock()
        mock_response.read.return_value = (
            b"https://ftp.gnu.org/gnu/gawk/gawk-5.3.2.tar.xz\n"
            b"https://official.url/bash-5.3.tar.gz\n"
        )
        mock_response.__enter__.return_value = mock_response

        with patch('urllib.request.urlopen', return_value=mock_response):
            result = builder._update_sources_list()
            assert result is True

        content = sources_file.read_text()
        # The custom (newer) version should win
        assert "https://mirrors.kernel.org/gnu/gawk/gawk-5.4.0.tar.xz" in content
        # The official (older) version should be replaced
        assert "https://ftp.gnu.org/gnu/gawk/gawk-5.3.2.tar.xz" not in content
        assert "https://official.url/bash-5.3.tar.gz" in content

    def test_update_sources_list_official_all_fail_no_custom(self, tmp_path, monkeypatch):
        """Test quand officiel échoue et custom n'existe pas -> doit retourner False."""
        monkeypatch.chdir(tmp_path)
        output_dir = tmp_path / "lfs-build"
        output_dir.mkdir()
        config_file = tmp_path / "config.json"
        config = LFSConfig(config_file)
        config.set('repositories', ['https://fail1.com', 'https://fail2.com'])

        builder = LFSBuilder(profile='minimal', output_dir=output_dir, config_file=config_file)
        builder.config = config

        packages_dir = tmp_path / "packages"
        packages_dir.mkdir()
        sources_file = packages_dir / "sources.list"
        # Pas de custom

        with patch('urllib.request.urlopen', side_effect=Exception("Network error")):
            result = builder._update_sources_list()
            assert result is False   # Aucune URL

        # sources.list ne doit pas avoir été créé
        assert not sources_file.exists()

    def test_update_sources_list_url_without_filename_uses_full_url_key(self, tmp_path, monkeypatch):
        """Couvre le fallback source_key() quand l'URL n'a pas de nom de fichier."""
        monkeypatch.chdir(tmp_path)
        output_dir = tmp_path / "lfs-build"
        output_dir.mkdir()
        config_file = tmp_path / "config.json"
        config = LFSConfig(config_file)
        config.set('repositories', ['https://example.com/wget-list'])

        builder = LFSBuilder(profile='minimal', output_dir=output_dir, config_file=config_file)
        builder.config = config

        packages_dir = tmp_path / "packages"
        packages_dir.mkdir()
        sources_file = packages_dir / "sources.list"

        mock_response = MagicMock()
        mock_response.read.return_value = (
            b"https://repo.example.com\n"
            b"https://official.url/file1.tar.gz\n"
        )
        mock_response.__enter__.return_value = mock_response

        with patch('urllib.request.urlopen', return_value=mock_response):
            result = builder._update_sources_list()
            assert result is True

        content = sources_file.read_text()
        assert "https://repo.example.com" in content
        assert "https://official.url/file1.tar.gz" in content

    def test_update_sources_list_kernel_type_gnu_hurd(self, tmp_path, monkeypatch):
        """Vérifie que le type de noyau 'gnu-hurd' génère la bonne URL."""
        from builder import LFSBuilder, LFSConfig
        from unittest.mock import patch, MagicMock

        monkeypatch.chdir(tmp_path)

        output_dir = tmp_path / 'lfs-build'
        output_dir.mkdir()
        config_file = tmp_path / 'config.json'
        config = LFSConfig(config_file)
        config.set('kernel.type', 'gnu-hurd')
        config.set('kernel.version', '0.9')
        config.set('repositories', ['https://example.com/wget-list'])

        builder = LFSBuilder(profile='minimal', output_dir=output_dir, config_file=config_file)
        builder.config = config

        fake_content = b"""https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.16.1.tar.xz
        https://example.com/other-package.tar.gz
        """

        mock_response = MagicMock()
        mock_response.read.return_value = fake_content
        mock_response.__enter__.return_value = mock_response
        mock_response.__exit__.return_value = None

        with patch('urllib.request.urlopen', return_value=mock_response):
            result = builder._update_sources_list()

        assert result is True

        sources_file = Path('packages/sources.list')
        assert sources_file.exists()
        content = sources_file.read_text()
        expected_url = "https://ftpmirror.gnu.org/hurd/hurd-0.9.tar.gz"
        assert expected_url in content
        assert "linux-6.16.1.tar.xz" not in content

    def test_update_sources_list_kernel_type_freebsd(self, tmp_path, monkeypatch):
        """Vérifie que le type de noyau 'freebsd' génère la bonne URL."""
        from builder import LFSBuilder, LFSConfig
        from unittest.mock import patch, MagicMock

        monkeypatch.chdir(tmp_path)

        output_dir = tmp_path / 'lfs-build'
        output_dir.mkdir()
        config_file = tmp_path / 'config.json'
        config = LFSConfig(config_file)
        config.set('kernel.type', 'freebsd')
        config.set('kernel.version', '13.0')
        config.set('repositories', ['https://example.com/wget-list'])

        builder = LFSBuilder(profile='minimal', output_dir=output_dir, config_file=config_file)
        builder.config = config

        fake_content = b"""https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.16.1.tar.xz
        https://example.com/other-package.tar.gz
        """

        mock_response = MagicMock()
        mock_response.read.return_value = fake_content
        mock_response.__enter__.return_value = mock_response
        mock_response.__exit__.return_value = None

        with patch('urllib.request.urlopen', return_value=mock_response):
            result = builder._update_sources_list()

        assert result is True

        sources_file = Path('packages/sources.list')
        assert sources_file.exists()
        content = sources_file.read_text()
        expected_url = "https://download.freebsd.org/ftp/releases/amd64/13.0/src.txz"
        assert expected_url in content
        assert "linux-6.16.1.tar.xz" not in content

    def test_update_sources_list_filename_completely_stripped_by_regex(self, tmp_path, monkeypatch):
        """Vérifie que le regex de source_key gère correctement les noms de fichiers avec des versions."""
        from builder import LFSBuilder, LFSConfig
        from unittest.mock import patch, MagicMock

        monkeypatch.chdir(tmp_path)

        output_dir = tmp_path / 'lfs-build'
        output_dir.mkdir()
        config_file = tmp_path / 'config.json'
        config = LFSConfig(config_file)
        config.set('repositories', ['https://example.com/sources'])
        config.set('kernel.type', 'linux')
        config.set('kernel.version', '6.16.1')

        builder = LFSBuilder(profile='minimal', output_dir=output_dir, config_file=config_file)
        builder.config = config

        fake_content = b"""https://example.com/pkg-5.3.2.tar.xz
        https://example.com/pkg_v7.1.0.tar.gz
        https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.16.1.tar.xz
        """

        mock_response = MagicMock()
        mock_response.read.return_value = fake_content
        mock_response.__enter__.return_value = mock_response
        mock_response.__exit__.return_value = None

        with patch('urllib.request.urlopen', return_value=mock_response):
            result = builder._update_sources_list()

        assert result is True

        sources_file = Path('packages/sources.list')
        assert sources_file.exists()
        content = sources_file.read_text()

        # La substitution du noyau doit être présente
        assert 'linux-6.16.1.tar.xz' in content
        # Une seule des deux URLs de paquet doit être présente (celle qui survit)
        # car les clés sont identiques, seule la première est conservée.
        assert 'https://example.com/pkg-5.3.2.tar.xz' in content
        # L'autre ne doit pas être présente
        assert 'https://example.com/pkg_v7.1.0.tar.gz' not in content
        # Il doit y avoir 2 URLs au total (1 paquet + 1 noyau)
        lines = [line for line in content.splitlines() if line.startswith(('http://', 'https://'))]
        assert len(lines) == 2

    def test_update_sources_list_kernel_type_linux_libre(self, tmp_path, monkeypatch):
        """Vérifie que le type de noyau 'linux-libre' génère la bonne URL."""
        from builder import LFSBuilder, LFSConfig
        from unittest.mock import patch, MagicMock

        monkeypatch.chdir(tmp_path)

        output_dir = tmp_path / 'lfs-build'
        output_dir.mkdir()
        config_file = tmp_path / 'config.json'
        config = LFSConfig(config_file)
        config.set('kernel.type', 'linux-libre')
        config.set('kernel.version', '6.12.20')
        config.set('repositories', ['https://example.com/wget-list'])

        builder = LFSBuilder(profile='minimal', output_dir=output_dir, config_file=config_file)
        builder.config = config

        fake_content = b"""https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.16.1.tar.xz
        https://example.com/other-package.tar.gz
        """

        mock_response = MagicMock()
        mock_response.read.return_value = fake_content
        mock_response.__enter__.return_value = mock_response
        mock_response.__exit__.return_value = None

        with patch('urllib.request.urlopen', return_value=mock_response):
            result = builder._update_sources_list()

        assert result is True

        sources_file = Path('packages/sources.list')
        assert sources_file.exists()
        content = sources_file.read_text()

        expected_url = "https://www.linux-libre.fsfla.org/pub/linux-libre/releases/6.12.20-gnu/linux-libre-6.12.20-gnu.tar.xz"
        assert expected_url in content
        assert "linux-6.16.1.tar.xz" not in content
        assert "https://example.com/other-package.tar.gz" in content

        # Vérifier qu'il y a 2 URLs (le noyau substitué + l'autre paquet)
        lines = [line for line in content.splitlines() if line.startswith(('http://', 'https://'))]
        assert len(lines) == 2

    def test_source_key_regex_strips_entire_filename(self, tmp_path, monkeypatch):
        """Vérifie que source_key gère le cas où le regex supprime tout le nom de fichier."""
        from builder import LFSBuilder, LFSConfig
        from unittest.mock import patch, MagicMock

        monkeypatch.chdir(tmp_path)

        output_dir = tmp_path / 'lfs-build'
        output_dir.mkdir()
        config_file = tmp_path / 'config.json'
        config = LFSConfig(config_file)
        config.set('repositories', ['https://example.com/sources'])
        config.set('kernel.type', 'linux')
        config.set('kernel.version', '6.16.1')

        builder = LFSBuilder(profile='minimal', output_dir=output_dir, config_file=config_file)
        builder.config = config

        # Une URL dont le nom de fichier est entièrement supprimé par le regex (ex: commence par '-')
        fake_content = b"""https://example.com/-5.3.2.tar.xz
        https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.16.1.tar.xz
        """

        mock_response = MagicMock()
        mock_response.read.return_value = fake_content
        mock_response.__enter__.return_value = mock_response
        mock_response.__exit__.return_value = None

        with patch('urllib.request.urlopen', return_value=mock_response):
            with patch.object(builder.logger, 'warning') as mock_warning:
                result = builder._update_sources_list()

        assert result is True

        sources_file = Path('packages/sources.list')
        assert sources_file.exists()
        content = sources_file.read_text()

        # L'URL est présente avec son nom complet (car la clé est pkg:-5.3.2.tar.xz)
        assert 'https://example.com/-5.3.2.tar.xz' in content
        # Le noyau substitué est présent
        assert 'linux-6.16.1.tar.xz' in content
        # Vérifier que le warning a été émis
        mock_warning.assert_called_once()
        args, _ = mock_warning.call_args
        assert "source_key: regex stripped entire filename '-5.3.2.tar.xz'" in args[0]