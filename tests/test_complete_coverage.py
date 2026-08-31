#!/usr/bin/env python3
"""
Complete coverage tests for 100% code coverage
Tests all uncovered paths from the coverage report
"""

import pytest
import tempfile
import json
import os
import sys
import logging
from pathlib import Path
from unittest.mock import patch, MagicMock, mock_open, call
import subprocess

# Import all classes
sys.path.insert(0, str(Path(__file__).parent.parent))
from builder import (
    LFSConfig, ProfileManager, SourceDownloader, ScriptExecutor,
    USBWriter, LFSBuilder, clean_build_directory, create_parser, main
)


class TestLFSConfigStringPath:
    """Test LFSConfig with string path conversion"""

    def test_config_file_string_conversion_to_path(self, tmp_path):
        """Test that string config_file is converted to Path (line 83)"""
        config_file = str(tmp_path / "test.conf")
        config = LFSConfig(config_file)
        assert isinstance(config.config_file, Path)
        assert config.config_file == Path(config_file)


class TestSourceDownloaderCoverage:
    """Test SourceDownloader uncovered paths"""

    def test_download_all_retries_fail_return_false(self, tmp_path):
        """Test download returns False after all retries fail (line 490)"""
        logger = logging.getLogger('test')
        downloader = SourceDownloader(tmp_path, logger)

        with patch('urllib.request.urlretrieve', side_effect=Exception("Download failed")):
            result = downloader.download("http://invalid.url/file.tar.gz", retries=2)
            assert result is False

    def test_download_from_list_some_fail(self, tmp_path):
        """Test download_from_list when some downloads fail (line 528)"""
        logger = logging.getLogger('test')
        downloader = SourceDownloader(tmp_path, logger)

        # Create a sources list file
        list_file = tmp_path / "sources.list"
        list_file.write_text("http://example.com/file1.tar.gz\nhttp://example.com/file2.tar.gz")

        def mock_download(url, filename=None, retries=3):
            # First succeeds, second fails
            return "file1" in url

        with patch.object(downloader, 'download', side_effect=mock_download):
            result = downloader.download_from_list(list_file, parallel=1)
            assert result is False  # Some failed

    def test_verify_checksums_invalid_format(self, tmp_path):
        """Test verify_checksums with invalid line format (line 543)"""
        logger = logging.getLogger('test')
        downloader = SourceDownloader(tmp_path, logger)

        # Create checksum file with invalid format
        checksum_file = tmp_path / "md5sums"
        checksum_file.write_text("onlyonepart\n")

        result = downloader.verify_checksums(checksum_file)
        assert result is True  # Should continue with invalid lines


class TestScriptExecutorCoverage:
    """Test ScriptExecutor uncovered paths"""

    def test_find_script_no_prefix_exists(self, tmp_path):
        """Test find_script when base filename exists (line 591)"""
        logger = logging.getLogger('test')
        env = {}
        executor = ScriptExecutor(env, tmp_path, logger)

        # Create a script with just the base name in current directory
        script_file = Path("test_script.sh")
        script_file.write_text("#!/bin/bash\necho test")
        script_file.chmod(0o755)

        try:
            result = executor.find_script("test_script.sh")
            # May or may not find it depending on working directory
        finally:
            # Cleanup
            if script_file.exists():
                script_file.unlink()

    def test_run_script_not_found(self, tmp_path):
        """Test run_script when script is not found (line 601-602)"""
        logger = logging.getLogger('test')
        env = {}
        executor = ScriptExecutor(env, tmp_path, logger)

        result = executor.run_script("nonexistent.sh", "test-stage")
        assert result is False

    def test_run_script_logs_last_lines_on_failure(self, tmp_path):
        """Test run_script logs last 10 lines on failure (line 634)"""
        logger = logging.getLogger('test')
        env = {}
        output_dir = tmp_path / "output"
        output_dir.mkdir()
        executor = ScriptExecutor(env, output_dir, logger)

        # Create a failing script
        script_file = tmp_path / "failing.sh"
        script_file.write_text("#!/bin/bash\nexit 1")
        script_file.chmod(0o755)

        with patch('subprocess.run', return_value=MagicMock(returncode=1)):
            result = executor.run_script(str(script_file), "test-stage")
            assert result is False

class TestLFSBuilderCoverage:
    """Test LFSBuilder uncovered paths"""

    def test_check_prerequisites_unsupported_os(self, tmp_path):
        """Test check_prerequisites with unsupported OS (line 916-917)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("minimal", tmp_path, config_file)

        with patch('platform.system', return_value='SunOS'):
            result = builder.check_prerequisites()
            assert result is False

    def test_check_prerequisites_missing_commands(self, tmp_path):
        """Test check_prerequisites with missing commands (line 925-928)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("minimal", tmp_path, config_file)

        with patch('platform.system', return_value='Linux'):
            with patch('shutil.which', return_value=None):
                result = builder.check_prerequisites()
                assert result is False

    def test_check_prerequisites_low_disk_space(self, tmp_path):
        """Test check_prerequisites warning for low disk space (line 930-935)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")
        builder = LFSBuilder("minimal", tmp_path, config_file)

        with patch('platform.system', return_value='Linux'):
            with patch('shutil.which', return_value='/usr/bin/gcc'):
                with patch('shutil.disk_usage', return_value=MagicMock(free=10*1024**3)):
                    with patch.object(builder, 'ensure_lfs_user', return_value=True):
                        result = builder.check_prerequisites()
                        assert result is True  # Should still pass with warning

    def test_download_sources_failure(self, tmp_path):
        """Test download_sources when sources file not found (line 1000-1008)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("minimal", tmp_path, config_file)

        with patch('pathlib.Path.exists', return_value=False):
            result = builder.download_sources()
            assert result is False

    def test_build_detailed_flow(self, tmp_path):
        """Test build method detailed flow (line 1089-1129)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("minimal", tmp_path, config_file)

        # Mock executor to succeed
        with patch.object(builder.executor, 'run_script', return_value=True):
            result = builder.build()
            assert result is True

    def test_create_writable_media_no_iso(self, tmp_path):
        """Test create_writable_media when ISO doesn't exist (line 1135-1137)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("minimal", tmp_path, config_file)

        result = builder.create_writable_media()
        assert result is False

    def test_create_writable_media_no_device_list_devices(self, tmp_path):
        """Test create_writable_media lists devices when no device specified (line 1142-1152)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("minimal", tmp_path, config_file)

        # Create fake ISO with dynamic name
        iso_file = tmp_path / builder.get_iso_name()
        iso_file.write_text("fake iso")

        with patch.object(USBWriter, 'list_devices', return_value=[]):
            result = builder.create_writable_media()
            assert result is True


class TestCleanBuildDirectory:
    """Test clean_build_directory function"""

    def test_clean_build_directory_not_exists(self, tmp_path):
        """Test clean_build_directory when directory doesn't exist (line 1248-1249)"""
        logger = logging.getLogger('test')
        result = clean_build_directory(tmp_path / "nonexistent", logger)
        assert result is True

    def test_clean_build_directory_cancelled(self, tmp_path):
        """Test clean_build_directory when user cancels (line 1262-1263)"""
        logger = logging.getLogger('test')
        tmp_path.mkdir(exist_ok=True)

        with patch('builtins.input', return_value='no'):
            result = clean_build_directory(tmp_path, logger)
            assert result is False

    def test_clean_build_directory_confirmed(self, tmp_path):
        """Test clean_build_directory when user confirms deletion"""
        logger = logging.getLogger('test')
        test_dir = tmp_path / "build_test"
        test_dir.mkdir()
        (test_dir / "file.txt").write_text("test")

        with patch('builtins.input', return_value='yes'):
            result = clean_build_directory(test_dir, logger)
            assert result is True
            assert not test_dir.exists()


class TestMainCLI:
    """Test main CLI functionality"""

    def test_main_init_system_override(self, tmp_path):
        """Test main with --init override (line 1307-1308)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        with patch('sys.argv', ['builder.py', '--profile', 'minimal', '--output', str(tmp_path),
                                '--config', str(config_file), '--init', 'systemd',
                                '--verbose']):
            with patch.object(LFSBuilder, 'check_prerequisites', return_value=True):
                with patch.object(LFSBuilder, 'prepare_environment', return_value=True):
                    with patch.object(LFSBuilder, 'download_sources', return_value=True):
                        with patch.object(LFSBuilder, 'build', return_value=True):
                            main()

    def test_main_no_live_flag(self, tmp_path):
        """Test main with --no-live flag (line 1310-1312)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        with patch('sys.argv', ['builder.py', '--profile', 'minimal', '--output', str(tmp_path),
                                '--config', str(config_file), '--no-live']):
            with patch.object(LFSBuilder, 'check_prerequisites', return_value=True):
                with patch.object(LFSBuilder, 'prepare_environment', return_value=True):
                    with patch.object(LFSBuilder, 'download_sources', return_value=True):
                        with patch.object(LFSBuilder, 'build', return_value=True):
                            main()

    def test_main_list_profiles(self, capsys):
        """Test main with --list-profiles flag"""
        with patch('sys.argv', ['builder.py', '--list-profiles']):
            main()
            captured = capsys.readouterr()
            assert "Available LFS Build Profiles" in captured.out

    def test_main_profile_info(self, capsys):
        """Test main with --profile-info flag"""
        with patch('sys.argv', ['builder.py', '--profile-info', 'minimal']):
            main()
            captured = capsys.readouterr()
            assert "Profile: MINIMAL" in captured.out

    def test_main_clean(self, tmp_path):
        """Test main with --clean flag"""
        build_dir = tmp_path / "build"
        build_dir.mkdir()

        with patch('sys.argv', ['builder.py', '--clean', '--output', str(build_dir)]):
            with patch('builtins.input', return_value='yes'):
                main()

    def test_main_write_usb(self, tmp_path):
        """Test main with --write-usb flag"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")
        builder = LFSBuilder("minimal", tmp_path, config_file)
        iso_file = tmp_path / builder.get_iso_name()
        iso_file.write_text("fake")

        with patch('sys.argv', ['builder.py', '--profile', 'minimal', '--output', str(tmp_path),
                                '--config', str(config_file), '--write-usb', '/dev/sdb']):
            with patch.object(LFSBuilder, 'check_prerequisites', return_value=True):
                with patch.object(LFSBuilder, 'prepare_environment', return_value=True):
                    with patch.object(LFSBuilder, 'download_sources', return_value=True):
                        with patch.object(LFSBuilder, 'build', return_value=True):
                            with patch.object(LFSBuilder, 'create_writable_media'):
                                main()

    def test_main_build_failure_at_prerequisites(self, tmp_path):
        """Test main when check_prerequisites fails (line 1330-1331)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        with patch('sys.argv', ['builder.py', '--profile', 'minimal', '--output', str(tmp_path),
                                '--config', str(config_file)]):
            with patch.object(LFSBuilder, 'check_prerequisites', return_value=False):
                with pytest.raises(SystemExit):
                    main()

    def test_main_build_failure_at_prepare_environment(self, tmp_path):
        """Test main when prepare_environment fails (line 1333-1334)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        with patch('sys.argv', ['builder.py', '--profile', 'minimal', '--output', str(tmp_path),
                                '--config', str(config_file)]):
            with patch.object(LFSBuilder, 'check_prerequisites', return_value=True):
                with patch.object(LFSBuilder, 'prepare_environment', return_value=False):
                    with pytest.raises(SystemExit):
                        main()

    def test_main_build_failure_at_download_sources(self, tmp_path):
        """Test main when download_sources fails (line 1336-1338)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        with patch('sys.argv', ['builder.py', '--profile', 'minimal', '--output', str(tmp_path),
                                '--config', str(config_file)]):
            with patch.object(LFSBuilder, 'check_prerequisites', return_value=True):
                with patch.object(LFSBuilder, 'prepare_environment', return_value=True):
                    with patch.object(LFSBuilder, 'download_sources', return_value=False):
                        with pytest.raises(SystemExit):
                            main()

    def test_main_build_failure_at_build(self, tmp_path):
        """Test main when build fails (line 1340-1341)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        with patch('sys.argv', ['builder.py', '--profile', 'minimal', '--output', str(tmp_path),
                                '--config', str(config_file)]):
            with patch.object(LFSBuilder, 'check_prerequisites', return_value=True):
                with patch.object(LFSBuilder, 'prepare_environment', return_value=True):
                    with patch.object(LFSBuilder, 'download_sources', return_value=True):
                        with patch.object(LFSBuilder, 'build', return_value=False):
                            with pytest.raises(SystemExit):
                                main()


class TestScriptExecutorResumeFrom:
    """Test ScriptExecutor resume_from method"""

    def test_resume_from_stage_not_found(self, tmp_path):
        """Test resume_from when stage is not found (incomplete search)"""
        logger = logging.getLogger('test')
        env = {}
        executor = ScriptExecutor(env, tmp_path, logger)

        stages = [
            ('stage1', 'script1.sh'),
            ('stage2', 'script2.sh'),
        ]

        with patch.object(executor, 'run_script', return_value=True):
            result = executor.resume_from('nonexistent', stages)
            # Should start from the beginning since stage not found
            assert executor.run_script.called


class TestCrossCompileEnvironment:
    """Test cross-compilation environment setup"""

    def test_cross_compile_check_prerequisites(self, tmp_path):
        """Test check_prerequisites with cross-compilation enabled"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("arm64", tmp_path, config_file)

        with patch('platform.system', return_value='Linux'):
            with patch('shutil.which') as mock_which:
                mock_which.side_effect = lambda x: '/usr/bin/test' if 'gcc' in x else None
                result = builder.check_prerequisites()


class TestPrepareEnvironmentCrossCompile:
    """Test prepare_environment with cross-compilation"""

    def test_prepare_environment_creates_sysroot(self, tmp_path):
        """Test prepare_environment creates sysroot for cross-compile"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("arm64", tmp_path, config_file)
        result = builder.prepare_environment()

        assert result is True
        sysroot = tmp_path / f"sysroot/{builder.get_target_architecture()}"
        assert sysroot.exists()


class TestDownloadSourcesWithChecksums:
    """Test download_sources with checksum verification"""

    def test_download_sources_with_checksum_file(self, tmp_path):
        """Test download_sources when checksum file exists"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        # Create sources.list
        sources_list = tmp_path / 'packages' / 'sources.list'
        sources_list.parent.mkdir(parents=True)
        sources_list.write_text("http://example.com/file.tar.gz")

        # Create checksum file
        checksum_file = tmp_path / 'packages' / 'md5sums'
        checksum_file.write_text("abc123 file.tar.gz")

        builder = LFSBuilder("minimal", tmp_path, config_file)

        with patch.object(builder.downloader, 'download_from_list', return_value=True):
            with patch.object(builder.downloader, 'verify_checksums', return_value=True):
                result = builder.download_sources()
                assert result is True


class TestBuildWithResumeFrom:
    """Test build method with resume_from parameter"""

    def test_build_resume_from_stage(self, tmp_path):
        """Test build with resume_from parameter"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("minimal", tmp_path, config_file)

        with patch.object(builder.executor, 'resume_from', return_value=True):
            result = builder.build(resume_from='toolchain')
            assert result is True
            builder.executor.resume_from.assert_called_once()


class TestGetEnvironmentVariables:
    """Test environment variable generation"""

    def test_get_env_cross_compile(self, tmp_path):
        """Test _get_env with cross-compilation"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("arm64", tmp_path, config_file)
        env = builder._get_env()

        assert 'CROSS_COMPILE' in env
        assert env['CROSS_COMPILE'] == '/usr/bin/aarch64-linux-gnu-'
        assert 'ARCH' in env
        assert env['ARCH'] == 'aarch64'


class TestGetInitSystem:
    """Test get_init_system method"""

    def test_get_init_system_normalize_sysv(self, tmp_path):
        """Test get_init_system normalizes 'sysv' to 'sysvinit'"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("minimal", tmp_path, config_file)
        builder.config.set('init_system.choice', 'sysv')

        init = builder.get_init_system()
        assert init == 'sysvinit'

    def test_get_init_system_unknown_defaults_to_sysvinit(self, tmp_path):
        """Test get_init_system with unknown choice defaults to sysvinit"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("minimal", tmp_path, config_file)
        builder.config.set('init_system.choice', 'unknown_init')

        init = builder.get_init_system()
        assert init == 'sysvinit'


class TestUSBWriterCrossCompile:
    """Test USB writer with cross-compilation warning"""

    def test_write_iso_cancelled_by_user(self, tmp_path):
        """Test write_iso when user cancels (line 705-707)"""
        logger = logging.getLogger('test')
        iso_file = tmp_path / "test.iso"
        iso_file.write_text("FAKE ISO")

        with patch('builtins.input', return_value='NO'):
            result = USBWriter.write_iso(iso_file, "/dev/sdb", logger)
            assert result is False


class TestLFSBuilderBuildInfo:
    """Test LFSBuilder prepare_environment creates build_info"""

    def test_prepare_environment_builds_info_file(self, tmp_path):
        """Test prepare_environment creates build_info.json"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("minimal", tmp_path, config_file)
        result = builder.prepare_environment()

        assert result is True
        build_info_file = tmp_path / 'build_info.json'
        assert build_info_file.exists()

        with open(build_info_file) as f:
            data = json.load(f)
            assert data['profile'] == 'minimal'


class TestCreateParser:
    """Test argument parser creation"""

    def test_create_parser_returns_parser(self):
        """Test create_parser returns ArgumentParser"""
        parser = create_parser()
        assert parser is not None
        assert hasattr(parser, 'parse_args')


class TestLFSBuilderMissingISO:
    """Test LFSBuilder.build with missing ISO file"""

    def test_build_missing_iso_no_output(self, tmp_path):
        """Test build output when ISO creation failed"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        builder = LFSBuilder("minimal", tmp_path, config_file)

        with patch.object(builder.executor, 'run_script', return_value=True):
            result = builder.build()
            # Should still return True even if ISO not created
            assert result is True

    def test_main_use_cache_flag(self, capsys):
        with patch('sys.argv', ['builder.py', '--profile', 'minimal', '--use-cache']):
            with patch('builder.LFSBuilder') as MockBuilder:
                mock_instance = MockBuilder.return_value
                mock_instance.check_prerequisites.return_value = True
                mock_instance.prepare_environment.return_value = True
                mock_instance.download_sources.return_value = True
                mock_instance.build.return_value = True
                main()
                # assert that build was called with use_cache=True
                mock_instance.build.assert_called_once_with(resume_from=None, use_cache=True, cache_only=False)

    def test_main_cache_only_flag(self, capsys):
        with patch('sys.argv', ['builder.py', '--profile', 'minimal', '--use-cache', '--cache-only']):
            with patch('builder.LFSBuilder') as MockBuilder:
                mock_instance = MockBuilder.return_value
                mock_instance.check_prerequisites.return_value = True
                mock_instance.prepare_environment.return_value = True
                mock_instance.download_sources.return_value = True
                mock_instance.build.return_value = True
                main()
                mock_instance.build.assert_called_once_with(resume_from=None, use_cache=True, cache_only=True)

    def test_main_cache_url_flag(self, capsys):
        url = "https://my-custom/metadata.json"
        with patch('sys.argv', ['builder.py', '--profile', 'minimal', '--cache-url', url]):
            with patch('builder.LFSBuilder') as MockBuilder:
                mock_instance = MockBuilder.return_value
                mock_instance.check_prerequisites.return_value = True
                mock_instance.prepare_environment.return_value = True
                mock_instance.download_sources.return_value = True
                mock_instance.build.return_value = True
                main()
                # Verify that the builder was created with the cache_url
                MockBuilder.assert_called_once_with(
                    profile='minimal',
                    output_dir='./lfs-build',
                    config_file='config/build.conf',
                    cache_url='https://my-custom/metadata.json',
                    download_timeout=None,
                    download_retries=None,
                    milestone=None,
                    stage_timeout=None,
                    nightly=False,
                    skip_man_pages=False
                )